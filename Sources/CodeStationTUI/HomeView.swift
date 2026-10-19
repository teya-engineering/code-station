import CodeStationCore
import Foundation
import TerminalKit
import TerminalTranscript

// Home: what the main pane shows when no session is open, the terminal's version of the
// GUI's Home. The GUI draws a work map, an orbit and a day ribbon; a terminal lists the
// same facts: the sessions that need the person, the ones running, and the ones most
// recently at work. Each session is listed once, under the first of those it belongs to.
//
// View state only: the directory the station last sent, which entry is selected (by id,
// so a list that reorders keeps pointing at the same session) and how far it is scrolled.
struct HomeView {
    private(set) var directory: RemoteDirectory?
    private(set) var selectedID: String?
    private var top = 0

    // How many of the quieter sessions are listed under Recent.
    static let recentLimit = 10

    enum Section: CaseIterable {
        case needsYou, running, recent

        var title: String {
            switch self {
            case .needsYou: "NEEDS YOU"
            case .running: "RUNNING"
            case .recent: "RECENT"
            }
        }
    }

    struct Entry {
        let row: RemoteSessionRow
        let container: RemoteContainer
        // Why it needs the person, for an entry under Needs you.
        let reason: String?
    }

    // MARK: - The list

    // What the session waits on the person for, when it does: an agent blocked on a
    // permission or a question, a turn that failed, or one that finished unseen.
    static func reason(_ row: RemoteSessionRow) -> String? {
        if let needsInput = row.needsInput { return needsInput }
        if row.failure != nil || row.state == "FAILED" { return "failed" }
        if row.isUnread || row.state == "NEEDS YOU" { return "finished" }
        return nil
    }

    static func isRunning(_ row: RemoteSessionRow) -> Bool {
        row.state == "RUNNING" || row.state == "WAITING"
    }

    // The entries of each section, newest first, sections with nothing left out.
    var sections: [(section: Section, entries: [Entry])] {
        let all = (directory?.containers ?? []).flatMap { container in
            container.sessions.map { Entry(row: $0, container: container, reason: Self.reason($0)) }
        }.sorted { $0.row.lastActivity > $1.row.lastActivity }
        let needsYou = all.filter { $0.reason != nil }
        let running = all.filter { $0.reason == nil && Self.isRunning($0.row) }
        let recent = all.filter { $0.reason == nil && !Self.isRunning($0.row) }.prefix(Self.recentLimit)
        return [(Section.needsYou, needsYou), (.running, running), (.recent, Array(recent))]
            .filter { !$0.1.isEmpty }
    }

    private var entryIDs: [String] { sections.flatMap { $0.entries.map(\.row.id) } }

    var isEmpty: Bool { entryIDs.isEmpty }

    mutating func show(_ directory: RemoteDirectory) {
        self.directory = directory
        let ids = entryIDs
        if selectedID == nil || !ids.contains(selectedID!) { selectedID = ids.first }
    }

    // The selected session and the conversation its card speaks for.
    var selected: (id: String, conversation: RemoteCommand.Conversation)? {
        guard let selectedID, entryIDs.contains(selectedID) else { return nil }
        let row = directory?.containers?.flatMap(\.sessions).first { $0.id == selectedID }
        return (selectedID, row?.conversation ?? .main)
    }

    // MARK: - Moving

    mutating func move(by offset: Int) {
        let ids = entryIDs
        guard !ids.isEmpty else { return }
        let current = selectedID.flatMap(ids.firstIndex(of:)) ?? 0
        selectedID = ids[min(max(current + offset, 0), ids.count - 1)]
    }

    mutating func moveToFirst() { selectedID = entryIDs.first }
    mutating func moveToLast() { selectedID = entryIDs.last }

    // MARK: - Drawing

    // The list at the main pane's size. The selection only shows while Home has the keys,
    // so it never reads as a second selection beside the sidebar's.
    mutating func frame(size: TerminalSize, focused: Bool, theme: TranscriptTheme,
                        now: Date = Date()) -> [String] {
        let width = max(size.cols, 1)
        let sections = sections
        let count = { (section: Section) in sections.first { $0.section == section }?.entries.count ?? 0 }
        let total = (directory?.containers ?? []).reduce(0) { $0 + $1.sessions.count }
        let needing = count(.needsYou)
        let counts = "\(needing) \(needing == 1 ? "needs" : "need") you · \(count(.running)) running · "
            + "\(total) \(total == 1 ? "session" : "sessions")"
        let header = [SidebarView.paint([(" Home", Style.bold)], width: width),
                      SidebarView.paint([(" " + counts, Style.dim)], width: width), ""]

        var lines: [String] = []
        var selectedLine: Int?
        if directory == nil {
            lines = [SidebarView.paint([("  Loading…", Style.dim)], width: width)]
        } else if sections.isEmpty {
            lines = [SidebarView.paint([("  No sessions yet.", Style.dim)], width: width),
                     SidebarView.paint([("  Press n to start one, or Ctrl-K to find anything.", Style.dim)],
                                       width: width)]
        } else {
            for (section, entries) in sections {
                if !lines.isEmpty { lines.append("") }
                lines.append(SidebarView.paint([(" " + section.title, Style.bold + Style.dim)], width: width))
                for entry in entries {
                    let selected = focused && entry.row.id == selectedID
                    if selected { selectedLine = lines.count }
                    lines.append(draw(entry, width: width, selected: selected, theme: theme, now: now))
                }
            }
        }
        let height = max(size.rows - header.count, 1)
        if let selectedLine {
            if selectedLine < top { top = max(selectedLine - 1, 0) }
            if selectedLine >= top + height { top = selectedLine - height + 1 }
        }
        top = min(max(top, 0), max(lines.count - height, 0))
        return header + Array(lines[top..<min(lines.count, top + height)])
    }

    // One line: the node, the title, then where it is, why it is listed (or its state
    // word) and how long ago.
    private func draw(_ entry: Entry, width: Int, selected: Bool, theme: TranscriptTheme,
                      now: Date) -> String {
        let row = entry.row
        let node: (String, String) = row.isUnread ? ("●", Style.code(.attention, theme: theme))
            : row.isPinned ? ("⚑", "") : ("│", Style.dim)
        let word = row.failure == nil ? row.state : "FAILED"
        let why: (String, String) = entry.reason.map { ($0, Style.code(.attention, theme: theme)) }
            ?? (word, Style.state(word, theme: theme))
        let age = " · " + SidebarView.age(since: row.lastActivity, now: now)
        let place = entry.container.name + " · "
        let factsWidth = TerminalColumns.width(of: place + why.0 + age)
        let prefix = (selected ? "▸ " : "  ") + node.0 + " "
        let room = max(width - TerminalColumns.width(of: prefix) - 2 - factsWidth, min(12, width))
        let title = TerminalColumns.pad(TerminalColumns.fit(row.title, to: room), to: room)
        return SidebarView.paint([(selected ? "▸ " : "  ", ""), node, (" ", ""),
                                  (title, row.isUnread ? Style.bold : ""), ("  " + place, Style.dim),
                                  why, (age, Style.dim)], width: width, reversed: selected)
    }
}
