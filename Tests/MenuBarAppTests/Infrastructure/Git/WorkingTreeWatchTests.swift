import Foundation
import Testing
@testable import CodeStationCore

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
    }

    @Test func readsATreeAgainOnlyAfterItChanges() async throws {
        let folder = ScratchDirectory(prefix: "working-tree-watch")
        let path = folder.url.path
        let inspections = InspectionCount(result: 0)
        let watch = WorkingTreeWatch { path in
            await inspections.inspect(path)
        }

        watch.refresh([path])
        try await eventually { inspections.value == 1 && watch.hasInspected(path) }

        // Longer than the stream's one-second latency, so a stray event would have landed.
        try await Task.sleep(for: .seconds(2))
        watch.refresh([path])
        watch.refresh([path])
        try await Task.sleep(for: .milliseconds(200))
        #expect(inspections.value == 1)

        try "new".write(to: folder.path("file.txt"), atomically: true, encoding: .utf8)
        try await eventually {
            watch.refresh([path])
            return inspections.value == 2
        }
    }

    // Restarting the stream throws away events it had not handed over yet, so a tree
    // already read is read again rather than trusted.
    @Test func readsEveryTreeAgainWhenTheWatchStartsOver() async throws {
        let first = ScratchDirectory(prefix: "working-tree-watch")
        let second = ScratchDirectory(prefix: "working-tree-watch")
        let inspections = InspectionCount(result: 0)
        let watch = WorkingTreeWatch { path in
            await inspections.inspect(path)
        }

        watch.refresh([first.url.path])
        try await eventually {
            inspections.count(of: first.url.path) == 1 && watch.hasInspected(first.url.path)
        }

        watch.refresh([first.url.path, second.url.path])
        try await eventually {
            inspections.count(of: first.url.path) == 2 && inspections.count(of: second.url.path) == 1
        }
    }

    @Test func readsAWatchedTreeAgainAsSoonAsItIsMarkedChanged() async throws {
        let watched = ScratchDirectory(prefix: "working-tree-watch")
        let unwatched = ScratchDirectory(prefix: "working-tree-watch")
        let inspections = InspectionCount(result: 0)
        let watch = WorkingTreeWatch { path in
            await inspections.inspect(path)
        }

        watch.refresh([watched.url.path])
        try await eventually {
            inspections.count(of: watched.url.path) == 1 && watch.hasInspected(watched.url.path)
        }

        watch.noteChanged([watched.url.path, unwatched.url.path])
        try await eventually { inspections.count(of: watched.url.path) == 2 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(inspections.count(of: unwatched.url.path) == 0)
        #expect(!watch.hasInspected(unwatched.url.path))
    }

    @Test func noticesLinkedWorktreeEditsStagingCommitsAndDeletion() async throws {
        let repo = try GitRepo()
        let scratch = ScratchDirectory(prefix: "working-tree-watch")
        let worktree = scratch.path("linked")
        try repo.git("worktree", "add", "-q", "-b", "linked", worktree.path)
        defer { _ = try? repo.git("worktree", "remove", "--force", worktree.path) }

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
        private var counts: [String: Int] = [:]
        let result: Int
        let delay: Duration

        init(result: Int, delay: Duration = .zero) {
            self.result = result
            self.delay = delay
        }

        var value: Int { lock.withLock { count } }

        func count(of path: String) -> Int {
            let key = URL(fileURLWithPath: path).standardizedFileURL.path
            return lock.withLock { counts[key, default: 0] }
        }

        func inspect(_ path: String) async -> Int {
            lock.withLock {
                count += 1
                counts[path, default: 0] += 1
            }
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
