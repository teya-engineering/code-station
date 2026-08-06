import Foundation
import Testing
@testable import MenuBarApp

// The warning the new session sheet shows about the checkout a session would fork from.
// A wrong answer either lets work start from stale code in silence or nags about a
// checkout that is exactly where it should be.
struct GitFreshnessTests {

    @Test func staysQuietForACleanCloneOnTheDefaultBranch() async throws {
        let pair = try ClonedRepo()
        let report = try #require(await GitFreshness.check(at: pair.clone.path, fetch: false))
        #expect(report.currentBranch == "main")
        #expect(report.defaultBranch == "main")
        #expect(report.remoteRef == "origin/main")
        #expect(report.behind == 0)
        #expect(!report.isStale)
    }

    @Test func countsCommitsTheRemoteHasGained() async throws {
        let pair = try ClonedRepo()
        try pair.origin.commit("more.txt", "more")

        // Without a fetch the clone's remote refs still say nothing happened.
        let stale = try #require(await GitFreshness.check(at: pair.clone.path, fetch: false))
        #expect(stale.behind == 0)

        let fresh = try #require(await GitFreshness.check(at: pair.clone.path, fetch: true))
        #expect(fresh.fetched)
        #expect(fresh.behind == 1)
        #expect(fresh.isStale)
    }

    @Test func noticesAFeatureBranch() async throws {
        let pair = try ClonedRepo()
        pair.clone.git("checkout", "-q", "-b", "feature")
        let report = try #require(await GitFreshness.check(at: pair.clone.path, fetch: false))
        #expect(report.currentBranch == "feature")
        #expect(!report.onDefaultBranch)
        #expect(report.isStale)
    }

    @Test func noticesADetachedHead() async throws {
        let pair = try ClonedRepo()
        pair.clone.git("checkout", "-q", "--detach")
        let report = try #require(await GitFreshness.check(at: pair.clone.path, fetch: false))
        #expect(report.currentBranch == nil)
        #expect(!report.onDefaultBranch)
    }

    @Test func noticesUncommittedWork() async throws {
        let pair = try ClonedRepo()
        try pair.clone.write("README.md", "changed")
        let report = try #require(await GitFreshness.check(at: pair.clone.path, fetch: false))
        #expect(report.dirty)
    }

    // The pull-first option is only offered when it cannot go wrong: a clean checkout,
    // on the default branch, with a remote to pull from.
    @Test func offersAFastForwardOnlyForACleanDefaultBranchCheckout() async throws {
        let pair = try ClonedRepo()
        try pair.origin.commit("more.txt", "more")

        let clean = try #require(await GitFreshness.check(at: pair.clone.path, fetch: true))
        #expect(clean.canFastForward)

        try pair.clone.write("README.md", "changed")
        let dirty = try #require(await GitFreshness.check(at: pair.clone.path, fetch: false))
        #expect(!dirty.canFastForward)
    }

    @Test func doesNotOfferAFastForwardOffTheDefaultBranch() async throws {
        let pair = try ClonedRepo()
        try pair.origin.commit("more.txt", "more")
        pair.clone.git("checkout", "-q", "-b", "feature")
        let report = try #require(await GitFreshness.check(at: pair.clone.path, fetch: true))
        #expect(report.behind == 1)
        #expect(!report.canFastForward)
    }

    // Without a remote the local main is the only yardstick, so being on a feature
    // branch still reads as off the default branch.
    @Test func fallsBackToALocalMainWhenThereIsNoRemote() async throws {
        let repo = try Repo(name: "lone")
        repo.git("checkout", "-q", "-b", "feature")
        let report = try #require(await GitFreshness.check(at: repo.path, fetch: false))
        #expect(report.defaultBranch == "main")
        #expect(report.remoteRef == nil)
        #expect(!report.onDefaultBranch)
    }

    // A repository with no commits has nothing to compare, and a plain folder is not a
    // repository at all: both are nothing for the sheet to warn about.
    @Test func saysNothingWithoutACommitToStandOn() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("freshness-plain-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(await GitFreshness.check(at: folder.path, fetch: false) == nil)
    }

    // MARK: - Fixtures

    // A repository with one commit in it, thrown away with the test.
    private final class Repo {
        let url: URL
        var path: String { url.path }

        init(name: String) throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("freshness-\(name)-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            git("init", "-q", "-b", "main")
            try commit("README.md", "hello")
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ name: String, _ contents: String) throws {
            try contents.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        func commit(_ name: String, _ contents: String) throws {
            try write(name, contents)
            git("add", ".")
            git("commit", "-qm", "change " + name)
        }

        func git(_ arguments: String...) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            // The machine running this may have no identity configured, and a commit
            // without one fails.
            process.arguments = ["git", "-c", "user.email=t@example.com",
                                 "-c", "user.name=Test", "-c", "commit.gpgsign=false"]
                + arguments
            process.currentDirectoryURL = url
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    // An origin and a clone of it, so fetches and behind-counts work without a network.
    private final class ClonedRepo {
        let origin: Repo
        let clone: Repo

        init() throws {
            origin = try Repo(name: "origin")
            clone = try Repo(name: "clone")
            // Cloning into the existing folder keeps Repo's cleanup; the fixture commit
            // there gives way to the clone's contents.
            try FileManager.default.removeItem(at: clone.url)
            origin.git("clone", "-q", origin.path, clone.path)
        }
    }
}
