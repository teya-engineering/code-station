import Foundation
import Testing
@testable import MenuBarApp

struct GitBranchesTests {
    private func branch(_ name: String, _ repo: GitRepo) async throws -> GitBranch {
        let catalog = try await GitBranches.catalog(at: repo.path).get()
        return try #require(catalog.branches.first { $0.name == name })
    }

    private func preview(_ name: String, _ repo: GitRepo) async throws -> GitBranchPreview {
        try await GitBranches.preview(branch(name, repo), at: repo.path).get()
    }

    private func feature(_ repo: GitRepo, conflict: Bool = false) throws {
        try repo.git("switch", "-c", "feature")
        try repo.write(conflict ? "README.md" : "feature.txt", "incoming\n")
        try repo.commit("Incoming change")
        try repo.git("switch", "main")
        if conflict {
            try repo.write("README.md", "current\n")
            try repo.commit("Current change")
        }
    }

    @Test func selectingAndPreviewingDoNotChangeCheckoutOrIndex() async throws {
        let repo = try GitRepo()
        try feature(repo)
        try repo.write("draft.txt", "draft")
        let head = repo.head
        let status = try repo.git("status", "--porcelain")
        let preview = try await preview("feature", repo)
        #expect(preview.source.name == "feature")
        #expect(preview.destination == "main")
        #expect(preview.incoming.count == 1)
        #expect(preview.files.map(\.path) == ["feature.txt"])
        #expect(preview.conflicts.isEmpty)
        #expect(preview.conflictNote == nil)
        #expect(preview.dirtyCount == 1)
        #expect(repo.head == head)
        #expect(try repo.git("status", "--porcelain") == status)
    }

    @Test(arguments: [GitBranchRecovery.Kind.merge, .squash])
    func mergeRequiresConsentAndRestoresTrackedAndUntrackedWork(_ kind: GitBranchRecovery.Kind) async throws {
        let repo = try GitRepo()
        try feature(repo)
        try repo.write("README.md", "staged work")
        try repo.git("add", "README.md")
        try repo.write("README.md", "unstaged work")
        try repo.write("notes.txt", "untracked work")
        let before = repo.head
        let preview = try await preview("feature", repo)
        let blocked = await GitBranches.integrate(preview, kind: kind, consent: false, at: repo.path)
        #expect(blocked.failed)
        #expect(repo.head == before)
        let result = await GitBranches.integrate(preview, kind: kind, consent: true, at: repo.path)
        #expect(!result.failed, Comment(rawValue: result.message))
        #expect(result.recovery == nil)
        #expect(repo.read("README.md") == "unstaged work")
        #expect(try repo.git("show", ":README.md") == "staged work")
        #expect(repo.read("notes.txt") == "untracked work")
        #expect(repo.read("feature.txt") == "incoming\n")
        #expect(try repo.git("stash", "list").isEmpty)
        let parents = try repo.git("rev-list", "--parents", "-n", "1", "HEAD").split(separator: " ")
        #expect(parents.count == (kind == .merge ? 3 : 2))
        #expect(try await self.preview("feature", repo).incoming.isEmpty)
    }

    @Test(arguments: ["head", "source", "tracked", "untracked"])
    func stalePreviewCannotMutateTheRepository(_ change: String) async throws {
        let repo = try GitRepo()
        try feature(repo)
        try repo.write("draft.txt", "first version")
        let preview = try await preview("feature", repo)
        switch change {
        case "head": try repo.commit("Another commit")
        case "source": try repo.git("branch", "-f", "feature", "HEAD")
        case "tracked": try repo.write("README.md", "changed after preview")
        default: try repo.write("draft.txt", "changed after preview")
        }
        let head = repo.head
        let result = await GitBranches.integrate(preview, kind: .merge, consent: true, at: repo.path)
        #expect(result.failed)
        #expect(result.message.contains("changed"))
        #expect(repo.head == head)
        #expect(try repo.git("stash", "list").isEmpty)
    }

