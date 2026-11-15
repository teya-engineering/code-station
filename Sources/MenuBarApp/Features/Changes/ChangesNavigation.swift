import AppKit
import SwiftUI

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
    // A comment listed under the file, which the arrow keys step onto like a file.
    var note: UUID? = nil

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
    var commitDrafts: [String: ChangesCommitDraft] = [:]

    func commitDraft(for root: String) -> ChangesCommitDraft {
        if let draft = commitDrafts[root] { return draft }
        let draft = ChangesCommitDraft()
        commitDrafts[root] = draft
        return draft
    }
    var collapsed: Set<String> = []
    var treeWidth = ExplorerSplitLayout.defaultTreeWidth
    var showingHistory = false
    var histories: [String: CommitHistorySelection] = [:]
    // Every project's commits, so each project's navigator can list the others' too.
    var commits: [String: [GitCommitSummary]] = [:]
    var collapsedHistories: Set<String> = []
    var historyFilter = ""
    // Narrows the changed files by name.
    var fileFilter = ""
    // Files whose comments are folded away, and files showing their resolved ones too,
    // keyed by repository and path.
    var foldedNotes: Set<String> = []
    var resolvedShown: Set<String> = []
    // Kept here, with the comment in focus, because each project gets a screen of its own
    // and stepping through a review moves between them.
    var focusedComment: UUID?
    var secondOpinionFocus = Set(SecondOpinion.Focus.standard)
    var secondOpinionScope = SecondOpinionScopeChoice.all
    var secondOpinionNote = ""
    // The MCP servers the next ask's reviewers may use. Nil keeps them away from all.
    var secondOpinionServers: SecondOpinion.ServerAccess?
    // An ask settled in the session's dialog, or a click on a run under way, from the
    // session header, which sits outside the screen that starts runs and shows them. It
    // waits here until that screen takes it, since a click from another tab opens the
    // screen in the same moment.
    enum SecondOpinionRequest: Equatable {
        case ask([SecondOpinion.Reviewer])
        case open
    }
    var secondOpinionRequest: SecondOpinionRequest?
    // The card for questions about the whole change is opened from the session header and
    // drawn by the screen under it, so both read its state from here. It does not hang on
    // the list's mode, so the card and its button cannot drift apart.
    private(set) var askingWholeChange = false
    // When the card was last open. An answer that lands after it is waiting to be read.
    private(set) var wholeChangeSeen = Date()
    // The middle of the header button in window coordinates, so the card can point at it.
    var askOrigin: CGPoint?
    var askDraft = ""
    // The thread the next question goes into, instead of starting a new one.
    var askFollowing: UUID?
    // The one thread the card shows open. Nil opens the newest.
    var askExpanded: UUID?
    var askShowsResolved = false
    // The file and lines an answer pointed at, lit in the diff under the card.
    var citation: ChangeCitation?
    // The file a reference in an answer is under the pointer, lit in the file list so the
    // person sees where it is before they click.
    var citeHover: ChangeCitation?

    func setAskingWholeChange(_ open: Bool) {
        guard open != askingWholeChange else { return }
        askingWholeChange = open
        wholeChangeSeen = Date()
        if !open {
            askFollowing = nil
            citeHover = nil
        }
    }

    func history(for root: String) -> CommitHistorySelection {
        if let selection = histories[root] { return selection }
        let selection = CommitHistorySelection()
        histories[root] = selection
        return selection
    }
}

// How the card for the whole change lays out its questions: oldest first, so a thread
// reads top to bottom like a conversation, with the resolved ones kept apart.
enum WholeChangeThreads {
    static func split(_ questions: [ReviewQuestion]) -> (open: [ReviewQuestion], resolved: [ReviewQuestion]) {
        let whole = questions.filter(\.isWhole).sorted { $0.created < $1.created }
        return (whole.filter { !$0.resolved }, whole.filter(\.resolved))
    }

    // The thread shown open: the one picked, or else the newest that is still open.
    static func expanded(_ picked: UUID?, in open: [ReviewQuestion]) -> UUID? {
        if let picked, open.contains(where: { $0.id == picked }) { return picked }
        return open.last?.id
    }

    // Questions the card offers before anything is asked. Each is a whole question, so a
    // click asks it at once. The last one only makes sense when the change spans projects.
    static func starters(projects: Int) -> [String] {
        let fit = projects > 1
            ? "How do the \(projects == 2 ? "two" : "\(projects)") projects fit together?"
            : "Why was it built this way?"
        return ["What does this change do, in short?", "Where should I start reading?",
                "What could break for existing users?", fit]
    }

    // A step the side copy has finished, told as done: "Reading the chat" becomes "Read
    // the chat". Steps are written as "-ing" phrases while they run.
    static func finishedStep(_ step: String) -> String {
        let done = ["Opening": "Opened", "Reading": "Read", "Writing": "Wrote", "Going on": "Went on",
                    "Checking": "Checked", "Looking": "Looked", "Searching": "Searched", "Starting": "Started"]
        for (running, finished) in done where step.hasPrefix(running + " ") || step == running {
            return finished + step.dropFirst(running.count)
        }
        return step
    }

