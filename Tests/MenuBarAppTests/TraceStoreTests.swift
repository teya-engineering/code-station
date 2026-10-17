import Foundation
import Testing
@testable import MenuBarApp

// Grafana and the agent, as the store reaches them, scripted. A trace whose id is in
// `holdTraces` waits for `release()` before it answers, and so does the next summary
// while `holdSummary` is set.
@MainActor
final class FakeTraceBackend {
    var availability: GrafanaQueryRunner.Availability = .ready
    var tools: [String] = []
    var servers: [String] = []
    var holdTraces: Set<String> = []
    var holdSummary = false
    var summaryPrompts: [String] = []
    var summary: String? = "The gateway timed out waiting for orders."
    var logRuns: [(server: String, toolID: String, query: String)] = []
    private var gates: [CheckedContinuation<Void, Never>] = []

    var waiting: Int { gates.count }

    static let tempoList = #"[{"uid":"TEMPO-1","name":"Tempo","type":"tempo"}]"#
    static let lokiList = #"[{"uid":"LOKI-1","name":"Loki","type":"loki"}]"#

    static func traceJSON(_ id: String) -> String {
        #"{"trace":{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"gateway"}}]},"scopeSpans":[{"spans":[{"traceId":"\#(id)","spanId":"b7ad6b7169203331","name":"GET /orders","kind":2,"startTimeUnixNano":"1790938800000000000","endTimeUnixNano":"1790938800412000000","status":{"code":2,"message":"upstream timed out"}},{"traceId":"\#(id)","spanId":"00f067aa0ba902b7","parentSpanId":"b7ad6b7169203331","name":"SELECT","kind":3,"startTimeUnixNano":"1790938800010000000","endTimeUnixNano":"1790938800390000000","status":{}}]}]}]}}"#
    }

    func backend() -> TraceStore.Backend {
        TraceStore.Backend(
            availability: { _ in self.availability },
            call: { tool, arguments, server in try await self.answer(tool, arguments, server) },
            runLogs: { call, toolID, _ in
                self.logRuns.append((call.server, toolID, call.query))
            },
            summarize: { _, prompt in
                self.summaryPrompts.append(prompt)
                if self.holdSummary {
                    self.holdSummary = false
                    await self.wait()
                    return "stale summary"
                }
                return self.summary
            })
    }

    func answer(_ tool: String, _ arguments: Data, _ server: String) async throws
        -> MCPHTTPClient.ToolResult {
        tools.append(tool)
        servers.append(server)
        let text = String(decoding: arguments, as: UTF8.self)
        if tool == "list_datasources" {
            return .init(text: text.contains("loki") ? Self.lokiList : Self.tempoList, isError: false)
        }
        let id = TraceInput.traceID(from: text) ?? ""
        if holdTraces.contains(id) { await wait() }
        return .init(text: Self.traceJSON(id), isError: false)
    }

    private func wait() async {
        await withCheckedContinuation { gates.append($0) }
    }

    func release() {
        let open = gates
        gates = []
        open.forEach { $0.resume() }
    }
}

@MainActor
struct TraceStoreTests {
    static let traceA = "0af7651916cd43dd8448eb211c80319c"
    static let traceB = "1bf7651916cd43dd8448eb211c80319d"
    static let prod = TroubleshootEnvironment(name: "prd", title: "Prod", isDangerous: true)
    static let dev = TroubleshootEnvironment(name: "dev", title: "Dev")

    let session = UUID()

    func settle(_ done: () -> Bool) async {
        var tries = 0
        while !done(), tries < 2_000 {
            await Task.yield()
            tries += 1
        }
    }

    func makeStore(_ fake: FakeTraceBackend, input: String = traceA,
                   environment: TroubleshootEnvironment = prod) -> TraceStore {
        let store = TraceStore(backend: fake.backend())
        store.edit(session) {
            $0.input = input
            $0.environment = environment
        }
        return store
    }

    @Test func rejectsWhatIsNotATraceIdWithoutCallingGrafana() {
        let fake = FakeTraceBackend()
        let store = makeStore(fake, input: "hello")
        store.find(session)
        #expect(store.lookup(session).phase == .failed(.invalidID))
        #expect(fake.tools.isEmpty)
    }

