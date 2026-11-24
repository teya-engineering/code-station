import Foundation
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct AgentSessionLiveTests {
    private let testPreferences = TestPreferences()
    @Test(arguments: [AgentKind.codex, .copilot])
    func backgroundTimerCanBeContinuedAndStopped(agent: AgentKind) async throws {
        guard ProcessInfo.processInfo.environment["CODE_STATION_LIVE_AGENT_TESTS"] == "1" else { return }
        if let only = ProcessInfo.processInfo.environment["CODE_STATION_LIVE_AGENT"], only != agent.rawValue { return }
        let executable = try #require(ProcessManager.resolve(agent.command))
        let scratch = ScratchDirectory(prefix: "agent-session-live")
        let store = ProjectStore(preferences: testPreferences.store, storeURL: scratch.path("projects.json"))
        let project = try TestStore.project(in: store)
        let session = try store.insertSession(in: project.id, seed: .init(agent: agent)).get()
        let models = agent == .codex
            ? await CodexModelReader.read(at: executable, searchPath: ProcessManager.searchPath) : nil
        if let model = models?.first(where: { $0.isDefault })?.id ?? models?.first?.id {
            var settings = session.settings ?? SessionSettings()
            settings.model = model
            store.setSettings(settings, for: session.id)
        }
        let runner = SessionRunner(preferences: testPreferences.store, paths: [agent: executable], discoveredModels: models.map { [agent: $0] } ?? [:],
                                   automaticRecapsEnabled: { false },
                                   automaticTitlesEnabled: { false }, promptSuggestionsEnabled: { false })
        defer { runner.stopAll() }
        let prompt = """
        This is a background-task UI test. Start exactly one shell command, `sleep 600`,
        as a managed background task with description "Waiting notice preview timer".
        For Codex use exec_command with yield_time_ms 1000. For Copilot use bash in async mode.
        Reply "Timer started" immediately after the tool yields. Do not poll or wait for it.
        Do not read, write, or inspect any files.
        """
        runner.send(prompt, sessionID: session.id, store: store)
        let waiting = await waitUntil(timeout: .seconds(120)) {
            runner.state(session.id) == .waiting || !runner.state(session.id).isBusy
        }
        #expect(waiting)
        #expect(runner.state(session.id) == .waiting, "\(agent): \(runner.state(session.id))")
        guard runner.state(session.id) == .waiting else { return }
        #expect(runner.backgroundTasks(session.id).contains { $0.command?.contains("sleep 600") == true })
        let conversation = try #require(store.session(session.id)?.agentSessionID(for: agent))
        runner.send("Reply only 'Still here'. Leave the timer running. Do not call any tools.",
                    sessionID: session.id, store: store)
        #expect(await waitUntil(timeout: .seconds(120)) {
            runner.state(session.id) == .waiting || !runner.state(session.id).isBusy
        })
        #expect(runner.state(session.id) == .waiting)
        #expect(store.session(session.id)?.agentSessionID(for: agent) == conversation)
        runner.endWait(session.id)
        #expect(await waitUntil { !runner.state(session.id).isBusy })
        #expect(runner.state(session.id) == .idle)
        #expect(runner.backgroundTasks(session.id).isEmpty)
    }
}

// A real Kiro session through the runner, with one of the app's MCP servers: a tiny
// server whose only tool answers a word nothing else knows. The reply carrying that word
// shows the server was handed over and reached, and the turn's summary must leave
// credits on the session. Opt in with CODE_STATION_LIVE_AGENT_TESTS=1 on a Mac signed
// into Kiro; it spends a few credits.
@MainActor
struct KiroLiveTests {
    private let testPreferences = TestPreferences()

    @Test func aKiroSessionReachesTheAppsMCPServerAndCountsCredits() async throws {
        guard ProcessInfo.processInfo.environment["CODE_STATION_LIVE_AGENT_TESTS"] == "1" else { return }
        if let only = ProcessInfo.processInfo.environment["CODE_STATION_LIVE_AGENT"], only != "kiro" { return }
        let executable = try #require(ProcessManager.resolve(AgentKind.kiro.command))
        let python = try #require(ProcessManager.resolve("python3"))
        let scratch = ScratchDirectory(prefix: "kiro-live")
        let server = scratch.path("ping.py")
        try Data("""
        import json, sys
        for line in sys.stdin:
            msg = json.loads(line)
            if msg.get("id") is None: continue
            method = msg.get("method")
            if method == "initialize":
                res = {"protocolVersion": msg["params"].get("protocolVersion", "2025-03-26"),
                       "capabilities": {"tools": {}}, "serverInfo": {"name": "ping", "version": "1"}}
            elif method == "tools/list":
                res = {"tools": [{"name": "ping", "description": "Answers with a secret word.",
                                  "inputSchema": {"type": "object", "properties": {}}}]}
            elif method == "tools/call":
                res = {"content": [{"type": "text", "text": "pong kestrel-42"}]}
            else:
                print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "no"}}), flush=True)
                continue
            print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": res}), flush=True)

        """.utf8).write(to: server)
        let config = scratch.path("mcp.json")
        let entry: [String: Any] = ["command": python, "args": ["-I", server.path]]
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["ping": entry]]).write(to: config)
        let configs = ConfigStore(configURL: config)
        #expect(configs.servers.map(\.name) == ["ping"])

        let store = ProjectStore(preferences: testPreferences.store, storeURL: scratch.path("projects.json"))
        let project = try TestStore.project(in: store)
        let session = try store.insertSession(in: project.id, seed: .init(agent: .kiro)).get()
        let runner = SessionRunner(preferences: testPreferences.store, configs: configs, paths: [.kiro: executable],
                                   automaticRecapsEnabled: { false },
                                   automaticTitlesEnabled: { false }, promptSuggestionsEnabled: { false })
        defer { runner.stopAll() }

        runner.send("Call the ping tool from the ping MCP server, then reply with exactly what it returned.",
                    sessionID: session.id, store: store)
        var answered: [String] = []
        let finished = await waitUntil(timeout: .seconds(180)) {
            if let question = runner.question(session.id) {
                answered.append(question.toolName)
                runner.answer(question, with: .allowOnce, sessionID: session.id, store: store)
            }
            return !runner.state(session.id).isBusy
        }
        #expect(finished)
        let transcript = store.transcript(of: session.id)
        #expect(transcript.contains { $0.text.contains("kestrel-42") },
                "asked: \(answered); transcript: \(transcript.map(\.text).joined(separator: " | "))")
        let credits = try #require(store.session(session.id)?.usage?.credits)
        #expect(credits > 0)
        print("Kiro live: asked \(answered), credits \(credits)")
    }
}
