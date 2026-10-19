import CodeStationCore
import Foundation
import TerminalKit
import TerminalTranscript

// One entry of an actions menu: the terminal's version of an `.appContextMenu` item or
// an `.appMenu` entry. What it does is a closure the menu's builder hands it, so adding
// an entry is one line where the menu is built (see `TUIApp.rowActions(for:)`).
struct MenuAction {
    enum Effect {
        // Runs at once, the menu closed first.
        case run(@MainActor () -> Void)
        // Asks first, with what goes and what stays (`ImpactConfirmation`), and runs only
        // once the person confirms.
        case confirm(ImpactConfirmation, then: @MainActor () -> Void)
        // Listed for parity with the GUI but not reachable from here yet: Enter says why,
        // in the menu's own footer, and the menu stays open.
        case unavailable(String)
    }

    let title: String
    // Said dim after the title, such as the key that does the same.
    var detail: String?
    var isDestructive = false
    let effect: Effect

    init(_ title: String, detail: String? = nil, destructive: Bool = false, _ effect: Effect) {
        self.title = title
        self.detail = detail
        self.isDestructive = destructive
        self.effect = effect
    }

    var isAvailable: Bool {
        if case .unavailable = effect { return false }
        return true
    }
}

// A menu over everything: a heading naming what it acts on, its entries, and the key
// help. Arrows or j/k move, Enter chooses, Esc closes.
struct ActionMenu {
    let title: String
    // What the heading says under the title, such as "Project · ~/code/alpha".
    var subtitle: String?
    let actions: [MenuAction]
    private(set) var selected = 0
    // Why the entry chosen cannot run yet, until the next key.
    private(set) var notice: String?

    init(title: String, subtitle: String? = nil, actions: [MenuAction]) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
        selected = actions.firstIndex(where: \.isAvailable) ?? 0
    }

    enum Outcome {
        case handled, ignored, close
        case choose(MenuAction)
    }

    mutating func handle(_ key: Key) -> Outcome {
        notice = nil
        switch key {
        case .escape, .char("q", []), .left, .char("h", []): return .close
        case .up, .char("k", []), .char("p", .ctrl), .tab(.shift): move(by: -1)
        case .down, .char("j", []), .char("n", .ctrl), .tab([]): move(by: 1)
        case .home, .char("g", []): selected = 0
        case .end, .char("G", []): selected = max(actions.count - 1, 0)
        case .enter([]), .right, .char("l", []), .char(" ", []):
            guard actions.indices.contains(selected) else { return .close }
            let action = actions[selected]
            if case .unavailable(let why) = action.effect {
                notice = why
                return .handled
            }
            return .choose(action)
        default: return .ignored
        }
        return .handled
    }

    private mutating func move(by offset: Int) {
        guard !actions.isEmpty else { return }
        selected = min(max(selected + offset, 0), actions.count - 1)
    }

    func frame(size: TerminalSize, theme: TranscriptTheme) -> [String] {
        let width = max(size.cols, 1)
        var lines = [SidebarView.paint([(" " + title, Style.bold)], width: width)]
        if let subtitle { lines.append(SidebarView.paint([(" " + subtitle, Style.dim)], width: width)) }
        lines.append("")
        for (index, action) in actions.enumerated() {
            let picked = index == selected
            let titleStyle = action.isDestructive ? Style.code(.state(.failed), theme: theme)
                : action.isAvailable ? "" : Style.dim
            let detail: String? = action.isAvailable ? action.detail : {
                if case .unavailable(let why) = action.effect { return why }
                return nil
            }()
            lines.append(SidebarView.paint([(picked ? "  ▸ " : "    ", ""), (action.title, titleStyle),
                                            (detail.map { "   " + $0 } ?? "", Style.dim)],
                                           width: width, reversed: picked))
        }
        let height = max(size.rows - 1, 1)
        let shown = Array(lines.prefix(height))
        let footer = notice.map { SidebarView.paint([(" " + $0, Style.code(.attention, theme: theme))], width: width) }
            ?? SidebarView.paint([(" ↑↓ move · enter choose · esc close", Style.dim)], width: width)
        return shown + Array(repeating: "", count: max(height - shown.count, 0)) + [footer]
    }
}

