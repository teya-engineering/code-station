import CodeStationCore
import Foundation
import TerminalKit
import TerminalTranscript

// The top bar over an open session, as the GUI's identity deck draws it. The first row
// names the session (its container, a TROUBLESHOOT mark, its title) and says what it is
// doing (the state word with how long it has been in it, the agents at work or failed,
// then the facts: branch, changes, pull requests, model, context and cost). Under it a
// one-row context bar fills with the context window, and under that the tab row, as the
// GUI's destination deck: each tab with the number key that reaches it. A session that
// cannot work as it is (a missing folder, a lost checkout, an agent not installed) gets
// the GUI's warning strip as one more row.
//
// Like the GUI's `ViewThatFits`, the row is drawn whole when everything fits and folded
// otherwise: the facts give way to a Details entry, which `D` opens (see `FactsView`).
// The title is what gives way first in either fit.
struct TopBarView {
    let header: RemoteHeader
    // The state word the transcript would rather show, such as STOPPING after Esc.
    var stateOverride: String?
    let theme: TranscriptTheme
    // The tab on screen, picked out in the tab row.
    var selectedTab: RemoteSessionTab.Kind = .chat

    // The rows this bar takes: the identity row, the context bar, the tab row, and the
    // warning strip when there is something to warn about.
    var rows: Int { warning == nil ? 3 : 4 }

    private var warning: RemoteWarning? { header.warnings?.first }
    // How much of the title the whole fit keeps before the facts fold instead, as the
    // GUI fits its row around a stub of the title rather than the whole of it.
    static let titleStub = 12

    // The key that opens the facts, shown on the folded entry.
    static let detailsEntry = "Details (D)"

    func lines(width: Int, now: Date) -> [String] {
        let width = max(width, 1)
        let rows = [identityRow(width: width, now: now), contextBar(width: width), tabRow(width: width)]
        return rows + (warning.map { [warningStrip($0, width: width)] } ?? [])
    }

    // MARK: - The warning strip

    // " ⚠ Folder not found at ~/alpha. Move it back or remove the project.", in amber.
    private func warningStrip(_ warning: RemoteWarning, width: Int) -> String {
        SidebarView.paint(Self.fit([(" ⚠ ", Style.yellow), (warning.message, Style.yellow),
                                    (warning.canRebuild ? "  R rebuild" : "", Style.bold + Style.yellow)], to: width),
                          width: width)
    }

    // MARK: - The tab row

    // " 1 Chat  2 Design  3 Troubleshoot  4 Changes +3 −1  5 Explorer", the tab on screen
    // in bold and the others dim, as the GUI underlines the one it shows.
    private func tabRow(width: Int) -> String {
        var runs: [Run] = [(" ", "")]
        for (index, tab) in SessionTabs.tabs(of: header).enumerated() {
            if index > 0 { runs.append(("  ", "")) }
            let selected = tab.kind == selectedTab
            runs.append(("\(index + 1) ", Style.dim))
            runs.append((tab.title, selected ? Style.bold + Style.cyan : ""))
            if tab.hasContent == true { runs.append(("•", Style.cyan)) }
            if tab.kind == .changes, header.added > 0 || header.removed > 0 {
                runs.append((" +\(header.added)", Style.green))
                runs.append((" −\(header.removed)", Style.red))
            }
        }
        // The actions of the top bar sit at the end of the row, while there is room.
        let actions = actionRuns()
        let gap = width - Self.width(of: runs) - Self.width(of: actions) - 1
        if !actions.isEmpty, gap >= 2 {
            runs += [(String(repeating: " ", count: gap), "")] + actions
        }
        return SidebarView.paint(Self.fit(runs, to: width), width: width)
    }

    // "a agents · / find · C compact · X clear": the top bar's actions on offer now, with
    // their keys. Find is the chat's own.
    private func actionRuns() -> [Run] {
        var actions: [[Run]] = []
        if header.agentToolID != nil { actions.append([("a", Style.cyan), (" agents", Style.dim)]) }
        if selectedTab == .chat { actions.append([("/", Style.cyan), (" find", Style.dim)]) }
        if header.canCompact == true { actions.append([("C", Style.cyan), (" compact", Style.dim)]) }
        if header.canClear == true { actions.append([("X", Style.cyan), (" clear", Style.dim)]) }
        var runs: [Run] = []
        for (index, action) in actions.enumerated() {
            if index > 0 { runs.append((" · ", Style.dim)) }
            runs += action
        }
        return runs
    }

    // MARK: - The identity row

    typealias Run = (text: String, style: String)

    private func identityRow(width: Int, now: Date) -> String {
        let readings = stateRuns(now: now) + agentRuns()
        let facts = factRuns()
        let whole = facts.isEmpty ? readings : readings + [("  ", "")] + facts
        let folded = facts.isEmpty ? readings : readings + [("  ", ""), (Self.detailsEntry, Style.dim)]
        let room = width - Self.width(of: identityRuns(titleRoom: Self.titleStub)) - 2
        let right = Self.width(of: whole) <= room ? whole : folded
        let rightWidth = Self.width(of: right) + 1
        // The left side takes what the readings leave, the title giving way first.
        let left = identityRuns(titleRoom: max(width - rightWidth - 2 - Self.width(of: identityRuns(titleRoom: 0)), 0))
        let leftText = Self.fit(left, to: max(width - rightWidth - 1, 1))
        let gap = max(width - Self.width(of: leftText) - rightWidth, 1)
        return SidebarView.paint(leftText + [(String(repeating: " ", count: gap), "")] + right + [(" ", "")],
                                 width: width)
    }

