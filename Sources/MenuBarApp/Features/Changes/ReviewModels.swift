import Foundation

// Which version of a file a review comment points into. Added lines use the new file,
// removed lines use the old one, and unchanged lines can belong to a range in either.
enum ReviewSide: String, Codable, Sendable, Hashable {
    case new, old
}

// The line, or run of lines, a comment hangs from. A run is anchored at its first line
// and drawn below its last, the way a review on a pull request reads.
struct DiffAnchor: Hashable, Sendable {
    var side: ReviewSide
    var line: Int
    var lastLine: Int?

    init(side: ReviewSide, line: Int, lastLine: Int? = nil) {
        self.side = side
        self.line = line
        self.lastLine = lastLine.flatMap { $0 == line ? nil : $0 }
    }

    // Shift-clicking a second line stretches the run to it, whichever way it lies. A line
    // on the other side of the diff starts over, since a run cannot cross versions.
    func extended(to other: DiffAnchor) -> DiffAnchor {
        guard other.side == side else { return other }
        let all = [line, lastLine ?? line, other.line]
        return DiffAnchor(side: side, line: all.min()!, lastLine: all.max()!)
    }

    var label: String {
        let lines = lastLine.map { "Lines \(line)–\($0)" } ?? "Line \(line)"
        return side == .old ? lines + " (removed)" : lines
    }
}

// A note left on a line of a session's changes, waiting to be sent back to the agent.
// It names the line by number and keeps the text that was there, so a diff that moves
// under it can still find where it belongs.
struct ReviewComment: Identifiable, Codable, Equatable, Sendable {
    enum Author: Codable, Equatable, Sendable {
        case you
        // A second opinion: another agent read the changes and raised this.
        case agent(AgentKind)
    }

    // A reviewer's finding waits as pending until the person keeps it. Only kept
    // comments are ever sent, so nothing a reviewer says reaches the agent unread.
    enum Status: String, Codable, Sendable {
        case pending, kept
    }

    // A question asks for an answer, not a change, and the prompt says so.
    enum Kind: String, Codable, Sendable {
        case change, question
    }

    // How much a reviewer thinks a finding matters, in its own words.
    enum Severity: String, Codable, Sendable, CaseIterable {
        case must, should, look

        var label: String {
            switch self {
            case .must: "Must fix"
            case .should: "Should fix"
            case .look: "Worth a look"
            }
        }
    }

    // Another reviewer that raised the same lines, in its own words.
    struct Voice: Codable, Equatable, Sendable {
        var agent: AgentKind
        var body: String
        var model: String? = nil

        var name: String { model.map { agent.title + " on " + $0 } ?? agent.title }
    }

    var id = UUID()
    var root: String
    var path: String
    var side: ReviewSide
    var line: Int
    var lastLine: Int?
    var excerpt: String
    // A collapsed gap leaves holes in the quote. Offsets keep each quoted line at its
    // position in the range. Without offsets, the quoted lines are consecutive.
    var excerptOffsets: [Int]?
    var body: String
    var author: Author = .you
    var created = Date()
    var status: Status = .kept
    var kind: Kind = .change
    var severity: Severity?
    var also: [Voice] = []
    // The model and effort a reviewer ran on, as in "Sol high". Nil for one that ran on
    // whatever its agent is set to use.
    var reviewerModel: String?
    // Kept after the person rewrote it, so the card says the words are partly theirs.
    var edited = false
    // Its code left the diff and the person chose to keep it on the file as a whole.
    var onFile = false
    // Made from a question's suggested change. The question stays on the Changes screen.
    var questionID: UUID?
    // The question and its answer, sent along only when the person ticks to include them.
    var why: String?

    init(root: String, path: String, anchor: DiffAnchor, excerpt: String, body: String,
         author: Author = .you, excerptOffsets: [Int]? = nil, kind: Kind = .change,
         status: Status = .kept, severity: Severity? = nil) {
        self.root = root
        self.path = path
        side = anchor.side
        line = anchor.line
        lastLine = anchor.lastLine
        self.excerpt = excerpt
        self.excerptOffsets = excerptOffsets
        self.body = body
        self.author = author
        self.kind = kind
        self.status = status
        self.severity = severity
    }