extension ImpactConfirmation {
    // The confirmation for what the station says a removal takes and leaves.
    init(_ impact: RemoteImpact) {
        self.init(impact.title, message: impact.message,
                  subject: impact.subject.map { Subject(name: $0.name, kind: $0.kind) },
                  rows: impact.rows.map { Row($0.title, $0.detail, kept: $0.kept) },
                  warning: impact.warning, action: impact.action)
    }
}

// The confirmation a deletion asks for, mirroring the GUI's `Dialog.impact`: the project,
// task or workspace it happens in, a title and message, one row for each thing that goes
// (a minus) and each thing that stays (a tick), and a warning for what cannot be restored.
// Enter takes the focused button, which starts on the action as the GUI's default does;
// Tab and the arrows move between the action and Cancel; Esc cancels.
struct ImpactConfirmation {
    struct Subject {
        let name: String
        var kind: RemoteContainer.Kind = .project
    }

    struct Row {
        let title: String
        let detail: String
        var kept = false

        init(_ title: String, _ detail: String, kept: Bool = false) {
            self.title = title
            self.detail = detail
            self.kept = kept
        }
    }

    let title: String
    var message: String?
    var subject: Subject?
    let rows: [Row]
    var warning: String?
    // The destructive button's label, such as "Delete session".
    let action: String
    // A deletion's button is red; a repair's, such as a rebuild, is not.
    var isDestructive = true
    // Whether the action's button has the focus rather than Cancel.
    private(set) var onAction = true

    init(_ title: String, message: String? = nil, subject: Subject? = nil, rows: [Row],
         warning: String? = nil, action: String) {
        self.title = title
        self.message = message
        self.subject = subject
        self.rows = rows
        self.warning = warning
        self.action = action
    }

    enum Outcome { case handled, ignored, confirm, cancel }

    mutating func handle(_ key: Key) -> Outcome {
        switch key {
        case .escape, .char("n", []), .char("q", []): return .cancel
        case .char("y", []): return .confirm
        case .enter([]): return onAction ? .confirm : .cancel
        case .tab, .left, .right, .char("h", []), .char("l", []): onAction.toggle()
        default: return .ignored
        }
        return .handled
    }

    func frame(size: TerminalSize, theme: TranscriptTheme) -> [String] {
        let width = max(size.cols, 1)
        let red = Style.code(.state(.failed), theme: theme)
        let green = Style.code(.state(.running), theme: theme)
        let rule = SidebarView.paint([(" " + String(repeating: "─", count: max(width - 2, 1)), Style.dim)], width: width)
        var lines: [String] = []
        if let subject {
            let glyph = switch subject.kind {
            case .project: "■"
            case .task: "□"
            case .workspace: "▤"
            }
            lines.append(SidebarView.paint([(" " + glyph + " " + subject.name, Style.dim)], width: width))
        }
        lines.append(SidebarView.paint([(" " + title, Style.bold)], width: width))
        if let message {
            lines += TranscriptRenderer.wrap(message, width: max(width - 2, 1))
                .map { SidebarView.paint([(" " + $0, Style.dim)], width: width) }
        }
        lines.append("")
        for row in rows {
            lines.append(rule)
            lines.append(SidebarView.paint([(row.kept ? " ✓ " : " − ", Style.bold + (row.kept ? green : red)),
                                            (row.title, Style.bold)], width: width))
            lines.append(SidebarView.paint([("   " + row.detail, Style.dim)], width: width))
        }
        if !rows.isEmpty { lines.append(rule) }
        if let warning {
            lines += TranscriptRenderer.wrap("ⓘ " + warning, width: max(width - 2, 1))
                .map { SidebarView.paint([(" " + $0, red)], width: width) }
        }
        lines.append("")
        let actionLabel = "[ \(action) ]"
        let cancelLabel = "[ Cancel ]"
        lines.append(SidebarView.paint([(" ", ""), (actionLabel, Style.bold + (isDestructive ? red : green) + (onAction ? Style.reverse : "")),
                                        ("  ", ""), (cancelLabel, onAction ? "" : Style.reverse)], width: width))
        let height = max(size.rows - 1, 1)
        let shown = Array(lines.prefix(height))
        let footer = SidebarView.paint([(" enter \(onAction ? action.lowercased() : "cancel") · tab switch · esc cancel",
                                         Style.dim)], width: width)
        return shown + Array(repeating: "", count: max(height - shown.count, 0)) + [footer]
    }
}
