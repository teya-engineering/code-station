import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

// What "Review changes" opens after a turn. A turn that committed everything has an empty
// working tree, so the review has to show its commits or it shows nothing at all.
struct TurnCommitsTests {

    @Test func readsTheCheckedOutCommit() async throws {
        let repo = try GitRepo()
        #expect(await GitInspector.head(at: repo.path) == repo.head)
    }

    @Test func hasNoHeadOutsideARepository() async throws {
        let folder = ScratchDirectory(prefix: "turn-commits-plain")
        #expect(await GitInspector.head(at: folder.url.path) == nil)
    }

    @Test func findsTheRangeATurnCommitted() async throws {
        let repo = try GitRepo()
        let start = repo.head
        try repo.write("a.txt", "one")
        try repo.commit("First")
        try repo.write("b.txt", "two")
        try repo.commit("Second")

        let commits = try #require(await GitInspector.turnCommits(roots: [repo.path],
                                                                  startHeads: [repo.path: start]))
        #expect(commits.root == repo.path)
        #expect(commits.start == start)
        #expect(commits.head.hash == repo.head)
        #expect(commits.head.subject == "Second")
    }

    @Test func leavesATurnThatDidNotCommitOnTheWorkingTree() async throws {
        let repo = try GitRepo()
        try repo.write("a.txt", "one")
        #expect(await GitInspector.turnCommits(roots: [repo.path],
                                               startHeads: [repo.path: repo.head]) == nil)
    }

    // Committed and uncommitted work together: the uncommitted part is what still needs a
    // decision, and only the working tree view can comment on it or commit it.
    @Test func prefersUncommittedWorkOverCommits() async throws {
        let repo = try GitRepo()
        let start = repo.head
        try repo.write("a.txt", "one")
        try repo.commit("First")
        try repo.write("b.txt", "two")

        #expect(await GitInspector.turnCommits(roots: [repo.path],
                                               startHeads: [repo.path: start]) == nil)
    }

    @Test func uncommittedWorkInAnotherFolderAlsoKeepsTheWorkingTree() async throws {
        let committed = try GitRepo()
        let edited = try GitRepo()
        let start = committed.head
        try committed.write("a.txt", "one")
        try committed.commit("First")
        try edited.write("b.txt", "two")

        #expect(await GitInspector.turnCommits(
            roots: [committed.path, edited.path],
            startHeads: [committed.path: start, edited.path: edited.head]) == nil)
    }

    @Test func picksTheFolderThatMoved() async throws {
        let still = try GitRepo()
        let moved = try GitRepo()
        let start = moved.head
        try moved.write("a.txt", "one")
        try moved.commit("First")

        let commits = try #require(await GitInspector.turnCommits(
            roots: [still.path, moved.path],
            startHeads: [still.path: still.head, moved.path: start]))
        #expect(commits.root == moved.path)
    }

    // A turn too short for its starting commit to have been read has nothing to compare
    // against, so it falls back to the working tree.
    @Test func needsTheStartingCommit() async throws {
        let repo = try GitRepo()
        try repo.write("a.txt", "one")
        try repo.commit("First")
        #expect(await GitInspector.turnCommits(roots: [repo.path], startHeads: [:]) == nil)
    }
}
