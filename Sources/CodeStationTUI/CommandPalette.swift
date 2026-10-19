import CodeStationCore
import Foundation
import TerminalKit
import TerminalTranscript

// The command palette, the terminal's version of the GUI's ⌘K palette: one line to type
// on over a list of sessions, projects and actions, narrowed as the person types and
// grouped as the GUI groups it (Needs you, Recent, Projects, Actions). Enter goes to the
// one picked; what going there means is the app's, so the palette only says which.
//
// Matching follows the GUI's: every typed word must turn up in what a result says, case
// and accents aside. A word can also match as letters the title holds in that order, so
// "flb" finds "Fix the login bug". Results rank as the GUI ranks them: by group, then how
// well the title matches, then the most recent.
//
// View state only: the directory it was opened over, the query, the kind shown and which
// result is picked (by what it goes to, so narrowing keeps the pick where it can).
struct CommandPalette {
    enum Destination: Hashable {
        case session(id: String)
        case container(id: String)
        case action(Action)
    }

    enum Action: CaseIterable {
        case newSession, home, back, forward, keys, settings
    }

    enum Kind: CaseIterable {
        case all, sessions, projects, actions

        var title: String {
            switch self {
            case .all: "All"
            case .sessions: "Sessions"
            case .projects: "Projects"
            case .actions: "Actions"
            }
        }
    }

    enum Group: Int, CaseIterable {
        case needsYou, recent, projects, actions

        var title: String {
            switch self {
            case .needsYou: "NEEDS YOU"
            case .recent: "RECENT"
            case .projects: "PROJECTS"
            case .actions: "ACTIONS"
            }
        }
    }

    struct Item {
        let destination: Destination
        let kind: Kind
        let group: Group
        let glyph: (String, String)
        let title: String
        let subtitle: String
        var keywords = ""
        var badge = ""
        var needsAttention = false
        var activity: Date?
        // Conversation a session's card speaks for, for a session result.
        var conversation: RemoteCommand.Conversation = .main

        var searchable: String { CommandPalette.fold([title, subtitle, keywords].joined(separator: " ")) }
    }

    private let items: [Item]
    private(set) var field = ComposerView()
    private(set) var kind = Kind.all
    private var picked: Destination?
    private var top = 0

    init(directory: RemoteDirectory?, theme: TranscriptTheme) {
        items = Self.items(in: directory, theme: theme)
        picked = results.first?.destination
    }

    var query: String { field.string }

    // MARK: - Results

    var results: [Item] {
        let words = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        return items.enumerated().compactMap { index, item -> (Item, Int, Int)? in
            guard kind == .all || item.kind == kind else { return nil }
            guard let score = Self.score(item, words: words) else { return nil }
            return (item, score, index)
        }
        .sorted { lhs, rhs in
            if lhs.0.group != rhs.0.group { return lhs.0.group.rawValue < rhs.0.group.rawValue }
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.2 < rhs.2
        }
        .map(\.0)
    }

    // How well the item matches, lower being better, or nil when a word does not match.
    // A title equal to the query beats one starting with it, which beats one holding it;
    // a match elsewhere comes next, and letters in order last.
    static func score(_ item: Item, words: [String]) -> Int? {
        guard !words.isEmpty else { return 0 }
        let haystack = item.searchable
        let title = fold(item.title)
        var fuzzy = false
        for word in words where !haystack.contains(word) {
            guard isSubsequence(word, of: title) else { return nil }
            fuzzy = true
        }
        if fuzzy { return 4 }
        let query = words.joined(separator: " ")
        if title == query { return 0 }
        if title.hasPrefix(query) { return 1 }
        if title.contains(query) { return 2 }
        return 3
    }

