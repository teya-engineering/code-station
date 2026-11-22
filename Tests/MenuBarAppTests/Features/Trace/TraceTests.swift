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

    // q (0-1000) calls check fourteen times side by side, then a lone save; one check fails.
    static let checks: Trace = {
        var spans = [span("q", start: 0, duration: 1_000)]
        for index in 0..<14 {
            let check = Trace.Span(id: "c\(index)", parentID: "q", service: "authz",
                                   operation: "DispatchCheck", kind: "client",
                                   startNanos: 500 + Int64(index), durationNanos: 2,
                                   isError: index == 3, statusMessage: index == 3 ? "cancelled" : nil,
                                   attributes: [], resourceAttributes: [], events: [])
            spans.append(check)
        }
        spans.append(span("s", parent: "q", start: 900, duration: 50))
        return Trace(traceID: "t", spans: spans)
    }()

    @Test func foldsARunOfAlikeSpansIntoOneRow() throws {
        let rows = Self.checks.displayRows(collapsed: [])
        #expect(rows.map(\.id) == ["q", "g:q:authz:DispatchCheck", "s"])
        guard case .group(let group) = rows[1] else {
            Issue.record("not grouped"); return
        }
        #expect(group.spans.count == 14)
        #expect(group.depth == 1)
        #expect(group.failures.map(\.id) == ["c3"])
        #expect(group.startNanos == 500)
        #expect(group.endNanos == 515)

        let listed = Self.checks.displayRows(collapsed: [], openGroups: [group.key])
        #expect(listed.count == 16)
    }

    @Test func twoAlikeSpansStayApart() {
        let pair = Trace(traceID: "t", spans: [
            Self.span("r", start: 0, duration: 100),
            Self.span("a", parent: "r", start: 1, duration: 1),
            Self.span("b", parent: "r", start: 2, duration: 1),
        ].map { span in
            Trace.Span(id: span.id, parentID: span.parentID, service: span.service,
                       operation: span.parentID == nil ? "root" : "same", kind: span.kind,
                       startNanos: span.startNanos, durationNanos: span.durationNanos,
                       isError: false, statusMessage: nil, attributes: [],
                       resourceAttributes: [], events: [])
        })
        #expect(pair.displayRows(collapsed: []).map(\.id) == ["r", "a", "b"])
    }

    // The failed view keeps each failure and the callers above it, and nothing else.
    @Test func keepsTheWayDownToEachFailure() {
        #expect(Self.tree.failurePath == ["r", "b"])
        let rows = Self.tree.displayRows(collapsed: [], keep: Self.tree.failurePath)
        #expect(rows.map(\.id) == ["r", "b"])
        #expect(Self.tree.failuresBelow["r"] == 1)
        #expect(Self.tree.failuresBelow["a"] == 0)
    }

    // A zoom keeps the spans that run inside it, and the callers that lead to them.
    @Test func zoomingHidesTheSpansOutsideTheWindow() {
        let rows = Self.tree.displayRows(collapsed: [], window: 14...22)
        #expect(rows.map(\.id) == ["r", "a", "c"])
        #expect(Self.tree.spanCount(in: 14...22) == 3)
    }

    @Test func aZoomStaysInsideTheTrace() {
        #expect(Self.tree.zoomWindow(-50, 200) == nil)
        #expect(Self.tree.zoomWindow(60, 20) == 20...60)
        let around = Self.checks.zoomWindow(around: Self.checks.span("s")!)
        #expect(around?.lowerBound ?? 0 < 900)
        #expect(around?.upperBound ?? 0 > 950)
    }

    // What ran below a span, as merged stretches, and each service's own time.
    @Test func measuresWorkBelowAndOwnTime() {
        #expect(Self.tree.busy["r"] == [10...30, 50...100])
        #expect(Self.tree.busyNanos(Self.tree.span("r")!) == 70)
        // api: r has 30 of its own, a has 15, o has 1.
        #expect(Self.tree.ownTime == ["api": 46, "db": 5, "orders": 50])
        #expect(Self.tree.parentIDs["c"] == "a")
        #expect(Self.tree.childIDs["r"] == ["a", "b"])
    }

    @Test func splitsTheVerbOffAnOperation() {
        #expect(Trace.verb(of: "POST /v1/tokens") == ("POST", "/v1/tokens"))
        #expect(Trace.verb(of: "publish payments-topic") == ("PUBLISH", "payments-topic"))
        #expect(Trace.verb(of: "CheckPermission") == (nil, "CheckPermission"))
        #expect(Trace.verb(of: "Get user") == (nil, "Get user"))
        #expect(Trace.verb(of: "GET ") == (nil, "GET "))
    }

    @Test func marksAnAxisInRoundSteps() {
        let trace = Trace(traceID: "t", spans: [Self.span("r", start: 0, duration: 17_060_000_000)])
        let ticks = trace.ticks(in: trace.wholeWindow)
        #expect(ticks.step == 2_000_000_000)
        #expect(ticks.offsets.first == 0)
        #expect(ticks.offsets.last == 16_000_000_000)
        #expect(Trace.tickText(4_000_000_000, step: ticks.step) == "4 s")
        #expect(Trace.tickText(16_980_000_000, step: 20_000_000) == "16,980 ms")
        #expect(Trace.tickText(0, step: 1) == "0")
    }

    @Test func writesTimesForReadingOnTheirOwn() {
        #expect(Trace.spacedDuration(17_060_000_000) == "17.06 s")
        #expect(Trace.spacedDuration(900_000) == "900 µs")
        #expect(Trace.offsetText(16_980_000_000) == "+16,980 ms")
        #expect(Trace.offsetText(470_000_000) == "+470 ms")
    }
}
