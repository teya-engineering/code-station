import Testing
@testable import MenuBarApp

struct TraceCondenserTests {
    private static let ms: Int64 = 1_000_000

    private static func span(_ id: String, parent: String? = nil, service: String = "api",
                             start: Int64, duration: Int64, error: Bool = false) -> Trace.Span {
        TraceTests.span(id, parent: parent, service: service,
                        start: start * ms, duration: duration * ms, error: error)
    }

    @Test func writesASmallTraceInFull() {
        let trace = Trace(traceID: "abc", spans: [
            Self.span("r", service: "gateway", start: 0, duration: 100),
            Self.span("a", parent: "r", service: "orders", start: 10, duration: 80, error: true),
        ])
        let text = TraceCondenser.text(trace, environment: "Prod (prd)")
        #expect(text.contains("Trace abc in Prod (prd): 2 spans across 2 services, 100ms end to end, 1 failed."))
        #expect(text.contains("\n*  gateway op-r 100ms"))
        #expect(text.contains("\n  *! orders op-a 80ms - boom"))
        #expect(!text.contains("left out"))
    }

    @Test func keepsEveryFailureAndTheCriticalPathOfALargeTrace() {
        var spans = [Self.span("root", start: 0, duration: 5_000)]
        for index in 1..<2_000 {
            spans.append(Self.span("s\(index)", parent: "root", service: "svc\(index % 7)",
                                   start: Int64(index), duration: Int64(index % 50 + 1),
                                   error: index % 200 == 0))
        }
        let trace = Trace(traceID: "big", spans: spans)
        let kept = TraceCondenser.keptIDs(trace, cap: 300)
        #expect(kept.count <= 300)
        for index in stride(from: 200, to: 2_000, by: 200) {
            #expect(kept.contains("s\(index)"))
        }
        #expect(trace.criticalPath.isSubset(of: kept))

        let text = TraceCondenser.text(trace, environment: "dev")
        #expect(text.contains("op-s1800"))
        #expect(text.contains("spans left out"))
    }

    // A retry storm fails far more spans than the cap holds. The prompt stays bounded, and
    // the failures it cannot list are counted by service, operation and message instead.
    @Test func countsTheFailuresItCannotList() {
        var spans = [Self.span("root", start: 0, duration: 5_000)]
        for index in 1...1_200 {
            spans.append(Trace.Span(id: "s\(index)", parentID: "root", service: "orders",
                                    operation: "SELECT orders", kind: "client",
                                    startNanos: Int64(index) * Self.ms, durationNanos: 2 * Self.ms,
                                    isError: true, statusMessage: "timeout",
                                    attributes: [], resourceAttributes: [], events: []))
        }
        let trace = Trace(traceID: "storm", spans: spans)
        let kept = TraceCondenser.keptIDs(trace, cap: 300)
        #expect(kept.count <= 300)

        let lines = TraceCondenser.text(trace, environment: "dev").components(separatedBy: "\n")
        let listed = lines.filter { $0.contains("! orders SELECT orders") }.count
        #expect(listed == kept.count - 1)
        #expect(lines.contains("- \(1_200 - listed) × orders SELECT orders - timeout"))
        #expect(lines.count < 310)
    }
}