    private static func isSubsequence(_ word: String, of text: String) -> Bool {
        var rest = text[...]
        for character in word {
            guard let found = rest.firstIndex(of: character) else { return false }
            rest = rest[rest.index(after: found)...]
        }
        return true
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    var pickedItem: Item? {
        let results = results
        return results.first { $0.destination == picked } ?? results.first
    }

    // MARK: - Keys

    enum Outcome { case edited, go(Item), close, ignored }

    mutating func handle(_ key: Key, rows: Int) -> Outcome {
        switch key {
        case .escape: return .close
        case .enter([]):
            guard let item = pickedItem else { return .edited }
            return .go(item)
        case .up, .char("p", .ctrl): move(by: -1)
        case .down, .char("n", .ctrl): move(by: 1)
        case .pageUp: move(by: -max(rows - 6, 1))
        case .pageDown: move(by: max(rows - 6, 1))
        case .tab([]): changeKind(by: 1)
        case .tab(.shift): changeKind(by: -1)
        case .enter, .char("j", .ctrl): return .ignored
        case .paste(let text):
            return edit(.paste(text.split(whereSeparator: \.isNewline).joined(separator: " ")))
        default: return edit(key)
        }
        return .edited
    }

    private mutating func edit(_ key: Key) -> Outcome {
        guard field.handle(key) != .ignored else { return .ignored }
        picked = results.first?.destination
        top = 0
        return .edited
    }

    private mutating func move(by offset: Int) {
        let results = results
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.destination == picked } ?? 0
        picked = results[min(max(current + offset, 0), results.count - 1)].destination
    }

    private mutating func changeKind(by offset: Int) {
        let kinds = Kind.allCases
        let index = kinds.firstIndex(of: kind) ?? 0
        kind = kinds[(index + offset + kinds.count) % kinds.count]
        picked = results.first?.destination
        top = 0
    }

    // MARK: - Drawing

    mutating func frame(size: TerminalSize, theme: TranscriptTheme,
                        now: Date = Date()) -> (lines: [String], cursor: Screen.Cursor?) {
        let width = max(size.cols, 10)
        // The query on one line: the one the cursor is on, should it ever wrap.
        let (fieldLines, at) = field.layout(width: max(width - 1, 1))
        let queryLine = " " + fieldLines[min(at.row, fieldLines.count - 1)]
        let kinds = SidebarView.paint(Kind.allCases.flatMap { option -> [(text: String, style: String)] in
            [(" ", ""), (" " + option.title + " ", option == kind ? Style.reverse : Style.dim)]
        }, width: width)
        let header = [SidebarView.paint([(" Go to", Style.bold)], width: width), queryLine, kinds, ""]

        let results = results
        let pickedID = pickedItem?.destination
        var lines: [String] = []
        var pickedLine: Int?
        if results.isEmpty {
            lines = [SidebarView.paint([("  No matching projects, sessions or actions.", Style.dim)], width: width)]
        } else {
            for group in Group.allCases {
                let grouped = results.filter { $0.group == group }
                guard !grouped.isEmpty else { continue }
                if !lines.isEmpty { lines.append("") }
                lines.append(SidebarView.paint([(" " + group.title, Style.bold + Style.dim)], width: width))
                for item in grouped {
                    let isPicked = item.destination == pickedID
                    if isPicked { pickedLine = lines.count }
                    lines.append(draw(item, width: width, picked: isPicked, theme: theme, now: now))
                }
            }
        }
        let height = max(size.rows - header.count - 1, 1)
        if let pickedLine {
            if pickedLine < top { top = max(pickedLine - 1, 0) }
            if pickedLine >= top + height { top = pickedLine - height + 1 }
        }
        top = min(max(top, 0), max(lines.count - height, 0))
        let shown = Array(lines[top..<min(lines.count, top + height)])
        let footer = SidebarView.paint([(" ↑↓ move · enter go · tab kind · esc close", Style.dim)], width: width)
        let all = header + shown + Array(repeating: "", count: max(height - shown.count, 0)) + [footer]
        return (all, Screen.Cursor(row: 1, col: min(1 + at.col, width - 1)))
    }

