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

    // Updating the checkout is offered whenever it cannot go wrong: a clean checkout
    // with a remote to catch up with, whether it trails the default branch or sits on
    // another one.
    @Test func offersToUpdateACleanCheckoutThatIsBehind() async throws {
        let pair = try ClonedRepo()
        try pair.origin.commit("more.txt", "more")

        let clean = try #require(await GitFreshness.check(at: pair.clone.path, fetch: true))
        #expect(clean.canUpdateCheckout)

        try pair.clone.write("README.md", "changed")
        let dirty = try #require(await GitFreshness.check(at: pair.clone.path, fetch: false))
        #expect(!dirty.canUpdateCheckout)
    }

    @Test func offersToUpdateACheckoutSittingOnAnotherBranch() async throws {
        let pair = try ClonedRepo()
        try pair.origin.commit("more.txt", "more")
        pair.clone.git("checkout", "-q", "-b", "feature")
        let report = try #require(await GitFreshness.check(at: pair.clone.path, fetch: true))
        #expect(report.behind == 1)
        #expect(report.canUpdateCheckout)
    }

    // Nothing to catch up with means nothing to offer, and without a remote there is no
    // latest revision to name.
    @Test func offersNoUpdateWithNothingToCatchUpWith() async throws {
        let pair = try ClonedRepo()
        let fresh = try #require(await GitFreshness.check(at: pair.clone.path, fetch: true))
        #expect(!fresh.canUpdateCheckout)

        let lone = try Repo(name: "lone")
        lone.git("checkout", "-q", "-b", "feature")
        let remoteless = try #require(await GitFreshness.check(at: lone.path, fetch: false))
        #expect(remoteless.isStale)
        #expect(!remoteless.canUpdateCheckout)
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

    // The one-line caption the workspace rows show in a tooltip. It has to read as a
    // warning when something is off and as reassurance when nothing is.
    @Test func explainsItselfInPlainSentences() {
        let fine = GitFreshness.Report(currentBranch: "main", defaultBranch: "main",
                                       remoteRef: "origin/main")
        #expect(fine.explanation == "The checkout is main at its latest revision.")

        let behind = GitFreshness.Report(currentBranch: "main", defaultBranch: "main",
                                         remoteRef: "origin/main", behind: 3)
        #expect(behind.explanation == "main is 3 commits behind origin/main.")

        let elsewhere = GitFreshness.Report(currentBranch: "feature", defaultBranch: "main",
                                            remoteRef: "origin/main", behind: 1)
        #expect(elsewhere.explanation
                == "The checkout is on feature, not main. It is 1 commit behind origin/main.")

        let unreachable = GitFreshness.Report(currentBranch: "main", defaultBranch: "main",
                                              remoteRef: "origin/main",
                                              fetchAttempted: true, fetched: false)
        #expect(unreachable.explanation
                == "The checkout is main at its latest revision. Origin could not be reached, so this may be out of date.")
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
