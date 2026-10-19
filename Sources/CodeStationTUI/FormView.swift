import Foundation
import TerminalKit
import TerminalTranscript

// A form over everything else: a heading, a column of labelled fields, lines of its own
// under them (such as a preview), and the key help. It is the terminal's version of the
// GUI's sheets for tasks: each field is a line of text, a few lines, a choice, a switch
// or a typed path. The task forms build one and read its values back (see `TaskForms`).
//
// Keys: ↑↓ (and Tab, Shift-Tab, except in a path) move between fields. A text field
// types; Ctrl-J or Alt-Enter starts a new line in a field of several lines. ←→ or Space
// change a choice, Space flips a switch, Tab completes a path. Enter submits from any
// field, Esc cancels. Why a submit was refused shows in the footer until the next key.
struct FormView {
    struct Field {
        enum Value {
            case text(ComposerView)
            // A field of several lines, such as a prompt.
            case lines(ComposerView)
            case choice([String], selected: Int)
            case toggle(Bool)
            // A file or a folder, typed, which Tab completes against this machine's files.
            case path(ComposerView)
        }

        let id: String
        var label: String
        var value: Value
        // Said dim beside or under the field, such as "optional" or what a hint says.
        var detail: String?
        var hidden = false

        static func text(_ id: String, _ label: String, _ text: String = "", detail: String? = nil) -> Field {
            Field(id: id, label: label, value: .text(Self.composer(text)), detail: detail)
        }

        static func lines(_ id: String, _ label: String, _ text: String = "", detail: String? = nil) -> Field {
            Field(id: id, label: label, value: .lines(Self.composer(text)), detail: detail)
        }

        static func choice(_ id: String, _ label: String, _ options: [String], selected: Int = 0,
                           detail: String? = nil) -> Field {
            Field(id: id, label: label, value: .choice(options, selected: max(0, min(selected, options.count - 1))),
                  detail: detail)
        }

        static func toggle(_ id: String, _ label: String, _ on: Bool, detail: String? = nil) -> Field {
            Field(id: id, label: label, value: .toggle(on), detail: detail)
        }

        static func path(_ id: String, _ label: String, _ text: String = "", detail: String? = nil) -> Field {
            Field(id: id, label: label, value: .path(Self.composer(text)), detail: detail)
        }

        private static func composer(_ text: String) -> ComposerView {
            var composer = ComposerView()
            composer.replace(with: text)
            return composer
        }
    }

    let title: String
    var subtitle: String?
    var fields: [Field]
    // Lines drawn under the fields, such as the prompt a run will send.
    var extra: [String] = []
    // What Enter does, for the key help, such as "run".
    var submitLabel: String
    // Keys of the form's own, said in the help after Enter's.
    var keys: String?
    private(set) var focused = 0
    // Why the last submit was refused, until the next key.
    var notice: String?
    // Set while the station takes what was submitted, so a second Enter does nothing.
    var busy = false
    // The paths the last Tab found, when it found more than one.
    private(set) var candidates: [String] = []
    // Where a relative path starts, for completion.
    var pathBase: String?

    init(title: String, subtitle: String? = nil, fields: [Field], submitLabel: String, keys: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.fields = fields
        self.submitLabel = submitLabel
        self.keys = keys
        focused = fields.firstIndex { !$0.hidden } ?? 0
    }

    // MARK: - Values

    var focusedID: String? { fields.indices.contains(focused) ? fields[focused].id : nil }

    func text(_ id: String) -> String {
        switch fields.first(where: { $0.id == id })?.value {
        case .text(let composer)?, .lines(let composer)?, .path(let composer)?: composer.string
        case .choice(let options, let selected)?: options.indices.contains(selected) ? options[selected] : ""
        case .toggle(let on)?: on ? "on" : "off"
        case nil: ""
        }
    }

    func choice(_ id: String) -> Int {
        if case .choice(_, let selected)? = fields.first(where: { $0.id == id })?.value { return selected }
        return 0
    }

    func isOn(_ id: String) -> Bool {
        if case .toggle(let on)? = fields.first(where: { $0.id == id })?.value { return on }
        return false
    }

    mutating func setHidden(_ id: String, _ hidden: Bool) {
        guard let index = fields.firstIndex(where: { $0.id == id }) else { return }
        fields[index].hidden = hidden
        if hidden, index == focused { move(by: 1) }
        if fields.indices.contains(focused), fields[focused].hidden { move(by: -1) }
    }

    // MARK: - Keys

    enum Outcome { case edited, submit, cancel, ignored }

