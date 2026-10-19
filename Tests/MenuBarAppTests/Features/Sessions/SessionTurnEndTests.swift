import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

@MainActor
struct SessionTurnEndTests {
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
}
