import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct SecondOpinionContextTests {
    private let root = "/repo"
    private let changed = GitChange(path: "Committed.swift", kind: .modified, isStaged: false, isUnstaged: false,
                                    added: 12, removed: 3, isBinary: false)

    private func facts(head: Bool = false) -> SecondOpinionAskFacts {
        SecondOpinionAskFacts(file: .init(root: root, path: changed.path, added: 12, removed: 3),
                              repositories: [.init(root: root, name: "App")],
                              compareRefs: [root: "upstream/develop"], headRoots: head ? [root] : [])
    }

    private func snapshot() -> GitSnapshot {
        GitSnapshot(state: .ready, root: root, files: [changed],
                    remoteBase: .init(ref: "upstream/develop", commit: "branch-point"),
                    comparedToRemote: true, pathsChangedFromBase: [changed.path])
    }

    @Test func cleanHEADCanSwitchToCommittedBranchWorkWithoutChangingTheScreen() async {
        let facts = facts(head: true)
        let context = SecondOpinionContext(facts: facts, comparison: .changesTab)
        await context.read(snapshot: { path, ref in
            #expect(path == root)
            #expect(ref == "upstream/develop")
            return snapshot()
        }, remoteBranches: { _ in ["upstream/develop"] })

        #expect(context.inheritsComparison)
        #expect(context.files(for: .uncommitted).isEmpty)
        #expect(context.blockedReason(for: .uncommitted) != nil)
        context.comparison = .branch
        #expect(!context.inheritsComparison)
        #expect(context.files(for: .uncommitted).map(\.path) == [changed.path])
        #expect(context.scope(for: .uncommitted) == .branch(bases: [root: "upstream/develop"]))
        #expect(context.blockedReason(for: .uncommitted) == nil)
        #expect(facts.headRoots == [root])
    }

    @Test func fileScopeKeepsTheChosenBaseAndExactFile() async {
        let context = SecondOpinionContext(facts: facts(), comparison: .changesTab)
        await context.read(snapshot: { _, _ in snapshot() }, remoteBranches: { _ in [] })
        #expect(context.scope(for: .file) == .file(root: root, path: changed.path, base: "upstream/develop"))
        #expect(context.files(for: .file).count == 1)
        context.comparison = .head
        #expect(context.scope(for: .file) == .file(root: root, path: changed.path))
        #expect(context.files(for: .file).isEmpty)
        #expect(context.blockedReason(for: .file) != nil)
    }

    @Test func snapshotScopeHasItsOwnCountsEvenWithACleanWorkingTree() async {
        var facts = facts(head: true)
        facts.canReadSince = true
        facts.reviewTrees = [root: "review-tree"]
        let context = SecondOpinionContext(facts: facts, comparison: .head)
        await context.read(snapshot: { _, _ in snapshot() }, remoteBranches: { _ in [] }, since: { path, tree in
            #expect(path == root)
            #expect(tree == "review-tree")
            return [.init(root: root, path: "New.swift", label: "New.swift",
                          text: "--- a/New.swift\n+++ b/New.swift\n@@ -1 +1,2 @@\n-old\n+new\n+extra")]
        })
        #expect(context.scope(for: .sinceReview) == .sinceReview(trees: [root: "review-tree"]))
        #expect(context.files(for: .sinceReview) == [.init(root: root, path: "New.swift", added: 2, removed: 1)])
        #expect(context.blockedReason(for: .sinceReview) == nil)
    }

    @Test func failedReadsAndMissingSnapshotsBlockSubmissionAndCanRecover() async {
        var facts = facts()
        facts.canReadSince = true
        facts.reviewTrees = [root: "missing"]
        let context = SecondOpinionContext(facts: facts, comparison: .branch)
        #expect(context.blockedReason(for: .uncommitted) != nil)
        await context.read(snapshot: { _, _ in .init(state: .failed("Cannot read")) }, remoteBranches: { _ in [] },
                           since: { _, _ in nil })
        #expect(context.failure != nil)
        #expect(context.blockedReason(for: .uncommitted) != nil)
        await context.read(snapshot: { _, _ in snapshot() }, remoteBranches: { _ in [] }, since: { _, _ in nil })
        #expect(context.failure == nil)
        #expect(context.blockedReason(for: .uncommitted) == nil)
        #expect(context.blockedReason(for: .sinceReview)?.contains("unavailable") == true)
        #expect(context.blockedReason(for: .answer) == nil)
    }

    @Test func anUnavailableBaseDoesNotQuietlyBecomeHEAD() async {
        var facts = facts()
        facts.branch = .init(base: "upstream/develop", files: [], bases: [root: "upstream/develop"])
        let context = SecondOpinionContext(facts: facts, comparison: .branch)
        await context.read(snapshot: { _, _ in .init(state: .ready, root: root, files: [changed]) },
                           remoteBranches: { _ in [] })
        #expect(context.blockedReason(for: .uncommitted)?.contains("No base branch") == true)
    }

    @Test func realGitPreviewAndReviewUseTheSameSelectedRemoteBranch() async throws {
        let repository = try GitRepo()
        try repository.git("update-ref", "refs/remotes/upstream/develop", "HEAD")
        try repository.git("checkout", "-qb", "feature")
        try repository.write("README.md", "committed change\n")
        try repository.commit("Change readme")
        let facts = SecondOpinionAskFacts(
            file: .init(root: repository.path, path: "README.md", added: 0, removed: 0),
            repositories: [.init(root: repository.path, name: "App")],
            compareRefs: [repository.path: "upstream/develop"], headRoots: [repository.path])
        let context = SecondOpinionContext(facts: facts, comparison: .changesTab)
        await context.read()
        #expect(context.files(for: .uncommitted).isEmpty)
        #expect(context.baseTitle == "upstream/develop")
        context.comparison = .branch
        let file = try #require(context.files(for: .uncommitted).first)
        let request = SecondOpinionRequest(scope: context.fileScope(file, for: .uncommitted),
                                          repositories: facts.repositories, executable: "")
        let patches = await SecondOpinion.patches(for: request)
        #expect(patches.map(\.path) == ["README.md"])
        #expect(patches.first?.text.contains("+committed change") == true)
        #expect(context.files(for: .uncommitted) == SecondOpinionContext.files(in: patches))
        #expect(context.baseTitle == "upstream/develop")
    }
}