    // The container's glyph and name, a slash, the troubleshoot mark and the title, cut
    // to `titleRoom` columns of title.
    private func identityRuns(titleRoom: Int) -> [Run] {
        let glyph = switch header.containerKind {
        case .task: "□"
        case .workspace: "▤"
        case .project, nil: "■"
        }
        var runs: [Run] = [(" " + glyph + " ", ""), (header.container ?? header.project, Style.bold),
                           (" / ", Style.dim)]
        if header.isTroubleshooting == true {
            runs.append(("TROUBLESHOOT", Style.bold + Style.code(.syntax(.keyword), theme: theme)))
            runs.append((" ", ""))
        }
        let title = TerminalColumns.width(of: header.title) <= titleRoom
            ? header.title : TerminalColumns.fit(header.title, to: max(titleRoom, 1))
        if titleRoom > 0 { runs.append((title, "")) }
        return runs
    }

    // "● RUNNING · 41s", "IDLE · 5m": the state word and, while a turn runs or waits,
    // how long it has gone on, counted each second; otherwise how long ago it moved.
    private func stateRuns(now: Date) -> [Run] {
        var word = stateOverride ?? (header.failure == nil ? header.state : "FAILED")
        if word == "RUNNING", header.isTroubleshooting == true { word = "DIAGNOSING" }
        let ticking = header.failure == nil && (header.state == "RUNNING" || header.state == "WAITING")
        let time = ticking ? Self.duration(since: header.since, now: now)
            : SidebarView.age(since: header.since, now: now)
        let style = Style.state(word, theme: theme)
        return [("● ", style), (word, style), (" · " + time, Style.dim)]
    }

    // "2 agents running" in the accent, or "1 agent failed" in red, as the GUI's agents
    // indicator reads.
    private func agentRuns() -> [Run] {
        let running = header.agentsRunning ?? 0
        let failed = header.agentsFailed ?? 0
        if running > 0 {
            return [("  ", ""), (Self.counted(running, "agent") + " running", Style.cyan)]
        }
        if failed > 0 {
            return [("  ", ""), (Self.counted(failed, "agent") + " failed", Style.red)]
        }
        return []
    }

    // The facts that have something to say, one after another.
    private func factRuns() -> [Run] {
        var facts: [[Run]] = []
        if let branch = header.branch, !branch.isEmpty { facts.append([("⎇ " + branch, "")]) }
        if let changes = Self.changes(header) { facts.append(changes) }
        if let pullRequests = header.pullRequests, !pullRequests.isEmpty {
            facts.append([(pullRequests.map { "#\($0.number)" }.joined(separator: " "), Style.cyan)])
        }
        if let model = header.model { facts.append([(model, "")]) }
        if let context = header.context {
            facts.append([(Self.percent(context) + " context", Style.code(contextStyle(context), theme: theme))])
        }
        if let cost = header.cost { facts.append([(Self.cost(cost), "")]) }
        var runs: [Run] = []
        for (index, fact) in facts.enumerated() {
            if index > 0 { runs.append((" · ", Style.dim)) }
            runs += fact
        }
        return runs
    }

    // MARK: - The context bar

    // As long as the context fraction, on a dim track the width of the bar.
    private func contextBar(width: Int) -> String {
        guard let context = header.context else {
            return Style.dim + String(repeating: "─", count: width) + Style.reset
        }
        let filled = min(max(Int((context * Double(width)).rounded()), 0), width)
        return Style.code(contextStyle(context), theme: theme) + String(repeating: "━", count: filled) + Style.reset
            + Style.dim + String(repeating: "─", count: width - filled) + Style.reset
    }

    // Green, then amber from 70%, then red from 85% for an agent that asks for permissions.
    // Codex and Copilot make their own room as the window fills, so a full one there is
    // worth noticing rather than a failure waiting to happen.
    private func contextStyle(_ fraction: Double) -> LineStyle {
        let asksPermissions = AgentKind.allCases.first { $0.title == header.agent }?.asksPermissions ?? true
        switch Int((fraction * 100).rounded()) {
        case 85...: return asksPermissions ? .removed : .toolRunning
        case 70...: return .toolRunning
        default: return .added
        }
    }

    // MARK: - Readings

    // "1 file +3 −1", or "+3 −1" before the tree has been read. Nil with nothing changed.
    static func changes(_ header: RemoteHeader) -> [Run]? {
        let files = header.files ?? 0
        guard files > 0 || header.added > 0 || header.removed > 0 else { return nil }
        var runs: [Run] = []
        if files > 0 { runs.append((counted(files, "file") + " ", "")) }
        runs.append(("+\(header.added)", Style.green))
        runs.append((" −\(header.removed)", Style.red))
        return runs
    }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    static func cost(_ dollars: Double) -> String { String(format: "$%.2f", dollars) }

    static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)" + (count == 1 ? "" : "s")
    }

    // "41s", "2m", "1h": a length of time, for the readings that count seconds. It stops
    // at days, as the GUI's does.
    static func duration(since date: Date, now: Date) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        switch seconds {
        case ..<60: return "\(Int(seconds))s"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }

    private static func width(of runs: [Run]) -> Int {
        runs.reduce(0) { $0 + TerminalColumns.width(of: $1.text) }
    }

    // The runs cut to `width` columns, the last one cut short where they run over.
    private static func fit(_ runs: [Run], to width: Int) -> [Run] {
        var out: [Run] = []
        var used = 0
        for run in runs where used < width {
            let text = TerminalColumns.width(of: run.text) > width - used
                ? TerminalColumns.fit(run.text, to: width - used) : run.text
            used += TerminalColumns.width(of: text)
            out.append((text, run.style))
        }
        return out
    }
}
