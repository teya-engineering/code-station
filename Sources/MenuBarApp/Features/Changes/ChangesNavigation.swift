import AppKit
import SwiftUI
import CodeStationCore

struct ChangeFileSelection: Equatable {
    private(set) var ids: Set<GitChange.ID> = []
    private(set) var anchorID: GitChange.ID?
    private(set) var activeID: GitChange.ID?

    mutating func select(_ id: GitChange.ID, in orderedIDs: [GitChange.ID],
                         extendingRange: Bool, toggling: Bool) {
        guard let clickedIndex = orderedIDs.firstIndex(of: id) else { return }

        if extendingRange,
           let anchorID,
           let anchorIndex = orderedIDs.firstIndex(of: anchorID) {
            let bounds = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            let range = Set(orderedIDs[bounds])
            ids = toggling ? ids.union(range) : range
            activeID = id
            return
        }

        if toggling {
            if ids.remove(id) == nil {
                ids.insert(id)
                anchorID = id
                activeID = id
            } else {
                let replacement = orderedIDs.first { ids.contains($0) }
                if anchorID == id { anchorID = replacement }
                if activeID == id { activeID = replacement }
            }
            return
        }

        ids = [id]
        anchorID = id
        activeID = id
    }

    mutating func retain(_ validIDs: Set<GitChange.ID>, in orderedIDs: [GitChange.ID]) {
        ids.formIntersection(validIDs)
        if anchorID.map({ !validIDs.contains($0) }) == true { anchorID = nil }
        if activeID.map({ !validIDs.contains($0) }) == true {
            activeID = orderedIDs.first { ids.contains($0) }
        }
        if ids.isEmpty {
            anchorID = nil
            activeID = nil
        } else if anchorID == nil {
            anchorID = activeID
        }
    }

    mutating func clear() {
        ids = []
        anchorID = nil
        activeID = nil
    }

    func contextMenuFiles(for file: GitChange, in files: [GitChange]) -> [GitChange] {
        ids.contains(file.id) ? files.filter { ids.contains($0.id) } : [file]
    }
}

// Where an arrow key lands in a list of rows. With nothing open it starts at the end the
// key points away from, and at either end it stays where it is rather than wrapping.
enum RowStep {
    static func destination(from current: Int?, step: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return step > 0 ? 0 : count - 1 }
        let next = current + step
        return (0..<count).contains(next) ? next : nil
    }
}

struct ChangesNavigatorItem: Hashable {
    let root: String
    let path: String?

    static func next(after current: Self?, step: Int, in items: [Self]) -> Self? {
        guard let index = RowStep.destination(from: current.flatMap { items.firstIndex(of: $0) },
                                              step: step, count: items.count) else { return nil }
        return items[index]
    }
}

@MainActor
@Observable
final class ChangesNavigationMemory {
    var selections: [String: ChangeFileSelection] = [:]
    var collapsed: Set<String> = []
    var treeWidth = ExplorerSplitLayout.defaultTreeWidth
    var showingHistory = false
    var histories: [String: CommitHistorySelection] = [:]
    // Every project's commits, so each project's navigator can list the others' too.
    var commits: [String: [GitCommitSummary]] = [:]
    var collapsedHistories: Set<String> = []
    var historyFilter = ""
    // The navigator lists the review instead of the files. Kept here, with the comment in
    // focus, because each project gets a screen of its own and stepping through a review
    // moves between them.
    var list = NavigatorList.files
    var reviewFilter = ReviewFilter.all
    var focusedComment: UUID?
    var secondOpinionFocus = Set(SecondOpinion.Focus.standard)

    var showingReview: Bool {
        get { list == .review }
        set { list = newValue ? .review : .files }
    }

    var showingQuestions: Bool {
        get { list == .questions }
        set { list = newValue ? .questions : .files }
    }

    func history(for root: String) -> CommitHistorySelection {
        if let selection = histories[root] { return selection }
        let selection = CommitHistorySelection()
        histories[root] = selection
        return selection
    }
}

struct ChangesRepository: Identifiable {
    let root: String
    let name: String
    var id: String { root }

    static func statusLabel(for snapshot: GitSnapshot?) -> String {
        guard let snapshot else { return "Checking" }
        guard snapshot.state == .ready else { return "Unavailable" }
        return snapshot.files.isEmpty ? "Clean" : "\(snapshot.files.count) changed"
    }
}

// What the navigator lists: the changed files, the review, or the questions asked here.
enum NavigatorList: Hashable {
    case files, review, questions
}

// Which comments the review list shows. Findings still to look at are not in it: they
// wait in the second opinion's own dialog until they are kept.
enum ReviewFilter: Hashable {
    case all, yours, reviewers

    func admits(_ comment: ReviewComment) -> Bool {
        switch self {
        case .all: true
        case .yours: comment.reviewer == nil
        case .reviewers: comment.reviewer != nil
        }
    }
}

// Where comments left on a diff go: the session whose changes these are, and its agent.
// A project's own Changes screen has no agent to answer them, so it takes none.
struct ReviewTarget {
    let sessionID: UUID
    let agent: AgentKind
    let reviews: ReviewCommentStore
    // The model and effort the session's agent works on, which a reviewer's independence
    // is measured against.
    var authorModel: String? = nil
    var authorEffort: String? = nil
    // Where each agent's CLI is, for asking one for a second opinion. Nil for one that
    // is not installed.
    var executable: (AgentKind) -> String? = { _ in nil }
    var isBusy: () -> Bool = { false }
    // Hands the finished review to the session as one prompt.
    var send: (String) -> Void = { _ in }
    // Goes back to the conversation, to watch the agent take a sent review up.
    var openChat: () -> Void = {}
    // What a side copy needs from the session to answer a question.
    var conversation: () -> ReviewConversation? = { nil }

    var author: SecondOpinion.Reviewer { .init(agent: agent, model: authorModel, effort: authorEffort) }
}

// The session as a side copy sees it: the folder it runs in, Claude's id for its
// conversation, and the latest turns as text for an agent that cannot fork it.
struct ReviewConversation {
    var directory: String
    var claudeSessionID: String?
    var recentChat: String
}

// A comment being written or edited, and the lines it is about.
struct CommentDraft: Equatable {
    var anchor: DiffAnchor
    var path: String
    // The code under the lines when they were picked. The agent can change the file while
    // the note is being written, so the note stays with this code, not with a line number.
    var excerpt = ""
    var excerptOffsets: [Int]?
    var text = ""
    // A new note starts as a question, which is answered here and sends nothing.
    var kind = ReviewComment.Kind.question
    // The comment being edited, or nil for a new one.
    var editing: UUID?
}
