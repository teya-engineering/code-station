@testable import MenuBarApp

extension PullRequestStatus {
    // A status that reads as the given readiness, for tests that walk every state.
    init(readiness: Readiness) {
        switch readiness {
        case .draft: self.init(state: .open, title: "", headBranch: "b", isDraft: true)
        case .inReview: self.init(state: .open, title: "", headBranch: "b", reviewDecision: .reviewRequired)
        case .approved: self.init(state: .open, title: "", headBranch: "b", reviewDecision: .approved)
        case .changesRequested: self.init(state: .open, title: "", headBranch: "b", reviewDecision: .changesRequested)
        case .merged: self.init(state: .merged, title: "", headBranch: "b")
        case .closed: self.init(state: .closed, title: "", headBranch: "b")
        }
    }
}
