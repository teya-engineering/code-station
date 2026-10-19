import TerminalKit
import TerminalTranscript

// The prompt being written for the open session. View state only: the text and where the
// cursor sits in it. Sending hands the text to the façade, which hands it to the session
// runner, so queuing behind a running turn is the runner's, as it is in the GUI.
//
// Keys, while it has focus:
// - Enter sends. Alt+Enter, Shift+Enter (where the terminal reports it) and Ctrl-J start
//   a new line. A paste goes in whole, line breaks and all.
// - ←/→ and Ctrl-B/F move by character, Alt+←/→ by word, ↑/↓ by line, Home/End and
//   Ctrl-A/E to the start and end of the line.
// - Backspace and Delete (Ctrl-D on a non-empty prompt) remove a character, Ctrl-W or
//   Alt+Backspace the word before the cursor, Ctrl-U to the start of the line and Ctrl-K
//   to its end.
struct ComposerView {
    private(set) var text: [Character] = []
    private(set) var cursor = 0

    var isEmpty: Bool { String(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    // What goes out with the prompt besides its text, as the GUI's composer holds it:
    // files by their path on the host's machine, and instructions for this prompt alone.
    // They stay with the prompt's text when the session is closed with it half written.
    var attachments: [String] = []
    var instructions = ""
    var hasSomethingToSend: Bool {
        !isEmpty || !attachments.isEmpty || !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var string: String { String(text) }

    enum Outcome { case edited, send, ignored }

    // What the key did. `send` leaves the text in place: it is cleared only once the
    // façade has taken it, so a refused prompt is not lost.
    mutating func handle(_ key: Key) -> Outcome {
        switch key {
        case .enter([]): return .send
        case .enter, .char("j", .ctrl): insert("\n")
        case .paste(let pasted):
            insert(pasted.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n"))
        case .char(let character, let mods) where mods.isEmpty || mods == .shift:
            insert(String(character))
        case .backspace(.alt), .char("w", .ctrl): deleteWordBackward()
        case .backspace: deleteBackward()
        case .delete, .char("d", .ctrl): deleteForward()
        case .left(.alt), .char("b", .alt): cursor = wordStart(before: cursor)
        case .right(.alt), .char("f", .alt): cursor = wordEnd(after: cursor)
        case .left, .char("b", .ctrl): cursor = max(cursor - 1, 0)
        case .right, .char("f", .ctrl): cursor = min(cursor + 1, text.count)
        case .home, .char("a", .ctrl): cursor = lineStart(of: cursor)
        case .end, .char("e", .ctrl): cursor = lineEnd(of: cursor)
        case .up: moveLine(by: -1)
        case .down: moveLine(by: 1)
        case .char("u", .ctrl):
            let start = lineStart(of: cursor)
            text.removeSubrange(start..<cursor)
            cursor = start
        case .char("k", .ctrl):
            let end = lineEnd(of: cursor)
            // At the end of a line it joins the next one, as in a shell.
            text.removeSubrange(cursor..<(end == cursor ? min(end + 1, text.count) : end))
        default: return .ignored
        }
        return .edited
    }

    mutating func clear() {
        text = []
        cursor = 0
    }

    // Puts a whole prompt in the composer, such as one recalled from the session's
    // history, with the cursor at its end.
    mutating func replace(with string: String) {
        text = Array(string)
        cursor = text.count
    }

    // MARK: - Editing

    private mutating func insert(_ string: String) {
        let characters = Array(string)
        text.insert(contentsOf: characters, at: cursor)
        cursor += characters.count
    }

    private mutating func deleteBackward() {
        guard cursor > 0 else { return }
        text.remove(at: cursor - 1)
        cursor -= 1
    }

    private mutating func deleteForward() {
        guard cursor < text.count else { return }
        text.remove(at: cursor)
    }

    private mutating func deleteWordBackward() {
        let start = wordStart(before: cursor)
        text.removeSubrange(start..<cursor)
        cursor = start
    }

    private func wordStart(before index: Int) -> Int {
        var at = index
        while at > 0, text[at - 1].isWhitespace { at -= 1 }
        while at > 0, !text[at - 1].isWhitespace { at -= 1 }
        return at
    }

    private func wordEnd(after index: Int) -> Int {
        var at = index
        while at < text.count, text[at].isWhitespace { at += 1 }
        while at < text.count, !text[at].isWhitespace { at += 1 }
        return at
    }

    private func lineStart(of index: Int) -> Int {
        var at = index
        while at > 0, text[at - 1] != "\n" { at -= 1 }
        return at
    }

    private func lineEnd(of index: Int) -> Int {
        var at = index
        while at < text.count, text[at] != "\n" { at += 1 }
        return at
    }

    // Keeps the column where the next line is long enough, and lands at its end where
    // it is not.
    private mutating func moveLine(by step: Int) {
        let start = lineStart(of: cursor)
        let column = cursor - start
        if step < 0 {
            guard start > 0 else { cursor = 0; return }
            let previous = lineStart(of: start - 1)
            cursor = min(previous + column, start - 1)
        } else {
            let end = lineEnd(of: cursor)
            guard end < text.count else { cursor = text.count; return }
            let next = end + 1
            cursor = min(next + column, lineEnd(of: next))
        }
    }

    // MARK: - Drawing

    // The prompt laid out in `width` columns behind a `› ` marker, every line wrapped by
    // column, and the cursor's place among those lines.
    func layout(width: Int) -> (lines: [String], cursor: (row: Int, col: Int)) {
        let room = max(width - 2, 1)
        var lines: [String] = []
        var current = ""
        var used = 0
        var cursorAt = (row: 0, col: 0)
        for (index, character) in text.enumerated() {
            if index == cursor { cursorAt = (lines.count, used) }
            // A pasted control is drawn as its symbol, never sent to the terminal, and a
            // carriage return breaks the line as a newline does.
            let drawn = TerminalText.sanitized(String(character))
            if drawn.contains("\n") {
                lines.append(current)
                current = ""
                used = 0
                continue
            }
            let width = TerminalColumns.width(of: drawn)
            if used + width > room {
                lines.append(current)
                current = ""
                used = 0
                if index == cursor { cursorAt = (lines.count, 0) }
            }
            current += drawn
            used += width
        }
        if cursor == text.count {
            // A cursor past the last column sits at the start of the next line.
            if used >= room {
                lines.append(current)
                current = ""
                used = 0
            }
            cursorAt = (lines.count, used)
        }
        lines.append(current)
        return (lines.enumerated().map { ($0.offset == 0 ? "› " : "  ") + $0.element },
                (cursorAt.row, cursorAt.col + 2))
    }
}
