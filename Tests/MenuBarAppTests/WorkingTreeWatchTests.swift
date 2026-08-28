import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct WorkingTreeWatchTests {
    @Test func doesNotQueueASecondInspectionWhileOneIsRunning() async throws {
        let folder = ScratchDirectory(prefix: "working-tree-watch")
        let path = folder.url.path
        let inspections = InspectionCount(result: 3, delay: .milliseconds(100))
        let watch = WorkingTreeWatch { path in
            await inspections.inspect(path)
        }

        #expect(!watch.hasInspected(path))
        watch.refresh([path])
        watch.refresh([path])
        try await eventually { inspections.value == 1 && watch.isDirty(path) }
        #expect(watch.hasInspected(path))
        #expect(watch.isDirty(path))
        #expect(watch.uncommittedFileCount(at: path) == 3)

        watch.refresh([path])
        try await eventually { inspections.value == 2 }
    }

    @Test func noticesLinkedWorktreeEditsStagingCommitsAndDeletion() async throws {
        let repo = try GitRepo()
        let scratch = ScratchDirectory(prefix: "working-tree-watch")
        let worktree = scratch.path("linked")
        try repo.git("worktree", "add", "-q", "-b", "linked", worktree.path)
        defer { try? repo.git("worktree", "remove", "--force", worktree.path) }

        let inspections = RepositoryInspections()
        let watch = WorkingTreeWatch { path in
            await inspections.inspect(path)
        }

        #expect(!watch.hasInspected(worktree.path))
        watch.refresh([worktree.path])
        try await eventually { inspections.value == 1 && watch.hasInspected(worktree.path) }
        #expect(watch.hasInspected(worktree.path))
        #expect(!watch.isDirty(worktree.path))

        try "changed".write(
            to: worktree.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try await refreshAfterEvent(
            watch, inspections: inspections, count: 2, path: worktree.path, dirty: true)

        try repo.git("-C", worktree.path, "add", "README.md")
        try await refreshAfterEvent(
            watch, inspections: inspections, count: 3, path: worktree.path, dirty: true)

        try repo.git("-C", worktree.path, "commit", "-qm", "change")
        try await refreshAfterEvent(
            watch, inspections: inspections, count: 4, path: worktree.path, dirty: false)

        try repo.git("worktree", "remove", "--force", worktree.path)
        try await refreshAfterEvent(
            watch, inspections: inspections, count: 5, path: worktree.path, dirty: false)
    }

    private func refreshAfterEvent(
        _ watch: WorkingTreeWatch,
        inspections: RepositoryInspections,
        count: Int,
        path: String,
        dirty expected: Bool
    ) async throws {
        try await eventually {
            watch.refresh([path])
            return inspections.value >= count && watch.isDirty(path) == expected
        }
    }

    // The wait is wall-clock, but this test shares the main actor with every other one in
    // the run, so the time it actually gets to poll in is a fraction of it. The budget is
    // generous for that reason: a passing run never spends it, and a tighter one turns
    // into a failure whenever the suite grows rather than when the watch breaks.
    private func eventually(_ condition: () -> Bool) async throws {
        let held = await waitUntil(timeout: .seconds(20), condition)
        #expect(held, "Condition did not become true within 20 seconds")
    }

    // Counted behind a lock rather than on an actor, so a poll can read the count without
    // suspending.
    private final class InspectionCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let result: Int
        let delay: Duration

        init(result: Int, delay: Duration = .zero) {
            self.result = result
            self.delay = delay
        }

        var value: Int { lock.withLock { count } }

        func inspect(_ path: String) async -> Int {
            lock.withLock { count += 1 }
            try? await Task.sleep(for: delay)
            return result
        }
    }

    private final class RepositoryInspections: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int { lock.withLock { count } }

        func inspect(_ path: String) async -> Int {
            let result = await GitInspector.uncommittedFileCount(at: path)
            lock.withLock { count += 1 }
            return result
        }
    }
}
