import CodeStationCore
import Foundation
import TerminalKit
import TerminalTranscript

// What the open session's agent is waiting on, drawn at the foot of the transcript where
// the composer sits. View state only: which question is showing, which row is pointed at,
// and what has been picked or typed so far. An answer goes back through the façade's
// answer permission, in the phone's vocabulary.
//
// A tool asking for permission is a yes or no, so it takes three keys and leaves every
// other key to the transcript: 1 allows once, 2 allows always when the agent offered it,
// 3 (or n) denies. Allowing takes a digit on purpose: y and c copy in the transcript, and
// a key pressed out of habit must never let a command run.
//
// A question is a choice, so it takes the keys while it shows, as the composer does:
// - ↑/↓ point at an option, or at the "something else" line under them.
// - Space picks the option pointed at (ticks it, in a question that takes several), and
//   1-9 pick an option by number.
// - Typing writes an answer of its own on the "something else" line, which replaces
//   anything picked, as in the GUI. Backspace and Ctrl-U edit it.
// - Enter goes on to the next question once this one has an answer, or sends them all
//   from the last. On an option nobody has picked yet, Enter picks it first.
// - Tab and Shift-Tab move between questions. Ctrl-X skips the question, which the agent
//   reads as a refusal, as the GUI's Skip.
struct PermissionPrompt {
    let permission: RemotePermission
    private(set) var current = 0
    private var row = 0
    private var picked: [Int: Set<String>] = [:]
    private var typed: [Int: String] = [:]

    init(_ permission: RemotePermission) {
        self.permission = permission
    }

    var isQuestion: Bool { permission.kind == "question" && !permission.questions.isEmpty }

    enum Outcome: Equatable {
        case answer(RemoteCommand.Answer, [String: String]?)
        case edited
        case ignored
    }

    mutating func handle(_ key: Key) -> Outcome {
        isQuestion ? handleQuestion(key) : handlePermission(key)
    }

    private func handlePermission(_ key: Key) -> Outcome {
        switch key {
        case .char("1", []): return .answer(.allowOnce, nil)
        // A call reaching a folder outside the session's offers to add the folder in
        // place of "always", as the GUI's card does: the narrower yes, and the one that
        // stops the next call there asking too.
        case .char("2", []) where permission.outsideDirectory != nil: return .answer(.allowAddingDirectory, nil)
        case .char("2", []) where permission.alwaysTitle != nil: return .answer(.allowAlways, nil)
        case .char("n", []), .char("3", []): return .answer(.deny, nil)
        default: return .ignored
        }
    }

    // MARK: - Questions

    private var question: RemotePermission.Question { permission.questions[current] }
    // The options, then the line for an answer of one's own.
    private var otherRow: Int { question.options.count }

    private mutating func handleQuestion(_ key: Key) -> Outcome {
        switch key {
        case .char("x", .ctrl): return .answer(.deny, nil)
        case .up, .char("p", .ctrl): row = max(row - 1, 0)
        case .down, .char("n", .ctrl): row = min(row + 1, otherRow)
        case .tab([]): show(current + 1)
        case .tab(.shift): show(current - 1)
        case .enter([]):
            if row < otherRow && answer(for: current).isEmpty { pick(row) }
            guard !answer(for: current).isEmpty else { return .edited }
            if current < permission.questions.count - 1 {
                show(current + 1)
            } else if let first = permission.questions.indices.first(where: { answer(for: $0).isEmpty }) {
                show(first)
            } else {
                return .answer(.answers, answers)
            }
        case .char(" ", []) where row < otherRow: pick(row)
        case .char(let digit, []) where row < otherRow && digit.wholeNumberValue.map({ (1...9).contains($0) }) == true:
            let index = digit.wholeNumberValue! - 1
            guard index < question.options.count else { return .edited }
            row = index
            pick(index)
        case .backspace where row == otherRow:
            if typed[current]?.isEmpty == false { typed[current]!.removeLast() }
        case .char("u", .ctrl) where row == otherRow: typed[current] = ""
        case .paste(let text): write(text.replacingOccurrences(of: "\n", with: " "))
        case .char(let character, let mods) where mods.isEmpty || mods == .shift:
            write(String(character))
        default: return .ignored
        }
        return .edited
    }