    @Test func conflictCanBeInspectedEditedAndCompleted() async throws {
        let repo = try GitRepo()
        try feature(repo, conflict: true)
        try repo.write("draft.txt", "keep local work")
        let preview = try await preview("feature", repo)
        #expect(preview.conflicts == ["README.md"])
        let result = await GitBranches.integrate(preview, kind: .merge, consent: true, at: repo.path)
        #expect(result.failed)
        #expect(result.recovery != nil)
        #expect(await GitBranches.continueOperation(at: repo.path).failed)
        let conflicted = GitChange(path: "README.md", originalPath: nil, kind: .conflicted,
                                   isStaged: false, isUnstaged: true,
                                   added: nil, removed: nil, isBinary: false)
        #expect(await GitActions.commitSelected(message: "Must not bypass recovery",
                                                files: [conflicted], at: repo.path) != nil)
        let versions = await GitBranches.contents(path: "README.md", at: repo.path)
        #expect(versions.current == "current\n")
        #expect(versions.incoming == "incoming\n")
        #expect(await GitBranches.resolve(path: "README.md", text: "<<<<<<< unresolved\n", at: repo.path).failed)
        #expect(!(await GitBranches.resolve(path: "README.md", text: "combined\n", at: repo.path).failed))
        let finished = await GitBranches.continueOperation(at: repo.path)
        #expect(!finished.failed, Comment(rawValue: finished.message))
        #expect(repo.read("README.md") == "combined\n")
        #expect(repo.read("draft.txt") == "keep local work")
        #expect(try await GitBranches.catalog(at: repo.path).get().recovery == nil)
    }

    @Test(arguments: [GitBranchRecovery.Kind.merge, .squash, .rebase])
    func abortRestoresTheOriginalBranchAndLocalWork(_ kind: GitBranchRecovery.Kind) async throws {
        let repo = try GitRepo()
        try feature(repo, conflict: true)
        try repo.write("draft.txt", "local")
        let head = repo.head
        let result = await GitBranches.integrate(try await preview("feature", repo), kind: kind, consent: true, at: repo.path)
        #expect(result.recovery != nil, Comment(rawValue: result.message))
        let aborted = await GitBranches.abort(at: repo.path)
        #expect(!aborted.failed, Comment(rawValue: aborted.message))
        #expect(repo.head == head)
        #expect(try repo.git("branch", "--show-current") == "main")
        #expect(repo.read("README.md") == "current\n")
        #expect(repo.read("draft.txt") == "local")
        #expect(try repo.git("stash", "list").isEmpty)
    }

    @Test func rebaseCanResolveAndContinue() async throws {
        let repo = try GitRepo()
        try feature(repo, conflict: true)
        let result = await GitBranches.integrate(try await preview("feature", repo), kind: .rebase, consent: true, at: repo.path)
        #expect(result.recovery?.kind == .rebase)
        #expect(!(await GitBranches.resolve(path: "README.md", text: "combined\n", at: repo.path).failed))
        let continued = await GitBranches.continueOperation(at: repo.path)
        #expect(!continued.failed, Comment(rawValue: continued.message))
        #expect(try repo.git("branch", "--show-current") == "main")
        #expect(repo.read("README.md") == "combined\n")
    }

    @Test func restorationFailureRetainsStashAcrossRecovery() async throws {
        let repo = try GitRepo()
        try feature(repo, conflict: true)
        try repo.write("README.md", "local work on conflicting file\n")
        let result = await GitBranches.integrate(try await preview("feature", repo), kind: .merge, consent: true, at: repo.path)
        #expect(result.recovery?.stash != nil)
        #expect(!(await GitBranches.resolve(path: "README.md", side: "theirs", at: repo.path).failed))
        let finished = await GitBranches.continueOperation(at: repo.path)
        #expect(finished.failed)
        #expect(finished.recovery?.restoring == true)
        #expect(!((try repo.git("stash", "list")).isEmpty))
        #expect(try await GitBranches.catalog(at: repo.path).get().recovery?.restoring == true)
        for path in await GitBranches.conflicts(at: repo.path) {
            #expect(!(await GitBranches.resolve(path: path, text: "restored and combined\n", at: repo.path).failed))
        }
        let recovered = await GitBranches.continueOperation(at: repo.path)
        #expect(!recovered.failed)
        #expect(!((try repo.git("stash", "list")).isEmpty))
    }

    @Test func switchingLeavesWorkInANamedStashForOriginalBranch() async throws {
        let repo = try GitRepo()
        try feature(repo)
        try repo.write("draft.txt", "unfinished")
        let preview = try await preview("feature", repo)
        #expect(await GitBranches.switchBranch(preview, consent: false, at: repo.path).failed)
        let result = await GitBranches.switchBranch(preview, consent: true, at: repo.path)
        #expect(!result.failed, Comment(rawValue: result.message))
        #expect(try repo.git("branch", "--show-current") == "feature")
        #expect(repo.read("draft.txt") == nil)
        let stash = try #require(try await GitBranches.catalog(at: repo.path).get().stashes.first)
        #expect(stash.message.contains("main"))
        #expect(!(await GitBranches.restore(stash, at: repo.path).failed))
        #expect(repo.read("draft.txt") == "unfinished")
        #expect(try repo.git("stash", "list").isEmpty)
    }

    @Test func createValidateRenameDeleteAndOccupancy() async throws {
        let repo = try GitRepo()
        #expect(await GitBranches.create(name: "invalid name", from: nil, at: repo.path).failed)
        #expect(!(await GitBranches.create(name: "feature", from: nil, at: repo.path).failed))
        #expect(await GitBranches.create(name: "feature", from: nil, at: repo.path).failed)
        #expect(await GitBranches.delete(try await branch("feature", repo), force: true, at: repo.path).failed)
        try repo.git("switch", "main")
        #expect(!(await GitBranches.rename(try await branch("feature", repo), to: "renamed", at: repo.path).failed))
        #expect(!(await GitBranches.delete(try await branch("renamed", repo), force: false, at: repo.path).failed))
        let scratch = ScratchDirectory(prefix: "branch-worktree")
        let path = scratch.url.appendingPathComponent("checkout").path
        let result = await GitBranches.create(name: "isolated", from: try await branch("main", repo), worktree: path, at: repo.path)
        #expect(!result.failed, Comment(rawValue: result.message))
        let occupied = try await branch("isolated", repo)
        #expect(URL(fileURLWithPath: occupied.worktree).resolvingSymlinksInPath() == URL(fileURLWithPath: path).resolvingSymlinksInPath())
        #expect(await GitBranches.delete(occupied, force: true, at: repo.path).failed)
        #expect(await GitBranches.switchBranch(try await preview("isolated", repo), consent: false, at: repo.path).failed)
        #expect(try repo.git("branch", "--show-current") == "main")
    }

    @Test func unmergedBranchNeedsExplicitForceDeletion() async throws {
        let repo = try GitRepo()
        try feature(repo)
        let feature = try await branch("feature", repo)
        #expect(await GitBranches.delete(feature, force: false, at: repo.path).failed)
        #expect(!(await GitBranches.delete(feature, force: true, at: repo.path).failed))
    }

    @Test func remotePreviewReportsFailedFetchAndCannotMerge() async throws {
        let repo = try GitRepo()
        try feature(repo)
        try repo.git("remote", "add", "other", "/private/tmp/missing-code-station-design-remote")
        try repo.git("update-ref", "refs/remotes/other/feature", "refs/heads/feature")
        let preview = try await preview("other/feature", repo)
        #expect(!preview.remoteVerified)
        #expect(preview.freshness.contains("Fetch failed"))
        #expect(await GitBranches.integrate(preview, kind: .merge, consent: true, at: repo.path).failed)
    }

    @Test func newBranchSupportsAnUnbornRepositoryAndRenamingTheCurrentBranch() async throws {
        let repo = try GitRepo(initialCommit: false)
        #expect(!(await GitBranches.create(name: "first-work", from: nil, at: repo.path).failed))
        try repo.write("README.md", "first")
        try repo.commit("First commit")
        let result = await GitBranches.rename(try await branch("first-work", repo), to: "renamed", at: repo.path)
        #expect(!result.failed, Comment(rawValue: result.message))
        #expect(try repo.git("branch", "--show-current") == "renamed")
    }

    @Test func remoteTrackingBranchCanBeFetchedAndSwitchedExplicitly() async throws {
        let upstream = try GitRepo()
        try feature(upstream)
        let remote = try upstream.clone(bare: true)
        let repo = try remote.clone()
        let preview = try await preview("origin/feature", repo)
        #expect(preview.remoteVerified)
        #expect(preview.source.remote)
        #expect(preview.freshness.contains("Fetched origin"))
        let result = await GitBranches.switchBranch(preview, consent: false, at: repo.path)
        #expect(!result.failed, Comment(rawValue: result.message))
        #expect(try repo.git("branch", "--show-current") == "feature")
        #expect(try repo.git("rev-parse", "--abbrev-ref", "@{u}") == "origin/feature")
    }

    @Test func resolvingADeletionAndSkippingARebaseCommitHaveRecoveryPaths() async throws {
        let repo = try GitRepo()
        try repo.git("switch", "-c", "feature")
        try repo.git("rm", "README.md")
        try repo.commit("Remove readme")
        try repo.git("switch", "main")
        try repo.write("README.md", "edited readme")
        try repo.commit("Edit readme")
        let result = await GitBranches.integrate(try await preview("feature", repo), kind: .merge, consent: false, at: repo.path)
        #expect(result.recovery != nil)
        let resolved = await GitBranches.resolve(path: "README.md", side: "theirs", at: repo.path)
        #expect(!resolved.failed, Comment(rawValue: resolved.message))
        #expect(!(await GitBranches.continueOperation(at: repo.path).failed))
        #expect(repo.read("README.md") == nil)

        let rebasing = try GitRepo()
        try feature(rebasing, conflict: true)
        #expect(await GitBranches.integrate(try await preview("feature", rebasing), kind: .rebase, consent: false, at: rebasing.path).recovery != nil)
        let skipped = await GitBranches.skipRebaseCommit(at: rebasing.path)
        #expect(!skipped.failed, Comment(rawValue: skipped.message))
        #expect(rebasing.read("README.md") == "incoming\n")
    }

    @Test func fastForwardMovesTheBranchWithoutANewCommitOnlyWhenItCan() async throws {
        let repo = try GitRepo()
        try feature(repo)
        let tip = try repo.git("rev-parse", "feature")
        let result = await GitBranches.integrate(try await preview("feature", repo), kind: .fastForward, consent: false, at: repo.path)
        #expect(!result.failed, Comment(rawValue: result.message))
        #expect(repo.head == tip)

        let diverged = try GitRepo()
        try feature(diverged, conflict: true)
        let head = diverged.head
        let blocked = await GitBranches.integrate(try await preview("feature", diverged), kind: .fastForward, consent: false, at: diverged.path)
        #expect(blocked.failed)
        #expect(diverged.head == head)
    }

    // Mirrors merging a worktree branch into main, which stays checked out in the main checkout.
    @Test func mergingIntoAnotherCheckoutFinishesThereAndRefusesWhatItCannotUndo() async throws {
        let repo = try GitRepo()
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("git-worktree-" + UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        try repo.git("worktree", "add", "-q", "-b", "feature", worktree)
        try "incoming\n".write(toFile: worktree + "/feature.txt", atomically: true, encoding: .utf8)
        try repo.git("-C", worktree, "add", "feature.txt")
        try repo.git("-C", worktree, "commit", "-q", "-m", "Incoming change")
        let source = try await branch("feature", repo)
        #expect(!source.worktree.isEmpty)

        try repo.write("draft.txt", "main checkout work")
        let dirty = await GitBranches.integrateIntoOtherCheckout(try await preview("feature", repo), kind: .fastForward, at: repo.path)
        #expect(dirty.failed)
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("draft.txt"))

        let result = await GitBranches.integrateIntoOtherCheckout(try await preview("feature", repo), kind: .fastForward, at: repo.path)
        #expect(!result.failed, Comment(rawValue: result.message))
        #expect(repo.head == (try repo.git("rev-parse", "feature")))
        #expect(repo.read("feature.txt") == "incoming\n")

        try "worktree side\n".write(toFile: worktree + "/README.md", atomically: true, encoding: .utf8)
        try repo.git("-C", worktree, "commit", "-q", "-am", "Worktree change")
        try repo.write("README.md", "main side\n")
        try repo.commit("Main change")
        let head = repo.head
        let conflicted = await GitBranches.integrateIntoOtherCheckout(try await preview("feature", repo), kind: .merge, at: repo.path)
        #expect(conflicted.failed)
        #expect(repo.head == head)
        #expect(try repo.git("status", "--porcelain").isEmpty)
        #expect(try await GitBranches.catalog(at: repo.path).get().recovery == nil)
    }

    @Test func operationsRemainScopedToTheSelectedRepository() async throws {
        let first = try GitRepo()
        let second = try GitRepo()
        try feature(second)
        let firstHead = first.head
        let secondHead = second.head
        let result = await GitBranches.integrate(try await preview("feature", second), kind: .merge, consent: false, at: second.path)
        #expect(!result.failed)
        #expect(first.head == firstHead)
        #expect(second.head != secondHead)
        #expect(first.read("feature.txt") == nil)
        #expect(second.read("feature.txt") == "incoming\n")
    }

    @Test(arguments: [GitBranchRecovery.Kind.merge, .rebase])
    func externallyFinishedOperationsCanRecoverWithoutMovingTheBranchAgain(_ kind: GitBranchRecovery.Kind) async throws {
        let repo = try GitRepo()
        try feature(repo, conflict: true)
        try repo.write("draft.txt", "saved local work")
        let result = await GitBranches.integrate(try await preview("feature", repo), kind: kind, consent: true, at: repo.path)
        #expect(result.recovery != nil)
        if kind == .merge {
            try repo.write("README.md", "resolved in an editor")
            try repo.git("add", "README.md")
            try repo.git("commit", "-m", "Finish merge externally")
        } else {
            try repo.git("rebase", "--abort")
        }
        let head = repo.head
        let recovered = await GitBranches.continueOperation(at: repo.path)
        #expect(!recovered.failed, Comment(rawValue: recovered.message))
        #expect(recovered.recovery == nil)
        #expect(repo.head == head)
        #expect(repo.read("draft.txt") == "saved local work")
        #expect(try await GitBranches.catalog(at: repo.path).get().recovery == nil)
    }

    @Test @MainActor func commitDraftAndSelectionsStayWithTheirRepository() {
        let navigation = ChangesNavigationMemory()
        let first = navigation.commitDraft(for: "/first")
        first.message = "First change"
        first.excluded = ["leave.txt"]
        first.setAmend(true, lastMessage: "Last commit")
        let second = navigation.commitDraft(for: "/second")
        second.message = "Second change"
        #expect(first === navigation.commitDraft(for: "/first"))
        #expect(first.message == "Last commit")
        first.setAmend(false, lastMessage: nil)
        #expect(first.message == "First change")
        first.didCommit()
        #expect(first.message.isEmpty)
        #expect(first.excluded == ["leave.txt"])
        #expect(second.message == "Second change")
        #expect(second.excluded.isEmpty)
    }
}
