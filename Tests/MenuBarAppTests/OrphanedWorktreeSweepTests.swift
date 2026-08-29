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

    @Test func waitsAFullHourAfterAnOrphanIsFirstSeen() {
        let orphan = worktree("one")
        var buffer = OrphanedWorktreeSweep.EligibilityBuffer()

        #expect(buffer.nextReadyAt == nil)
        #expect(buffer.ready([orphan], now: now).isEmpty)
        #expect(buffer.nextReadyAt
            == now.addingTimeInterval(OrphanedWorktreeSweep.gracePeriod))
        #expect(buffer.ready(
            [orphan],
            now: now.addingTimeInterval(OrphanedWorktreeSweep.gracePeriod - 1)).isEmpty)
        #expect(buffer.ready(
            [orphan],
            now: now.addingTimeInterval(OrphanedWorktreeSweep.gracePeriod)) == [orphan])
    }

    @Test func forgetsAnOrphanThatDisappearsDuringTheWarningHour() {
        let orphan = worktree("one")
        var buffer = OrphanedWorktreeSweep.EligibilityBuffer()

        #expect(buffer.ready([orphan], now: now).isEmpty)
        #expect(buffer.ready([], now: now.addingTimeInterval(1_800)).isEmpty)
        #expect(buffer.nextReadyAt == nil)
        #expect(buffer.ready([orphan], now: now.addingTimeInterval(3_600)).isEmpty)
    }

    @Test func capsEachAutomaticPruningPass() {
        let worktrees = (0..<(OrphanedWorktreeSweep.batchLimit + 10)).map {
            worktree("\($0)")
        }
        var buffer = OrphanedWorktreeSweep.EligibilityBuffer()

        #expect(buffer.ready(worktrees, now: now).isEmpty)
        let ready = buffer.ready(
            worktrees,
            now: now.addingTimeInterval(OrphanedWorktreeSweep.gracePeriod))

        #expect(ready.count == OrphanedWorktreeSweep.batchLimit)
    }

    @Test func replacingVisibleWorktreesStartsTheAutomaticPruningCountdown() {
        let orphan = worktree("one")
        let project = Project(id: orphan.projectID,
                              name: orphan.projectName,
                              path: orphan.projectPath)
        let monitor = OrphanedWorktreeMonitor()
        monitor.setAutomaticPruningEnabled(true, now: now)

        monitor.replace([
            GitWorktree.Orphaned(path: orphan.path,
                                 branch: orphan.branch,
                                 allocatedBytes: orphan.allocatedBytes)
        ], for: project, now: now)

        #expect(monitor.automaticDeletionAt
            == now.addingTimeInterval(OrphanedWorktreeSweep.gracePeriod))
        #expect(monitor.automaticPruningCandidates(now: now).isEmpty)
    }

    @Test func disablingAutomaticPruningClearsTheCountdown() {
        let orphan = worktree("one")
        let project = Project(id: orphan.projectID,
                              name: orphan.projectName,
                              path: orphan.projectPath)
        let monitor = OrphanedWorktreeMonitor()
        monitor.setAutomaticPruningEnabled(true, now: now)
        monitor.replace([
            GitWorktree.Orphaned(path: orphan.path,
                                 branch: orphan.branch,
                                 allocatedBytes: orphan.allocatedBytes)
        ], for: project, now: now)

        monitor.setAutomaticPruningEnabled(false, now: now)

        #expect(monitor.automaticDeletionAt == nil)
        #expect(monitor.automaticPruningCandidates(
            now: now.addingTimeInterval(OrphanedWorktreeSweep.gracePeriod)).isEmpty)
    }

    @Test func removesSuccessfulCheckoutsAndKeepsFailuresVisible() async {
        let removed = worktree("removed")
        let kept = worktree("kept")
        let monitor = OrphanedWorktreeMonitor()
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

        let result = await monitor.prune([removed, kept]) { worktree in
            worktree == removed
                ? .success(())
                : .failure(GitWorktree.Failure(message: "still in use"))
        }

        #expect(result.removed == [removed])
        #expect(result.failures.map(\.message) == ["still in use"])
        #expect(monitor.worktrees == [kept])
    }
}