    private func draw(_ item: Item, width: Int, picked: Bool, theme: TranscriptTheme, now: Date) -> String {
        let marker = picked ? "▸ " : "  "
        var trailing = item.badge.isEmpty ? "" : "  " + item.badge
        if let activity = item.activity { trailing += "  " + SidebarView.age(since: activity, now: now) }
        let prefix = marker + item.glyph.0 + " "
        let room = max(width - TerminalColumns.width(of: prefix) - TerminalColumns.width(of: trailing) - 1, 4)
        let title = TerminalColumns.fit(item.title, to: room)
        let subtitleRoom = max(room - TerminalColumns.width(of: title) - 2, 0)
        let subtitle = subtitleRoom > 3 ? TerminalColumns.fit("  " + item.subtitle, to: subtitleRoom) : ""
        let gap = String(repeating: " ", count: max(room - TerminalColumns.width(of: title)
                                                       - TerminalColumns.width(of: subtitle), 0))
        let badgeStyle = item.needsAttention ? Style.code(.attention, theme: theme) : Style.dim
        return SidebarView.paint([(marker, ""), item.glyph, (" ", ""), (title, Style.bold), (subtitle, Style.dim),
                                  (gap, ""), (trailing, badgeStyle)], width: width, reversed: picked)
    }

    // MARK: - What it lists

    private static func items(in directory: RemoteDirectory?, theme: TranscriptTheme) -> [Item] {
        let containers = directory?.containers ?? []
        var sessions: [Item] = []
        for container in containers {
            for row in container.sessions {
                let reason = HomeView.reason(row)
                let needsAttention = row.needsInput != nil || reason == "finished"
                let badge = row.needsInput != nil ? "ANSWER"
                    : reason == "finished" ? "REVIEW"
                    : HomeView.isRunning(row) ? "RUNNING" : ""
                let word = row.failure == nil ? row.state : "FAILED"
                let node: (String, String) = row.isUnread ? ("●", Style.code(.attention, theme: theme))
                    : ("│", Style.dim)
                sessions.append(Item(destination: .session(id: row.id), kind: .sessions,
                                     group: needsAttention ? .needsYou : .recent, glyph: node,
                                     title: row.title, subtitle: container.name + " · " + word.lowercased(),
                                     keywords: [container.path, row.workspace ?? "", row.branch ?? "", row.agent]
                                         .joined(separator: " "),
                                     badge: badge, needsAttention: needsAttention,
                                     activity: row.lastActivity, conversation: row.conversation))
            }
        }
        sessions.sort { ($0.activity ?? .distantPast) > ($1.activity ?? .distantPast) }

        let projects = containers.map { container -> Item in
            let glyph: String
            let label: String
            switch container.kind {
            case .project: (glyph, label) = ("■", "Project")
            case .task: (glyph, label) = ("□", "Task")
            case .workspace: (glyph, label) = ("▤", "Workspace")
            }
            let count = container.sessions.count
            return Item(destination: .container(id: container.id), kind: .projects, group: .projects,
                        glyph: (glyph, ""), title: container.name,
                        subtitle: "\(label) · \(count) \(count == 1 ? "session" : "sessions")",
                        keywords: container.path, badge: label.uppercased())
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let actions = Action.allCases.map { action -> Item in
            let (title, subtitle, keywords, keys): (String, String, String, [Key]) = switch action {
            case .newSession: ("New session", "Start in the selected project or task", "add start create",
                               [.char("n", [])])
            case .home: ("Home", "What needs you, what is running, recent sessions", "dashboard start",
                         [])
            case .back: ("Back", "The place before this one", "previous history", [.char("[", [])])
            case .forward: ("Forward", "The place after this one", "next history", [.char("]", [])])
            case .keys: ("Keys", "Every key, screen by screen", "help shortcuts bindings",
                         [.char("?", [])])
            case .settings: ("Settings", "Agent defaults, old sessions, memory, sound, sidebar",
                             "preferences options agents sign in login", [.char(",", [])])
            }
            return Item(destination: .action(action), kind: .actions, group: .actions, glyph: ("›", Style.dim),
                        title: title, subtitle: subtitle, keywords: keywords,
                        badge: keys.map(KeyBindings.name(of:)).joined(separator: " "))
        }
        return sessions + projects + actions
    }
}