    // Reviews saved before findings could wait, or comments could be questions, still
    // load: anything they lack takes the value every comment had then.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        root = try values.decode(String.self, forKey: .root)
        path = try values.decode(String.self, forKey: .path)
        side = try values.decode(ReviewSide.self, forKey: .side)
        line = try values.decode(Int.self, forKey: .line)
        lastLine = try values.decodeIfPresent(Int.self, forKey: .lastLine)
        excerpt = try values.decode(String.self, forKey: .excerpt)
        excerptOffsets = try values.decodeIfPresent([Int].self, forKey: .excerptOffsets)
        body = try values.decode(String.self, forKey: .body)
        author = try values.decodeIfPresent(Author.self, forKey: .author) ?? .you
        created = try values.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        status = try values.decodeIfPresent(Status.self, forKey: .status) ?? .kept
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .change
        severity = try values.decodeIfPresent(Severity.self, forKey: .severity)
        also = try values.decodeIfPresent([Voice].self, forKey: .also) ?? []
        reviewerModel = try values.decodeIfPresent(String.self, forKey: .reviewerModel)
        edited = try values.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        onFile = try values.decodeIfPresent(Bool.self, forKey: .onFile) ?? false
        questionID = try values.decodeIfPresent(UUID.self, forKey: .questionID)
        why = try values.decodeIfPresent(String.self, forKey: .why)
    }

    var anchor: DiffAnchor { DiffAnchor(side: side, line: line, lastLine: lastLine) }

    var isPending: Bool { status == .pending }

    var reviewer: AgentKind? {
        if case .agent(let agent) = author { return agent }
        return nil
    }

    // Every reviewer that raised these lines with the model it ran on, the first one first.
    var voices: [Voice] {
        (reviewer.map { [Voice(agent: $0, body: body, model: reviewerModel)] } ?? []) + also
    }

    // Every reviewer that raised these lines, the first one first.
    var reviewers: [AgentKind] { (reviewer.map { [$0] } ?? []) + also.map(\.agent) }

    func raised(by seat: SecondOpinion.Reviewer) -> Bool {
        voices.contains { $0.agent == seat.agent && $0.model == seat.seatLabel }
    }

    var authorName: String {
        switch author {
        case .you: "You"
        case .agent(let agent):
            also.isEmpty ? Voice(agent: agent, body: body, model: reviewerModel).name
                : reviewers.map(\.title).joined(separator: " and ")
        }
    }

    var linesLabel: String { onFile ? "Whole file" : anchor.label }

    // What a screen reader hears for the card: what it is, who left it, and where.
    var spokenName: String {
        let what = isPending ? "Finding" : kind == .question ? "Question" : "Comment"
        return "\(what) from \(authorName) on \(linesLabel.lowercased())"
    }
}

// One line of the small diff shown in a thread: what the agent changed near a comment.
struct ReviewDiffLine: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case addition, deletion }
    var kind: Kind
    var number: Int
    var text: String

    // The lines that changed between two versions of a file, near the lines a comment
    // was left on. A comment on the whole file, or on removed lines, takes the first
    // changes in the file.
    static func near(_ comment: ReviewComment, before: String, after: String, limit: Int = 12) -> [ReviewDiffLine] {
        guard before != after else { return [] }
        let old = before.components(separatedBy: "\n")
        let new = after.components(separatedBy: "\n")
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Each changed line with the place in the old file it sits at.
        var rows: [(line: ReviewDiffLine, at: Int)] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                rows.append((ReviewDiffLine(kind: .deletion, number: i + 1, text: old[i]), i))
                i += 1
            } else if j < new.count, inserted.contains(j) {
                rows.append((ReviewDiffLine(kind: .addition, number: j + 1, text: new[j]), i))
                j += 1
            } else {
                i += 1
                j += 1
            }
        }
        guard comment.side == .new, !comment.onFile else { return Array(rows.prefix(limit).map(\.line)) }
        let near = (comment.line - 1 - 3)...((comment.lastLine ?? comment.line) - 1 + 3)
        return Array(rows.filter { near.contains($0.at) }.prefix(limit).map(\.line))
    }
}

// A project a reviewer reads, by its folder and the name the workspace gives it.
struct ReviewRepository: Equatable, Sendable {
    var root: String
    var name: String
}

// A message in a sent comment's thread, after the comment itself: the agent's answer,
// or a reply from you.
struct ReviewReply: Identifiable, Codable, Equatable, Sendable {
    enum Author: String, Codable, Sendable {
        case you, agent
    }

    var id = UUID()
    var author: Author
    var body: String
    var sent = Date()
    // Yours: the exact words the agent was given, which is how its turn is recognised.
    var prompt: String?
    // The agent's: a reply it offers, sent with one click.
    var suggestion: String?
    // The agent's: what it changed near the comment, and whether it touched the file.
    var diff: [ReviewDiffLine] = []
    var changedFile = false
}

