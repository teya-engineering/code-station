import CodeStationCore
import Foundation
import TerminalKit
import TerminalTranscript

// The old-sessions review, drawn over everything, as the GUI's `OldSessionsView` sheet:
// the sessions past the shared age by project, each with what deleting it costs, the
// harmless ones ticked. A project can be snoozed for a day, or woken. Under the list, the
// cards the sheet puts there, and over it the sweep's countdown while one runs.
//
// View state only: the review as the station last answered, the ticks, and the pointer.
// Deleting, snoozing and waking go to the station (see `CleanupActions`).
struct OldSessionsScreen {
    // Nil until the station has answered: reading costs a git look at every worktree.
    private(set) var review: RemoteOldSessions?
    private(set) var ticked: Set<String> = []
    private var selected = 0
    private var top = 0
    // What the station said last, until the next key: a refusal, or work under way.
    var notice: String?
    // Deleting, so no second deletion can start.
    var isDeleting = false

    // One line the pointer can rest on: a project's heading or one of its sessions.
    private enum Line {
        case group(RemoteOldSessions.Group)
        case session(RemoteOldSessions.Session, RemoteOldSessions.Group)
    }

    // Shows a fresh read. Ticks the person set on sessions still listed stay; the
    // station's own picks are taken only on the first read.
    mutating func show(_ review: RemoteOldSessions) {
        let listed = Set(review.groups.flatMap(\.sessions).map(\.id))
        if self.review == nil {
            ticked = Set(review.groups.flatMap(\.sessions).filter(\.isTicked).map(\.id))
        } else {
            ticked.formIntersection(listed)
        }
        self.review = review
        selected = min(selected, max(lines.count - 1, 0))
    }

    private var lines: [Line] {
        guard let review else { return [] }
        return review.groups.flatMap { group -> [Line] in
            [.group(group)] + (group.isSnoozed ? [] : group.sessions.map { .session($0, group) })
        }
    }

    // The sessions a deletion would take: ticked, in a project that is awake.
    var chosen: [RemoteOldSessions.Session] {
        (review?.awakeSessions ?? []).filter { ticked.contains($0.id) }
    }

    enum Outcome: Equatable {
        case handled, ignored, close, reread
        case delete
        // The project to snooze for a day, or to wake.
        case snooze(String), wake(String)
    }

    mutating func handle(_ key: Key, rows height: Int) -> Outcome {
        notice = nil
        switch key {
        case .escape, .char("q", []): return isDeleting ? .handled : .close
        case .up, .char("k", []), .char("p", .ctrl): move(by: -1)
        case .down, .char("j", []), .char("n", .ctrl): move(by: 1)
        case .pageUp: move(by: -max(height - 6, 1))
        case .pageDown: move(by: max(height - 6, 1))
        case .home, .char("g", []): selected = 0
        case .end, .char("G", []): selected = max(lines.count - 1, 0)
        case .char(" ", []), .char("x", []): toggle()
        case .char("r", []): return .reread
        case .char("z", []):
            guard let group = selectedGroup, !isDeleting else { return .handled }
            return .snooze(group.projectID)
        case .char("w", []):
            guard let group = selectedGroup, group.isSnoozed, !isDeleting else { return .handled }
            return .wake(group.projectID)
        case .char("d", []), .enter([]):
            guard !isDeleting else { return .handled }
            guard !chosen.isEmpty else {
                notice = "Tick a session first."
                return .handled
            }
            return .delete
        default: return .ignored
        }
        return .handled
    }

    private var selectedGroup: RemoteOldSessions.Group? {
        guard lines.indices.contains(selected) else { return nil }
        switch lines[selected] {
        case .group(let group), .session(_, let group): return group
        }
    }

    private mutating func move(by step: Int) {
        selected = min(max(selected + step, 0), max(lines.count - 1, 0))
    }

    private mutating func toggle() {
        guard !isDeleting, lines.indices.contains(selected),
              case .session(let session, _) = lines[selected] else { return }
        guard session.canSelect else {
            notice = "Git could not say what \(session.title) would lose, so it cannot be ticked."
            return
        }
        if ticked.contains(session.id) { ticked.remove(session.id) } else { ticked.insert(session.id) }
    }

    // MARK: - Drawing

