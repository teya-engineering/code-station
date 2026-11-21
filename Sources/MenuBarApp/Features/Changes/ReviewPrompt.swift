import Foundation

// The prompt a set of comments becomes. Each one names its file and lines and quotes
// the code, so the agent can act on it without having seen the diff the comments were
// written on.
enum ReviewPrompt {
    static func feedback(_ comments: [ReviewComment], projectNames: [String: String] = [:],
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
    static func reply(_ text: String, to comment: ReviewComment, number: Int, earlier: [ReviewReply],
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
enum ReviewAnswers {
    struct Answer: Equatable, Sendable {
        var body: String
        // A short reply the agent offers, for when it proposes to do something more.
        var suggestion: String?
    }

    static let suggestionInstructions = "If you offer to do something more, end that answer with a line that starts "
        + "`Suggested reply:` followed by the few words I could send to say yes."

    static let instructions = "When you are done, answer each comment in a few sentences under a heading line "
        + "of its own: `### Comment 1`, `### Comment 2` and so on, using the numbers below. "
        + suggestionInstructions

    // Where the answers start in a turn's text, and each one by the number of its comment.
    // Nil when the agent wrote no headings at all.
    static func split(_ text: String) -> (start: Int, answers: [Int: Answer])? {
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
    static func read(_ message: ChatMessage, count: Int) -> (start: Int, answers: [Int: Answer])? {
        if let found = split(message.text) { return found }
        guard count == 1 else { return nil }
        let start = min(message.tools.compactMap(\.textOffset).max() ?? 0, message.text.count)
        let tail = String(message.text.dropFirst(start))
        guard !tail.isBlank else { return nil }
        return (start, [1: read(tail)])
    }

    // The message that answered a prompt: the agent's turn right after it.
    static func reply(to prompt: String, in messages: [ChatMessage]) -> ChatMessage? {
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

// The one order comments are read in everywhere: the review list, stepping from one to
// the next, the send checklist and the prompt. File by file, new lines before removed
// ones, top to bottom.
enum ReviewOrder {
    static func sorted(_ comments: [ReviewComment], roots: [String] = []) -> [ReviewComment] {
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
    static func step(from current: UUID?, by step: Int, in ordered: [ReviewComment]) -> ReviewComment? {
        guard !ordered.isEmpty else { return nil }
        guard let current, let index = ordered.firstIndex(where: { $0.id == current }) else {
            return step > 0 ? ordered.first : ordered.last
        }
        return ordered[(index + step + ordered.count) % ordered.count]
    }
}
