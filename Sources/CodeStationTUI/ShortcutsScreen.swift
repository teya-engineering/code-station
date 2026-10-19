import CodeStationCore
import Foundation
import TerminalKit
import TerminalTranscript

// Command shortcuts, drawn over everything: the saved commands a project, a session or the
// Mac offers (as the station lists them, see `StationShortcuts`), each with how its last
// run here went; under them, while one is open, what a run printed; and the editor that
// adds or edits one.
//
// The GUI keeps shortcuts in three places: a menu on a project's status strip, a split
// Run button by a session's composer, and the Shortcuts sheet in Tools. A terminal has no
// room for a button that unfolds a list of cards, so all three open this one screen, with
// `!` from a project or task screen and from an open session (scoped to what is on
// screen), and from Tools for the Mac's own list. The project strip still carries the
// count, as the GUI's chip does.
//
// View state only: the list and the output as the station last answered, which row the
// pointer is on, and the editor while one is open. Running, stopping and saving go to the
// station, and the screen shows what it answers.
struct ShortcutsScreen {
    let scope: String?
    private(set) var list: RemoteShortcuts?
    // The run whose output shows under the list, while one does.
    private(set) var output: RemoteShortcutOutput?
    private var selectedID: String?
    private(set) var editor: ShortcutEditor?
    // Why the last command was turned down, or what it did, until the next key.
    var notice: String?
    private let theme: TranscriptTheme

    init(scope: String?, theme: TranscriptTheme) {
        self.scope = scope
        self.theme = theme
    }

    var selected: RemoteShortcut? { list?.shortcuts.first { $0.id == selectedID } }
    var isEditing: Bool { editor != nil }

    // MARK: - Updates

    // A fresh list. The pointer stays on its row, or starts on the one this place ran
    // last, which is what Run offers again in the GUI.
    mutating func show(_ list: RemoteShortcuts) {
        let first = self.list == nil
        self.list = list
        if first || !list.shortcuts.contains(where: { $0.id == selectedID }) {
            selectedID = list.shortcuts.first { $0.id == list.lastStartedID }?.id ?? list.shortcuts.first?.id
        }
    }

    mutating func show(_ output: RemoteShortcutOutput?) {
        self.output = output
    }

    mutating func select(_ id: String) {
        selectedID = id
    }

    mutating func closeEditor() {
        editor = nil
    }

    mutating func editorRefused(_ message: String) {
        editor?.notice = message
    }

    // MARK: - Keys

    enum Outcome {
        case handled, ignored, close
        case run(String), stop(String), showOutput(String)
        case save(RemoteShortcutDraft)
        case remove(RemoteShortcut)
    }

    mutating func handle(_ key: Key) -> Outcome {
        notice = nil
        if editor != nil { return handleInEditor(key) }
        switch key {
        case .escape where output != nil:
            output = nil
        case .escape, .char("q", []), .left, .char("h", []): return .close
        case .up, .char("k", []), .char("p", .ctrl): move(by: -1)
        case .down, .char("j", []), .char("n", .ctrl): move(by: 1)
        case .home, .char("g", []): selectedID = list?.shortcuts.first?.id
        case .end, .char("G", []): selectedID = list?.shortcuts.last?.id
        // As the GUI's Run button: a running command shows what it prints, and anything
        // else starts and shows it.
        case .enter([]), .right, .char("l", []):
            guard let selected else { return .handled }
            return selected.run.outcome == .running ? .showOutput(selected.id) : .run(selected.id)
        case .char("s", []):
            guard let selected else { return .handled }
            guard selected.run.outcome == .running else {
                notice = "\(selected.name) is not running."
                return .handled
            }
            return .stop(selected.id)
        case .char("o", []):
            guard let selected else { return .handled }
            return .showOutput(selected.id)
        case .char("n", []):
            editor = ShortcutEditor(new: list)
        case .char("e", []):
            guard let selected else { return .handled }
            guard selected.run.outcome != .running else {
                notice = "\(selected.name) is running. Stop it before editing it."
                return .handled
            }
            editor = ShortcutEditor(editing: selected, in: list)
        case .char("x", []), .delete:
            guard let selected else { return .handled }
            return .remove(selected)
        default: return .ignored
        }
        return .handled
    }