// A sent review, kept so Chat and Changes can show each comment as a thread: the
// comment, what came of it, the agent's answer and any replies after.
struct ReviewRound: Identifiable, Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case changed, answered, unchanged
    }

    // Where a thread stands, always said in a word and not only a colour.
    enum Status: Equatable, Sendable {
        case waiting, answered, changed, unchanged, resolved

        var label: String {
            switch self {
            case .waiting: "Waiting"
            case .answered: "Answered"
            case .changed: "Changed"
            case .unchanged: "Not changed"
            case .resolved: "Resolved"
            }
        }
    }

    var id = UUID()
    var sent = Date()
    // The exact words the agent was given, which is how the message in the conversation
    // is recognised as this review.
    var prompt: String
    var note: String
    var comments: [ReviewComment]
    // What each commented file held when the review went, by "root/path". A comment with
    // no lines of its own to look for is judged by whether its file moved at all.
    var fileDigests: [String: String] = [:]
    // The tree each project held when the review went, so a later reviewer can read only
    // what changed after it.
    var trees: [String: String] = [:]
    // Filled in once the turn that took the review ends.
    var outcomes: [UUID: Outcome]?
    // Each comment's thread after the comment, by the comment's id.
    var replies: [UUID: [ReviewReply]] = [:]
    var resolved: Set<UUID> = []
    // Comments with an answer from the agent that has not been opened yet.
    var unread: Set<UUID> = []

    init(prompt: String, note: String, comments: [ReviewComment]) {
        self.prompt = prompt
        self.note = note
        self.comments = comments
    }

    // Rounds saved before comments had threads still load, with none.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sent = try values.decode(Date.self, forKey: .sent)
        prompt = try values.decode(String.self, forKey: .prompt)
        note = try values.decode(String.self, forKey: .note)
        comments = try values.decode([ReviewComment].self, forKey: .comments)
        fileDigests = try values.decodeIfPresent([String: String].self, forKey: .fileDigests) ?? [:]
        trees = try values.decodeIfPresent([String: String].self, forKey: .trees) ?? [:]
        outcomes = try values.decodeIfPresent([UUID: Outcome].self, forKey: .outcomes)
        replies = try values.decodeIfPresent([UUID: [ReviewReply]].self, forKey: .replies) ?? [:]
        resolved = try values.decodeIfPresent(Set<UUID>.self, forKey: .resolved) ?? []
        unread = try values.decodeIfPresent(Set<UUID>.self, forKey: .unread) ?? []
    }

    var isSettled: Bool { outcomes != nil }

    func replies(_ commentID: UUID) -> [ReviewReply] { replies[commentID] ?? [] }

    // A reply of yours the agent has not answered yet.
    func isAwaitingReply(_ commentID: UUID) -> Bool { replies(commentID).last?.author == .you }

    func status(_ commentID: UUID) -> Status {
        if resolved.contains(commentID) { return .resolved }
        guard let outcome = outcomes?[commentID], !isAwaitingReply(commentID) else { return .waiting }
        switch outcome {
        case .changed: return .changed
        case .answered: return .answered
        case .unchanged: return .unchanged
        }
    }

    // The comment's place in the round, counted from 1, as the prompt numbers it.
    func number(_ commentID: UUID) -> Int? {
        comments.firstIndex { $0.id == commentID }.map { $0 + 1 }
    }

    // What came of one comment, judged from the file as it is now. A question was asked
    // to be answered, so it was. Otherwise the comment's code still on its own lines means
    // nothing touched it; code that moved or is gone means the lines were changed.
    static func outcome(for comment: ReviewComment, fileText: String?, digestAtSend: String?) -> Outcome {
        if comment.kind == .question { return .answered }
        guard let fileText else { return .changed }
        if comment.onFile || comment.side == .old || comment.excerpt.isBlank {
            return digest(fileText) == digestAtSend ? .unchanged : .changed
        }
        let numbered = fileText.components(separatedBy: "\n").enumerated().map {
            NumberedDiffLine(id: $0.offset, side: .new, number: $0.offset + 1, code: $0.element)
        }
        let found = ReviewPlacement.locate(comment.anchor, excerpt: comment.excerpt,
                                           excerptOffsets: comment.excerptOffsets, in: numbered)
        return found?.anchor == comment.anchor ? .unchanged : .changed
    }

    static func digest(_ text: String) -> String { String(StableHash.fnv1a(text), radix: 16) }

    static func fileKey(root: String, path: String) -> String { root + "/" + path }
}