    mutating func frame(size: TerminalSize, cleanup: RemoteCleanup?, now: Date, theme: TranscriptTheme) -> [String] {
        let width = max(size.cols, 10)
        let red = Style.code(.state(.failed), theme: theme)
        let days = review?.days ?? cleanup?.oldSessionDays ?? 0
        var head = [SidebarView.paint([(" Sessions older than \(counted(days, "day"))", Style.bold)], width: width)]
        if let deleting = cleanup?.oldSessionsDeleting, let at = cleanup?.oldSessionsDeletingAt {
            let urgent = CleanupCountdown.isUrgent(until: at, now: now)
            head.append(SidebarView.paint([(" \(counted(deleting, "session")) will be deleted automatically · ⏱ "
                                            + CleanupCountdown.text(until: at, now: now),
                                            urgent ? red : Style.yellow)], width: width))
        }
        head.append(SidebarView.paint([(" Ticked sessions are removed from the app. Change the \(counted(days, "day")) in Settings.",
                                        Style.dim)], width: width))
        head.append("")

        var body: [String] = []
        var pointerRow = 0
        if let review {
            for (index, line) in lines.enumerated() {
                let picked = index == selected
                if picked { pointerRow = body.count }
                switch line {
                case .group(let group):
                    if index > 0 { body.append("") ; if picked { pointerRow = body.count } }
                    body.append(groupLine(group, picked: picked, width: width))
                case .session(let session, _):
                    body.append(contentsOf: sessionLines(session, picked: picked, width: width, theme: theme))
                }
            }
            if review.groups.isEmpty {
                body.append(SidebarView.paint([(" No session is older than \(counted(days, "day")).", Style.dim)], width: width))
            }
            for notice in review.notices {
                body.append("")
                body += TranscriptRenderer.wrap("ⓘ " + notice, width: max(width - 2, 1))
                    .map { SidebarView.paint([(" " + $0, notice.contains("uncommitted") || notice.contains("never implemented")
                                                ? red : Style.dim)], width: width) }
            }
        } else {
            body.append(SidebarView.paint([(" Reading old sessions…", Style.dim)], width: width))
        }

        let footerRows = 2
        let height = max(size.rows - head.count - footerRows, 1)
        if pointerRow < top { top = pointerRow }
        if pointerRow >= top + height - 1 { top = pointerRow - height + 2 }
        top = max(min(top, max(body.count - height, 0)), 0)
        let shown = Array(body.dropFirst(top).prefix(height))
        let count = chosen.count
        let button = isDeleting ? "[ Deleting… ]" : "[ \(OldSessions.deleteLabel(count)) ]"
        let footnote = SidebarView.paint([(" ", ""), (button, Style.bold + (count > 0 ? red : Style.dim)),
                                          ("  Project folders stay on disk.", Style.dim)], width: width)
        let keys = notice.map { SidebarView.paint([(" " + $0, Style.yellow)], width: width) }
            ?? SidebarView.paint([(" space tick · d delete ticked · z snooze 1 day · w wake · esc close", Style.dim)],
                                 width: width)
        return head + shown + Array(repeating: "", count: max(height - shown.count, 0)) + [footnote, keys]
    }

    // "▸ alpha  2 sessions" or "  beta  1 session · alpha snoozed until tomorrow · back on 15 Sep"
    private func groupLine(_ group: RemoteOldSessions.Group, picked: Bool, width: Int) -> String {
        var runs: [(String, String)] = [(picked ? "▸ " : "  ", ""), (group.name, Style.bold),
                                        ("  " + counted(group.sessions.count, "session"), Style.dim)]
        if let until = group.snoozedUntil {
            runs.append(("  ☾ " + ProjectSnooze.title(group.name, until: until), Style.dim))
            runs.append((" · back on " + ProjectSnooze.wakeDay(until), Style.dim))
        }
        return SidebarView.paint(runs, width: width, reversed: picked)
    }

    // "  [✓] Fix the login bug   history only", then its detail, dim, coloured by cost.
    private func sessionLines(_ session: RemoteOldSessions.Session, picked: Bool, width: Int,
                              theme: TranscriptTheme) -> [String] {
        let tint = switch session.tone {
        case .quiet: Style.dim
        case .files: Style.yellow
        case .loss: Style.code(.state(.failed), theme: theme)
        }
        let box = !session.canSelect ? "[-]" : ticked.contains(session.id) ? "[✓]" : "[ ]"
        let first = SidebarView.paint([(picked ? "  ▸ " : "    ", ""), (box + " ", ""), (session.title, Style.bold),
                                       (session.hasWorktree ? "  WT" : "", Style.dim),
                                       ("   " + session.cost, tint)], width: width, reversed: picked)
        let second = SidebarView.paint([("        " + session.detail, tint)], width: width)
        return [first, second]
    }
}