    private mutating func handleInEditor(_ key: Key) -> Outcome {
        guard var open = editor else { return .ignored }
        let outcome = open.handle(key)
        editor = open
        switch outcome {
        case .handled: return .handled
        case .ignored: return .ignored
        case .cancel:
            editor = nil
            return .handled
        case .save(let draft): return .save(draft)
        }
    }

    private mutating func move(by step: Int) {
        guard let ids = list?.shortcuts.map(\.id), !ids.isEmpty else { return }
        let current = selectedID.flatMap(ids.firstIndex(of:)) ?? 0
        selectedID = ids[min(max(current + step, 0), ids.count - 1)]
    }

    // MARK: - Drawing

    func frame(size: TerminalSize, now: Date) -> (lines: [String], cursor: Screen.Cursor?) {
        if let editor { return editor.frame(size: size) }
        let width = max(size.cols, 10)
        var lines = [SidebarView.paint([(" Shortcuts · " + (list?.title ?? "…"), Style.bold)], width: width)]
        lines.append(SidebarView.paint([(" " + summary, Style.dim)], width: width))
        if let problem = list?.problem {
            lines.append(SidebarView.paint([(" ⚠ " + problem, Style.yellow)], width: width))
        }
        lines.append("")
        if let list {
            if list.shortcuts.isEmpty {
                lines.append(SidebarView.paint([("  Nothing saved yet. Press n to save a command.", Style.dim)],
                                               width: width))
            }
            for shortcut in list.shortcuts {
                lines.append(row(shortcut, selected: shortcut.id == selectedID, width: width, now: now))
            }
        } else {
            lines.append(SidebarView.paint([("  Reading the shortcuts…", Style.dim)], width: width))
        }
        let height = max(size.rows - 1, 1)
        if let output {
            lines.append("")
            lines += outputLines(output, width: width, room: max(height - lines.count, 2))
        }
        var shown = Array(lines.prefix(height))
        shown += Array(repeating: "", count: max(height - shown.count, 0))
        let helpText = notice.map { " " + $0 }
            ?? " enter run · s stop · o output · n new · e edit · x remove · \(output == nil ? "esc close" : "esc hide output")"
        return (shown + [SidebarView.paint([(helpText, notice == nil ? Style.dim : Style.yellow)], width: width)], nil)
    }

    // "Run in the project folder · 3 saved · 1 running".
    private var summary: String {
        guard let list else { return "" }
        let place = list.scope == nil ? "Run from your home folder"
            : list.shortcuts.contains(where: { $0.projectName != nil && $0.projectName != list.projectName })
                ? "Run in each project's checkout" : "Run in \(list.projectName ?? "the project")'s checkout"
        var parts = [place, "\(list.shortcuts.count) saved"]
        if list.running > 0 { parts.append("\(list.running) running") }
        if list.failed > 0 { parts.append("\(list.failed) failed") }
        return parts.joined(separator: " · ")
    }

    // "  ▸ ✓ Tests   swift test   Passed just now in 1.2s".
    private func row(_ shortcut: RemoteShortcut, selected: Bool, width: Int, now: Date) -> String {
        let (glyph, tone) = Self.glyph(shortcut.run.outcome)
        let status = Self.status(shortcut.run, now: now)
            + (shortcut.availableInAllProjects ? " · all projects" : "")
        let nameWidth = min(max(width / 4, 10), 24)
        let commandRoom = max(width - 6 - nameWidth - TerminalColumns.width(of: status) - 4, 0)
        return SidebarView.paint([(selected ? "  ▸ " : "    ", ""), (glyph, styleFor(tone)), (" ", ""),
                                  (TerminalColumns.pad(TerminalColumns.fit(shortcut.name, to: nameWidth - 1),
                                                       to: nameWidth), Style.bold),
                                  (TerminalColumns.pad(TerminalColumns.fit(shortcut.command, to: commandRoom),
                                                       to: commandRoom), Style.dim),
                                  ("  " + status, styleFor(tone))],
                                 width: width, reversed: selected)
    }