    @Test func saysWhenTheEdgeGrafanaIsNotThere() {
        let fake = FakeTraceBackend()
        fake.availability = .notConfigured("grafana-edge-prd is not set up in Code Station's MCP servers.")
        let store = makeStore(fake)
        store.find(session)
        #expect(store.lookup(session).phase
                == .failed(.unavailable("grafana-edge-prd is not set up in Code Station's MCP servers.")))
        #expect(fake.tools.isEmpty)
    }

    @Test func findsTheTraceOnTheEdgeGrafanaOfTheChosenEnvironment() async {
        let fake = FakeTraceBackend()
        let store = makeStore(fake)
        store.find(session)
        #expect(store.lookup(session).phase == .fetching(server: "grafana-edge-prd"))
        await settle { store.lookup(session).phase == .found }

        let lookup = store.lookup(session)
        #expect(lookup.trace?.traceID == Self.traceA)
        #expect(lookup.datasource == .init(uid: "TEMPO-1", name: "Tempo"))
        #expect(lookup.server == "grafana-edge-prd")
        #expect(fake.tools == ["list_datasources", "grafana_api_request"])
        #expect(Set(fake.servers) == ["grafana-edge-prd"])
    }

    @Test func asksEachGrafanaForItsTempoOnce() async {
        let fake = FakeTraceBackend()
        let store = makeStore(fake)
        store.find(session)
        await settle { store.lookup(session).phase == .found }
        store.edit(session) { $0.input = Self.traceB }
        store.find(session)
        await settle { store.lookup(session).trace?.traceID == Self.traceB }
        #expect(fake.tools.filter { $0 == "list_datasources" }.count == 1)
    }

    @Test func aNewerLookupWinsOverAnOlderOneStillRunning() async {
        let fake = FakeTraceBackend()
        fake.holdTraces = [Self.traceA]
        let store = makeStore(fake)
        store.find(session)
        await settle { fake.waiting == 1 }

        store.edit(session) { $0.input = Self.traceB }
        store.find(session)
        await settle { store.lookup(session).trace?.traceID == Self.traceB }

        fake.release()
        for _ in 0..<50 { await Task.yield() }
        #expect(store.lookup(session).trace?.traceID == Self.traceB)
    }

    @Test func summarisesAFoundTrace() async {
        let fake = FakeTraceBackend()
        let store = makeStore(fake)
        store.find(session)
        await settle { store.lookup(session).summary == .done("The gateway timed out waiting for orders.") }
        #expect(fake.summaryPrompts.count == 1)
        #expect(fake.summaryPrompts[0].contains("Trace \(Self.traceA) in Prod (prd)"))
    }

    @Test func saysWhenNoSummaryCame() async {
        let fake = FakeTraceBackend()
        fake.summary = nil
        let store = makeStore(fake)
        store.find(session)
        await settle { store.lookup(session).summary == .failed }
        #expect(store.lookup(session).summary == .failed)
    }

    @Test func aSummaryOfAnOlderTraceIsDropped() async {
        let fake = FakeTraceBackend()
        fake.holdSummary = true
        let store = makeStore(fake)
        store.find(session)
        await settle { fake.waiting == 1 }

        store.edit(session) { $0.input = Self.traceB }
        store.find(session)
        await settle { store.lookup(session).summary == .done("The gateway timed out waiting for orders.") }

        fake.release()
        for _ in 0..<50 { await Task.yield() }
        #expect(store.lookup(session).summary == .done("The gateway timed out waiting for orders."))
    }

    // The trace goes into the composer as an attached file the person can see and take
    // off, and asking twice about the same trace attaches it once.
    @Test func asksInChatWithTheTraceAttachedOnce() async throws {
        let fake = FakeTraceBackend()
        let store = makeStore(fake)
        let runner = SessionRunner()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let attach: (String, String) -> URL? = { name, text in
            let url = folder.appendingPathComponent(name)
            return (try? text.write(to: url, atomically: true, encoding: .utf8)) == nil ? nil : url
        }
        store.find(session)
        await settle { store.lookup(session).phase == .found }

        runner.composer.editDraft(session) { $0.text = "Why is this slow?" }
        store.askInChat(session, runner: runner, attach: attach)
        store.askInChat(session, runner: runner, attach: attach)
        let draft = runner.composer.draft(session)
        #expect(draft.text == "Why is this slow?\n\nAbout trace `\(Self.traceA)` in Prod (attached): ")
        #expect(draft.customInstructions == nil)
        #expect(draft.attachments.map(\.name) == ["trace-\(Self.traceA).txt"])
        let written = try String(contentsOf: try #require(draft.attachments.first).url, encoding: .utf8)
        #expect(written.contains("Trace \(Self.traceA) in Prod (prd)"))
    }

    // Moving the environment pills to look the next trace up must not send the actions of
    // the trace on screen to the other environment.
    @Test func aTracesActionsStayWithTheEnvironmentItCameFrom() async throws {
        let fake = FakeTraceBackend()
        let store = makeStore(fake)
        store.find(session)
        await settle { store.lookup(session).phase == .found }
        store.edit(session) { $0.environment = Self.dev }

        let runner = SessionRunner()
        store.troubleshoot(session, runner: runner, services: [])
        #expect(runner.composer.brief(session).environment == Self.prod)
        #expect(runner.composer.brief(session).trace?.environment == "prd")

        let trace = try #require(store.lookup(session).trace)
        let span = trace.rows[1].span
        let db = SiteDefaults.Service(name: "db", lokiSelector: #"{app="db"}"#, logFormat: .json,
                                      scope: "platform", traceServiceName: span.service)
        store.showLogs(for: span, sessionID: session, services: [db])
        await settle { !fake.logRuns.isEmpty }
        #expect(fake.logRuns.first?.server == "grafana-platform-prd")
    }

    // A span's logs that could not be read, because the server was off, can be asked for
    // again once it is on.
    @Test func spanLogsThatFailedCanBeAskedForAgain() async throws {
        let fake = FakeTraceBackend()
        let store = makeStore(fake)
        store.find(session)
        await settle { store.lookup(session).phase == .found }
        let trace = try #require(store.lookup(session).trace)
        let span = trace.rows[1].span
        let db = SiteDefaults.Service(name: "db", lokiSelector: #"{app="db"}"#, logFormat: .json,
                                      scope: "platform", traceServiceName: span.service)
        let key = TraceSpanLogs.toolID(traceID: trace.traceID, spanID: span.id, environment: "prd")

        fake.availability = .disabled("grafana-platform-prd is turned off in MCP servers.")
        store.showLogs(for: span, sessionID: session, services: [db])
        #expect(store.spanLogs(key)?.message?.hasPrefix("grafana-platform-prd is turned off") == true)

        fake.availability = .ready
        store.showLogs(for: span, sessionID: session, services: [db])
        await settle { store.spanLogs(key)?.call != nil }
        #expect(fake.logRuns.count == 1)
    }

    @Test func readsASpansLogsFromItsServicesGrafana() async throws {
        let fake = FakeTraceBackend()
        let store = makeStore(fake)
        store.find(session)
        await settle { store.lookup(session).phase == .found }
        let trace = try #require(store.lookup(session).trace)
        let span = trace.rows[1].span
        // Both fixture spans come from the "gateway" resource, so the site file's "db" is
        // tied to them through its trace name.
        let db = SiteDefaults.Service(name: "db", lokiSelector: #"{app="db"}"#,
                                      logFormat: .json, scope: "platform",
                                      traceServiceName: span.service)
        store.showLogs(for: span, sessionID: session, services: [db])

        let key = TraceSpanLogs.toolID(traceID: trace.traceID, spanID: span.id, environment: "prd")
        await settle { store.spanLogs(key)?.call != nil }
        #expect(store.spanLogs(key)?.toolID == key)
        #expect(fake.logRuns.count == 1)
        #expect(fake.logRuns.first?.server == "grafana-platform-prd")
        #expect(fake.logRuns.first?.query == #"{app="db"} |= "\#(Self.traceA)""#)
        #expect(fake.servers.contains("grafana-platform-prd"))
    }

    @Test func loadsInFullATraceTheTranscriptCutShort() async throws {
        let fake = FakeTraceBackend()
        let store = TraceStore(backend: fake.backend())
        let tool = try TraceToolCallTests.tool(
            "mcp__grafana-edge-dev__grafana_api_request",
            ["endpoint": "/api/datasources/proxy/uid/T/api/traces/\(Self.traceA)"])
        let call = try #require(TraceToolCall(tool: tool))
        store.loadFull("call-1", call: call)
        #expect(store.fullTrace("call-1")?.isLoading == true)
        await settle { store.fullTrace("call-1")?.isLoading == false }
        #expect(store.fullTrace("call-1")?.trace?.traceID == Self.traceA)
        #expect(Set(fake.servers) == ["grafana-edge-dev"])
    }

    @Test func namesTheEnvironmentItLookedIn() {
        let failure = TraceStore.Failure.notFound(traceID: Self.traceA, environment: Self.prod)
        #expect(failure.message.contains("No trace \(Self.traceA) in edge Prod"))
    }
}
