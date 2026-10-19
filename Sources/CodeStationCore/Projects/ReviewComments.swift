import Foundation
import Observation

// Which version of a file a review comment points into. Added lines use the new file,
// removed lines use the old one, and unchanged lines can belong to a range in either.
public enum ReviewSide: String, Codable, Sendable, Hashable {
    case new, old
}

// The line, or run of lines, a comment hangs from. A run is anchored at its first line
// and drawn below its last, the way a review on a pull request reads.
public struct DiffAnchor: Hashable, Sendable {
    public var side: ReviewSide
    public var line: Int
    public var lastLine: Int?

    public init(side: ReviewSide, line: Int, lastLine: Int? = nil) {
        self.side = side
        self.line = line
        self.lastLine = lastLine.flatMap { $0 == line ? nil : $0 }
    }

    // Shift-clicking a second line stretches the run to it, whichever way it lies. A line
    // on the other side of the diff starts over, since a run cannot cross versions.
    public func extended(to other: DiffAnchor) -> DiffAnchor {
        guard other.side == side else { return other }
        let all = [line, lastLine ?? line, other.line]
        return DiffAnchor(side: side, line: all.min()!, lastLine: all.max()!)
    }

    public var label: String {
        let lines = lastLine.map { "Lines \(line)–\($0)" } ?? "Line \(line)"
        return side == .old ? lines + " (removed)" : lines
    }
}

// A note left on a line of a session's changes, waiting to be sent back to the agent.
// It names the line by number and keeps the text that was there, so a diff that moves
// under it can still find where it belongs.
public struct ReviewComment: Identifiable, Codable, Equatable, Sendable {
    public enum Author: Codable, Equatable, Sendable {
        case you
        // A second opinion: another agent read the changes and raised this.
        case agent(AgentKind)
    }

    // A reviewer's finding waits as pending until the person keeps it. Only kept
    // comments are ever sent, so nothing a reviewer says reaches the agent unread.
    public enum Status: String, Codable, Sendable {
        case pending, kept
    }

    // A question asks for an answer, not a change, and the prompt says so.
    public enum Kind: String, Codable, Sendable {
        case change, question
    }

    // How much a reviewer thinks a finding matters, in its own words.
    public enum Severity: String, Codable, Sendable, CaseIterable {
        case must, should, look

        public var label: String {
            switch self {
            case .must: "Must fix"
            case .should: "Should fix"
            case .look: "Worth a look"
            }
        }
    }

    // Another reviewer that raised the same lines, in its own words.
    public struct Voice: Codable, Equatable, Sendable {
        public var agent: AgentKind
        public var body: String
        public var model: String? = nil

        public var name: String { model.map { agent.title + " on " + $0 } ?? agent.title }
    }

    public var id = UUID()
    public var root: String
    public var path: String
    public var side: ReviewSide
    public var line: Int
    public var lastLine: Int?
    public var excerpt: String
    // A collapsed gap leaves holes in the quote. Offsets keep each quoted line at its
    // position in the range. Without offsets, the quoted lines are consecutive.
    public var excerptOffsets: [Int]?
    public var body: String
    public var author: Author = .you
    public var created = Date()
    public var status: Status = .kept
    public var kind: Kind = .change
    public var severity: Severity?
    public var also: [Voice] = []
    // The model and effort a reviewer ran on, as in "Sol high". Nil for one that ran on
    // whatever its agent is set to use.
    public var reviewerModel: String?
    // Kept after the person rewrote it, so the card says the words are partly theirs.
    public var edited = false
    // Its code left the diff and the person chose to keep it on the file as a whole.
    public var onFile = false
    // Made from a question's suggested change. The question stays on the Changes screen.
    public var questionID: UUID?
    // The question and its answer, sent along only when the person ticks to include them.
    public var why: String?