    // True when an answer has landed since the card was last open.
    static func hasUnreadAnswer(_ questions: [ReviewQuestion], seen: Date) -> Bool {
        questions.contains { question in
            question.isWhole && question.exchanges.contains { ($0.answered ?? .distantPast) > seen }
        }
    }
}

// A file an answer points at, with the lines when it names them.
struct ChangeCitation: Equatable {
    var root: String
    var path: String
    var anchor: DiffAnchor?
    // A new click on the same reference brings the lines on screen again.
    var serial = 0

    // Reads a link from an answer as a file in one of the changed repositories. Links
    // come as absolute file paths or as paths relative to a repository, with an optional
    // ":line" or ":first-last" at the end. Anything else is left to open as usual.
    static func resolve(_ url: URL, roots: [String],
                        isChanged: (_ root: String, _ path: String) -> Bool) -> ChangeCitation? {
        let raw: String
        if url.isFileURL {
            raw = url.path
        } else if url.scheme == nil || url.scheme?.contains(".") == true {
            // A bare "File.swift:12" reads to URL as a scheme of "file.swift".
            raw = url.scheme == nil ? url.path : (url.absoluteString.removingPercentEncoding ?? url.absoluteString)
        } else {
            return nil
        }
        var path = raw
        var anchor: DiffAnchor?
        if let suffix = raw.range(of: #":(\d+)(?:[-:](\d+))?$"#, options: .regularExpression) {
            let numbers = raw[suffix].dropFirst().split(whereSeparator: { $0 == "-" || $0 == ":" }).compactMap { Int($0) }
            path = String(raw[..<suffix.lowerBound])
            if let first = numbers.first {
                // A second number after a colon is a column, not the end of a range.
                let isRange = raw[suffix].contains("-")
                let last = isRange ? numbers.dropFirst().first.flatMap { $0 > first ? $0 : nil } : nil
                anchor = DiffAnchor(side: .new, line: first, lastLine: last)
            }
        }
        if path.hasPrefix("/") {
            let root = roots
                .filter { path.pathRelative(to: $0).map { !$0.isEmpty } ?? false }
                .max { $0.count < $1.count }
            guard let root, let relative = path.pathRelative(to: root), isChanged(root, relative) else { return nil }
            return ChangeCitation(root: root, path: relative, anchor: anchor)
        }
        let relative = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        guard !relative.isEmpty, let root = roots.first(where: { isChanged($0, relative) }) else { return nil }
        return ChangeCitation(root: root, path: relative, anchor: anchor)
    }
}

extension ChangeCitation {
    // Every changed file an answer points at, in the order it names them, each once.
    // Links are read first; a code span such as `Sources/App.swift:12` counts as well,
    // since that is how a file is most often named in prose.
    static func references(in answer: String, roots: [String],
                           isChanged: (_ root: String, _ path: String) -> Bool) -> [ChangeCitation] {
        guard let parsed = try? AttributedString(markdown: answer, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return [] }
        var found: [ChangeCitation] = []
        for run in parsed.runs {
            var url = run.link
            if url == nil, run.inlinePresentationIntent?.contains(.code) == true {
                let span = String(parsed[run.range].characters).trimmed
                url = span.contains(" ") ? nil : URL(string: span)
            }
            guard let url, let citation = resolve(url, roots: roots, isChanged: isChanged),
                  !found.contains(where: { $0.root == citation.root && $0.path == citation.path && $0.anchor == citation.anchor })
            else { continue }
            found.append(citation)
        }
        return found
    }

    var fileName: String { (path as NSString).lastPathComponent }

    // ":42" or ":42-48", the way the chip writes it after the file name.
    var linesSuffix: String {
        guard let anchor else { return "" }
        return ":\(anchor.line)" + (anchor.lastLine.map { "-\($0)" } ?? "")
    }

    var spokenName: String {
        guard let anchor else { return "Show \(fileName)" }
        return "Show \(fileName) " + (anchor.lastLine.map { "lines \(anchor.line) to \($0)" } ?? "line \(anchor.line)")
    }

    func sameFile(root: String, path: String) -> Bool { self.root == root && self.path == path }
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

@MainActor
@Observable
final class ChangesCommitDraft {
    var message = ""
    var excluded: Set<GitChange.ID> = []
    var amend = false
    var messageBeforeAmend = ""

    func setAmend(_ enabled: Bool, lastMessage: String?) {
        guard amend != enabled else { return }
        if enabled {
            messageBeforeAmend = message
            if let lastMessage { message = lastMessage }
        } else {
            message = messageBeforeAmend
        }
        amend = enabled
    }

    func didCommit() {
        message = ""
        messageBeforeAmend = ""
        amend = false
    }
}
