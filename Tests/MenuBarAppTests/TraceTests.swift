import Testing
@testable import MenuBarApp

struct TraceTests {
    static func span(_ id: String, parent: String? = nil, service: String = "api",
                     start: Int64, duration: Int64, error: Bool = false) -> Trace.Span {
        Trace.Span(id: id, parentID: parent, service: service, operation: "op-\(id)",
                   kind: "internal", startNanos: start, durationNanos: duration,
                   isError: error, statusMessage: error ? "boom" : nil,
                   attributes: [], resourceAttributes: [], events: [])
    }

    // r (0-100) calls a (10-30) and b (50-100); a calls c (15-20); o names a parent the
    // trace does not hold.
    static let tree = Trace(traceID: "t", spans: [
        span("b", parent: "r", service: "orders", start: 50, duration: 50, error: true),
        span("c", parent: "a", service: "db", start: 15, duration: 5),
        span("r", start: 0, duration: 100),
        span("o", parent: "missing", start: 5, duration: 1),
        span("a", parent: "r", start: 10, duration: 20),
    ])

    @Test func ordersSpansUnderTheirCallersBySiblingStart() {
        #expect(Self.tree.rows.map(\.id) == ["r", "a", "c", "b", "o"])
        #expect(Self.tree.rows.map(\.depth) == [0, 1, 2, 1, 0])
        #expect(Self.tree.rows.map(\.hasChildren) == [true, true, false, false, false])
        #expect(Self.tree.rows.map(\.parentMissing) == [false, false, false, false, true])
    }

    @Test func readsTheTraceAsAWhole() {
        #expect(Self.tree.root?.id == "r")
        #expect(Self.tree.services == ["api", "db", "orders"])
        #expect(Self.tree.errorCount == 1)
        #expect(Self.tree.startNanos == 0)
        #expect(Self.tree.endNanos == 100)
        #expect(Self.tree.durationNanos == 100)
    }

    @Test func followsTheChildThatFinishesLastForTheCriticalPath() {
        #expect(Self.tree.criticalPath == ["r", "b"])
    }

    @Test func drawsEverySpanOnceWhateverItsParentsSay() {
        let trace = Trace(traceID: "t", spans: [
            Self.span("z", start: 0, duration: 10),
            Self.span("x", parent: "y", start: 1, duration: 1),
            Self.span("y", parent: "x", start: 2, duration: 1),
            Self.span("s", parent: "s", start: 3, duration: 1),
            Self.span("z", start: 50, duration: 50),
        ])
        #expect(trace.rows.map(\.id).sorted() == ["s", "x", "y", "z"])
        #expect(trace.rows.first { $0.id == "z" }?.span.durationNanos == 10)
    }

    @Test func foldingASpanHidesEverythingBeneathIt() {
        #expect(Self.tree.visibleRows(collapsed: ["a"]).map(\.id) == ["r", "a", "b", "o"])
        #expect(Self.tree.visibleRows(collapsed: ["r"]).map(\.id) == ["r", "o"])
        #expect(Self.tree.visibleRows(collapsed: []).count == 5)
    }

    @Test func placesBarsOnTheTracesOwnTimeAxis() {
        let root = Self.tree.bar(for: Self.tree.rows[0].span)
        #expect(root.offset == 0)
        #expect(root.width == 1)
        let b = Self.tree.bar(for: Self.tree.rows[3].span)
        #expect(b.offset == 0.5)
        #expect(b.width == 0.5)
        let instant = Self.tree.bar(for: Self.span("i", start: 40, duration: 0))
        #expect(instant.width >= 0.002)
    }

    @Test func writesDurationsWithAsFewDigitsAsTellSpansApart() {
        #expect(Trace.durationText(850_000) == "850µs")
        #expect(Trace.durationText(4_200_000) == "4.2ms")
        #expect(Trace.durationText(412_000_000) == "412ms")
        #expect(Trace.durationText(1_240_000_000) == "1.24s")
    }

    // A trace opens with its top spans and the way down to each failure unfolded, and
    // everything else with spans below it folded.
    @Test func opensWithTheWayDownToEachFailureUnfolded() {
        // r calls a (which calls c) and the failing b; o hangs from a parent not in the trace.
        #expect(Self.tree.initiallyFolded == ["a"])

        // r calls x, x calls y, y calls the failing z; r also calls w, which calls v.
        let deep = Trace(traceID: "t", spans: [
            Self.span("r", start: 0, duration: 100),
            Self.span("x", parent: "r", start: 1, duration: 50),
            Self.span("y", parent: "x", start: 2, duration: 40),
            Self.span("z", parent: "y", start: 3, duration: 10, error: true),
            Self.span("q", parent: "z", start: 4, duration: 1),
            Self.span("w", parent: "r", start: 60, duration: 30),
            Self.span("v", parent: "w", start: 61, duration: 5),
        ])
        #expect(deep.initiallyFolded == ["z", "w"])
    }

    @Test func aTraceWithNoFailuresOpensOnItsFirstTwoLevels() {
        let healthy = Trace(traceID: "t", spans: [
            Self.span("r", start: 0, duration: 100),
            Self.span("a", parent: "r", start: 10, duration: 20),
            Self.span("c", parent: "a", start: 15, duration: 5),
            Self.span("b", parent: "r", start: 50, duration: 50),
        ])
        #expect(healthy.initiallyFolded == ["a"])
        let failingRoot = Trace(traceID: "t", spans: [
            Self.span("r", start: 0, duration: 100, error: true),
            Self.span("a", parent: "r", start: 10, duration: 20),
            Self.span("c", parent: "a", start: 15, duration: 5),
        ])
        #expect(failingRoot.initiallyFolded == ["a"])
    }

    // What a fold hides, said on the folded row.
    @Test func countsTheSpansBelowEachSpan() {
        #expect(Self.tree.descendantCounts == ["r": 3, "a": 1, "c": 0, "b": 0, "o": 0])
    }

    // Spans whose callers are missing from the trace hang at the top. They fold like any
    // other unless a failure lies below them, so a patchy trace does not open them all.
    @Test func spansWhoseCallerIsMissingOpenFolded() {
        let patchy = Trace(traceID: "t", spans: [
            Self.span("r", start: 0, duration: 100),
            Self.span("a", parent: "r", start: 10, duration: 20),
            Self.span("o", parent: "gone", start: 30, duration: 10),
            Self.span("p", parent: "o", start: 31, duration: 5),
            Self.span("m", parent: "lost", start: 50, duration: 10),
            Self.span("n", parent: "m", start: 51, duration: 5, error: true),
        ])
        #expect(patchy.initiallyFolded == ["o"])
    }
}
