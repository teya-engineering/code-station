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
        #expect(report.defaultBranchAhead == 0)
        #expect(report.defaultBranchBehind == 0)
        #expect(!report.isStale)
    }

    @Test func countsCommitsTheRemoteHasGained() async throws {
        let pair = try ClonedRepo()
        try pair.origin.commitChange("more.txt", "more")

        // Without a fetch the clone's remote refs still say nothing happened.
        let stale = try #require(await GitFreshness.check(at: pair.clone.path, fetch: false))
        #expect(stale.behind == 0)

        let fresh = try #require(await GitFreshness.check(at: pair.clone.path, fetch: true))
        #expect(fresh.fetched)
        #expect(fresh.behind == 1)
        #expect(fresh.defaultBranchBehind == 1)
        #expect(fresh.isStale)
    }

    // HEAD may be a feature branch, but the update offered by the sheet switches to main.
    // Its safety and copy therefore have to describe main rather than the checked-out ref.
    @Test func measuresDivergenceOnTheDefaultBranchInsteadOfHead() async throws {
        let pair = try ClonedRepo()
        try pair.clone.commitChange("local.txt", "local main work")
        try pair.clone.git("checkout", "-q", "-b", "feature")
        try pair.clone.commitChange("feature.txt", "feature work")
        try pair.origin.commitChange("remote.txt", "remote work")

        let report = try #require(await GitFreshness.check(at: pair.clone.path, fetch: true))
        #expect(report.currentBranch == "feature")
        #expect(report.defaultBranchAhead == 1)
        #expect(report.defaultBranchBehind == 1)
        #expect(report.defaultBranchHasDiverged)
        #expect(report.canUpdateCheckout)
    }

    @Test func noticesAFeatureBranch() async throws {
        let pair = try ClonedRepo()
        try pair.clone.git("checkout", "-q", "-b", "feature")
        let report = try #require(await GitFreshness.check(at: pair.clone.path, fetch: false))
        #expect(report.currentBranch == "feature")
        #expect(!report.onDefaultBranch)
        #expect(report.isStale)
    }

    @Test func noticesADetachedHead() async throws {
        let pair = try ClonedRepo()
        try pair.clone.git("checkout", "-q", "--detach")
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
        try pair.origin.commitChange("more.txt", "more")

        let clean = try #require(await GitFreshness.check(at: pair.clone.path, fetch: true))
        #expect(clean.canUpdateCheckout)

        try pair.clone.write("README.md", "changed")
        let dirty = try #require(await GitFreshness.check(at: pair.clone.path, fetch: false))
        #expect(!dirty.canUpdateCheckout)
    }

    // A dirty folder only gets the default branch moved, and only when that move is a
    // fast-forward.
    @Test func offersToFastForwardTheDefaultBranchOfADirtyFolder() async throws {
        let pair = try ClonedRepo()
        try pair.origin.commitChange("more.txt", "more")
        try pair.clone.write("README.md", "changed")

        let dirty = try #require(await GitFreshness.check(at: pair.clone.path, fetch: true))
        #expect(dirty.canFastForwardDefaultBranch)

        try pair.clone.git("commit", "-qam", "local work")
        try pair.clone.write("README.md", "changed again")
        let diverged = try #require(await GitFreshness.check(at: pair.clone.path, fetch: false))
        #expect(!diverged.canFastForwardDefaultBranch)
    }

    @Test func offersToUpdateACheckoutSittingOnAnotherBranch() async throws {
        let pair = try ClonedRepo()
        try pair.origin.commitChange("more.txt", "more")
        try pair.clone.git("checkout", "-q", "-b", "feature")
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

        let lone = try GitRepo()
        try lone.git("checkout", "-q", "-b", "feature")
        let remoteless = try #require(await GitFreshness.check(at: lone.path, fetch: false))
        #expect(remoteless.isStale)
        #expect(!remoteless.canUpdateCheckout)
    }

    // Without a remote the local main is the only yardstick, so being on a feature
    // branch still reads as off the default branch.
    @Test func fallsBackToALocalMainWhenThereIsNoRemote() async throws {
        let repo = try GitRepo()
        try repo.git("checkout", "-q", "-b", "feature")
        let report = try #require(await GitFreshness.check(at: repo.path, fetch: false))
        #expect(report.defaultBranch == "main")
        #expect(report.remoteRef == nil)
        #expect(!report.onDefaultBranch)
    }

    // A repository with no commits has nothing to compare, and a plain folder is not a
    // repository at all: both are nothing for the sheet to warn about.
    @Test func saysNothingWithoutACommitToStandOn() async throws {
        let folder = ScratchDirectory(prefix: "freshness-plain")
        #expect(await GitFreshness.check(at: folder.url.path, fetch: false) == nil)
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

        let diverged = GitFreshness.Report(currentBranch: "main", defaultBranch: "main",
                                           remoteRef: "origin/main", behind: 2,
                                           defaultBranchAhead: 1, defaultBranchBehind: 2)
        #expect(diverged.explanation
                == "main and origin/main have diverged: main has 1 local commit and origin/main has 2 remote commits.")

        let unreachable = GitFreshness.Report(currentBranch: "main", defaultBranch: "main",
                                              remoteRef: "origin/main",
                                              fetchAttempted: true, fetched: false)
        #expect(unreachable.explanation
                == "The checkout is main at its latest revision. Origin could not be reached, so this may be out of date.")
    }

    // A retry only earns a longer wait when origin was slow, and the wait stops
    // climbing at the last step.
    @Test func climbsTheWaitLadderOnlyAfterATimeout() {
        var report = GitFreshness.Report(fetchAttempted: true, fetched: false, fetchWait: 8,
                                         fetchTimedOut: true)
        #expect(report.retryWait == 30)
        report.fetchWait = 30
        #expect(report.retryWait == 60)
        report.fetchWait = 60
        #expect(report.retryWait == 60)

        let refused = GitFreshness.Report(fetchAttempted: true, fetched: false, fetchWait: 30,
                                          fetchFailure: "fatal: Could not read from remote repository.")
        #expect(refused.retryWait == 30)
    }

    // The notice names the wait when origin was slow, and points away from waiting when
    // origin said no.
    @Test func explainsAFailedFetchByHowItFailed() {
        let first = GitFreshness.Report(fetchAttempted: true, fetched: false, fetchWait: 8,
                                        fetchTimedOut: true)
        #expect(first.fetchProblem == "Origin did not answer within 8 seconds, so this may be out of date.")
        #expect(first.fetchAdvice == "A slow VPN or a large repository can take longer than that.")

        let again = GitFreshness.Report(fetchAttempted: true, fetched: false, fetchWait: 30,
                                        fetchTimedOut: true)
        #expect(again.fetchProblem == "Origin did not answer within 30 seconds, so this may be out of date.")
        #expect(again.fetchAdvice == "Still no answer. Check that you are on the VPN, or start from what is already here.")

        let key = GitFreshness.Report(fetchAttempted: true, fetched: false, fetchWait: 8,
                                      fetchFailure: "git@github.com: Permission denied (publickey).")
        #expect(key.fetchProblem == "Origin refused the fetch, so this may be out of date.")
        #expect(key.fetchAdvice == "Waiting longer will not help here. Check that your SSH key is loaded, then try again.")

        let fine = GitFreshness.Report(fetchAttempted: true, fetched: true, fetchWait: 8)
        #expect(fine.fetchProblem == nil)
        #expect(fine.fetchAdvice == nil)
    }

    @Test func keepsWhatGitSaidWhenOriginRefuses() async throws {
        let pair = try ClonedRepo()
        try pair.clone.git("remote", "set-url", "origin", pair.origin.path + "-missing")

        let report = try #require(await GitFreshness.check(at: pair.clone.path, fetch: true))
        #expect(report.fetchFailed)
        #expect(!report.fetchTimedOut)
        #expect(report.fetchWait == 8)
        #expect(report.fetchFailure?.isEmpty == false)
    }

    @Test func tellsATimeoutFromARefusal() async throws {
        let pair = try ClonedRepo()
        try pair.clone.git("config", "protocol.ext.allow", "always")
        try pair.clone.git("remote", "set-url", "origin", "ext::sh -c sleep% 10")

        let report = try #require(await GitFreshness.check(at: pair.clone.path, fetch: true,
                                                           timeout: 0.5))
        #expect(report.fetchFailed)
        #expect(report.fetchTimedOut)
        #expect(report.fetchFailure == nil)
        #expect(report.fetchWait == 0.5)
    }

    // Stopping a retry gives no report at all, so the card keeps the failure it had.
    @Test func answersNothingWhenTheFetchIsStopped() async throws {
        let pair = try ClonedRepo()
        try pair.clone.git("config", "protocol.ext.allow", "always")
        try pair.clone.git("remote", "set-url", "origin", "ext::sh -c sleep% 10")

        let started = Date.now
        let check = Task { await GitFreshness.check(at: pair.clone.path, fetch: true, timeout: 30) }
        try await Task.sleep(for: .milliseconds(300))
        check.cancel()
        #expect(await check.value == nil)
        #expect(Date.now.timeIntervalSince(started) < 5)
    }

    // New sessions start from the default branch at its latest revision and bring the
    // project folder along, unless uncommitted work makes the update unsafe.
    @Test func recommendsUpdatingTheCheckoutFirst() {
        let behind = GitFreshness.Report(currentBranch: "main", defaultBranch: "main",
                                         remoteRef: "origin/main", behind: 2)
        #expect(SessionStartPoint.recommended(for: behind, worktree: true) == .updateCheckout)
        #expect(SessionStartPoint.recommended(for: behind, worktree: false) == .updateCheckout)

        let diverged = GitFreshness.Report(currentBranch: "main", defaultBranch: "main",
                                           remoteRef: "origin/main", behind: 2,
                                           defaultBranchAhead: 1, defaultBranchBehind: 2)
        #expect(SessionStartPoint.recommended(for: diverged, worktree: true) == .updateCheckout)

        let elsewhere = GitFreshness.Report(currentBranch: "feature", defaultBranch: "main",
                                            remoteRef: "origin/main")
        #expect(SessionStartPoint.recommended(for: elsewhere, worktree: true) == .updateCheckout)

        let dirty = GitFreshness.Report(currentBranch: "main", defaultBranch: "main",
                                        remoteRef: "origin/main", behind: 2, dirty: true)
        #expect(SessionStartPoint.recommended(for: dirty, worktree: true) == .remote)
        #expect(SessionStartPoint.recommended(for: dirty, worktree: false) == .currentCheckout)

        let fine = GitFreshness.Report(currentBranch: "main", defaultBranch: "main",
                                       remoteRef: "origin/main")
        #expect(SessionStartPoint.recommended(for: fine, worktree: true) == .currentCheckout)
    }

    // MARK: - Fixtures

    // An origin and a clone of it, so fetches and behind-counts work without a network.
    private struct ClonedRepo {
        let origin: GitRepo
        let clone: GitRepo

        init() throws {
            origin = try GitRepo()
            clone = try origin.clone()
        }
    }
}

private extension GitRepo {
    func commitChange(_ name: String, _ contents: String) throws {
        try write(name, contents)
        try commit("change " + name)
    }
}