    mutating func handle(_ key: Key) -> Outcome {
        notice = nil
        if key != .tab([]) { candidates = [] }
        if busy { return key == .escape ? .cancel : .ignored }
        guard fields.indices.contains(focused) else {
            switch key {
            case .escape: return .cancel
            case .enter([]): return .submit
            default: return .ignored
            }
        }
        switch key {
        case .escape: return .cancel
        case .enter([]): return .submit
        case .up, .tab(.shift):
            move(by: -1)
            return .edited
        case .down:
            move(by: 1)
            return .edited
        default: break
        }
        var field = fields[focused]
        defer { fields[focused] = field }
        switch field.value {
        case .text(var composer):
            if key == .tab([]) {
                move(by: 1)
                return .edited
            }
            // One line only: a newline key or a pasted break is not part of it.
            if case .enter = key { return .ignored }
            if key == .char("j", .ctrl) { return .ignored }
            let pressed: Key = if case .paste(let text) = key {
                .paste(text.split(whereSeparator: \.isNewline).joined(separator: " "))
            } else { key }
            let outcome = composer.handle(pressed)
            field.value = .text(composer)
            return outcome == .ignored ? .ignored : .edited
        case .lines(var composer):
            if key == .tab([]) {
                move(by: 1)
                return .edited
            }
            let outcome = composer.handle(key)
            field.value = .lines(composer)
            return outcome == .ignored ? .ignored : .edited
        case .path(var composer):
            if key == .tab([]) {
                let completion = PathCompletion.complete(composer.string, startingAt: pathBase, files: true)
                composer.replace(with: completion.text)
                candidates = completion.candidates
                if completion.candidates.isEmpty, !completion.completed { notice = "Nothing there starts with that." }
                field.value = .path(composer)
                return .edited
            }
            if case .enter = key { return .ignored }
            if key == .char("j", .ctrl) { return .ignored }
            let pressed: Key = if case .paste(let text) = key {
                .paste(text.split(whereSeparator: \.isNewline).joined())
            } else { key }
            let outcome = composer.handle(pressed)
            field.value = .path(composer)
            return outcome == .ignored ? .ignored : .edited
        case .choice(let options, let selected):
            guard !options.isEmpty else { return .ignored }
            switch key {
            case .left, .char("h", []): field.value = .choice(options, selected: (selected - 1 + options.count) % options.count)
            case .right, .char("l", []), .char(" ", []):
                field.value = .choice(options, selected: (selected + 1) % options.count)
            case .tab([]):
                move(by: 1)
            default: return .ignored
            }
            return .edited
        case .toggle(let on):
            switch key {
            case .char(" ", []), .left, .right, .char("h", []), .char("l", []): field.value = .toggle(!on)
            case .tab([]): move(by: 1)
            default: return .ignored
            }
            return .edited
        }
    }

    private mutating func move(by step: Int) {
        let shown = fields.indices.filter { !fields[$0].hidden }
        guard !shown.isEmpty else { return }
        let current = shown.firstIndex(of: focused) ?? shown.firstIndex { $0 > focused } ?? 0
        focused = shown[min(max(current + step, 0), shown.count - 1)]
    }

    // MARK: - Drawing

    func frame(size: TerminalSize, theme: TranscriptTheme) -> (lines: [String], cursor: Screen.Cursor?) {
        let width = max(size.cols, 20)
        var lines = [SidebarView.paint([(" " + title, Style.bold)], width: width)]
        if let subtitle { lines.append(SidebarView.paint([(" " + subtitle, Style.dim)], width: width)) }
        lines.append("")
        let labelWidth = min(max(fields.filter { !$0.hidden }.map { TerminalColumns.width(of: $0.label) }.max() ?? 0, 6), 22)
        let room = max(width - labelWidth - 6, 8)
        var cursor: Screen.Cursor?
        for (index, field) in fields.enumerated() where !field.hidden {
            let picked = index == focused
            let lead = (picked ? "  ▸ " : "    ") + TerminalColumns.pad(TerminalColumns.fit(field.label, to: labelWidth),
                                                                     to: labelWidth) + "  "
            let indent = String(repeating: " ", count: TerminalColumns.width(of: lead))
            switch field.value {
            case .text(let composer), .lines(let composer), .path(let composer):
                let (rows, at) = composer.layout(width: room + 2)
                // The composer's own `› ` marker is left off: the label says what it is.
                let shown = rows.map { String($0.dropFirst(2)) }
                if picked { cursor = Screen.Cursor(row: lines.count + at.row, col: TerminalColumns.width(of: lead) + at.col - 2) }
                for (row, text) in shown.enumerated() {
                    let empty = composer.string.isEmpty && row == 0
                    let body = empty ? [(field.detail ?? "", Style.dim)] : [(text, picked ? "" : Style.bold)]
                    lines.append(SidebarView.paint([(row == 0 ? lead : indent, picked ? Style.bold : "")] + body, width: width))
                }
                if let detail = field.detail, !composer.string.isEmpty, picked {
                    lines.append(SidebarView.paint([(indent + detail, Style.dim)], width: width))
                }
            case .choice(let options, let selected):
                let value = options.indices.contains(selected) ? options[selected] : ""
                lines.append(SidebarView.paint([(lead, picked ? Style.bold : ""),
                                                ("‹ \(value) ›", picked ? Style.reverse : Style.bold),
                                                (field.detail.map { "  " + $0 } ?? "", Style.dim)], width: width))
            case .toggle(let on):
                let green = Style.code(.state(.running), theme: theme)
                lines.append(SidebarView.paint([(lead, picked ? Style.bold : ""),
                                                (on ? "[●] on" : "[ ] off", (picked ? Style.reverse : "") + (on ? green : Style.dim)),
                                                (field.detail.map { "  " + $0 } ?? "", Style.dim)], width: width))
            }
        }
        if !candidates.isEmpty {
            lines.append("")
            lines += candidates.prefix(8).map { SidebarView.paint([("      " + $0, Style.dim)], width: width) }
            if candidates.count > 8 { lines.append(SidebarView.paint([("      +\(candidates.count - 8) more", Style.dim)], width: width)) }
        }
        if !extra.isEmpty {
            lines.append("")
            lines += extra.map { SidebarView.paint([($0, "")], width: width) }
        }
        let height = max(size.rows - 1, 1)
        let shown = Array(lines.prefix(height))
        if let at = cursor, at.row >= height { cursor = nil }
        let help = " ↑↓ field · enter \(submitLabel)" + (keys.map { " · " + $0 } ?? "") + " · esc cancel"
        let footer = notice.map { SidebarView.paint([(" " + $0, Style.code(.attention, theme: theme))], width: width) }
            ?? SidebarView.paint([(busy ? " Working…" : help, Style.dim)], width: width)
        return (shown + Array(repeating: "", count: max(height - shown.count, 0)) + [footer], cursor)
    }
}