    private mutating func show(_ index: Int) {
        let count = permission.questions.count
        current = (index % count + count) % count
        row = 0
    }

    private mutating func write(_ text: String) {
        row = otherRow
        typed[current, default: ""] += text
        picked[current] = []
    }

    // A pick replaces the typed answer. A question that takes several ticks and unticks;
    // one that takes a single answer swaps it.
    private mutating func pick(_ index: Int) {
        let label = question.options[index].label
        typed[current] = ""
        var chosen = picked[current] ?? []
        if question.multiSelect {
            if chosen.remove(label) == nil { chosen.insert(label) }
        } else {
            chosen = [label]
        }
        picked[current] = chosen
    }

    // Several picks go back as one comma-separated string, as the GUI sends them.
    private func answer(for index: Int) -> String {
        let text = (typed[index] ?? "").trimmingCharacters(in: .whitespaces)
        guard text.isEmpty else { return text }
        let chosen = picked[index] ?? []
        return permission.questions[index].options.map(\.label).filter(chosen.contains)
            .joined(separator: ", ")
    }

    private var answers: [String: String] {
        var result: [String: String] = [:]
        for (index, question) in permission.questions.enumerated() {
            result[question.text] = answer(for: index)
        }
        return result
    }

    // MARK: - Drawing

    // The prompt's lines, at most `room` of them, and where the cursor sits while an
    // answer of one's own is being typed.
    func frame(width: Int, room: Int) -> ([String], (row: Int, col: Int)?) {
        if isQuestion { return questionFrame(width: width, room: room) }
        return (permissionFrame(width: width, room: room), nil)
    }

    private func permissionFrame(width: Int, room: Int) -> [String] {
        var lines = [Style.bold + Style.yellow
                     + TerminalColumns.fit(" ✋ \(permission.title) needs permission", to: width) + Style.reset]
        if !permission.detail.isEmpty {
            lines += TranscriptRenderer.wrap(permission.detail, width: max(width - 2, 1))
                .map { Style.dim + " " + $0 + Style.reset }
        }
        lines.append(" " + TerminalColumns.fit(permission.lead, to: max(width - 1, 1)))
        // The subject is what will really run, so it is shown as written, line for line,
        // and cut only when it would push the answers off the screen.
        let subjectRoom = max(room - lines.count - 2, 1)
        var subject = permission.subject.split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { TranscriptRenderer.wrap(String($0), width: max(width - 4, 1)) }
        if subject.count > subjectRoom {
            let hidden = subject.count - subjectRoom + 1
            subject = Array(subject.prefix(subjectRoom - 1)) + ["… \(hidden) more lines"]
        }
        lines += subject.map { Style.cyan + "   " + $0 + Style.reset }
        if !permission.runsIn.isEmpty {
            lines.append(Style.dim + TerminalColumns.fit(" runs in \(permission.runsIn)", to: width) + Style.reset)
        }
        if let outside = permission.outsideDirectory {
            lines += TranscriptRenderer.wrap("Reaches \(Self.abbreviated(outside)), outside this session's folders.",
                                             width: max(width - 2, 1))
                .map { Style.dim + " " + $0 + Style.reset }
        }
        var choices = [("1", "allow once")]
        if let outside = permission.outsideDirectory {
            choices.append(("2", "allow, and add \((outside as NSString).lastPathComponent)"))
        } else if let always = permission.alwaysTitle {
            choices.append(("2", always))
        }
        choices.append(("3", "deny"))
        // One row when they fit, one each when the terminal is too narrow for that.
        let plain = choices.map { " \($0.0)  \($0.1)" }.joined(separator: "   ")
        if TerminalColumns.width(of: plain) < width {
            lines.append(" " + choices.map { key($0.0, $0.1) }.joined(separator: "   "))
        } else {
            lines += choices.map { " " + key($0.0, TerminalColumns.fit($0.1, to: max(width - 5, 1))) }
        }
        return Array(lines.suffix(room))
    }

