import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct CleanupCoordinatorTests {
    private let testPreferences = TestPreferences()

    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let project: Project
    private let runner: SessionRunner
    private let settings: AppSettings
    private let cleanup: CleanupCoordinator

    init() throws {
        (store, scratch) = TestStore.make()
        project = try TestStore.project(in: store)
        runner = SessionRunner(store: store, preferences: testPreferences.store, paths: [:])
        settings = AppSettings(agentAvatarURL: scratch.path("avatar.png"),
                               preferences: scratchDefaults())
        settings.oldSessionDays = 7
        cleanup = CleanupCoordinator(store: store, runner: runner, settings: settings,
                                     orphanedWorktrees: OrphanedWorktreeMonitor(preferences: scratchDefaults()))
    }

    // A session that went quiet over a week ago. The fresh one beside it takes the
    // selection, since the sweep never touches the session on screen.
    private func agedSession() -> ChatSession {
        let old = store.newSession(in: project.id)
        store.append(ChatMessage(role: .user, text: "Old work",
                                 date: Date().addingTimeInterval(-8 * 86_400)),
                     to: old.id)
        _ = store.newSession(in: project.id)
        return old
    }

    // A countdown belongs to the rule it was armed under. Turning the rule off has to
    // drop it, or a session would still go on a promise the person took back.
    @Test func theSweepStartsOverWhenTheRuleChanges() async throws {
        let old = agedSession()
        settings.oldSessionsDeleteOnTheirOwn = false
        cleanup.start()
        defer { cleanup.stop() }
        #expect(cleanup.status == OldSessionSweep.Status())

        settings.oldSessionsDeleteOnTheirOwn = true
        #expect(await waitUntil(timeout: .seconds(10)) { cleanup.status != OldSessionSweep.Status() })

        settings.oldSessionsDeleteOnTheirOwn = false
        #expect(await waitUntil(timeout: .seconds(10)) { cleanup.status == OldSessionSweep.Status() })
        #expect(store.session(old.id) != nil)
    }
}
