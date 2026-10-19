import CodeStationCore
import TerminalKit
import TerminalTranscript

// Push, pull and fetch, and the branch picker, for one checkout at a time, as the GUI's
// changes header offers them. The Changes tab and a project's screen both hold one: they
// say which checkout the keys act on, and draw its status line and picker.
//
// Keys, from the screen that holds it:
// - `P` pushes (publishing a branch with no upstream), `U` pulls, `F` fetches;
// - `B` opens the branch picker: type to filter, ↑↓ to move, Enter to switch to the
//   branch, or on "Create new branch" to name one; Esc closes.
//
// While a sync runs, its line says so ("Pushing alpha…"); once it answers, the line says
// what it did or why it could not, until the next key.
@MainActor
final class SyncActions {
    // The checkout the keys act on: a session's or project's id as the scope, the
    // checkout's path, and its project's name for the words on screen.
    struct Target: Equatable {
        let scope: String
        let checkout: String
        let name: String
    }

    private let commands: any StationInterface
    private let theme: TranscriptTheme
    private let work: (@escaping @MainActor () async -> Void) -> Task<Void, Never>
    private let repaint: @MainActor () -> Void
    // Called once a sync or switch went through, for the screen to read itself again.
    private let changed: @MainActor () -> Void

    private enum Status {
        case working(String)
        case done(String)
        case failed(String)
    }

    private var status: Status?
    private var picker: BranchPicker?

    init(commands: any StationInterface, theme: TranscriptTheme,
         work: @escaping (@escaping @MainActor () async -> Void) -> Task<Void, Never>,
         repaint: @escaping @MainActor () -> Void, changed: @escaping @MainActor () -> Void = {}) {
        self.commands = commands
        self.theme = theme
        self.work = work
        self.repaint = repaint
        self.changed = changed
    }

    // The picker is open, and takes every key.
    var isOpen: Bool { picker != nil }

    private var isWorking: Bool {
        if case .working = status { true } else { false }
    }

    // MARK: - Keys

    // A sync or picker key from the screen that holds this, for `target`. False for any
    // other key. A nil target (no checkout to act on) says so in the status line.
    func start(_ key: Key, at target: Target?) -> Bool {
        let action: RemoteSyncAction?
        switch key {
        case .char("P", []), .char("P", .shift): action = .push
        case .char("U", []), .char("U", .shift): action = .pull
        case .char("F", []), .char("F", .shift): action = .fetch
        case .char("B", []), .char("B", .shift): action = nil
        default:
            // Any other key clears what the last sync said, once it is over.
            if !isWorking { status = nil }
            return false
        }
        guard let target else {
            status = .failed("There is no git checkout here to sync.")
            return true
        }
        guard !isWorking else { return true }
        if let action { run(action, at: target) } else { openPicker(at: target) }
        return true
    }

    func handle(_ key: Key) -> Bool {
        guard var open = picker else { return false }
        switch open.handle(key) {
        case .handled: picker = open
        case .close: picker = nil
        case .switchTo(let branch): switchBranch(branch, creating: false, in: open)
        case .create(let branch): switchBranch(branch, creating: true, in: open)
        }
        return true
    }

    // MARK: - Sync

    private func run(_ action: RemoteSyncAction, at target: Target) {
        let verb = switch action {
        case .push: "Pushing"
        case .pull: "Pulling"
        case .fetch: "Fetching"
        }
        status = .working("\(verb) \(target.name)…")
        let commands = commands
        _ = work { [weak self] in
            do throws(StationRefusal) {
                let result = try await commands.sync(target.scope, checkout: target.checkout, action)
                self?.status = .done(result.summary)
                self?.changed()
            } catch {
                self?.status = .failed("Could not \(action.rawValue): " + error.message)
            }
            self?.repaint()
        }
    }

    // MARK: - Branches

    private func openPicker(at target: Target) {
        status = nil
        picker = BranchPicker(target: target)
        let commands = commands
        _ = work { [weak self] in
            do throws(StationRefusal) {
                let branches = try await commands.readBranches(target.scope, checkout: target.checkout)
                self?.picker?.show(branches)
            } catch {
                self?.picker = nil
                self?.status = .failed("Could not read the branches: " + error.message)
            }
            self?.repaint()
        }
    }