    private func key(_ letter: String, _ label: String) -> String {
        Style.reverse + Style.bold + " \(letter) " + Style.reset + " " + label
    }

    private func questionFrame(width: Int, room: Int) -> ([String], (row: Int, col: Int)?) {
        let count = permission.questions.count
        var heading = " ? QUESTION"
        if count > 1 { heading += " \(current + 1)/\(count)" }
        if !question.header.isEmpty { heading += " · " + question.header.uppercased() }
        if count > 1 {
            let done = permission.questions.indices.filter { !answer(for: $0).isEmpty }.count
            heading += " · \(done) of \(count) answered"
        }
        var lines = [Style.bold + Style.cyan + TerminalColumns.fit(heading, to: width) + Style.reset]
        lines += TranscriptRenderer.wrap(question.text, width: max(width - 2, 1))
            .map { Style.bold + " " + $0 + Style.reset }

        let chosen = picked[current] ?? []
        var rows: [String] = []
        for (index, option) in question.options.enumerated() {
            let on = chosen.contains(option.label)
            let box = question.multiSelect ? (on ? "[x]" : "[ ]") : (on ? "(•)" : "( )")
            let pointer = index == row ? "▸" : " "
            var text = "\(pointer) \(box) \(index + 1) \(option.label)"
            let description = option.description.isEmpty ? "" : "  " + option.description
            text = TerminalColumns.fit(text, to: max(width - 1, 1))
            let rest = TerminalColumns.fit(description, to: max(width - 1 - TerminalColumns.width(of: text), 0))
            rows.append(" " + (on ? Style.cyan : "") + text + Style.reset + Style.dim + rest + Style.reset)
        }
        let own = typed[current] ?? ""
        let pointer = row == otherRow ? "▸" : " "
        let label = "\(pointer) ✎ "
        let field = own.isEmpty && row != otherRow ? Style.dim + "something else (type it)" + Style.reset : own
        // The typed answer keeps its end in view, where the cursor is.
        let fieldRoom = max(width - 1 - TerminalColumns.width(of: label), 1)
        var shown = own
        while TerminalColumns.width(of: shown) > fieldRoom - 1, !shown.isEmpty { shown.removeFirst() }
        rows.append(" " + label + (own.isEmpty ? field : shown))

        // Keep the pointed row in view when the options are more than the room.
        let rowRoom = max(room - lines.count, 1)
        let first = min(max(row - rowRoom + 1, 0), max(rows.count - rowRoom, 0))
        let visible = Array(rows[first..<min(first + rowRoom, rows.count)])
        lines += visible
        lines = Array(lines.prefix(room))
        var cursor: (row: Int, col: Int)?
        if row == otherRow, let at = lines.firstIndex(of: rows.last!) {
            cursor = (at, 1 + TerminalColumns.width(of: label) + TerminalColumns.width(of: shown))
        }
        return (lines, cursor)
    }

    // A path under the home folder as `~/…`.
    private static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // The key help while the prompt shows.
    var help: String {
        if isQuestion {
            let last = current == permission.questions.count - 1
            return " ↑↓ choose · space pick · enter \(last ? "send" : "next")"
                + (permission.questions.count > 1 ? " · tab question" : "") + " · ctrl-x skip · esc back"
        }
        let always = permission.outsideDirectory.map { " · 2 add \(($0 as NSString).lastPathComponent)" }
            ?? (permission.alwaysTitle == nil ? "" : " · 2 always")
        return " 1 allow\(always) · 3/n deny · enter write · jk scroll · esc back"
    }
}