    public init(root: String, path: String, anchor: DiffAnchor, excerpt: String, body: String,
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
    public init(from decoder: Decoder) throws {
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

    public var anchor: DiffAnchor { DiffAnchor(side: side, line: line, lastLine: lastLine) }

    public var isPending: Bool { status == .pending }

    public var reviewer: AgentKind? {
        if case .agent(let agent) = author { return agent }
        return nil
    }

    // Every reviewer that raised these lines with the model it ran on, the first one first.
    public var voices: [Voice] {
        (reviewer.map { [Voice(agent: $0, body: body, model: reviewerModel)] } ?? []) + also
    }

    // Every reviewer that raised these lines, the first one first.
    public var reviewers: [AgentKind] { (reviewer.map { [$0] } ?? []) + also.map(\.agent) }

    public func raised(by seat: SecondOpinion.Reviewer) -> Bool {
        voices.contains { $0.agent == seat.agent && $0.model == seat.seatLabel }
    }

    public var authorName: String {
        switch author {
        case .you: "You"
        case .agent(let agent):
            also.isEmpty ? Voice(agent: agent, body: body, model: reviewerModel).name
                : reviewers.map(\.title).joined(separator: " and ")
        }
    }

    public var linesLabel: String { onFile ? "Whole file" : anchor.label }

    // What a screen reader hears for the card: what it is, who left it, and where.
    public var spokenName: String {
        let what = isPending ? "Finding" : kind == .question ? "Question" : "Comment"
        return "\(what) from \(authorName) on \(linesLabel.lowercased())"
    }
}

// One changed or unchanged line of a diff with the number it carries in the version it
// belongs to. The gutter, the comment rows and the placement below all read from this,
// so a number on screen and a number in a comment always agree.
public struct NumberedDiffLine: Equatable {
    public var id: Int
    public var side: ReviewSide
    public var number: Int
    // The code without the diff's sign column.
    public var code: String

    public static func lines(_ lines: [DiffLine]) -> [NumberedDiffLine] {
        var numbered: [NumberedDiffLine] = []
        for row in DiffComparisonRow.align(lines) {
            if let left = row.left, left == row.right {
                if left.kind == .context, let number = row.oldNumber {
                    numbered.append(.init(id: left.id, side: .old, number: number, code: code(left)))
                }
                if left.kind == .context, let number = row.newNumber {
                    numbered.append(.init(id: left.id, side: .new, number: number, code: code(left)))
                }
                continue
            }
            if let left = row.left, left.kind == .deletion, let number = row.oldNumber {
                numbered.append(.init(id: left.id, side: .old, number: number, code: code(left)))
            }
            if let right = row.right, right.kind == .addition, let number = row.newNumber {
                numbered.append(.init(id: right.id, side: .new, number: number, code: code(right)))
            }
        }
        return numbered
    }

    public static func excerpt(_ anchor: DiffAnchor, in diff: [DiffLine]) -> (text: String, offsets: [Int]) {
        let range = anchor.line...(anchor.lastLine ?? anchor.line)
        let selected = lines(diff).filter { $0.side == anchor.side && range.contains($0.number) }
        return (selected.map(\.code).joined(separator: "\n"), selected.map { $0.number - anchor.line })
    }

    private static func code(_ line: DiffLine) -> String { String(line.text.dropFirst()) }

    public var anchor: DiffAnchor { DiffAnchor(side: side, line: number) }
}

// Where each of a file's comments sits in the diff open now. The agent may have moved
// the code since a comment was left, so a comment whose line no longer holds the text it
// was left on looks for that text nearby, and one that cannot find it at all is listed
// above the diff instead of being pinned to the wrong line.
public struct ReviewPlacement: Equatable {
    // Keyed by the id of the diff line each group of comments is drawn below.
    public var below: [Int: [ReviewComment]] = [:]
    public var unplaced: [ReviewComment] = []

    // Kept on the file as a whole, by choice, after their code left the diff.
    public var onFile: [ReviewComment] = []

    public init(below: [Int: [ReviewComment]] = [:], unplaced: [ReviewComment] = [], onFile: [ReviewComment] = []) {
        self.below = below
        self.unplaced = unplaced
        self.onFile = onFile
    }

    public static func place(_ comments: [ReviewComment], in lines: [DiffLine]) -> ReviewPlacement {
        guard !comments.isEmpty else { return ReviewPlacement() }
        let numbered = NumberedDiffLine.lines(lines)
        var placement = ReviewPlacement()
        for comment in comments.sorted(by: { $0.created < $1.created }) {
            if comment.onFile {
                placement.onFile.append(comment)
            } else if let found = locate(comment.anchor, excerpt: comment.excerpt,
                                  excerptOffsets: comment.excerptOffsets, in: numbered) {
                placement.below[found.lastID, default: []].append(comment)
            } else {
                placement.unplaced.append(comment)
            }
        }
        return placement
    }

    // Where the lines that held `excerpt` are now, and the id of the last of them. The
    // lines a comment was left on win while every one of them still holds its code;
    // otherwise the nearest run that does. Code as plain as a lone brace turns up in many
    // places, so if it has moved and could be any of several, it is nowhere rather than
    // somewhere wrong. A comment that quotes nothing can only stay on its own number.
    public static func locate(_ anchor: DiffAnchor, excerpt: String,
                       excerptOffsets: [Int]? = nil,
                       in numbered: [NumberedDiffLine]) -> (anchor: DiffAnchor, lastID: Int)? {
        var lines: [Int: NumberedDiffLine] = [:]
        for line in numbered where line.side == anchor.side { lines[line.number] = line }
        let span = (anchor.lastLine ?? anchor.line) - anchor.line
        func last(from start: Int, count: Int) -> NumberedDiffLine? {
            lines[start + span] ?? lines[start + count - 1]
        }
        guard !excerpt.isBlank else {
            return lines[anchor.line + span].map { (anchor, $0.id) }
        }
        let expected = excerpt.components(separatedBy: "\n").map(\.trimmed)
        let offsets = excerptOffsets ?? Array(expected.indices)
        guard offsets.count == expected.count else { return nil }
        func holds(_ start: Int) -> Bool {
            zip(offsets, expected).allSatisfy { offset, code in lines[start + offset]?.code.trimmed == code }
        }
        if holds(anchor.line), let end = last(from: anchor.line, count: expected.count) {
            return (anchor, end.id)
        }
        let starts = lines.keys.filter(holds).sorted { abs($0 - anchor.line) < abs($1 - anchor.line) }
        guard let best = starts.first else { return nil }
        let distinctive = expected.joined().filter { $0.isLetter || $0.isNumber }.count >= 4
        guard starts.count == 1 || distinctive,
              let end = last(from: best, count: expected.count) else { return nil }
        let moved = DiffAnchor(side: anchor.side, line: best, lastLine: anchor.lastLine.map { _ in best + span })
        return (moved, end.id)
    }
}

// The prompt a set of comments becomes. Each one names its file and lines and quotes
// the code, so the agent can act on it without having seen the diff the comments were
// written on.
public enum ReviewPrompt {
    public static func feedback(_ comments: [ReviewComment], projectNames: [String: String] = [:],
                         note: String = "") -> String {
        let ordered = ReviewOrder.sorted(comments)
        // Named by the projects in the workspace rather than the ones the comments touch:
        // two projects can each have a src/App.swift, and the agent sees both.
        let spansProjects = projectNames.count > 1 || Set(comments.map(\.root)).count > 1
        var text = comments.count == 1
            ? "I reviewed your changes and left a comment. Please address it. "
                + "If you disagree, say why instead of changing the code."
            : "I reviewed your changes and left \(comments.count) comments. Please address each one. "
                + "If you disagree with a comment, say why instead of changing the code."
        if comments.contains(where: { $0.kind == .question }) {
            text += " A comment marked as a question only needs an answer, not a code change."
        }
        text += " " + ReviewAnswers.instructions
        for (index, comment) in ordered.enumerated() {
            var file = comment.path
            if spansProjects {
                let project = projectNames[comment.root] ?? (comment.root as NSString).lastPathComponent
                file = project + "/" + file
            }
            let lines = comment.lastLine.map { "lines \(comment.line)–\($0)" } ?? "line \(comment.line)"
            let place = comment.onFile ? "the whole file"
                : comment.side == .old ? "removed \(lines) of the previous version" : lines
            var heading = "\(index + 1). \(file), \(place)"
            if comment.kind == .question { heading += " (a question)" }
            if comment.reviewer != nil { heading += " (raised in a \(comment.authorName) review)" }
            text += "\n\n" + heading
            // Several notes on the same lines quote them once, at the first.
            let previous = index > 0 ? ordered[index - 1] : nil
            let sameLines = previous.map {
                $0.root == comment.root && $0.path == comment.path && $0.anchor == comment.anchor
                    && $0.onFile == comment.onFile
            } ?? false
            if sameLines {
                text += ", the same code as above"
            } else if !comment.excerpt.isBlank {
                text += "\n```\n" + comment.excerpt + "\n```"
            }
            text += "\n" + comment.body.trimmed
            if let why = comment.why, !why.isBlank { text += "\n\nWhy: " + why.trimmed }
        }
        if !note.isBlank { text += "\n\nOne more thing: " + note.trimmed }
        return text
    }

    // A reply in a thread goes at once, as a short turn about those lines alone. It
    // repeats the comment and the last answer, since the agent may have moved on since.
    public static func reply(_ text: String, to comment: ReviewComment, number: Int, earlier: [ReviewReply],
                      projectNames: [String: String] = [:]) -> String {
        var file = comment.path
        if projectNames.count > 1 {
            file = (projectNames[comment.root] ?? (comment.root as NSString).lastPathComponent) + "/" + file
        }
        let lines = comment.lastLine.map { "lines \(comment.line)–\($0)" } ?? "line \(comment.line)"
        let place = comment.onFile ? "the whole file"
            : comment.side == .old ? "removed \(lines) of the previous version" : lines
        var prompt = "A follow-up on my review comment \(number), on \(file), \(place)."
        if !comment.excerpt.isBlank { prompt += "\n```\n" + comment.excerpt + "\n```" }
        prompt += "\nI wrote: " + comment.body.trimmed
        if let answer = earlier.last(where: { $0.author == .agent }), !answer.body.isBlank {
            prompt += "\n\nYou answered: " + answer.body.trimmed
        }
        prompt += "\n\nMy reply: " + text.trimmed
        prompt += "\n\nAnswer under a heading line that says `### Comment \(number)`. " + ReviewAnswers.suggestionInstructions
        return prompt
    }
}

// The agent answers each comment under a heading of its own, so the app can hang each
// answer under the comment it is about instead of leaving it as loose prose.
public enum ReviewAnswers {
    public struct Answer: Equatable, Sendable {
        public var body: String
        // A short reply the agent offers, for when it proposes to do something more.
        public var suggestion: String?
    }

    public static let suggestionInstructions = "If you offer to do something more, end that answer with a line that starts "
        + "`Suggested reply:` followed by the few words I could send to say yes."

    public static let instructions = "When you are done, answer each comment in a few sentences under a heading line "
        + "of its own: `### Comment 1`, `### Comment 2` and so on, using the numbers below. "
        + suggestionInstructions

    // Where the answers start in a turn's text, and each one by the number of its comment.
    // Nil when the agent wrote no headings at all.
    public static func split(_ text: String) -> (start: Int, answers: [Int: Answer])? {
        let lines = text.components(separatedBy: "\n")
        var answers: [Int: Answer] = [:]
        var start: Int?
        var offset = 0
        var current: (number: Int, lines: [String])?
        func close() {
            guard let current else { return }
            let answer = read(current.lines.joined(separator: "\n"))
            if let existing = answers[current.number] {
                answers[current.number] = Answer(body: existing.body + "\n\n" + answer.body,
                                                 suggestion: answer.suggestion ?? existing.suggestion)
            } else {
                answers[current.number] = answer
            }
        }
        for line in lines {
            if let number = heading(line) {
                close()
                if start == nil { start = offset }
                current = (number, [])
            } else {
                current?.lines.append(line)
            }
            offset += line.count + 1
        }
        close()
        guard let start else { return nil }
        return (start, answers)
    }

    // A turn's answers, read from the message it ended with. One comment answered without
    // a heading is answered by the turn's last words, after its last tool call.
    public static func read(_ message: ChatMessage, count: Int) -> (start: Int, answers: [Int: Answer])? {
        if let found = split(message.text) { return found }
        guard count == 1 else { return nil }
        let start = min(message.tools.compactMap(\.textOffset).max() ?? 0, message.text.count)
        let tail = String(message.text.dropFirst(start))
        guard !tail.isBlank else { return nil }
        return (start, [1: read(tail)])
    }

    // The message that answered a prompt: the agent's turn right after it.
    public static func reply(to prompt: String, in messages: [ChatMessage]) -> ChatMessage? {
        let text = prompt.trimmed
        guard let index = messages.lastIndex(where: { $0.role == .user && $0.text.trimmed == text }) else { return nil }
        return messages[(index + 1)...].prefix { $0.role != .user }.last { $0.role == .assistant }
    }

    private static func heading(_ line: String) -> Int? {
        guard let match = line.firstMatch(of: /^\s{0,3}(?:#{1,6}\s*|\*\*)Comment\s+(\d+)\b.*$/.ignoresCase()) else {
            return nil
        }
        return Int(match.1)
    }

    private static func read(_ section: String) -> Answer {
        var lines = section.components(separatedBy: "\n")
        while lines.last?.isBlank == true { lines.removeLast() }
        var suggestion: String?
        if let last = lines.last,
           let match = last.firstMatch(of: /^\s*(?:[-*]\s*)?\**_?Suggested reply:?\**_?:?\s*(.+)$/.ignoresCase()) {
            let words = String(match.1).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*_“”‘’ "))
            if !words.isEmpty { suggestion = words }
            lines.removeLast()
        }
        return Answer(body: lines.joined(separator: "\n").trimmed, suggestion: suggestion)
    }
}

// One line of the small diff shown in a thread: what the agent changed near a comment.
public struct ReviewDiffLine: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case addition, deletion }
    public var kind: Kind
    public var number: Int
    public var text: String

    // The lines that changed between two versions of a file, near the lines a comment
    // was left on. A comment on the whole file, or on removed lines, takes the first
    // changes in the file.
    public static func near(_ comment: ReviewComment, before: String, after: String, limit: Int = 12) -> [ReviewDiffLine] {
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

// The one order comments are read in everywhere: the review list, stepping from one to
// the next, the send checklist and the prompt. File by file, new lines before removed
// ones, top to bottom.
public enum ReviewOrder {
    public static func sorted(_ comments: [ReviewComment], roots: [String] = []) -> [ReviewComment] {
        func rank(_ root: String) -> Int { roots.firstIndex(of: root) ?? roots.count }
        return comments.sorted { a, b in
            if a.root != b.root { return (rank(a.root), a.root) < (rank(b.root), b.root) }
            if a.path != b.path { return a.path < b.path }
            let place = { (comment: ReviewComment) in
                (comment.onFile ? 0 : 1, comment.side == .new ? 0 : 1, comment.line)
            }
            if place(a) != place(b) { return place(a) < place(b) }
            return a.created < b.created
        }
    }

    // The comment after or before `current`, going round at either end. With nothing
    // focused yet, the first step lands on the first or the last.
    public static func step(from current: UUID?, by step: Int, in ordered: [ReviewComment]) -> ReviewComment? {
        guard !ordered.isEmpty else { return nil }
        guard let current, let index = ordered.firstIndex(where: { $0.id == current }) else {
            return step > 0 ? ordered.first : ordered.last
        }
        return ordered[(index + step + ordered.count) % ordered.count]
    }
}

// A project a reviewer reads, by its folder and the name the workspace gives it.
public struct ReviewRepository: Equatable, Sendable {
    public var root: String
    public var name: String

    public init(root: String, name: String) {
        self.root = root
        self.name = name
    }
}

// What a second opinion was asked to do, kept with its run so Try again asks the same.
public struct SecondOpinionRequest: Equatable, Sendable {
    public enum Scope: Equatable, Sendable {
        case all
        case file(root: String, path: String)
        // Only what changed after the last review was sent, compared against the tree
        // recorded in each project at that moment.
        case sinceReview(trees: [String: String])

        public var isSinceReview: Bool {
            if case .sinceReview = self { return true }
            return false
        }
    }

    public var focus: [SecondOpinion.Focus] = SecondOpinion.Focus.standard
    public var scope: Scope = .all
    public var repositories: [ReviewRepository]
    public var executable: String

    public init(focus: [SecondOpinion.Focus] = SecondOpinion.Focus.standard, scope: Scope = .all, repositories: [ReviewRepository], executable: String) {
        self.focus = focus
        self.scope = scope
        self.repositories = repositories
        self.executable = executable
    }
}

// One reviewer's lane in the second opinion: what it is reading, how long it has taken,
// and what it came to.
public struct SecondOpinionRun: Equatable, Identifiable {
    public enum State: Equatable {
        case running
        case finished(found: Int)
        case failed(String)
    }

    public var reviewer: SecondOpinion.Reviewer
    public var started: Date
    public var ended: Date?
    public var state: State = .running
    public var activity = "Gathering the changes"
    // The last few things it did, oldest first, ending with the activity.
    public var recent = ["Gathering the changes"]
    public var request: SecondOpinionRequest

    public var agent: AgentKind { reviewer.agent }
    public var id: SecondOpinion.Reviewer { reviewer }
    public var isRunning: Bool { state == .running }
}

// A message in a sent comment's thread, after the comment itself: the agent's answer,
// or a reply from you.
public struct ReviewReply: Identifiable, Codable, Equatable, Sendable {
    public enum Author: String, Codable, Sendable {
        case you, agent
    }

    public var id = UUID()
    public var author: Author
    public var body: String
    public var sent = Date()
    // Yours: the exact words the agent was given, which is how its turn is recognised.
    public var prompt: String?
    // The agent's: a reply it offers, sent with one click.
    public var suggestion: String?
    // The agent's: what it changed near the comment, and whether it touched the file.
    public var diff: [ReviewDiffLine] = []
    public var changedFile = false
}

// A sent review, kept so Chat and Changes can show each comment as a thread: the
// comment, what came of it, the agent's answer and any replies after.
public struct ReviewRound: Identifiable, Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case changed, answered, unchanged
    }

    // Where a thread stands, always said in a word and not only a colour.
    public enum Status: Equatable, Sendable {
        case waiting, answered, changed, unchanged, resolved

        public var label: String {
            switch self {
            case .waiting: "Waiting"
            case .answered: "Answered"
            case .changed: "Changed"
            case .unchanged: "Not changed"
            case .resolved: "Resolved"
            }
        }
    }

    public var id = UUID()
    public var sent = Date()
    // The exact words the agent was given, which is how the message in the conversation
    // is recognised as this review.
    public var prompt: String
    public var note: String
    public var comments: [ReviewComment]
    // What each commented file held when the review went, by "root/path". A comment with
    // no lines of its own to look for is judged by whether its file moved at all.
    public var fileDigests: [String: String] = [:]
    // The tree each project held when the review went, so a later reviewer can read only
    // what changed after it.
    public var trees: [String: String] = [:]
    // Filled in once the turn that took the review ends.
    public var outcomes: [UUID: Outcome]?
    // Each comment's thread after the comment, by the comment's id.
    public var replies: [UUID: [ReviewReply]] = [:]
    public var resolved: Set<UUID> = []
    // Comments with an answer from the agent that has not been opened yet.
    public var unread: Set<UUID> = []

    public init(prompt: String, note: String, comments: [ReviewComment]) {
        self.prompt = prompt
        self.note = note
        self.comments = comments
    }

    // Rounds saved before comments had threads still load, with none.
    public init(from decoder: Decoder) throws {
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

    public var isSettled: Bool { outcomes != nil }

    public func replies(_ commentID: UUID) -> [ReviewReply] { replies[commentID] ?? [] }

    // A reply of yours the agent has not answered yet.
    public func isAwaitingReply(_ commentID: UUID) -> Bool { replies(commentID).last?.author == .you }

    public func status(_ commentID: UUID) -> Status {
        if resolved.contains(commentID) { return .resolved }
        guard let outcome = outcomes?[commentID], !isAwaitingReply(commentID) else { return .waiting }
        switch outcome {
        case .changed: return .changed
        case .answered: return .answered
        case .unchanged: return .unchanged
        }
    }

    // The comment's place in the round, counted from 1, as the prompt numbers it.
    public func number(_ commentID: UUID) -> Int? {
        comments.firstIndex { $0.id == commentID }.map { $0 + 1 }
    }

    // What came of one comment, judged from the file as it is now. A question was asked
    // to be answered, so it was. Otherwise the comment's code still on its own lines means
    // nothing touched it; code that moved or is gone means the lines were changed.
    public static func outcome(for comment: ReviewComment, fileText: String?, digestAtSend: String?) -> Outcome {
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

    public static func digest(_ text: String) -> String { String(StableHash.fnv1a(text), radix: 16) }

    public static func fileKey(root: String, path: String) -> String { root + "/" + path }
}

// Every session's review: the comments not yet sent, the reviewers at work, and the
// rounds already sent. Comments and rounds are kept on disk, so a review written before
// quitting is still there after.
@MainActor
@Observable
public final class ReviewCommentStore {
    public private(set) var loadError: String?
    public private(set) var saveError: String?
    private var comments: [UUID: [ReviewComment]] = [:]
    // Second opinions, one lane per reviewer. They outlive the Changes tab, which can be
    // closed and reopened while one runs.
    public private(set) var runs: [UUID: [SecondOpinionRun]] = [:]
    // Findings dismissed since the last second opinion was asked for, so they can still be
    // shown as dismissed and brought back. Kept only while the app runs.
    private var dismissedFindings: [UUID: [ReviewComment]] = [:]
    private var rounds: [UUID: [ReviewRound]] = [:]
    // Questions answered on the Changes screen, which never go to the agent.
    private var questions: [UUID: [ReviewQuestion]] = [:]
    // What each side copy is doing while it answers, step by step. Kept only while it runs.
    public private(set) var questionSteps: [UUID: [String]] = [:]
    // What each file held when a review or a reply went, by round or reply id, so the
    // answer can show what the agent changed. Kept only while the app runs.
    @ObservationIgnored private var sentTexts: [UUID: [String: String]] = [:]

    @ObservationIgnored private var tasks: [UUID: [SecondOpinion.Reviewer: Task<Void, Never>]] = [:]
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private let roundsURL: URL?
    @ObservationIgnored private let questionsURL: URL?
    @ObservationIgnored private let files: PersistentFileClient
    @ObservationIgnored private var questionTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var saver: DebouncedSaver?
    // Reading files and asking git for trees is done off the main thread; tests swap in
    // their own so a round settles without touching the disk.
    @ObservationIgnored public var readFile: @Sendable (String) -> String? = { path in
        try? String(contentsOfFile: path, encoding: .utf8)
    }
    // How a question is answered; tests swap in their own so nothing is run.
    @ObservationIgnored public var answerQuestion: @Sendable (SideQuestion.Request, @escaping @Sendable (String) -> Void)
        async -> Result<SideQuestion.Reply, SecondOpinion.Failure> = SideQuestion.answer

    public init(url: URL? = AppPaths.supportFile("review-comments.json"),
         files: PersistentFileClient = .live) {
        self.url = url
        self.files = files
        roundsURL = url.map {
            $0.deletingPathExtension().appendingPathExtension("rounds").appendingPathExtension("json")
        }
        questionsURL = url.map {
            $0.deletingPathExtension().appendingPathExtension("questions").appendingPathExtension("json")
        }
        var failures: [String] = []
        func read<Value: Decodable>(_ type: Value.Type, at url: URL?) -> Value? {
            guard let url else { return nil }
            do {
                guard let data = try files.readIfPresent(url) else { return nil }
                return try PersistentFile.makeDecoder().decode(type, from: data)
            } catch let error as DecodingError {
                failures.append(PersistentFile.decodeMessage(for: url, error: error))
            } catch {
                failures.append(PersistentFile.loadMessage(for: url, error: error))
            }
            return nil
        }
        comments = read([UUID: [ReviewComment]].self, at: url) ?? [:]
        rounds = read([UUID: [ReviewRound]].self, at: roundsURL) ?? [:]
        if let stored = read([UUID: [ReviewQuestion]].self, at: questionsURL) {
            // A side copy does not outlive the app, so one cut off by quitting says so.
            questions = stored.mapValues { list in
                list.map { question in
                    var question = question
                    if question.status == .answering, let last = question.exchanges.indices.last {
                        question.exchanges[last].failure = "The app quit before it answered."
                    }
                    return question
                }
            }
        }
        loadError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        saver = DebouncedSaver { [weak self] in self?.save() }
    }

    public func comments(_ sessionID: UUID) -> [ReviewComment] { comments[sessionID] ?? [] }

    public func comments(_ sessionID: UUID, root: String, path: String) -> [ReviewComment] {
        comments(sessionID).filter { $0.root == root && $0.path == path }
    }

    public func count(_ sessionID: UUID, root: String, path: String) -> Int {
        comments(sessionID, root: root, path: path).count
    }

    public func kept(_ sessionID: UUID) -> [ReviewComment] { comments(sessionID).filter { !$0.isPending } }

    public func pending(_ sessionID: UUID) -> [ReviewComment] { comments(sessionID).filter(\.isPending) }

    public func comment(_ id: UUID, in sessionID: UUID) -> ReviewComment? {
        comments[sessionID]?.first { $0.id == id }
    }

    public func add(_ comment: ReviewComment, to sessionID: UUID) {
        comments[sessionID, default: []].append(comment)
        saver?.schedule()
    }

    public func add(_ added: [ReviewComment], to sessionID: UUID) {
        guard !added.isEmpty else { return }
        comments[sessionID, default: []].append(contentsOf: added)
        saver?.schedule()
    }

    // Saving a finding the person rewrote keeps it: the words are now partly theirs.
    public func update(_ id: UUID, body: String, kind: ReviewComment.Kind? = nil, in sessionID: UUID) {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        comments[sessionID]?[index].body = body
        if let kind { comments[sessionID]?[index].kind = kind }
        if comments[sessionID]?[index].isPending == true {
            comments[sessionID]?[index].status = .kept
            comments[sessionID]?[index].edited = true
        }
        saver?.schedule()
    }

    // Moves a comment whose code left the diff onto lines picked by hand, or keeps it on
    // the file as a whole.
    public func move(_ id: UUID, to anchor: DiffAnchor, excerpt: String, offsets: [Int], in sessionID: UUID) {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        comments[sessionID]?[index].side = anchor.side
        comments[sessionID]?[index].line = anchor.line
        comments[sessionID]?[index].lastLine = anchor.lastLine
        comments[sessionID]?[index].excerpt = excerpt
        comments[sessionID]?[index].excerptOffsets = offsets
        comments[sessionID]?[index].onFile = false
        saver?.schedule()
    }

    public func keepOnFile(_ id: UUID, in sessionID: UUID) {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        comments[sessionID]?[index].onFile = true
        saver?.schedule()
    }

    public func remove(_ id: UUID, from sessionID: UUID) {
        comments[sessionID]?.removeAll { $0.id == id }
        if comments[sessionID]?.isEmpty == true { comments[sessionID] = nil }
        saver?.schedule()
    }

    // Takes away the comments that were just sent, and only those: one that arrived while
    // the preview was open was never part of the prompt, so it stays for the next one.
    public func remove(_ ids: Set<UUID>, from sessionID: UUID) {
        comments[sessionID]?.removeAll { ids.contains($0.id) }
        if comments[sessionID]?.isEmpty == true { comments[sessionID] = nil }
        saver?.schedule()
    }

    public func clear(_ sessionID: UUID) {
        comments[sessionID] = nil
        dismissedFindings[sessionID] = nil
        saver?.schedule()
    }

    // The session is gone, so is everything about its review.
    public func remove(_ sessionID: UUID) {
        stopSecondOpinion(sessionID)
        runs[sessionID] = nil
        clear(sessionID)
        rounds[sessionID] = nil
        for question in questions(sessionID) { stopQuestion(question.id) }
        questions[sessionID] = nil
        saver?.schedule()
    }

    @discardableResult
    public func flush() -> Bool {
        if saver?.isPending == true { saver?.flush() }
        else if saveError != nil { save() }
        return loadError == nil && saveError == nil
    }

    // MARK: - Sorting findings

    public func keep(_ id: UUID, in sessionID: UUID) {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        comments[sessionID]?[index].status = .kept
        saver?.schedule()
    }

    // Puts a kept finding back among those still to look at.
    public func reopen(_ id: UUID, in sessionID: UUID) {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }),
              comments[sessionID]?[index].reviewer != nil else { return }
        comments[sessionID]?[index].status = .pending
        saver?.schedule()
    }

    public func keepAll(_ sessionID: UUID) {
        guard let all = comments[sessionID] else { return }
        comments[sessionID] = all.map { var comment = $0; comment.status = .kept; return comment }
        saver?.schedule()
    }

    // Hands the finding back with where it was, so Undo can put it back in its place.
    @discardableResult
    public func dismiss(_ id: UUID, from sessionID: UUID) -> (comment: ReviewComment, index: Int)? {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }),
              let comment = comments[sessionID]?.remove(at: index) else { return nil }
        if comments[sessionID]?.isEmpty == true { comments[sessionID] = nil }
        if comment.isPending { dismissedFindings[sessionID, default: []].append(comment) }
        saver?.schedule()
        return (comment, index)
    }

    @discardableResult
    public func dismissAllPending(_ sessionID: UUID) -> [ReviewComment] {
        let gone = pending(sessionID)
        dismissedFindings[sessionID, default: []].append(contentsOf: gone)
        comments[sessionID]?.removeAll(where: \.isPending)
        if comments[sessionID]?.isEmpty == true { comments[sessionID] = nil }
        saver?.schedule()
        return gone
    }

    public func restore(_ comment: ReviewComment, at index: Int? = nil, to sessionID: UUID) {
        guard self.comment(comment.id, in: sessionID) == nil else { return }
        dismissedFindings[sessionID]?.removeAll { $0.id == comment.id }
        var list = comments[sessionID] ?? []
        list.insert(comment, at: min(index ?? list.count, list.count))
        comments[sessionID] = list
        saver?.schedule()
    }

    // A finding on lines another reviewer already raised joins that one as a second
    // voice, so the same problem is read, kept and sent once.
    @discardableResult
    public func addFindings(_ found: [ReviewComment], from agent: AgentKind, to sessionID: UUID) -> Int {
        var added = 0
        for var finding in found {
            // Two seats of one agent on different models are different voices too.
            let twin = comments[sessionID]?.firstIndex { other in
                guard other.reviewer != nil,
                      !other.voices.contains(where: { $0.agent == agent && $0.model == finding.reviewerModel })
                else { return false }
                return other.root == finding.root && other.path == finding.path
                    && other.anchor == finding.anchor
            }
            if let twin {
                comments[sessionID]?[twin].also.append(.init(agent: agent, body: finding.body, model: finding.reviewerModel))
                if let severity = finding.severity, let existing = comments[sessionID]?[twin].severity,
                   Self.rank(severity) < Self.rank(existing) {
                    comments[sessionID]?[twin].severity = severity
                }
            } else {
                finding.status = .pending
                comments[sessionID, default: []].append(finding)
                added += 1
            }
        }
        if !found.isEmpty { saver?.schedule() }
        return added
    }

    private static func rank(_ severity: ReviewComment.Severity) -> Int {
        ReviewComment.Severity.allCases.firstIndex(of: severity) ?? 0
    }

    // MARK: - Second opinion

    public func runs(_ sessionID: UUID) -> [SecondOpinionRun] { runs[sessionID] ?? [] }

    public func dismissedFindings(_ sessionID: UUID) -> [ReviewComment] { dismissedFindings[sessionID] ?? [] }

    // Every finding from a reviewer the person has yet to send: those still to look at,
    // those kept, and those dismissed since the last ask.
    public func findings(_ sessionID: UUID) -> [ReviewComment] {
        comments(sessionID).filter { $0.reviewer != nil } + dismissedFindings(sessionID)
    }

    // A new ask starts clean: lanes that already finished and findings already dismissed
    // belong to the one before. Nothing happens while a reviewer is still at work.
    public func beginSecondOpinion(_ sessionID: UUID) {
        guard !isReviewing(sessionID) else { return }
        runs[sessionID] = nil
        dismissedFindings[sessionID] = nil
    }

    public func isReviewing(_ sessionID: UUID) -> Bool { runs(sessionID).contains(where: \.isRunning) }

    public func isReviewing(_ sessionID: UUID, reviewer: SecondOpinion.Reviewer) -> Bool {
        runs(sessionID).contains { $0.reviewer == reviewer && $0.isRunning }
    }

    // Each seat gets a lane of its own and runs alongside the others. One already at
    // work is left to it.
    public func startSecondOpinion(_ sessionID: UUID, reviewer: SecondOpinion.Reviewer, request: SecondOpinionRequest) {
        guard !isReviewing(sessionID, reviewer: reviewer), !request.repositories.isEmpty else { return }
        let run = SecondOpinionRun(reviewer: reviewer, started: Date(), request: request)
        var lanes = runs(sessionID).filter { $0.reviewer != reviewer }
        lanes.append(run)
        runs[sessionID] = lanes
        let searchPath = ExecutableSearch.searchPath
        tasks[sessionID, default: [:]][reviewer] = Task { [weak self] in
            var patches = await SecondOpinion.patches(for: request)
            if case .file(let root, let path) = request.scope {
                patches = patches.filter { $0.root == root && $0.path == path }
            }
            guard !Task.isCancelled else { return }
            self?.setActivity("Reading \(counted(patches.count, "changed file"))", reviewer: reviewer, in: sessionID)
            let outcome: Result<[ReviewComment], SecondOpinion.Failure>
            if patches.isEmpty {
                outcome = .failure(.init(message: request.scope.isSinceReview
                    ? "Nothing changed since the last review." : "There are no changes to review."))
            } else {
                outcome = await SecondOpinion.review(
                    patches, reviewer: reviewer, executable: request.executable, searchPath: searchPath,
                    repositories: request.repositories.map { (root: $0.root, name: $0.name) },
                    focus: request.focus, sinceReview: request.scope.isSinceReview,
                    activity: { [weak self] text in
                        Task { @MainActor in self?.setActivity(text, reviewer: reviewer, in: sessionID) }
                    })
            }
            guard !Task.isCancelled, let self else { return }
            self.finishSecondOpinion(sessionID, reviewer: reviewer, outcome: outcome)
        }
    }

    public func retrySecondOpinion(_ sessionID: UUID, reviewer: SecondOpinion.Reviewer) {
        guard let run = runs(sessionID).first(where: { $0.reviewer == reviewer }), !run.isRunning else { return }
        startSecondOpinion(sessionID, reviewer: reviewer, request: run.request)
    }

    // Stopping a reviewer drops its lane: there is nothing it came to.
    public func stopSecondOpinion(_ sessionID: UUID, reviewer: SecondOpinion.Reviewer) {
        tasks[sessionID]?[reviewer]?.cancel()
        tasks[sessionID]?[reviewer] = nil
        runs[sessionID]?.removeAll { $0.reviewer == reviewer }
        if runs[sessionID]?.isEmpty == true { runs[sessionID] = nil }
    }

    public func stopSecondOpinion(_ sessionID: UUID) {
        for task in (tasks[sessionID] ?? [:]).values { task.cancel() }
        tasks[sessionID] = nil
        runs[sessionID]?.removeAll(where: \.isRunning)
        if runs[sessionID]?.isEmpty == true { runs[sessionID] = nil }
    }

    private func setActivity(_ text: String, reviewer: SecondOpinion.Reviewer, in sessionID: UUID) {
        guard let index = runs[sessionID]?.firstIndex(where: { $0.reviewer == reviewer && $0.isRunning }),
              var run = runs[sessionID]?[index], run.activity != text else { return }
        run.activity = text
        run.recent = Array((run.recent + [text]).suffix(3))
        runs[sessionID]?[index] = run
    }

    // Called by the run when it ends; tests call it directly with what a reviewer said.
    public func finishSecondOpinion(_ sessionID: UUID, reviewer: SecondOpinion.Reviewer,
                             outcome: Result<[ReviewComment], SecondOpinion.Failure>) {
        tasks[sessionID]?[reviewer] = nil
        if case .success(let found) = outcome { addFindings(found, from: reviewer.agent, to: sessionID) }
        guard let index = runs[sessionID]?.firstIndex(where: { $0.reviewer == reviewer }) else { return }
        runs[sessionID]?[index].ended = Date()
        switch outcome {
        case .success(let found): runs[sessionID]?[index].state = .finished(found: found.count)
        case .failure(let failure): runs[sessionID]?[index].state = .failed(failure.message)
        }
    }

    // MARK: - Rounds

    public func rounds(_ sessionID: UUID) -> [ReviewRound] { rounds[sessionID] ?? [] }

    public func round(prompt: String, in sessionID: UUID) -> ReviewRound? {
        let text = prompt.trimmed
        return rounds(sessionID).last { $0.prompt == text }
    }

    // The thread a reply of yours belongs to, while the agent has yet to answer it.
    public func awaitingReply(prompt: String, in sessionID: UUID) -> (round: ReviewRound, commentID: UUID)? {
        let text = prompt.trimmed
        for round in rounds(sessionID).reversed() {
            for (commentID, replies) in round.replies where replies.last?.author == .you && replies.last?.prompt == text {
                return (round, commentID)
            }
        }
        return nil
    }

    // Whether a prompt was a reply in a thread, answered or not, so Chat can leave it to
    // the thread instead of showing it as a message of its own.
    public func isThreadReply(prompt: String, in sessionID: UUID) -> Bool {
        let text = prompt.trimmed
        return rounds(sessionID).contains { round in
            round.replies.values.contains { $0.contains { $0.author == .you && $0.prompt == text } }
        }
    }

    // Every sent comment on one file, with the round it went in, oldest first.
    public func threads(_ sessionID: UUID, root: String, path: String) -> [(round: ReviewRound, comment: ReviewComment)] {
        threads(sessionID).filter { $0.comment.root == root && $0.comment.path == path }
    }

    public func threads(_ sessionID: UUID) -> [(round: ReviewRound, comment: ReviewComment)] {
        rounds(sessionID).flatMap { round in round.comments.map { (round, $0) } }
    }

    public func unreadCount(_ sessionID: UUID) -> Int {
        rounds(sessionID).reduce(0) { $0 + $1.unread.count }
    }

    // The trees the latest round recorded, for a reviewer asked to read only what
    // changed after it. Nil until a review has gone and its trees are in.
    public func latestTrees(_ sessionID: UUID) -> [String: String]? {
        guard let trees = rounds(sessionID).last?.trees, !trees.isEmpty else { return nil }
        return trees
    }

    // Records a review as it is sent and takes its comments out of the one being written.
    // What each file and project held is read in the background and filled in after.
    @discardableResult
    public func recordRound(_ sent: [ReviewComment], prompt: String, note: String,
                     roots: [String], in sessionID: UUID) -> ReviewRound {
        let round = ReviewRound(prompt: prompt.trimmed, note: note.trimmed, comments: ReviewOrder.sorted(sent, roots: roots))
        rounds[sessionID, default: []].append(round)
        remove(Set(sent.map(\.id)), from: sessionID)
        saver?.schedule()
        let files = Set(sent.map { ReviewRound.fileKey(root: $0.root, path: $0.path) })
        Task { [weak self] in
            guard let texts = await self?.readFiles(files) else { return }
            var trees: [String: String] = [:]
            for root in roots {
                if let tree = await TreeSnapshots.shared.record(at: root) { trees[root] = tree }
            }
            self?.fillRound(round.id, texts: texts, trees: trees, in: sessionID)
        }
        return round
    }

    private func readFiles(_ files: Set<String>) async -> [String: String] {
        let read = readFile
        return await Task.detached(priority: .utility) {
            var texts: [String: String] = [:]
            for file in files { texts[file] = read(file) }
            return texts
        }.value
    }

    private func fillRound(_ id: UUID, texts: [String: String], trees: [String: String], in sessionID: UUID) {
        sentTexts[id] = texts
        guard let index = rounds[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        rounds[sessionID]?[index].fileDigests.merge(texts.mapValues(ReviewRound.digest)) { old, _ in old }
        rounds[sessionID]?[index].trees.merge(trees) { old, _ in old }
        saver?.schedule()
    }

    // A turn has ended. If it took a review, each comment is checked against the files
    // as they are now and gets its answer from what the agent wrote. If it took a reply in
    // a thread, the agent's answer joins that thread. Any other turn changes nothing.
    public func turnEnded(_ sessionID: UUID, prompt: String, reply: ChatMessage? = nil) async {
        if let round = round(prompt: prompt, in: sessionID), !round.isSettled {
            await settle(round, reply: reply, in: sessionID)
        } else if let waiting = awaitingReply(prompt: prompt, in: sessionID) {
            await answer(waiting.commentID, round: waiting.round, prompt: prompt.trimmed, reply: reply, in: sessionID)
        }
    }

    private func settle(_ round: ReviewRound, reply: ChatMessage?, in sessionID: UUID) async {
        let read = readFile
        let comments = round.comments
        let digests = round.fileDigests
        let before = sentTexts[round.id] ?? [:]
        let checked = await Task.detached(priority: .utility) {
            var outcomes: [UUID: ReviewRound.Outcome] = [:]
            var diffs: [UUID: [ReviewDiffLine]] = [:]
            for comment in comments {
                let key = ReviewRound.fileKey(root: comment.root, path: comment.path)
                let now = read(key)
                outcomes[comment.id] = ReviewRound.outcome(for: comment, fileText: now, digestAtSend: digests[key])
                if let old = before[key], let now {
                    diffs[comment.id] = ReviewDiffLine.near(comment, before: old, after: now)
                }
            }
            return (outcomes, diffs)
        }.value
        let answers = reply.flatMap { ReviewAnswers.read($0, count: comments.count) }?.answers ?? [:]
        guard let index = rounds[sessionID]?.firstIndex(where: { $0.id == round.id }),
              rounds[sessionID]?[index].isSettled == false else { return }
        rounds[sessionID]?[index].outcomes = checked.0
        for (offset, comment) in comments.enumerated() {
            let answer = answers[offset + 1]
            let diff = checked.1[comment.id] ?? []
            guard answer != nil || !diff.isEmpty else { continue }
            rounds[sessionID]?[index].replies[comment.id, default: []].append(ReviewReply(
                author: .agent, body: answer?.body ?? "", suggestion: answer?.suggestion,
                diff: diff, changedFile: checked.0[comment.id] == .changed))
            rounds[sessionID]?[index].unread.insert(comment.id)
        }
        sentTexts[round.id] = nil
        saver?.schedule()
    }

    private func answer(_ commentID: UUID, round: ReviewRound, prompt: String, reply: ChatMessage?,
                        in sessionID: UUID) async {
        guard let comment = round.comments.first(where: { $0.id == commentID }),
              let mine = round.replies(commentID).last else { return }
        let key = ReviewRound.fileKey(root: comment.root, path: comment.path)
        let read = readFile
        let now = await Task.detached(priority: .utility) { read(key) }.value
        let before = sentTexts[mine.id]?[key]
        let changed = before != nil && now != nil && before != now
        let diff = changed ? ReviewDiffLine.near(comment, before: before!, after: now!) : []
        let number = round.number(commentID) ?? 1
        let answers = reply.flatMap { ReviewAnswers.read($0, count: 1) }?.answers ?? [:]
        let answer = answers[number] ?? (answers.count == 1 ? answers.values.first : nil)
        guard let index = rounds[sessionID]?.firstIndex(where: { $0.id == round.id }),
              rounds[sessionID]?[index].replies(commentID).last?.prompt == prompt else { return }
        rounds[sessionID]?[index].replies[commentID, default: []].append(ReviewReply(
            author: .agent, body: answer?.body ?? "", suggestion: answer?.suggestion,
            diff: diff, changedFile: changed))
        if changed { rounds[sessionID]?[index].outcomes?[commentID] = .changed }
        rounds[sessionID]?[index].unread.insert(commentID)
        sentTexts[mine.id] = nil
        saver?.schedule()
    }

    // A reply in a thread goes to the agent at once. Hands back the prompt to send, once
    // what the file holds now has been read, so the answer can show what the agent changed.
    public func reply(_ text: String, to commentID: UUID, round roundID: UUID, in sessionID: UUID,
               projectNames: [String: String] = [:]) async -> String? {
        guard !text.isBlank,
              let index = rounds[sessionID]?.firstIndex(where: { $0.id == roundID }),
              let round = rounds[sessionID]?[index],
              let comment = round.comments.first(where: { $0.id == commentID }),
              let number = round.number(commentID) else { return nil }
        let prompt = ReviewPrompt.reply(text, to: comment, number: number, earlier: round.replies(commentID),
                                        projectNames: projectNames).trimmed
        let mine = ReviewReply(author: .you, body: text.trimmed, prompt: prompt)
        rounds[sessionID]?[index].replies[commentID, default: []].append(mine)
        rounds[sessionID]?[index].resolved.remove(commentID)
        rounds[sessionID]?[index].unread.remove(commentID)
        saver?.schedule()
        sentTexts[mine.id] = await readFiles([ReviewRound.fileKey(root: comment.root, path: comment.path)])
        return prompt
    }

    public func resolve(_ commentID: UUID, round roundID: UUID, in sessionID: UUID) {
        guard let index = rounds[sessionID]?.firstIndex(where: { $0.id == roundID }) else { return }
        rounds[sessionID]?[index].resolved.insert(commentID)
        rounds[sessionID]?[index].unread.remove(commentID)
        saver?.schedule()
    }

    public func reopen(_ commentID: UUID, round roundID: UUID, in sessionID: UUID) {
        guard let index = rounds[sessionID]?.firstIndex(where: { $0.id == roundID }) else { return }
        rounds[sessionID]?[index].resolved.remove(commentID)
        saver?.schedule()
    }

    public func markRead(_ commentID: UUID, in sessionID: UUID) {
        guard let index = rounds[sessionID]?.firstIndex(where: { $0.unread.contains(commentID) }) else { return }
        rounds[sessionID]?[index].unread.remove(commentID)
        saver?.schedule()
    }

    // MARK: - Questions

    public func questions(_ sessionID: UUID) -> [ReviewQuestion] { questions[sessionID] ?? [] }

    public func questions(_ sessionID: UUID, root: String, path: String) -> [ReviewQuestion] {
        questions(sessionID).filter { $0.root == root && $0.path == path }
    }

    public func question(_ id: UUID, in sessionID: UUID) -> ReviewQuestion? {
        questions[sessionID]?.first { $0.id == id }
    }

    public func isAnswering(_ id: UUID) -> Bool { questionTasks[id] != nil }

    // A question goes at once to a side copy of the session. Nothing about it reaches the
    // main conversation.
    public func ask(_ question: ReviewQuestion, context: QuestionContext, in sessionID: UUID) {
        questions[sessionID, default: []].append(question)
        saver?.schedule()
        startAnswer(question.id, context: context, in: sessionID)
    }

    public func followUp(_ text: String, to id: UUID, context: QuestionContext, in sessionID: UUID) {
        guard !text.isBlank, let index = questionIndex(id, in: sessionID),
              questions[sessionID]?[index].status != .answering else { return }
        questions[sessionID]?[index].exchanges.append(.init(question: text.trimmed))
        questions[sessionID]?[index].resolved = false
        saver?.schedule()
        startAnswer(id, context: context, in: sessionID)
    }

    public func retryQuestion(_ id: UUID, context: QuestionContext, in sessionID: UUID) {
        guard let index = questionIndex(id, in: sessionID),
              let last = questions[sessionID]?[index].exchanges.indices.last,
              questions[sessionID]?[index].status == .failed else { return }
        questions[sessionID]?[index].exchanges[last].failure = nil
        saver?.schedule()
        startAnswer(id, context: context, in: sessionID)
    }

    public func deleteQuestion(_ id: UUID, in sessionID: UUID) {
        stopQuestion(id)
        questions[sessionID]?.removeAll { $0.id == id }
        if questions[sessionID]?.isEmpty == true { questions[sessionID] = nil }
        saver?.schedule()
    }

    public func setResolved(_ id: UUID, _ resolved: Bool, in sessionID: UUID) {
        guard let index = questionIndex(id, in: sessionID) else { return }
        questions[sessionID]?[index].resolved = resolved
        saver?.schedule()
    }

    // The answer's suggestion becomes a change on the question's lines. The question and
    // answer go along, so the agent knows why it is asked to make it.
    @discardableResult
    public func makeChange(from id: UUID, in sessionID: UUID) -> ReviewComment? {
        guard let index = questionIndex(id, in: sessionID), let question = questions[sessionID]?[index],
              !question.isWhole, let suggestion = question.suggestion else { return nil }
        if let existing = question.changeID.flatMap({ comment($0, in: sessionID) }) { return existing }
        var change = ReviewComment(root: question.root, path: question.path, anchor: question.anchor,
                                   excerpt: question.excerpt, body: suggestion,
                                   excerptOffsets: question.excerptOffsets)
        change.questionID = id
        change.why = question.why
        add(change, to: sessionID)
        questions[sessionID]?[index].changeID = change.id
        return change
    }

    public func takeOutOfReview(_ questionID: UUID, in sessionID: UUID) {
        guard let index = questionIndex(questionID, in: sessionID),
              let changeID = questions[sessionID]?[index].changeID else { return }
        remove(changeID, from: sessionID)
        questions[sessionID]?[index].changeID = nil
        saver?.schedule()
    }

    public func setSendsQuestion(_ on: Bool, change commentID: UUID, in sessionID: UUID) {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == commentID }),
              let questionID = comments[sessionID]?[index].questionID else { return }
        comments[sessionID]?[index].why = on ? question(questionID, in: sessionID)?.why : nil
        saver?.schedule()
    }

    // The round a comment went in, once it has been sent.
    public func round(sending commentID: UUID, in sessionID: UUID) -> ReviewRound? {
        rounds(sessionID).first { round in round.comments.contains { $0.id == commentID } }
    }

    private func questionIndex(_ id: UUID, in sessionID: UUID) -> Int? {
        questions[sessionID]?.firstIndex { $0.id == id }
    }

    private func stopQuestion(_ id: UUID) {
        questionTasks[id]?.cancel()
        questionTasks[id] = nil
        questionSteps[id] = nil
    }

    private func startAnswer(_ id: UUID, context: QuestionContext, in sessionID: UUID) {
        guard let question = question(id, in: sessionID) else { return }
        stopQuestion(id)
        guard let executable = context.executable else {
            finishAnswer(id, in: sessionID, outcome: .failure(.init(message: "\(context.agent.title) is not installed.")))
            return
        }
        questionSteps[id] = []
        let request = SideQuestion.Request(question: question, context: context, executable: executable,
                                           searchPath: ExecutableSearch.searchPath)
        let answer = answerQuestion
        questionTasks[id] = Task { [weak self] in
            let outcome = await answer(request) { step in
                Task { @MainActor in self?.addStep(step, to: id) }
            }
            guard !Task.isCancelled else { return }
            self?.finishAnswer(id, in: sessionID, outcome: outcome)
        }
    }

    private func addStep(_ step: String, to id: UUID) {
        guard questionTasks[id] != nil, questionSteps[id]?.last != step else { return }
        questionSteps[id, default: []].append(step)
    }

    // Called by the run when it ends; tests call it directly with what a side copy said.
    public func finishAnswer(_ id: UUID, in sessionID: UUID, outcome: Result<SideQuestion.Reply, SecondOpinion.Failure>) {
        questionTasks[id] = nil
        questionSteps[id] = nil
        guard let index = questionIndex(id, in: sessionID),
              let last = questions[sessionID]?[index].exchanges.indices.last else { return }
        switch outcome {
        case .success(let reply):
            questions[sessionID]?[index].exchanges[last].answer = reply.answer
            questions[sessionID]?[index].exchanges[last].suggestion = reply.suggestion
            questions[sessionID]?[index].exchanges[last].answered = Date()
            if let fork = reply.forkID { questions[sessionID]?[index].forkID = fork }
        case .failure(let failure):
            questions[sessionID]?[index].exchanges[last].failure = failure.message
        }
        saver?.schedule()
    }

    private func save() {
        // Comments, sent rounds and questions refer to each other. A failed read keeps
        // the whole set protected rather than saving a partial view of the review.
        guard loadError == nil else {
            saveError = "Reviews were not saved because the existing review files could not be loaded."
            return
        }
        do {
            if let url {
                if comments.isEmpty { try files.removeIfPresent(url) }
                else { try files.write(PersistentFile.makeEncoder().encode(comments), url) }
            }
            if let roundsURL {
                if rounds.isEmpty { try files.removeIfPresent(roundsURL) }
                else { try files.write(PersistentFile.makeEncoder().encode(rounds), roundsURL) }
            }
            if let questionsURL {
                if questions.isEmpty { try files.removeIfPresent(questionsURL) }
                else { try files.write(PersistentFile.makeEncoder().encode(questions), questionsURL) }
            }
            saveError = nil
        } catch {
            saveError = "Reviews could not be saved: \(error.localizedDescription)"
            SessionLog.note("could not save review comments: \(error.localizedDescription)")
        }
    }
}
