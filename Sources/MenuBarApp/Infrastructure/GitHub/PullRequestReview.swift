import Foundation

// What reviewers did to a pull request, as GitHub reports it. A review is one
// submission: a verdict, an optional summary, and the threads it left on lines of the
// diff. Threads can also arrive on their own, as single comments outside a review.
struct PullRequestReview: Equatable, Sendable, Identifiable {
    enum Kind: Sendable { case approved, changesRequested, commented }

    var id: Int
    var kind: Kind
    var author: Reviewer
    var body: String
    var submittedAt: Date
    var threads: [PullRequestReviewThread] = []

    // A review with no words and no threads is GitHub recording that someone pressed a
    // button, which is only worth showing when the button was a verdict.
    var isEmptyComment: Bool { kind == .commented && body.isEmpty && threads.isEmpty }
}

struct Reviewer: Equatable, Sendable {
    var login: String
    var avatarURL: String?
    // A GitHub App rather than a person, by GitHub's own account type: Copilot's
    // reviewer, an organisation's bot. Read in a different mood from a colleague's words.
    var isAutomated = false
}

// One conversation hanging off a line of the diff. The first comment carries the code it
// is attached to; the rest are the replies, in order.
struct PullRequestReviewThread: Equatable, Sendable, Identifiable {
    var id: Int
    var path: String
    var line: Int?
    var diffHunk: String
    var comments: [PullRequestReviewComment]
    var isResolved = false

    var first: PullRequestReviewComment? { comments.first }
    var body: String { first?.body ?? "" }
    var place: String { "\(path)\(line.map { ":\($0)" } ?? "")" }

    // Done when resolved on GitHub, or when the last word is the person's own.
    func isAnswered(by selfLogin: String?) -> Bool {
        isResolved || (selfLogin != nil && comments.last?.author.login == selfLogin)
    }
}

struct PullRequestReviewComment: Equatable, Sendable, Identifiable {
    var id: Int
    var author: Reviewer
    var body: String
    var createdAt: Date
    var url: String
}

struct PullRequestStatus: Equatable, Sendable {
    enum State: Sendable { case open, merged, closed }
    // What the reviewers have settled on, in GitHub's own three words.
    enum ReviewDecision: Sendable { case approved, changesRequested, reviewRequired }
    // Where the pull request stands, as its badge says it. Merged and closed say it all; a
    // draft is not up for review yet, whatever anyone said; an open one is wherever its
    // reviewers left it.
    enum Readiness: Sendable, CaseIterable {
        case draft, inReview, approved, changesRequested, merged, closed

        var label: String {
            switch self {
            case .draft: "Draft"
            case .inReview: "In review"
            case .approved: "Approved"
            case .changesRequested: "Changes requested"
            case .merged: "Merged"
            case .closed: "Closed"
            }
        }
    }

    var state: State
    var title: String
    var headBranch: String
    var headRepositoryURL: String? = nil
    // The branch the pull request merges into, which Changes compares the files with.
    var baseBranch = ""
    var isDraft = false
    var createdAt: Date? = nil
    var reviewDecision: ReviewDecision? = nil

    var readiness: Readiness {
        switch state {
        case .merged: return .merged
        case .closed: return .closed
        case .open:
            if isDraft { return .draft }
            switch reviewDecision {
            case .approved?: return .approved
            case .changesRequested?: return .changesRequested
            case .reviewRequired?, nil: return .inReview
            }
        }
    }
}
