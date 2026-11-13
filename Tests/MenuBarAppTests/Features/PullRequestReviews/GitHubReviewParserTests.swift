import Foundation
import Testing
@testable import MenuBarApp

// Reading what GitHub says about a pull request: which submissions count as a review,
// how line comments fold into threads, and where a lone comment goes.
struct GitHubReviewParserTests {
    @Test func keepsDraftReadinessSeparateFromOpenState() throws {
        let status = try #require(GitHubReviewParser.status(
            from: Data(#"{"state":"open","draft":true}"#.utf8)))
        #expect(status.state == .open)
        #expect(status.isDraft)
        #expect(status.readinessLabel == "Draft")
        let merged = try #require(GitHubReviewParser.status(
            from: Data(#"{"state":"closed","merged":true,"draft":true}"#.utf8)))
        #expect(merged.readinessLabel == "Merged")
    }

    @Test func readsThreadStatesAndNodeIDsAcrossAllGraphQLPages() throws {
        let pages: [[String: Any]] = stride(from: 1, through: 201, by: 100).map { start in
            let nodes: [[String: Any]] = (start...min(start + 99, 201)).map { id in
                ["id": "thread-\(id)", "isResolved": id > 100,
                 "comments": ["nodes": [["databaseId": id]]]]
            }
            return ["data": ["repository": ["pullRequest": ["reviewThreads": [
                "nodes": nodes, "pageInfo": ["hasNextPage": start < 201, "endCursor": "cursor-\(start)"]
            ]]]]]
        }
        let states = GitHubReviewParser.threadStates(from: try JSONSerialization.data(withJSONObject: pages))

        #expect(states.count == 201)
        #expect(states[1] == .init(nodeID: "thread-1", isResolved: false))
        #expect(states[101] == .init(nodeID: "thread-101", isResolved: true))
        #expect(states[201] == .init(nodeID: "thread-201", isResolved: true))
    }

    @Test func readsTheForkThatOwnsThePullRequestBranch() {
        let status = GitHubReviewParser.status(from: Data(#"{"state":"open","head":{"ref":"fix","repo":{"html_url":"https://github.com/contributor/app"}}}"#.utf8))

        #expect(status?.headBranch == "fix")
        #expect(status?.headRepositoryURL == "https://github.com/contributor/app")
    }

    private func reviewJSON(id: Int, state: String, body: String = "", login: String = "maria",
                            type: String = "User", at: String = "2026-10-16T10:00:00Z") -> String {
        """
        {"id": \(id), "state": "\(state)", "body": "\(body)", "submitted_at": "\(at)",
         "user": {"login": "\(login)", "type": "\(type)", "avatar_url": null}}
        """
    }

    private func commentJSON(id: Int, reviewID: Int?, body: String, replyTo: Int? = nil,
                             path: String = "Sources/A.swift", line: Int = 42, at: String = "2026-10-16T10:00:00Z") -> String {
        """
        {"id": \(id), "pull_request_review_id": \(reviewID.map(String.init) ?? "null"),
         "in_reply_to_id": \(replyTo.map(String.init) ?? "null"),
         "body": "\(body)", "path": "\(path)", "line": \(line), "created_at": "\(at)",
         "diff_hunk": "@@ -40,3 +40,4 @@", "html_url": "", "user": {"login": "maria", "avatar_url": null}}
        """
    }

    private func data(_ items: [String]) -> Data { Data("[\(items.joined(separator: ","))]".utf8) }
    private let none = Data("[]".utf8)

    @Test func foldsLineCommentsUnderTheirReview() {
        // Arrange
        let reviews = data([reviewJSON(id: 1, state: "CHANGES_REQUESTED", body: "Two things.")])
        let comments = data([commentJSON(id: 10, reviewID: 1, body: "Retries forever."),
                             commentJSON(id: 11, reviewID: 1, body: "Rename this.", path: "Sources/B.swift", line: 7)])

        // Act
        let parsed = GitHubReviewParser.reviews(reviews: reviews, comments: comments)

        // Assert
        #expect(parsed.map(\.kind) == [.changesRequested])
        #expect(parsed[0].threads.map(\.id) == [10, 11])
        #expect(parsed[0].threads[1].path == "Sources/B.swift")
        #expect(parsed[0].threads[1].line == 7)
    }

    @Test func foldsRepliesIntoTheThreadTheyAnswer() {
        // Arrange
        let reviews = data([reviewJSON(id: 1, state: "COMMENTED")])
        let comments = data([commentJSON(id: 10, reviewID: 1, body: "Why not a cap?"),
                             commentJSON(id: 12, reviewID: 2, body: "Good point.", replyTo: 10, at: "2026-10-16T11:00:00Z")])

        // Act
        let parsed = GitHubReviewParser.reviews(reviews: reviews, comments: comments)

        // Assert
        #expect(parsed.map { $0.threads.map { $0.comments.map(\.id) } } == [[[10, 12]]])
    }

    // GitHub wraps a lone line comment in a review the list endpoint omits, so the
    // thread has to stand as a review of its own or it would be lost.
    @Test func keepsAThreadWhoseReviewIsNotListed() {
        // Arrange
        let comments = data([commentJSON(id: 30, reviewID: 99, body: "Typo here.")])

        // Act
        let parsed = GitHubReviewParser.reviews(reviews: none, comments: comments)

        // Assert
        #expect(parsed.map(\.id) == [30])
        #expect(parsed[0].kind == .commented)
    }

    // Pressing Approve with nothing to say is still a verdict; a COMMENTED review with
    // no words and no threads is GitHub recording a button press.
    @Test func dropsAnEmptyCommentReviewButKeepsAnEmptyApproval() {
        // Arrange
        let reviews = data([reviewJSON(id: 1, state: "COMMENTED"), reviewJSON(id: 2, state: "APPROVED")])

        // Act
        let parsed = GitHubReviewParser.reviews(reviews: reviews, comments: none)

        // Assert
        #expect(parsed.map(\.id) == [2])
    }

    @Test func ignoresPendingAndDismissedReviewsAndOrdersOldestFirst() {
        // Arrange
        let reviews = data([reviewJSON(id: 1, state: "PENDING", body: "draft"),
                            reviewJSON(id: 3, state: "APPROVED", at: "2026-10-16T12:00:00Z"),
                            reviewJSON(id: 2, state: "DISMISSED", body: "gone"),
                            reviewJSON(id: 4, state: "COMMENTED", body: "First look", at: "2026-10-16T09:00:00Z")])

        // Act
        let parsed = GitHubReviewParser.reviews(reviews: reviews, comments: none)

        // Assert
        #expect(parsed.map(\.id) == [4, 3])
    }

    @Test func aGitHubAppIsAutomatedAndAPersonIsNot() {
        // Arrange
        let reviews = data([reviewJSON(id: 1, state: "APPROVED", login: "Copilot", type: "Bot"),
                            reviewJSON(id: 2, state: "APPROVED", login: "maria", type: "User")])

        // Act
        let parsed = GitHubReviewParser.reviews(reviews: reviews, comments: none)

        // Assert
        #expect(parsed.map(\.author.isAutomated) == [true, false])
    }

    @Test func readsMergedAsItsOwnStateRatherThanClosed() {
        // Arrange
        let merged = Data(#"{"state": "closed", "merged": true, "title": "Add login", "head": {"ref": "session-4"}}"#.utf8)
        let closed = Data(#"{"state": "closed", "merged": false}"#.utf8)
        let open = Data(#"{"state": "open", "merged": false}"#.utf8)

        // Act
        let states = [merged, closed, open].map { GitHubReviewParser.status(from: $0)?.state }

        // Assert
        #expect(states == [.merged, .closed, .open])
        #expect(GitHubReviewParser.status(from: merged)?.headBranch == "session-4")
        #expect(GitHubReviewParser.status(from: none) == nil)
    }

    @Test func readsEachThreadsNodeAndResolvedStateByItsFirstComment() {
        // Arrange
        let data = Data("""
        {"data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": [
          {"id": "PRRT_1", "isResolved": true, "comments": {"nodes": [{"databaseId": 10}]}},
          {"id": "PRRT_2", "isResolved": false, "comments": {"nodes": [{"databaseId": 20}]}}
        ]}}}}}
        """.utf8)

        // Act
        let states = GitHubReviewParser.threadStates(from: data)

        // Assert
        #expect(states[10] == .init(nodeID: "PRRT_1", isResolved: true))
        #expect(states[20]?.isResolved == false)
        #expect(states[30] == nil)
    }

}
