import CodeStationCore
import TerminalKit
import TerminalTranscript

// The new-workspace form, the terminal's version of the GUI's `NewWorkspaceView`: a name,
// and the projects worked on together, picked with Space. The first one picked leads
// (the folder every session starts in) until another is made lead with `l`. It holds view
// state only and hands the station the name, the projects and the lead.
struct WorkspaceForm {
    struct Choice: Equatable {
        let id: String
        let name: String
        let path: String
    }

    let choices: [Choice]
    var name = ComposerView()
    // The pointer: nil on the name, otherwise a project's row.
    private(set) var row: Int?
    // The projects picked, in the order they were picked.
    private(set) var picked: [String] = []
    private(set) var lead: String?
    // Set while the station makes it, so a second Enter does not make two.
    var creating = false
    // Why the last try was turned down, until the next key.
    var notice: String?

    init(choices: [Choice]) {
        self.choices = choices
    }

    var canCreate: Bool { !name.string.trimmed.isEmpty && picked.count >= 2 && lead != nil }

    enum Outcome { case handled, create, cancel, ignored }

    mutating func handle(_ key: Key) -> Outcome {
        notice = nil
        if creating { return .handled }
        switch key {
        case .escape: return .cancel
        case .enter([]): return .create
        case .up, .tab(.shift), .char("p", .ctrl): move(by: -1)
        case .down, .tab([]), .char("n", .ctrl): move(by: 1)
        default:
            guard let row else {
                return name.handle(key) == .ignored ? .ignored : .handled
            }
            switch key {
            case .char("k", []): move(by: -1)
            case .char("j", []): move(by: 1)
            case .char(" ", []): toggle(choices[row].id)
            case .char("l", []), .char("L", []), .char("L", .shift):
                let id = choices[row].id
                if !picked.contains(id) { toggle(id) }
                lead = id
            default: return .ignored
            }
        }
        return .handled
    }

    private mutating func move(by step: Int) {
        let last = choices.count - 1
        let current = row ?? -1
        let next = min(max(current + step, -1), last)
        row = next < 0 ? nil : next
    }

    private mutating func toggle(_ id: String) {
        if let index = picked.firstIndex(of: id) {
            picked.remove(at: index)
            if lead == id { lead = picked.first }
        } else {
            picked.append(id)
            if lead == nil { lead = id }
        }
    }

    // MARK: - Drawing

    func frame(size: TerminalSize, theme: TranscriptTheme) -> (lines: [String], cursor: Screen.Cursor?) {
        let width = max(size.cols, 10)
        var lines = [Style.bold + TerminalColumns.fit(" New workspace", to: width) + Style.reset,
                     Style.dim + TerminalColumns.fit(" Pick the projects that get worked on together. Every session starts with all of them.",
                                                    to: width) + Style.reset,
                     ""]
        let marker = row == nil ? " ▸ " : "   "
        let label = marker + "Name  "
        let (field, at) = name.layout(width: max(width - TerminalColumns.width(of: label), 1))
        let cursorRow = lines.count + at.row
        let cursorCol = TerminalColumns.width(of: label) + at.col
        lines += field.enumerated().map { index, text in
            (index == 0 ? label : String(repeating: " ", count: TerminalColumns.width(of: label))) + text
        }
        lines.append("")
        lines.append(SidebarView.paint([(" PROJECTS · \(picked.count) picked", Style.bold + Style.dim)], width: width))
        if choices.isEmpty {
            lines.append(SidebarView.paint([("   No projects yet. Add some first.", Style.dim)], width: width))
        }
        var selectedLine: Int?
        for (index, choice) in choices.enumerated() {
            let selected = index == row
            if selected { selectedLine = lines.count }
            let checked = picked.contains(choice.id)
            var runs: [ContainerScreen.Run] = [(selected ? " ▸ " : "   ", ""), (checked ? "[x] " : "[ ] ", ""),
                                               (choice.name, Style.bold)]
            if lead == choice.id { runs.append(("  LEAD", Style.cyan)) }
            runs.append(("  " + choice.path, Style.dim))
            lines.append(SidebarView.paint(runs, width: width, reversed: selected))
        }
        let height = max(size.rows - 1, 1)
        var top = 0
        if let selectedLine, selectedLine >= height { top = selectedLine - height + 1 }
        var shown = Array(lines.dropFirst(top).prefix(height))
        shown += Array(repeating: "", count: max(height - shown.count, 0))
        let help: String
        let style: String
        if let notice {
            (help, style) = (" " + notice, Style.code(.attention, theme: theme))
        } else if creating {
            (help, style) = (" Creating the workspace…", Style.dim)
        } else {
            (help, style) = (" ↑↓ move · space pick · l make lead · enter create · esc cancel", Style.dim)
        }
        shown.append(SidebarView.paint([(help, style)], width: width))
        let cursor = row == nil && cursorRow >= top ? Screen.Cursor(row: cursorRow - top, col: cursorCol) : nil
        return (shown, cursor)
    }
}
