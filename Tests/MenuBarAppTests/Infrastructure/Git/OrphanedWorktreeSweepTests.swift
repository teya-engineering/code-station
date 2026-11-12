import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct OrphanedWorktreeSweepTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let projectID = UUID(uuidString: "AABBCCDD-0000-4000-8000-000000000000")!

    private func worktree(_ name: String) -> OrphanedWorktree {
        OrphanedWorktree(projectID: projectID,
                         projectName: "Project",
                         projectPath: "/projects/project",
                         path: "/worktrees/\(name)",
                         branch: "code-station/\(name)",
                         allocatedBytes: 1_024)
    }

    private func orphaned(_ orphan: OrphanedWorktree) -> GitWorktree.Orphaned {
        GitWorktree.Orphaned(path: orphan.path, branch: orphan.branch,
                             allocatedBytes: orphan.allocatedBytes)
    }

    private func project(of orphan: OrphanedWorktree) -> Project {
        Project(id: orphan.projectID, name: orphan.projectName, path: orphan.projectPath)
    }

    // "Ask again in a week" takes an orphan out of cleanup until that date, and the answer
    // outlasts a restart.
    @Test func leavesADeferredOrphanOutOfCleanupUntilItsDate() {
        let preferences = TestPreferences()
        let first = worktree("one")
        let second = worktree("two")
        let monitor = OrphanedWorktreeMonitor(preferences: preferences.store)
        monitor.replace([orphaned(first), orphaned(second)], for: project(of: first))
        let until = now.addingTimeInterval(OldSessions.deferral)

        monitor.deferCleanup(of: first.id, until: until, now: now)

        #expect(monitor.cleanupCandidates(now: now) == [second])
        #expect(monitor.cleanupCandidates(now: until) == [first, second])
        let relaunched = OrphanedWorktreeMonitor(preferences: preferences.store)
        #expect(relaunched.deferredUntil == [first.id: until])
    }

    @Test func forgetsDeferralsThatHaveRunOut() {
        let preferences = TestPreferences()
        let monitor = OrphanedWorktreeMonitor(preferences: preferences.store)
        monitor.deferCleanup(of: "/worktrees/old", until: now.addingTimeInterval(-1), now: now)

        monitor.deferCleanup(of: "/worktrees/new", until: now.addingTimeInterval(60), now: now)

        #expect(Array(monitor.deferredUntil.keys) == ["/worktrees/new"])
    }

    @Test func dropsAWorktreeClaimedWhileDiscoveryIsRunning() async throws {
        let (store, scratch) = TestStore.make()
        _ = scratch
        let project = try TestStore.project(in: store)
        let path = "/worktrees/claimed"

        let found = await OrphanedWorktreeDiscovery.find(in: store) { _, protectedPaths in
            #expect(!protectedPaths.contains(path))
            store.newSession(in: project.id, worktreePath: path)
            return [GitWorktree.Orphaned(path: path,
                                         branch: "code-station/claimed",
                                         allocatedBytes: 1_024)]
        }

        #expect(found.isEmpty)
    }

    @Test func removesSuccessfulCheckoutsAndKeepsFailuresVisible() async {
        let (store, scratch) = TestStore.make()
        _ = scratch
        let removed = worktree("removed")
        let kept = worktree("kept")
        let monitor = OrphanedWorktreeMonitor(preferences: TestPreferences().store)
        monitor.replace([
            GitWorktree.Orphaned(path: removed.path,
                                 branch: removed.branch,
                                 allocatedBytes: removed.allocatedBytes),
            GitWorktree.Orphaned(path: kept.path,
                                 branch: kept.branch,
                                 allocatedBytes: kept.allocatedBytes)
        ], for: Project(id: removed.projectID,
                        name: removed.projectName,
                        path: removed.projectPath))

        let result = await monitor.prune([removed, kept], in: store) { worktree in
            worktree == removed
                ? .success(())
                : .failure(GitWorktree.Failure(message: "still in use"))
        }

        #expect(result.removed == [removed])
        #expect(result.failures.map(\.message) == ["still in use"])
        #expect(monitor.worktrees == [kept])
    }

    @Test func refusesToPruneAWorktreeNowOwnedByASession() async throws {
        let (store, scratch) = TestStore.make()
        _ = scratch
        let project = try TestStore.project(in: store)
        let claimed = worktree("claimed")
        store.newSession(in: project.id, worktreePath: claimed.path)
        let recorder = OrphanRemovalRecorder()
        let monitor = OrphanedWorktreeMonitor(preferences: TestPreferences().store)
        monitor.replace([
            GitWorktree.Orphaned(path: claimed.path,
                                 branch: claimed.branch,
                                 allocatedBytes: claimed.allocatedBytes)
        ], for: Project(id: claimed.projectID,
                        name: claimed.projectName,
                        path: claimed.projectPath))

        let result = await monitor.prune([claimed], in: store) { worktree in
            await recorder.record(worktree.path)
            return .success(())
        }

        #expect(result.removed.isEmpty)
        #expect(result.failures.isEmpty)
        #expect(monitor.worktrees.isEmpty)
        #expect(await recorder.recordedPaths().isEmpty)
    }

    @Test func pruningConfirmationIncludesWorktreeDetails() throws {
        let dialog = OrphanedWorktreePruning.confirmation(
            for: [worktree("one"), worktree("two")]) {}

        #expect(dialog.title == "Prune 2 orphaned worktrees?")
        #expect(dialog.message?.contains("uncommitted changes") == true)
        #expect(dialog.content != nil)
        #expect(dialog.width == 520)
        #expect(dialog.actions.map(\.label) == ["Prune all", "Cancel"])
    }
}

private actor OrphanRemovalRecorder {
    private var paths: [String] = []

    func record(_ path: String) { paths.append(path) }
    func recordedPaths() -> [String] { paths }
}