    // The heading over a run's output, then its last lines.
    private func outputLines(_ output: RemoteShortcutOutput, width: Int, room: Int) -> [String] {
        let (_, tone) = Self.glyph(output.run.outcome)
        let word = switch output.run.outcome {
        case .running: "RUNNING"
        case .passed: "PASSED"
        case .failed: output.run.exitStatus.map { "EXIT \($0)" } ?? "FAILED"
        case .stopped: "STOPPED"
        case .never: "NOT RUN"
        }
        let folder = (output.directory as NSString).abbreviatingWithTildeInPath
        // The state before the folder, which a long path would otherwise push off the row.
        let heading = SidebarView.paint([(" ─ Output · ", Style.dim), (output.name, Style.bold), ("  ", ""),
                                         (word, styleFor(tone)), ("  " + folder, Style.dim)], width: width)
        var body = output.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while body.last?.isEmpty == true { body.removeLast() }
        if body.isEmpty {
            body = [output.run.outcome == .running ? "Nothing printed yet." : "Nothing was printed."]
            return [heading] + body.map { SidebarView.paint([("   " + $0, Style.dim)], width: width) }
        }
        if output.run.outcome == .failed, let message = output.run.message, output.run.exitStatus == nil {
            body.append(message)
        }
        let tail = body.suffix(max(room - 1, 1))
        return [heading] + tail.map { SidebarView.paint([("   " + Self.printable($0), "")], width: width) }
    }

