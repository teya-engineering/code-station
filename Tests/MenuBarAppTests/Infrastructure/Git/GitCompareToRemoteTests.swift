import Foundation
import Testing
@testable import MenuBarApp

struct GitCompareToRemoteTests {
    @Test func listsCommittedAndUncommittedWorkSinceTheBranchLeftTheRemote() async throws {
        let (repo, remote) = try branchedFromOrigin()
        defer { withExtendedLifetime(remote) {} }
        try repo.write("feature.txt", "feature\n")
        try repo.git("add", "feature.txt")
        try repo.git("commit", "-qm", "Add feature")
        try repo.write("README.md", "changed")

        let local = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true, findingRemoteBase: true)
        #expect(local.files.map(\.path) == ["README.md"])
        #expect(local.remoteBase?.ref == "origin/main")
        #expect(!local.comparedToRemote)

        let compared = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true, comparingToRemote: true)
        #expect(compared.comparedToRemote)
        #expect(compared.files.map(\.path) == ["feature.txt", "README.md"])
        let feature = try #require(compared.files.first { $0.path == "feature.txt" })
        #expect(feature.kind == .added)
        #expect(!feature.hasLocalChanges)
        #expect(feature.added == 1)
        let readme = try #require(compared.files.first { $0.path == "README.md" })
        #expect(readme.hasLocalChanges)

        let diff = await GitInspector.reviewDiff(for: feature, root: repo.path, base: compared.diffBase(for: feature))
        #expect(diff.lines.contains { $0.kind == .addition && $0.text == "+feature" })
        let before = try await GitInspector.copyText(for: readme, root: repo.path, version: .before,
                                                     base: compared.diffBase(for: readme)).get()
        #expect(before == "hello")
    }

    @Test func onlyFilesWithWorkLeftCanBeCommitted() async throws {
        let (repo, remote) = try branchedFromOrigin()
        defer { withExtendedLifetime(remote) {} }
        try repo.write("feature.txt", "feature\n")
        try repo.git("add", "feature.txt")
        try repo.git("commit", "-qm", "Add feature")
        try repo.write("README.md", "changed")
        try repo.write("scratch.txt", "scratch\n")

        let compared = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true, comparingToRemote: true)
        #expect(compared.files.map(\.path) == ["feature.txt", "README.md", "scratch.txt"])
        #expect(compared.localFiles.map(\.path) == ["README.md", "scratch.txt"])
    }

    @Test func workLandedOnTheRemoteAfterBranchingIsLeftOut() async throws {
        let (repo, remote) = try branchedFromOrigin()
        defer { withExtendedLifetime(remote) {} }
        try repo.git("checkout", "-q", "main")
        try repo.write("other.txt", "someone else\n")
        try repo.git("add", "other.txt")
        try repo.git("commit", "-qm", "Land other work")
        try repo.git("push", "-q", "origin", "main")
        try repo.git("checkout", "-q", "feature")
        try repo.write("mine.txt", "mine\n")

        let compared = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true, comparingToRemote: true)
        #expect(compared.files.map(\.path) == ["mine.txt"])
    }

    @Test func comparesWithTheRemoteBranchPicked() async throws {
        let (repo, remote) = try branchedFromOrigin()
        defer { withExtendedLifetime(remote) {} }
        // A branch the feature was stacked on: its commit is shared, so comparing with it
        // leaves that commit's file out.
        try repo.write("shared.txt", "from the stack below\n")
        try repo.git("add", "shared.txt")
        try repo.git("commit", "-qm", "Work the stack below holds")
        try repo.git("push", "-q", "origin", "HEAD:stack-below")
        try repo.git("fetch", "-q", "origin")
        try repo.write("mine.txt", "mine\n")

        let againstMain = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true, comparingToRemote: true)
        #expect(againstMain.remoteBase?.ref == "origin/main")
        #expect(againstMain.files.map(\.path) == ["mine.txt", "shared.txt"])

        let againstStack = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true,
                                                       comparingToRemote: true, remoteRef: "origin/stack-below")
        #expect(againstStack.remoteBase?.ref == "origin/stack-below")
        #expect(againstStack.files.map(\.path) == ["mine.txt"])

        let branches = await GitInspector.remoteBranches(at: repo.path)
        #expect(branches.refs == ["origin/main", "origin/stack-below"])
        #expect(branches.remotes == ["origin"])
    }

    @Test func aBranchThatIsGoneFallsBackToTheDefault() async throws {
        let (repo, remote) = try branchedFromOrigin()
        defer { withExtendedLifetime(remote) {} }
        try repo.write("mine.txt", "mine\n")

        let snapshot = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true,
                                                   comparingToRemote: true, remoteRef: "origin/deleted")
        #expect(snapshot.remoteBase?.ref == "origin/main")
        // Only a remote branch is ever handed to git.
        let option = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true,
                                                 comparingToRemote: true, remoteRef: "--output=/tmp/x")
        #expect(option.remoteBase?.ref == "origin/main")
    }

    @Test func readsTheRemoteBranchesAndWhereEachRemoteLives() {
        let refs = GitInspector.parseRemoteRefs(
            "refs/remotes/origin/HEAD\nrefs/remotes/origin/main\nrefs/remotes/fork/feat/x\nrefs/remotes/origin/feat/a\n")
        #expect(refs == ["fork/feat/x", "origin/feat/a", "origin/main"])

        let urls = GitInspector.parseRemoteURLs(
            "remote.origin.url git@github.com:teya-engineering/code-station.git\nremote.fork.url https://github.com/someone/code-station\n")
        #expect(urls == ["origin": "git@github.com:teya-engineering/code-station.git",
                         "fork": "https://github.com/someone/code-station"])
    }

    @Test func theRemoteBranchABranchWasMadeFromIsReadFromItsOldestReflogEntry() {
        let refs = ["origin/feat/a", "origin/main"]
        let reflog = "commit: second\ncommit: first\nbranch: Created from origin/feat/a\n"

        #expect(GitInspector.parseStartedFrom(reflog, refs: refs) == "origin/feat/a")
        #expect(GitInspector.parseStartedFrom("branch: Created from refs/remotes/origin/main", refs: refs) == "origin/main")
        // A local branch, a commit, or a remote branch since deleted is nothing to compare with.
        #expect(GitInspector.parseStartedFrom("branch: Created from main", refs: refs) == nil)
        #expect(GitInspector.parseStartedFrom("branch: Created from HEAD", refs: refs) == nil)
        #expect(GitInspector.parseStartedFrom("branch: Created from origin/gone", refs: refs) == nil)
        #expect(GitInspector.parseStartedFrom("commit: first", refs: refs) == nil)
    }

    @Test func aBranchMadeFromARemoteBranchSaysWhichOne() async throws {
        let repo = try GitRepo()
        try repo.git("update-ref", "refs/remotes/origin/main", "HEAD")
        try repo.git("checkout", "-q", "-b", "feature", "origin/main")

        let branches = await GitInspector.remoteBranches(at: repo.path, branch: "feature")
        #expect(branches.startedFrom == "origin/main")
    }

    @Test func aPullRequestsBaseIsFoundOnTheRemoteThatHoldsItsRepository() {
        let branches = GitRemoteBranches(
            refs: ["fork/main", "origin/feat/a", "origin/main", "upstream/main"],
            urls: ["origin": "https://github.com/someone/app.git",
                   "upstream": "git@github.com:Team/App.git",
                   "fork": "https://github.com/other/app"])

        #expect(branches.ref(forBranch: "main", owner: "team", repository: "app") == "upstream/main")
        // Not on any remote that matches, origin wins over the rest.
        #expect(branches.ref(forBranch: "main", owner: "nobody", repository: "app") == "origin/main")
        #expect(branches.ref(forBranch: "feat/a", owner: nil, repository: nil) == "origin/feat/a")
        #expect(branches.ref(forBranch: "a", owner: nil, repository: nil) == nil)
        #expect(branches.ref(forBranch: "gone", owner: "team", repository: "app") == nil)
    }

    @Test func withoutARemoteTheLastCommitStaysTheBase() async throws {
        let repo = try GitRepo()
        try repo.write("README.md", "changed")

        let snapshot = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true, comparingToRemote: true)
        #expect(snapshot.remoteBase == nil)
        #expect(!snapshot.comparedToRemote)
        #expect(snapshot.files.map(\.path) == ["README.md"])
    }

    @Test func otherScreensDoNotLookUpTheRemoteBase() async throws {
        let (repo, remote) = try branchedFromOrigin()
        defer { withExtendedLifetime(remote) {} }
        try repo.write("README.md", "changed")

        let snapshot = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true)
        #expect(snapshot.remoteBase == nil)
    }

    @Test func aStaleOriginHeadFallsBackToTheUsualNames() async throws {
        let (repo, remote) = try branchedFromOrigin()
        defer { withExtendedLifetime(remote) {} }
        try repo.git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/gone")

        let snapshot = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true, findingRemoteBase: true)
        #expect(snapshot.remoteBase?.ref == "origin/main")
    }

    @Test func commitAndCountsUseOnlyTheUncommittedWork() async throws {
        let (repo, remote) = try branchedFromOrigin()
        defer { withExtendedLifetime(remote) {} }
        try repo.write("feature.txt", "one\ntwo\nthree\n")
        try repo.git("add", "feature.txt")
        try repo.git("commit", "-qm", "Add feature")
        try repo.write("feature.txt", "one\ntwo\nthree\nfour\n")

        let compared = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true, comparingToRemote: true)
        let row = try #require(compared.files.first { $0.path == "feature.txt" })
        #expect(row.added == 4)
        let local = try #require(compared.localFiles.first { $0.path == "feature.txt" })
        #expect(local.added == 1)
        #expect(compared.againstLastCommit.files == compared.localFiles)
        #expect(!compared.againstLastCommit.comparedToRemote)
    }

    @Test func aFileRenamedOnTheBranchAndEditedSinceCanBeCommitted() async throws {
        let (repo, remote) = try branchedFromOrigin()
        defer { withExtendedLifetime(remote) {} }
        // Long enough that git still sees a rename after the edit.
        let text = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try repo.git("checkout", "-q", "main")
        try repo.write("notes.txt", text)
        try repo.git("add", "notes.txt")
        try repo.git("commit", "-qm", "Add notes")
        try repo.git("push", "-q", "origin", "main")
        try repo.git("checkout", "-q", "-B", "feature", "main")
        try repo.git("mv", "notes.txt", "guide.txt")
        try repo.git("commit", "-qm", "Rename")
        try repo.write("guide.txt", text + "more\n")

        let compared = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true, comparingToRemote: true)
        let row = try #require(compared.files.first { $0.path == "guide.txt" })
        #expect(row.kind == .renamed && row.originalPath == "notes.txt")
        let local = try #require(compared.localFiles.first { $0.path == "guide.txt" })
        #expect(local.originalPath == nil)

        let error = await GitActions.commitSelected(message: "Edit guide", files: [local], at: repo.path)
        #expect(error == nil)
    }

    @Test func aFileTheBranchAddedAndTheWorkingTreeDeletedShowsTheLocalChange() async throws {
        let (repo, remote) = try branchedFromOrigin()
        defer { withExtendedLifetime(remote) {} }
        try repo.write("feature.txt", "feature\n")
        try repo.git("add", "feature.txt")
        try repo.git("commit", "-qm", "Add feature")
        try repo.git("rm", "-q", "feature.txt")

        let compared = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true, comparingToRemote: true)
        let row = try #require(compared.files.first { $0.path == "feature.txt" })
        #expect(row.kind == .deleted && row.removed == 1)
        #expect(compared.diffBase(for: row) == nil)
        let diff = await GitInspector.reviewDiff(for: row, root: repo.path, base: compared.diffBase(for: row))
        #expect(diff.lines.contains { $0.kind == .deletion && $0.text == "-feature" })
    }

    @Test func aLocalRenameTheBaseSeesAsDeleteAndAddStaysOneRow() {
        let local = [GitChange(path: "new.txt",
                               originalPath: "old.txt",
                               kind: .renamed,
                               isStaged: true,
                               isUnstaged: false,
                               added: nil,
                               removed: nil,
                               isBinary: false)]
        let merged = GitInspector.merging(local, with: [("old.txt", nil, .deleted), ("new.txt", nil, .added)])
        #expect(merged.count == 1)
        #expect(merged[0].kind == .renamed && merged[0].originalPath == "old.txt")
        #expect(merged[0].hasLocalChanges)
    }

    @Test func readsRenamesAndPlainChangesFromNameStatus() {
        let entries = GitInspector.parseNameStatus("R087\0old.txt\0new.txt\0M\0kept.txt\0D\0gone.txt\0")
        #expect(entries.count == 3)
        #expect(entries[0].path == "new.txt" && entries[0].originalPath == "old.txt" && entries[0].kind == .renamed)
        #expect(entries[1].path == "kept.txt" && entries[1].originalPath == nil && entries[1].kind == .modified)
        #expect(entries[2].path == "gone.txt" && entries[2].kind == .deleted)
    }

    @Test func aFileTheBranchAddedReadsAsAddedEvenWhenEditedSince() {
        let local = [GitChange(path: "new.txt",
                               originalPath: nil,
                               kind: .modified,
                               isStaged: false,
                               isUnstaged: true,
                               added: nil,
                               removed: nil,
                               isBinary: false)]
        let merged = GitInspector.merging(local, with: [("new.txt", nil, .added)])
        #expect(merged.count == 1)
        #expect(merged[0].kind == .added)
        #expect(merged[0].isUnstaged)
    }

    @Test func aSecondOpinionOnTheWholeBranchReadsWhatItCommittedToo() async throws {
        let (repo, remote) = try branchedFromOrigin()
        defer { withExtendedLifetime(remote) {} }
        try repo.write("feature.txt", "feature\n")
        try repo.git("add", "feature.txt")
        try repo.git("commit", "-qm", "Add feature")
        try repo.write("README.md", "changed")
        let root = try repo.git("rev-parse", "--show-toplevel").trimmingCharacters(in: .whitespacesAndNewlines)
        func request(_ scope: SecondOpinionRequest.Scope) -> SecondOpinionRequest {
            SecondOpinionRequest(scope: scope, repositories: [ReviewRepository(root: repo.path, name: "repo")],
                                 executable: "/bin/false")
        }

        let uncommitted = await SecondOpinion.patches(for: request(.all))
        #expect(uncommitted.map(\.path) == ["README.md"])

        let branch = await SecondOpinion.patches(for: request(.branch(bases: [repo.path: "origin/main"])))
        #expect(branch.map(\.path) == ["feature.txt", "README.md"])
        #expect(branch.first?.text.contains("+feature") == true)
        #expect(branch.allSatisfy { $0.root == root })

        let file = await SecondOpinion.patches(for: request(.file(root: root, path: "feature.txt", base: "origin/main")))
        #expect(file.map(\.path).contains("feature.txt"))

        // A base the remote no longer has falls back to the uncommitted changes.
        let gone = await SecondOpinion.patches(for: request(.branch(bases: [repo.path: "origin/deleted"])))
        #expect(gone.map(\.path).contains("README.md"))
    }

    // The bare remote is deleted with its object, so the caller keeps it alive.
    private func branchedFromOrigin() throws -> (GitRepo, GitRepo) {
        let repo = try GitRepo()
        let remote = try GitRepo.bare()
        try repo.addRemote(remote)
        try repo.git("push", "-q", "-u", "origin", "HEAD")
        try repo.git("checkout", "-q", "-b", "feature")
        return (repo, remote)
    }
}
