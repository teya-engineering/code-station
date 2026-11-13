import Foundation

// Reads the JSON that `gh api` returns for the pull request endpoints. String and
// dictionary work over documented fields, kept apart from the process that fetches it.
enum GitHubReviewParser {
    typealias Object = [String: Any]

    static func status(from data: Data) -> PullRequestStatus? {
        guard let object = json(data) as? Object, let state = object["state"] as? String else { return nil }
        let merged = object["merged"] as? Bool ?? false
        return PullRequestStatus(
            state: merged ? .merged : (state == "open" ? .open : .closed),
            title: object["title"] as? String ?? "",
            headBranch: (object["head"] as? Object)?["ref"] as? String ?? "",
            headRepositoryURL: ((object["head"] as? Object)?["repo"] as? Object)?["html_url"] as? String,
            isDraft: object["draft"] as? Bool ?? false)
    }

    // `/pulls/{n}/reviews` lists the submissions; `/pulls/{n}/comments` lists every line
    // comment with the review it belongs to. The two are joined here: threads under their
    // review, and a thread whose review GitHub did not list standing as a review of its own.
    static func reviews(reviews reviewsData: Data, comments commentsData: Data) -> [PullRequestReview] {
        var threadsByReview = threads(from: commentsData)
        var result: [PullRequestReview] = []
        for case let object as Object in (json(reviewsData) as? [Any]) ?? [] {
            guard let id = object["id"] as? Int,
                  let review = review(object, threads: threadsByReview.removeValue(forKey: id) ?? []) else { continue }
            result.append(review)
        }
        result += threadsByReview.values.flatMap { $0 }.compactMap(standalone)
        return result.filter { !$0.isEmptyComment }.sorted { $0.submittedAt < $1.submittedAt }
    }

    struct ThreadState: Equatable, Sendable {
        var nodeID: String
        var isResolved: Bool
    }

    // What GraphQL knows about each thread, keyed by the REST id of its first comment,
    // which is the one id both APIs share.
    static func threadStates(from data: Data) -> [Int: ThreadState] {
        let value = json(data)
        let pages = value as? [Object] ?? (value as? Object).map { [$0] } ?? []
        let nodes = pages.flatMap { page in
            (page["data"] as? Object)
                .flatMap { $0["repository"] as? Object }
                .flatMap { $0["pullRequest"] as? Object }
                .flatMap { $0["reviewThreads"] as? Object }
                .flatMap { $0["nodes"] as? [Object] } ?? []
        }
        var states: [Int: ThreadState] = [:]
        for node in nodes {
            let comments = (node["comments"] as? Object)?["nodes"] as? [Object]
            guard let first = comments?.first?["databaseId"] as? Int, let id = node["id"] as? String else { continue }
            states[first] = ThreadState(nodeID: id, isResolved: node["isResolved"] as? Bool ?? false)
        }
        return states
    }

    // MARK: - Pieces

    private static func review(_ object: Object, threads: [PullRequestReviewThread]) -> PullRequestReview? {
        guard let id = object["id"] as? Int, let kind = kind(object["state"] as? String),
              let author = reviewer(object["user"]) else { return nil }
        return PullRequestReview(
            id: id, kind: kind, author: author,
            body: (object["body"] as? String ?? "").trimmed,
            submittedAt: date(object["submitted_at"]) ?? .distantPast,
            threads: threads.sorted { $0.id < $1.id })
    }

    // Threads grouped by the review they belong to; nil for a comment made outside one.
    // Each line comment names the comment it replies to: the first in a chain is the
    // thread, and its replies are folded in under it.
    private static func threads(from data: Data) -> [Int?: [PullRequestReviewThread]] {
        let objects = (json(data) as? [Object]) ?? []
        var roots: [Int: (reviewID: Int?, thread: PullRequestReviewThread)] = [:]
        for object in objects where !(object["in_reply_to_id"] is Int) {
            guard let comment = comment(object) else { continue }
            roots[comment.id] = (object["pull_request_review_id"] as? Int, thread(object, first: comment))
        }
        for (parent, reply) in replies(in: objects) {
            roots[parent]?.thread.comments.append(reply)
        }
        var grouped: [Int?: [PullRequestReviewThread]] = [:]
        for root in roots.values.sorted(by: { $0.thread.id < $1.thread.id }) {
            grouped[root.reviewID, default: []].append(root.thread)
        }
        return grouped
    }

    // Replies in the order they were written, each with the comment it answers.
    private static func replies(in objects: [Object]) -> [(parent: Int, PullRequestReviewComment)] {
        objects.compactMap { object in
            guard let parent = object["in_reply_to_id"] as? Int, let comment = comment(object) else { return nil }
            return (parent, comment)
        }
        .sorted { $0.1.createdAt < $1.1.createdAt }
    }

    private static func comment(_ object: Object) -> PullRequestReviewComment? {
        guard let id = object["id"] as? Int, let author = reviewer(object["user"]) else { return nil }
        return PullRequestReviewComment(
            id: id, author: author,
            body: (object["body"] as? String ?? "").trimmed,
            createdAt: date(object["created_at"]) ?? .distantPast,
            url: object["html_url"] as? String ?? "")
    }

    private static func thread(_ object: Object, first: PullRequestReviewComment) -> PullRequestReviewThread {
        PullRequestReviewThread(
            id: first.id,
            path: object["path"] as? String ?? "",
            line: object["line"] as? Int ?? object["original_line"] as? Int,
            diffHunk: object["diff_hunk"] as? String ?? "",
            comments: [first])
    }

    private static func standalone(_ thread: PullRequestReviewThread) -> PullRequestReview? {
        guard let first = thread.first else { return nil }
        return PullRequestReview(id: thread.id, kind: .commented, author: first.author, body: "",
                                 submittedAt: first.createdAt, threads: [thread])
    }

    private static func kind(_ state: String?) -> PullRequestReview.Kind? {
        switch state {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "COMMENTED": .commented
        // PENDING is a draft nobody has sent; DISMISSED has been withdrawn.
        default: nil
        }
    }

    private static func reviewer(_ value: Any?) -> Reviewer? {
        guard let user = value as? Object, let login = user["login"] as? String else { return nil }
        return Reviewer(login: login, avatarURL: user["avatar_url"] as? String,
                        isAutomated: user["type"] as? String == "Bot" || login.hasSuffix("[bot]"))
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func json(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }
}
