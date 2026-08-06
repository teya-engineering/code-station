import Foundation
import Testing
@testable import MenuBarApp

// The git commands behind the changes screen's header: commit, switch, push and pull.
// They act on the user's real repository, so each one is checked against a throwaway
// repo rather than trusted to pass its arguments through correctly.
struct GitActionsTests {

    @Test func commitsEverythingInOneGo() async throws {
        let repo = try Repo()
        try repo.write("README.md", "changed")
        try repo.write("notes.txt", "untracked too")

        let error = await GitActions.commitAll(message: "Keep the lot", at: repo.path)
        #expect(error == nil)

        let after = await GitInspector.snapshot(at: repo.path)
        #expect(after.files.isEmpty)
    }

    @Test func switchesBetweenBranches() async throws {
        let repo = try Repo()
        repo.git("branch", "feature")

        let error = await GitActions.switchBranch("feature", at: repo.path)
        #expect(error == nil)

        let after = await GitInspector.snapshot(at: repo.path)
        #expect(after.branch == "feature")
        #expect(after.onBranch)
    }

    @Test func reportsWhyASwitchFailed() async throws {
        let repo = try Repo()
        let error = await GitActions.switchBranch("no-such-branch", at: repo.path)
        #expect(error?.isEmpty == false)
    }

    @Test func pushPublishesABranchWithNoUpstream() async throws {
        let repo = try Repo()
        let remote = try Bare()
        repo.git("remote", "add", "origin", remote.path)

        let before = await GitInspector.snapshot(at: repo.path)
        #expect(before.upstream == nil)

        let error = await GitActions.push(hasUpstream: false, at: repo.path)
        #expect(error == nil)

        let after = await GitInspector.snapshot(at: repo.path)
        #expect(after.upstream == "origin/main")
        #expect(after.ahead == 0)
    }

    @Test func pullBringsInTheRemoteCommits() async throws {
        let remote = try Bare()
        let first = try Repo()
        first.git("remote", "add", "origin", remote.path)
        first.git("push", "-q", "-u", "origin", "HEAD")

        let second = try Repo(cloneOf: remote)
        try first.write("README.md", "moved on")
        first.git("commit", "-qam", "second")
        first.git("push", "-q")

        // The behind count reads the tracking ref, so it only moves once a fetch has
        // seen what the remote gained.
        second.git("fetch", "-q")
        let behind = await GitInspector.snapshot(at: second.path)
        #expect(behind.behind == 1)

        let error = await GitActions.pull(at: second.path)
        #expect(error == nil)

        let after = await GitInspector.snapshot(at: second.path)
        #expect(after.behind == 0)
    }

    @Test func fastForwardPullMovesUpToTheRemoteTip() async throws {
        let remote = try Bare()
        let first = try Repo()
        first.git("remote", "add", "origin", remote.path)
        first.git("push", "-q", "-u", "origin", "HEAD")

        let second = try Repo(cloneOf: remote)
        try first.write("README.md", "moved on")
        first.git("commit", "-qam", "second")
        first.git("push", "-q")

        let error = await GitActions.fastForwardPull(at: second.path)
        #expect(error == nil)

        let after = await GitInspector.snapshot(at: second.path)
        #expect(after.behind == 0)
    }

    @Test func fastForwardPullRefusesToMerge() async throws {
        let remote = try Bare()
        let first = try Repo()
        first.git("remote", "add", "origin", remote.path)
        first.git("push", "-q", "-u", "origin", "HEAD")

        let second = try Repo(cloneOf: remote)
        try second.write("local.txt", "diverged")
        second.git("add", ".")
        second.git("commit", "-qm", "local work")
        try first.write("README.md", "moved on")
        first.git("commit", "-qam", "second")
        first.git("push", "-q")

        let error = await GitActions.fastForwardPull(at: second.path)
        #expect(error?.isEmpty == false)

        // The diverged branch is left exactly as it was.
        let after = await GitInspector.snapshot(at: second.path)
        #expect(after.ahead == 1)
    }

    @Test func snapshotListsBranchesAndCountsDrift() async throws {
        let repo = try Repo()
        let remote = try Bare()
        repo.git("remote", "add", "origin", remote.path)
        repo.git("push", "-q", "-u", "origin", "HEAD")
        repo.git("branch", "feature")
        try repo.write("README.md", "ahead now")
        repo.git("commit", "-qam", "second")

        let snapshot = await GitInspector.snapshot(at: repo.path)
        #expect(Set(snapshot.branches) == ["main", "feature"])
        #expect(snapshot.upstream == "origin/main")
        #expect(snapshot.ahead == 1)
        #expect(snapshot.behind == 0)
    }

    // A repository with one commit and an identity of its own, so the actions under test
    // can commit without leaning on the machine's git config. Thrown away with the test.
    private final class Repo {
        let url: URL
        var path: String { url.path }

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("actions-repo-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            git("init", "-q", "-b", "main")
            configureIdentity()
            try write("README.md", "hello")
            git("add", ".")
            git("commit", "-qm", "first")
        }

        init(cloneOf remote: Bare) throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("actions-clone-" + UUID().uuidString)
            Self.run(in: FileManager.default.temporaryDirectory,
                     ["clone", "-q", remote.path, url.path])
            configureIdentity()
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ name: String, _ contents: String) throws {
            try contents.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        func git(_ arguments: String...) {
            Self.run(in: url, arguments)
        }

        private func configureIdentity() {
            git("config", "user.email", "t@example.com")
            git("config", "user.name", "Test")
            git("config", "commit.gpgsign", "false")
        }

        static func run(in directory: URL, _ arguments: [String]) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    // A bare repository standing in for the remote, so push and pull never leave the
    // machine.
    private final class Bare {
        let url: URL
        var path: String { url.path }

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("actions-remote-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            Repo.run(in: url, ["init", "-q", "--bare", "-b", "main"])
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }
}
