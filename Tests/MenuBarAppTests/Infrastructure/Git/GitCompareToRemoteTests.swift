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

        let local = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true)
        #expect(local.files.map(\.path) == ["README.md"])
        #expect(local.remoteBase?.ref == "origin/main")
        #expect(!local.comparedToRemote)

        let compared = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true, comparingToRemote: true)
        #expect(compared.comparedToRemote)
        #expect(compared.diffBase == compared.remoteBase?.commit)
        #expect(compared.files.map(\.path) == ["feature.txt", "README.md"])
        let feature = try #require(compared.files.first { $0.path == "feature.txt" })
        #expect(feature.kind == .added)
        #expect(!feature.hasLocalChanges)
        #expect(feature.added == 1)
        let readme = try #require(compared.files.first { $0.path == "README.md" })
        #expect(readme.hasLocalChanges)

        let diff = await GitInspector.reviewDiff(for: feature, root: repo.path, base: compared.diffBase)
        #expect(diff.lines.contains { $0.kind == .addition && $0.text == "+feature" })
        let before = try await GitInspector.copyText(for: readme, root: repo.path, version: .before,
                                                     base: compared.diffBase).get()
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

    @Test func withoutARemoteTheLastCommitStaysTheBase() async throws {
        let repo = try GitRepo()
        try repo.write("README.md", "changed")

        let snapshot = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true, comparingToRemote: true)
        #expect(snapshot.remoteBase == nil)
        #expect(!snapshot.comparedToRemote)
        #expect(snapshot.diffBase == nil)
        #expect(snapshot.files.map(\.path) == ["README.md"])
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