    private func switchBranch(_ branch: String, creating: Bool, in open: BranchPicker) {
        var open = open
        open.working = creating ? "Creating \(branch)…" : "Switching to \(branch)…"
        picker = open
        let commands = commands, target = open.target
        _ = work { [weak self] in
            do throws(StationRefusal) {
                try await commands.switchBranch(target.scope, checkout: target.checkout, to: branch,
                                                creating: creating)
                self?.picker = nil
                let name = branch.hasPrefix("origin/") ? String(branch.dropFirst("origin/".count)) : branch
                self?.status = .done(creating ? "Created \(branch) and switched to it" : "Switched to \(name)")
                self?.changed()
            } catch {
                self?.picker?.working = nil
                self?.picker?.refusal = error.message
            }
            self?.repaint()
        }
    }

    // MARK: - Drawing

    // The screen's frame with the status line in place of its last row (its key help)
    // while there is something to say.
    func overlay(_ lines: [String], width: Int) -> [String] {
        guard let status, !lines.isEmpty else { return lines }
        var lines = lines
        let (text, colour) = switch status {
        case .working(let text): ("⟳ " + text, Style.cyan)
        case .done(let text): ("✓ " + text, Style.green)
        case .failed(let text): ("✗ " + text, Style.code(.attention, theme: theme))
        }
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        lines[lines.count - 1] = SidebarView.paint([(" " + line, colour)], width: max(width, 1))
        return lines
    }

    func frame(size: TerminalSize) -> (lines: [String], cursor: Screen.Cursor?) {
        picker?.frame(size: size, theme: theme) ?? ([], nil)
    }
}

// The branches of one checkout to pick from: "Create new branch" first, then the local
// branches and the remote ones, narrowed by what is typed.
struct BranchPicker {
    let target: SyncActions.Target
    private(set) var branches: RemoteBranches?
    private var filter = ComposerView()
    private var selected = 0
    // The name of a new branch being typed, once "Create new branch" was picked.
    private var naming: ComposerView?
    // What the switch under way is doing, and why the last one was refused.
    var working: String?
    var refusal: String?

    init(target: SyncActions.Target) {
        self.target = target
    }

    mutating func show(_ branches: RemoteBranches) {
        self.branches = branches
        selected = 0
    }

    enum Outcome: Equatable {
        case handled, close
        case switchTo(String), create(String)
    }

    private enum Row: Equatable {
        case create
        case heading(String)
        case branch(String, current: Bool)

        var pickable: Bool {
            if case .heading = self { false } else { true }
        }
    }

    private var rows: [Row] {
        guard let branches else { return [] }
        let words = filter.string.lowercased().split(separator: " ")
        let matches = { (name: String) in words.allSatisfy { name.lowercased().contains($0) } }
        var rows: [Row] = [.create]
        let local = branches.local.filter(matches)
        if !local.isEmpty {
            rows.append(.heading("LOCAL"))
            rows += local.map { .branch($0, current: branches.onBranch && $0 == branches.current) }
        }
        let remote = branches.remote.filter(matches)
        if !remote.isEmpty {
            rows.append(.heading("REMOTE"))
            rows += remote.map { .branch($0, current: false) }
        }
        return rows
    }

    private var pickable: [Row] { rows.filter(\.pickable) }

