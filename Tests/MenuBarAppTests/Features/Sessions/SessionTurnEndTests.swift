import Foundation
import Observation
import Testing
@testable import MenuBarApp

@MainActor
struct SessionTurnEndTests {
    private final class Flag: @unchecked Sendable {
        var raised = false
    }

    private let testPreferences = TestPreferences()
    private let store: ProjectStore
    private let scratch: ScratchDirectory

    init() {
        (store, scratch) = TestStore.make()
    }

    // A failed turn still ends, and whatever the agent left behind still needs reading.
    @Test func reportsATurnThatEndedEvenWhenItFailed() async throws {
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id, seed: .init(agent: .codex))
        let runner = SessionRunner(preferences: testPreferences.store, persistentAgentSessions: false,
                                   paths: [.codex: "/usr/bin/false"])
        defer { runner.stopAll() }
        var ended: [UUID] = []
        runner.onTurnEnded = { ended.append($0) }

        runner.send("Fix the bug", sessionID: session.id, store: store)

        #expect(await waitUntil { ended == [session.id] })
    }

    @Test func reportsFinishingOnlyAfterTheResultAndKeepsReadingUntilExit() async throws {
        let harness = try RunnerHarness(agent: .claudeCode, script: """
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"abc"}'
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Work complete"}]}}'
        wait_for "$folder/finish-response"
        printf '%s\\n' '{"type":"result","is_error":false,"result":"Work complete"}'
        wait_for "$folder/exit-process"
        printf '%s\\n' '{"type":"prompt_suggestion","suggestion":"Review the changes"}'
        """, promptSuggestionsEnabled: { true })
        defer { harness.tearDown() }
        let id = harness.session.id
        harness.runner.send("Fix the bug", sessionID: id, store: harness.store)
        #expect(await waitUntil { harness.runner.state(id) == .streaming })
        #expect(harness.runner.completionActivity(id) == nil)

        let changed = Flag()
        withObservationTracking {
            _ = harness.runner.completionActivity(id)
        } onChange: {
            changed.raised = true
        }
        try Data().write(to: harness.scratch.path("finish-response"))
        #expect(await waitUntil { harness.runner.completionActivity(id) == .finishing })
        #expect(changed.raised)
        #expect(harness.runner.state(id).isBusy)
        #expect(SessionActivity.line(for: harness.session, store: harness.store,
                                     runner: harness.runner) == "Finishing up")

        try Data().write(to: harness.scratch.path("exit-process"))
        #expect(await waitUntil { harness.runner.state(id) == .idle })
        #expect(harness.runner.completionActivity(id) == nil)
        #expect(harness.runner.suggestion(id) == "Review the changes")
    }
}
