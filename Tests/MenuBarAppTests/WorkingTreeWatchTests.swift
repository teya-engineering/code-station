import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct WorkingTreeWatchTests {
    @Test func doesNotQueueASecondInspectionWhileOneIsRunning() async throws {
        let folder = try TemporaryFolder()
        let inspections = InspectionCount(result: 3, delay: .milliseconds(100))
        let watch = WorkingTreeWatch { path in
            await inspections.inspect(path)
        }

        #expect(!watch.hasInspected(folder.path))
        watch.refresh([folder.path])
        watch.refresh([folder.path])
        try await eventually { await inspections.value == 1 && watch.isDirty(folder.path) }
        #expect(watch.hasInspected(folder.path))
        #expect(watch.isDirty(folder.path))
        #expect(watch.uncommittedFileCount(at: folder.path) == 3)

        watch.refresh([folder.path])
        try await eventually { await inspections.value == 2 }
    }

    @Test func noticesLinkedWorktreeEditsStagingCommitsAndDeletion() async throws {
        let repo = try Repo()
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("working-tree-watch-linked-" + UUID().uuidString)
        repo.git("worktree", "add", "-q", "-b", "linked", worktree.path)
        defer {
            repo.git("worktree", "remove", "--force", worktree.path)
            try? FileManager.default.removeItem(at: worktree)
        }

        let inspections = RepositoryInspections()
        let watch = WorkingTreeWatch { path in
            await inspections.inspect(path)
        }

        #expect(!watch.hasInspected(worktree.path))
        watch.refresh([worktree.path])
        try await eventually { await inspections.value == 1 }
        #expect(watch.hasInspected(worktree.path))
        #expect(!watch.isDirty(worktree.path))

        try "changed".write(
            to: worktree.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try await refreshAfterEvent(
            watch, inspections: inspections, count: 2, path: worktree.path, dirty: true)

        repo.git("-C", worktree.path, "add", "README.md")
        try await refreshAfterEvent(
            watch, inspections: inspections, count: 3, path: worktree.path, dirty: true)

        repo.git("-C", worktree.path, "commit", "-qm", "change")
        try await refreshAfterEvent(
            watch, inspections: inspections, count: 4, path: worktree.path, dirty: false)

        repo.git("worktree", "remove", "--force", worktree.path)
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
            return await inspections.value >= count && watch.isDirty(path) == expected
        }
    }

    // The wait is wall-clock, but this test shares the main actor with every other one in
    // the run, so the time it actually gets to poll in is a fraction of it. The budget is
    // generous for that reason: a passing run never spends it, and a tighter one turns
    // into a failure whenever the suite grows rather than when the watch breaks.
    private func eventually(
        timeout: Duration = .seconds(20),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Condition did not become true within \(timeout)")
    }

    private actor InspectionCount {
        private(set) var value = 0
        let result: Int
        let delay: Duration

        init(result: Int, delay: Duration = .zero) {
            self.result = result
            self.delay = delay
        }

        func inspect(_ path: String) async -> Int {
            value += 1
            try? await Task.sleep(for: delay)
            return result
        }
    }

    private actor RepositoryInspections {
        private(set) var value = 0

        func inspect(_ path: String) async -> Int {
            let result = await GitInspector.uncommittedFileCount(at: path)
            value += 1
            return result
        }
    }

    private final class TemporaryFolder {
        let url: URL
        var path: String { url.path }

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("working-tree-watch-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private final class Repo {
        let url: URL
        var path: String { url.path }

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("working-tree-watch-repo-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            git("init", "-q")
            try write("README.md", "hello")
            git("add", ".")
            git("commit", "-qm", "first")
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ name: String, _ contents: String) throws {
            try contents.write(
                to: url.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }

        func git(_ arguments: String...) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "git", "-c", "user.email=t@example.com", "-c", "user.name=Test",
                "-c", "commit.gpgsign=false"
            ] + arguments
            process.currentDirectoryURL = url
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }
}