    // What a command prints can carry its own colours and cursor moves, which would tear
    // the frame: they are taken out, and tabs become spaces.
    static func printable(_ line: String) -> String {
        var out = ""
        var escaping = false
        for scalar in line.unicodeScalars {
            if escaping {
                if (0x40...0x7E).contains(scalar.value) && scalar != "[" { escaping = false }
                continue
            }
            switch scalar {
            case "\u{1B}": escaping = true
            case "\t": out += "    "
            case "\r": continue
            default:
                if scalar.value < 0x20 { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    enum Tone { case running, passed, failed, quiet }

    static func glyph(_ outcome: RemoteShortcutRun.Outcome) -> (String, Tone) {
        switch outcome {
        case .running: ("●", .running)
        case .passed: ("✓", .passed)
        case .failed: ("✗", .failed)
        case .stopped: ("■", .quiet)
        case .never: ("·", .quiet)
        }
    }

    private func styleFor(_ tone: Tone) -> String {
        switch tone {
        case .running: Style.cyan
        case .passed: Style.green
        case .failed: Style.red
        case .quiet: Style.dim
        }
    }

    // The GUI's run summary: "Running now · 4.2s", "Passed just now in 1.2s",
    // "Failed 2 min ago · exit 3", "Stopped", "Never run".
    static func status(_ run: RemoteShortcutRun, now: Date) -> String {
        switch run.outcome {
        case .never: return "Never run"
        case .stopped: return "Stopped"
        case .running:
            return "Running now" + (run.at.map { " · " + TopBarView.duration(since: $0, now: now) } ?? "")
        case .passed, .failed:
            let verb = run.outcome == .passed ? "Passed" : "Failed"
            var text = verb + (run.at.map { " " + ago(now.timeIntervalSince($0)) } ?? "")
            if let duration = run.duration { text += " in " + length(duration) }
            if run.outcome == .failed, let status = run.exitStatus { text += " · exit \(status)" }
            return text
        }
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }

    static func length(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return "\(Int(seconds))s" }
        let whole = Int(seconds)
        if whole < 3_600 { return "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3_600)h \(whole % 3_600 / 60)m"
    }
}

// Adding or editing one shortcut: its name, its command, and whether it stays with the
// project it was made in (or the Mac's list) or is shared with every project, as the
// GUI's shortcut editor asks. Tab moves between the fields, Enter saves, Esc cancels.
struct ShortcutEditor {
    enum Field: Int, CaseIterable { case name, command, sharing }

    private let id: String?
    private let originalName: String?
    var name = ComposerView()
    var command = ComposerView()
    var shared: Bool
    // Where a shortcut that is not shared is filed, and that project's name.
    private let projectID: String?
    private let projectName: String?
    private(set) var field = Field.name
    var notice: String?

    init(new list: RemoteShortcuts?) {
        id = nil
        originalName = nil
        shared = false
        projectID = list?.projectID
        projectName = list?.projectName
    }

    init(editing shortcut: RemoteShortcut, in list: RemoteShortcuts?) {
        id = shortcut.id
        originalName = shortcut.name
        name.replace(with: shortcut.name)
        command.replace(with: shortcut.command)
        shared = shortcut.availableInAllProjects
        // A shared one made private goes to the project on screen.
        projectID = shortcut.projectID ?? list?.projectID
        projectName = shortcut.projectID == nil ? list?.projectName
            : (shortcut.projectID == list?.projectID ? list?.projectName : shortcut.projectName)
    }

    var draft: RemoteShortcutDraft {
        RemoteShortcutDraft(id: id, name: name.string, command: command.string,
                            projectID: shared ? nil : projectID, availableInAllProjects: shared)
    }

    enum Outcome { case handled, ignored, cancel, save(RemoteShortcutDraft) }

    mutating func handle(_ key: Key) -> Outcome {
        notice = nil
        switch key {
        case .escape: return .cancel
        case .enter([]): return save()
        case .tab([]), .down([]): moveField(by: 1)
        case .tab(.shift), .up([]): moveField(by: -1)
        default:
            if field == .sharing {
                switch key {
                case .left, .right, .char(" ", []), .char("h", []), .char("l", []): shared.toggle()
                default: return .ignored
                }
                return .handled
            }
            // One line each: a newline is not part of a name or a command.
            let line: Key = if case .paste(let text) = key {
                .paste(text.split(whereSeparator: \.isNewline).joined(separator: " "))
            } else {
                key
            }
            if case .enter = line { return .ignored }
            let edited = field == .name ? name.handle(line) : command.handle(line)
            return edited == .ignored ? .ignored : .handled
        }
        return .handled
    }

    private func save() -> Outcome {
        guard !name.string.isBlank, !command.string.isBlank else {
            return .handled
        }
        return .save(draft)
    }

    private mutating func moveField(by step: Int) {
        let count = Field.allCases.count
        field = Field(rawValue: ((field.rawValue + step) % count + count) % count) ?? .name
    }

    func frame(size: TerminalSize) -> (lines: [String], cursor: Screen.Cursor?) {
        let width = max(size.cols, 20)
        let title = id == nil ? "New shortcut" : "Edit " + (originalName ?? "shortcut")
        var lines = [SidebarView.paint([(" " + title, Style.bold)], width: width), ""]
        let labelWidth = 12
        var cursor: Screen.Cursor?
        for (label, editor, which) in [("Name", name, Field.name), ("Command", command, Field.command)] {
            let room = max(width - labelWidth - 4, 4)
            let (text, at) = editor.layout(width: room)
            let marker = field == which ? "  ▸ " : "    "
            if field == which { cursor = Screen.Cursor(row: lines.count, col: labelWidth + 4 + at.col) }
            lines.append(SidebarView.paint([(marker, ""), (TerminalColumns.pad(label, to: labelWidth), Style.bold),
                                            (text.last ?? "", field == which ? "" : Style.dim)], width: width))
        }
        let local = projectName.map { "Only \($0)" } ?? "This Mac only"
        let choice = "‹ " + (shared ? "All projects" : local) + " ›"
        lines.append(SidebarView.paint([(field == .sharing ? "  ▸ " : "    ", ""),
                                        (TerminalColumns.pad("Where", to: labelWidth), Style.bold),
                                        (choice, field == .sharing ? Style.reverse : "")], width: width))
        lines.append("")
        let explanation = shared ? "Every project offers it, run in its own checkout."
            : projectName == nil ? "Runs from your home folder." : "Runs in the project's checkout."
        lines.append(SidebarView.paint([("    " + explanation, Style.dim)], width: width))
        let height = max(size.rows - 1, 1)
        var shown = Array(lines.prefix(height))
        shown += Array(repeating: "", count: max(height - shown.count, 0))
        let canSave = !name.string.isBlank && !command.string.isBlank
        let help = notice.map { " " + $0 }
            ?? (canSave ? " tab next field · ←→ where · enter save · esc cancel"
                : " Give it a name and a command · tab next field · esc cancel")
        return (shown + [SidebarView.paint([(help, notice == nil ? Style.dim : Style.red)], width: width)],
                field == .sharing ? nil : cursor)
    }
}