    mutating func handle(_ key: Key) -> Outcome {
        guard working == nil else { return .handled }
        refusal = nil
        if var field = naming {
            switch key {
            case .escape: naming = nil
            case .enter([]): return .create(field.string)
            case .enter, .char("j", .ctrl): break
            case .paste(let text):
                _ = field.handle(.paste(text.split(whereSeparator: \.isNewline).joined(separator: " ")))
                naming = field
            default:
                _ = field.handle(key)
                naming = field
            }
            return .handled
        }
        let count = pickable.count
        switch key {
        case .escape: return .close
        case .up, .char("p", .ctrl): selected = max(selected - 1, 0)
        case .down, .char("n", .ctrl): selected = min(selected + 1, max(count - 1, 0))
        case .enter([]):
            guard branches != nil, pickable.indices.contains(selected) else { return .handled }
            switch pickable[selected] {
            case .create:
                var field = ComposerView()
                field.replace(with: filter.string.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: " ", with: "-"))
                naming = field
            case .branch(let name, let current):
                return current ? .close : .switchTo(name)
            case .heading: break
            }
        case .paste(let text):
            _ = filter.handle(.paste(text.split(whereSeparator: \.isNewline).joined(separator: " ")))
            selected = min(selected, max(pickable.count - 1, 0))
        case .enter, .char("j", .ctrl): break
        default:
            _ = filter.handle(key)
            // Typing jumps to the first branch that matches, past "Create new branch".
            selected = pickable.count > 1 && !filter.isEmpty ? 1 : 0
        }
        return .handled
    }

    func frame(size: TerminalSize, theme: TranscriptTheme) -> (lines: [String], cursor: Screen.Cursor?) {
        let width = max(size.cols, 10)
        let current = branches.map { $0.current.isEmpty ? "" : " · on \($0.current)" } ?? ""
        var lines = [Style.bold + TerminalColumns.fit(" Branches · \(target.name)\(current)", to: width) + Style.reset,
                     ""]
        var cursor: Screen.Cursor?
        if let naming {
            lines.append(Style.dim + TerminalColumns.fit(" New branch, from \(branches?.current ?? "here")",
                                                         to: width) + Style.reset)
            let (field, at) = naming.layout(width: width - 1)
            cursor = Screen.Cursor(row: lines.count + at.row, col: at.col + 1)
            lines += field.map { " " + $0 }
        } else {
            let (field, at) = filter.layout(width: width - 9)
            cursor = Screen.Cursor(row: lines.count + at.row, col: at.col + 9)
            lines.append(Style.dim + " Filter " + Style.reset + (field.first ?? ""))
            lines.append("")
            if branches == nil {
                lines.append(Style.dim + "  Reading branches…" + Style.reset)
            } else {
                let room = max(size.rows - lines.count - 2, 1)
                let all = rows
                let chosen = pickable.indices.contains(selected) ? pickable[selected] : nil
                let at = chosen.flatMap { row in all.firstIndex(of: row) } ?? 0
                let top = min(max(at - room + 1, 0), max(all.count - room, 0))
                for row in all[top..<min(all.count, top + room)] {
                    lines.append(draw(row, selected: row == chosen, width: width))
                }
                if all.count == 1 {
                    lines.append(Style.dim + "  No branch matches this filter." + Style.reset)
                }
            }
        }
        let rows = max(size.rows, lines.count + 1)
        lines += Array(repeating: "", count: rows - lines.count - 1)
        let footer: String
        if let working {
            footer = SidebarView.paint([(" ⟳ " + working, Style.cyan)], width: width)
        } else if let refusal {
            footer = SidebarView.paint([(" ✗ " + refusal.split(whereSeparator: \.isNewline).joined(separator: " "),
                                         Style.code(.attention, theme: theme))], width: width)
        } else {
            let help = naming == nil ? " type to filter · ↑↓ move · enter switch · esc close"
                : " enter create and switch · esc back"
            footer = Style.dim + TerminalColumns.fit(help, to: width) + Style.reset
        }
        lines.append(footer)
        return (lines, working == nil ? cursor : nil)
    }

    private func draw(_ row: Row, selected: Bool, width: Int) -> String {
        switch row {
        case .heading(let title):
            return Style.bold + Style.dim + TerminalColumns.fit(" " + title, to: width) + Style.reset
        case .create:
            return SidebarView.paint([(selected ? " ▸ " : "   ", ""), ("+ Create new branch…", Style.cyan)],
                                     width: width, reversed: selected)
        case .branch(let name, let current):
            return SidebarView.paint([(selected ? " ▸ " : "   ", ""), (current ? "● " : "  ", Style.green),
                                      (name, current ? Style.bold : "")],
                                     width: width, reversed: selected)
        }
    }
}
