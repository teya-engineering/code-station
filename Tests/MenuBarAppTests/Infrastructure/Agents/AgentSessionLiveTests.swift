import Foundation
import Testing
@testable import CodeStationCore

@MainActor
@Suite(.serialized)
struct AgentSessionLiveTests {
    private let testPreferences = TestPreferences()
    @Test(arguments: [AgentKind.codex, .copilot])
    func backgroundTimerCanBeContinuedAndStopped(agent: AgentKind) async throws {
        guard ProcessInfo.processInfo.environment["CODE_STATION_LIVE_AGENT_TESTS"] == "1" else { return }
        if let only = ProcessInfo.processInfo.environment["CODE_STATION_LIVE_AGENT"], only != agent.rawValue { return }
        let executable = try #require(ExecutableSearch.resolve(agent.command))
        let scratch = ScratchDirectory(prefix: "agent-session-live")
        let store = ProjectStore(preferences: testPreferences.store, storeURL: scratch.path("projects.json"))
        let project = try TestStore.project(in: store)
        let session = try store.insertSession(in: project.id, seed: .init(agent: agent)).get()
        let models = agent == .codex
            ? await CodexModelReader.read(at: executable, searchPath: ExecutableSearch.searchPath) : nil
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
