import Foundation
import Testing
@testable import MenuBarApp

// What Stats keeps when a session leaves the app, and that a read still under way never
// brings back a session that has gone.
@MainActor
struct StatsStoreTests {
    private let store: ProjectStore
    private let scratch: ScratchDirectory

    init() {
        (store, scratch) = TestStore.make()
    }

    private func makeStats(keptDays: Int, in store: ProjectStore? = nil) -> StatsStore {
        let store = store ?? self.store
        let stats = StatsStore(fileURL: scratch.path("stats-\(UUID().uuidString).json"),
                               transcripts: store.transcriptsURL,
                               loaded: { [store] in store.loadedTranscript(of: $0) })
        stats.isEnabled = { true }
        stats.keptDays = { keptDays }
        stats.turnOn()
        store.onSessionLeaving = { [stats, store] in stats.sessionLeaving($0, store: store) }
        return stats
    }

    private func prompt(_ text: String, to sessionID: UUID, in store: ProjectStore? = nil) {
        (store ?? self.store).append(ChatMessage(role: .user, text: text), to: sessionID)
    }

    // The workspace leaves the list before its sessions are taken down, and the stats
    // kept for them must still name it rather than one of its projects.
    @Test func keepsARemovedWorkspacesSessionsUnderThatWorkspace() async throws {
        let first = try TestStore.project(in: store, named: "api")
        let second = try TestStore.project(in: store, named: "web")
        let workspace = try #require(store.addWorkspace(name: "Checkout",
                                                        projectIDs: [first.id, second.id],
                                                        leadProjectID: first.id))
        let session = try store.insertSession(in: workspace.id, projects: [
            SessionProject(projectID: first.id, worktreePath: nil, worktreeBranch: nil),
            SessionProject(projectID: second.id, worktreePath: nil, worktreeBranch: nil)
        ]).get()
        let stats = makeStats(keptDays: 30)

        store.removeWorkspace(workspace.id)

        #expect(await waitUntil { stats.keptCount == 1 })
        let kept = try #require(stats.archive.kept.first)
        #expect(kept.id == session.id)
        #expect(kept.subject == StatsSubject(id: workspace.id, name: "Checkout", isWorkspace: true))
    }

    // Stats is only read while its sheet is open, so what it last read can be well
    // behind a session that kept working. The kept stats must hold the newer turns.
    @Test func readsASessionAgainBeforeKeepingItWhenItHasMovedOn() async throws {
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id)
        prompt("First", to: session.id)
        let stats = makeStats(keptDays: 30)
        stats.refresh(store)
        #expect(await waitUntil { !stats.isReading })
        #expect(stats.digests.first?.prompts.count == 1)

        prompt("Second", to: session.id)
        try store.removeSession(session.id).get()

        #expect(await waitUntil { stats.archive.kept.first?.prompts.count == 2 })
        #expect(stats.keptCount == 1)
    }

    @Test func dropsAReadThatLandsAfterTheSessionWasRemoved() async throws {
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id)
        prompt("Hello", to: session.id)
        let stats = makeStats(keptDays: 0)

        stats.refresh(store)
        #expect(stats.isReading)
        try store.removeSession(session.id).get()

        #expect(await waitUntil { !stats.isReading })
        #expect(stats.digests.isEmpty)
        #expect(stats.archive.cache.isEmpty)
    }

    // A removal that cannot be written down leaves the session in the app, so its
    // recorded waits must stay too: they cannot be read back from a transcript.
    @Test func leavesTheStatsAloneWhenTheRemovalIsNotCommitted() throws {
        let failing = PersistentFileClient(
            readIfPresent: { try PersistentFile.readIfPresent($0) },
            write: { data, url in
                if url.lastPathComponent.hasSuffix("-removals.json") {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try PersistentFile.write(data, to: url)
            },
            removeIfPresent: { try PersistentFile.removeIfPresent($0) })
        let store = ProjectStore(preferences: scratch.preferences.store,
                                 storeURL: scratch.path("failing/projects.json"),
                                 files: failing)
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id)
        let stats = makeStats(keptDays: 0, in: store)
        let ending = TurnEnding(started: Date().addingTimeInterval(-60), ended: Date(),
                                outcome: .finished)
        stats.recordTurn(ending, sessionID: session.id, subjectID: project.id)

        guard case .failure = store.removeSession(session.id) else {
            Issue.record("Expected the removal to fail")
            return
        }

        #expect(store.session(session.id) != nil)
        #expect(stats.archive.events.map(\.sessionID) == [session.id])
    }

    // A running turn's calls land without changing the session's summary, so a reading
    // taken mid-turn is taken again once the turn has stopped.
    @Test func readsARunningSessionAgainOnceItStops() async throws {
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id)
        prompt("Go", to: session.id)
        let stats = makeStats(keptDays: 0)
        var running = true
        stats.isRunning = { _ in running }

        stats.refresh(store)
        #expect(await waitUntil { !stats.isReading })
        stats.refresh(store)
        #expect(!stats.isReading)

        running = false
        stats.refresh(store)
        #expect(stats.isReading)
        #expect(await waitUntil { !stats.isReading })
        stats.refresh(store)
        #expect(!stats.isReading)
    }

    // A removed session's stats last as many days as the person chose, counted from its
    // last turn, and the waits recorded against it go with them.
    @Test func dropsKeptStatsOnceTheirLastTurnIsOlderThanTheDaysKept() async throws {
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id)
        prompt("Hello", to: session.id)
        var days = 30
        let stats = makeStats(keptDays: 30)
        stats.keptDays = { days }
        let ending = TurnEnding(started: Date().addingTimeInterval(-60), ended: Date(),
                                outcome: .finished)
        stats.recordTurn(ending, sessionID: session.id, subjectID: project.id)
        try store.removeSession(session.id).get()
        #expect(await waitUntil { stats.keptCount == 1 })

        #expect(!stats.pruneKept(now: Date().addingTimeInterval(29 * 86_400)))
        #expect(stats.keptCount == 1)

        #expect(stats.pruneKept(now: Date().addingTimeInterval(31 * 86_400)))
        #expect(stats.keptCount == 0)
        #expect(stats.archive.events.isEmpty)

        days = 0
        #expect(!stats.pruneKept())
    }

    @Test func dropsEveryKeptSessionWhenTheDaysGoToZero() async throws {
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id)
        prompt("Hello", to: session.id)
        var days = 30
        let stats = makeStats(keptDays: 30)
        stats.keptDays = { days }
        try store.removeSession(session.id).get()
        #expect(await waitUntil { stats.keptCount == 1 })

        days = 0
        stats.refresh(store)

        #expect(stats.keptCount == 0)
        #expect(stats.digests.isEmpty)
    }

    // Home looks back 30 days at most, so a longer choice saved earlier comes back as 30.
    @Test func keepsPastSessionsForThirtyDaysAtMost() {
        #expect(StatsStore.resolvedKeptDays(90) == 30)
        #expect(StatsStore.resolvedKeptDays(30) == 30)
        #expect(StatsStore.resolvedKeptDays(7) == 7)
        #expect(StatsStore.resolvedKeptDays(-1) == 0)
    }
}
