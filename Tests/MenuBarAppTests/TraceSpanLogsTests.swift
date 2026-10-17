import Foundation
import Testing
@testable import MenuBarApp

struct TraceSpanLogsTests {
    static let orders = SiteDefaults.Service(name: "orders", lokiSelector: #"{app="orders"}"#,
                                             logFormat: .logfmt, levelField: "level",
                                             scope: "non-platform", traceServiceName: "orders-api")
    static let unscoped = SiteDefaults.Service(name: "gateway", lokiSelector: #"{app="gw"}"#,
                                               logFormat: .json)
    static let trace = Trace(traceID: "0af7651916cd43dd8448eb211c80319c", spans: [
        TraceTests.span("r", service: "gateway", start: 1_790_938_800_000_000_000, duration: 412_000_000),
        TraceTests.span("a", parent: "r", service: "orders-api",
                        start: 1_790_938_800_010_000_000, duration: 380_000_000),
        TraceTests.span("x", parent: "r", service: "ledger", start: 1_790_938_800_020_000_000, duration: 1),
    ])

    @Test func matchesASpanToTheServiceItIsCalledInTraces() {
        let span = Self.trace.rows[1].span
        #expect(TraceSpanLogs.service(for: span, in: [Self.unscoped, Self.orders]) == Self.orders)
    }

    @Test func plansTheTraceQueryOnTheServicesOwnGrafana() {
        let plan = TraceSpanLogs.plan(span: Self.trace.rows[1].span, trace: Self.trace,
                                      environment: "prd", services: [Self.orders])
        guard case .run(let server, let query, let start, let end, let service) = plan else {
            Issue.record("expected a run, got \(plan)")
            return
        }
        #expect(server == "grafana-non-platform-prd")
        #expect(query == #"{app="orders"} |= "0af7651916cd43dd8448eb211c80319c""#)
        // Nanoseconds this large lose their last digits as a Double, so the window is
        // checked to the millisecond.
        #expect(abs(start.timeIntervalSince1970 - 1_790_938_740) < 0.001)
        #expect(abs(end.timeIntervalSince1970 - 1_790_938_860.412) < 0.001)
        #expect(service == Self.orders)
    }

    @Test func explainsWhyASpanHasNoLogsHere() {
        let services = [Self.orders, Self.unscoped]
        let ledger = Self.trace.rows.first { $0.span.service == "ledger" }!.span
        #expect(TraceSpanLogs.plan(span: ledger, trace: Self.trace, environment: "prd", services: services)
                == .unavailable("No service in the site file is called ledger."))
        #expect(TraceSpanLogs.plan(span: Self.trace.rows[0].span, trace: Self.trace,
                                   environment: "prd", services: services)
                == .unavailable("gateway has no scope in the site file, so the Grafana holding its logs is not known."))
    }

    @Test func writesTheCallAsTheAgentWouldHave() throws {
        let tool = TraceSpanLogs.toolUse(id: "k", server: "grafana-cde-dev", datasourceUID: "LOKI-1",
                                         query: #"{app="orders"} |= "abc""#,
                                         start: Date(timeIntervalSince1970: 1_790_938_740),
                                         end: Date(timeIntervalSince1970: 1_790_938_860))
        let call = try #require(GrafanaToolCall(tool: tool))
        #expect(call.kind == .lokiLogs)
        #expect(call.server == "grafana-cde-dev")
        #expect(call.datasourceUID == "LOKI-1")
        #expect(call.query == #"{app="orders"} |= "abc""#)
        #expect(call.start == "2026-10-02T10:59:00.000Z")
        #expect(call.end == "2026-10-02T11:01:00.000Z")
    }
}
