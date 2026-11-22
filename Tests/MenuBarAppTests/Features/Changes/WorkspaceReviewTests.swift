import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct WorkspaceReviewTests {
    @Test func eachRepositoryUsesItsOwnPullRequestAndIncludesCommittedFiles() async throws {
        let first = try repository("first")
        let second = try repository("second")
        try second.write("base-only.txt", "release content\n")
        try second.commit("Prepare release")
        try second.git("update-ref", "refs/remotes/origin/release", "HEAD")
        try first.write("first.txt", "first change\n")
        try first.commit("Change first")
        try second.write("second.txt", "second change\n")
        try second.commit("Change second")

        let navigation = ChangesNavigationMemory()
        let models = ChangesModels(navigation: navigation)
        let stats = GitStatsCache()
        let review = ReviewTarget(sessionID: UUID(), agent: .claudeCode, reviews: ReviewCommentStore(url: nil))
        let bases = [PullRequestBase(number: 1, headBranch: "code-station/shared", baseBranch: "main",
                                     owner: "team", repository: "first"),
                     PullRequestBase(number: 2, headBranch: "code-station/shared", baseBranch: "release",
                                     owner: "team", repository: "second")]
        let screen = ChangesScreen(gitStats: stats, otherRoots: [second.path], review: review,
                                   pullRequestBases: bases, models: models)
        let model = models.model(for: first.path, comparingToRemote: true)
        await model.reload(for: screen)
        await model.refreshOthers(for: screen)

        #expect(navigation.snapshots[first.path]?.remoteBase?.ref == "origin/main")
        #expect(navigation.snapshots[second.path]?.remoteBase?.ref == "origin/release")
        #expect(navigation.snapshots[first.path]?.files.map(\.path) == ["first.txt"])
        #expect(navigation.snapshots[second.path]?.files.map(\.path) == ["second.txt"])
        #expect(stats.snapshot(at: first.path)?.files.isEmpty == true)
        #expect(stats.snapshot(at: second.path)?.files.isEmpty == true)
        #expect(stats.snapshot(at: first.path)?.reviewChanges.isEmpty == true)
        #expect(navigation.snapshots[second.path]?.reviewChanges["second.txt"] != nil)

        navigation.compareRefs[second.path] = "origin/main"
        await model.refreshOthers(for: screen)
        #expect(navigation.snapshots[second.path]?.files.map(\.path) == ["base-only.txt", "second.txt"])
        navigation.lastCommitCompares.insert(second.path)
        await model.refreshOthers(for: screen)
        #expect(navigation.snapshots[second.path]?.files.isEmpty == true)
    }

    @Test func aRefreshDetectsEditsEvenWhenTheLineCountsStayTheSame() async throws {
        let repo = try repository("live")
        try repo.write("README.md", "first edit\n")
        let stats = GitStatsCache()
        let navigation = ChangesNavigationMemory()
        let model = ChangesModel(root: repo.path, navigation: navigation)
        let review = ReviewTarget(sessionID: UUID(), agent: .claudeCode, reviews: ReviewCommentStore(url: nil))
        let screen = ChangesScreen(gitStats: stats, review: review)
        await model.reload(for: screen)
        let initial = try #require(model.snapshot?.reviewChanges["README.md"])
        let key = ViewedFileStore.key(root: repo.path, path: "README.md")
        review.reviews.viewed.mark(key, change: initial, in: review.sessionID)
        #expect(stats.revision(at: repo.path) == 0)

        try repo.write("README.md", "other edit\n")
        let previous = stats.snapshot(at: repo.path)
        stats.store(await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true), at: repo.path)
        #expect(stats.snapshot(at: repo.path)?.files == previous?.files)
        #expect(stats.revision(at: repo.path) == 1)
        await model.reload(for: screen)
        #expect(stats.revision(at: repo.path) == 1)
        let change = try #require(navigation.snapshots[repo.path]?.reviewChanges["README.md"])
        #expect(change != initial)
        #expect(model.diff?.reviewChange == change)
        #expect(review.reviews.viewed.state(key, change: change, in: review.sessionID).isEdited)
    }

    @Test func repositoryMatchingSupportsForksAndRejectsUnrelatedRepositories() {
        let bases = [PullRequestBase(number: 1, headBranch: "feature", baseBranch: "main", owner: "team",
                                     repository: "app", headRepositoryURL: "https://github.com/person/app")]
        let fork = GitRemoteBranches(urls: ["origin": "git@github.com:person/app.git"])
        #expect(PullRequestBase.matching(bases, branch: "feature", remotes: fork)?.number == 1)
        let unrelated = GitRemoteBranches(urls: ["origin": "git@github.com:team/other.git"])
        #expect(PullRequestBase.matching(bases, branch: "feature", remotes: unrelated) == nil)
    }

    private func repository(_ name: String) throws -> GitRepo {
        let repo = try GitRepo()
        try repo.git("remote", "add", "origin", "https://github.com/team/\(name).git")
        try repo.git("update-ref", "refs/remotes/origin/main", "HEAD")
        try repo.git("checkout", "-qb", "code-station/shared")
        return repo
    }
}
