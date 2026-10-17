import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct TraceHandoffTests {
    static let trace = Trace(traceID: "0af7651916cd43dd8448eb211c80319c", spans: [
        TraceTests.span("r", service: "gateway", start: 0, duration: 100),
        TraceTests.span("a", parent: "r", service: "orders-api", start: 10, duration: 80, error: true),
        TraceTests.span("b", parent: "r", service: "ledger", start: 20, duration: 10),
    ])
    static let services = [
        SiteDefaults.Service(name: "orders", lokiSelector: #"{app="orders"}"#, logFormat: .json,
                             scope: "cde", traceServiceName: "orders-api"),
        SiteDefaults.Service(name: "gateway", lokiSelector: #"{app="gw"}"#, logFormat: .json,
                             scope: "edge"),
    ]

    @Test func namesEachServiceTheTraceTouchedAndWhereItsLogsAre() {
        let context = TraceHandoff.context(trace: Self.trace, environment: "prd", services: Self.services)
        #expect(context.services == [.init(name: "gateway", scope: "edge"),
                                     .init(name: "orders", scope: "cde"),
                                     .init(name: "ledger", scope: nil)])
        let text = context.promptContext
        #expect(text.contains("- Trace ID: 0af7651916cd43dd8448eb211c80319c"))
        #expect(text.contains("Tempo datasource on grafana-edge-prd"))
        #expect(text.contains("orders (logs on grafana-cde-prd)"))
        #expect(text.contains("ledger (Grafana not known)"))
    }

    @Test func writesTheProblemFromTheFailedSpans() {
        let problem = TraceHandoff.problem(trace: Self.trace, environmentTitle: "Prod")
        #expect(problem == """
        Investigate trace `0af7651916cd43dd8448eb211c80319c` in Prod.
        Failed spans:
        - orders-api op-a: boom
        """)
    }

    @Test func addsToWhatWasAlreadyWritten() {
        #expect(TraceHandoff.merged(problem: "  ", with: "B") == "B")
        #expect(TraceHandoff.merged(problem: "Checkout fails\n", with: "B") == "Checkout fails\n\nB")
    }

    @Test func theTraceReachesTheDiagnosis() {
        let context = TraceHandoff.context(trace: Self.trace, environment: "prd", services: Self.services)
        let environment = TroubleshootEnvironment(name: "prd", title: "Prod", isDangerous: true)
        let with = TroubleshootRequest(problem: "x", environment: environment, projects: ["api"],
                                       mcpServersEnabled: true, agent: .claudeCode, trace: context)
        let without = TroubleshootRequest(problem: "x", environment: environment, projects: ["api"],
                                          mcpServersEnabled: true, agent: .claudeCode)
        #expect(with.customInstructions.hasSuffix(context.promptContext))
        #expect(!without.customInstructions.contains("Trace context:"))
    }

    @Test func handsTheTraceToTheTroubleshootTabOnce() async {
        let fake = FakeTraceBackend()
        let session = UUID()
        let store = TraceStore(backend: fake.backend())
        store.edit(session) {
            $0.input = TraceStoreTests.traceA
            $0.environment = TraceStoreTests.prod
        }
        store.find(session)
        var tries = 0
        while store.lookup(session).phase != .found, tries < 2_000 {
            await Task.yield()
            tries += 1
        }
        let runner = SessionRunner()
        store.troubleshoot(session, runner: runner, services: Self.services)
        store.troubleshoot(session, runner: runner, services: Self.services)

        let brief = runner.composer.brief(session)
        #expect(brief.trace?.traceID == TraceStoreTests.traceA)
        #expect(brief.environment == TraceStoreTests.prod)
        #expect(brief.problem.components(separatedBy: "Investigate trace").count == 2)
    }
}
