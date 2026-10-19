import CodeStationCore
import TerminalKit
import TerminalTranscript

// The settings screen, drawn over everything: the settings that matter outside the GUI,
// as the station lists them, each a row whose value is changed with the arrows. Each
// agent's defaults sit under a heading that says whether the agent is ready, and the
// command that makes it so when it is not. An update waiting is said at the top.
//
// View state only: the settings as the station last answered, which row the pointer is
// on and how far the list is scrolled. A change goes to the station, and the screen
// shows what it answers.
struct SettingsScreen {
    private(set) var settings: RemoteSettings
    private var selected = 0
    private var top = 0
    // Why the last change was turned down, until the next key.
    var notice: String?
    // The heading, and whether `r` checks the agents again. A session's run settings
    // (`r` over an open session) are drawn on the same screen under their own heading,
    // and there `r` closes it again.
    var title = "Settings"
    var checksAgents = true

    init(_ settings: RemoteSettings) {
        self.settings = settings
    }

    private var rows: [RemoteSetting] { settings.sections.flatMap(\.settings) }

    var selectedSetting: RemoteSetting? {
        rows.indices.contains(selected) ? rows[selected] : nil
    }

    // The station's answer to a change, or a fresh read, keeping the pointer on its row.
    mutating func show(_ settings: RemoteSettings) {
        let id = selectedSetting?.id
        self.settings = settings
        selected = rows.firstIndex { $0.id == id } ?? min(selected, max(rows.count - 1, 0))
    }

    enum Outcome: Equatable {
        case handled, ignored, close, recheck
        // The setting to change and the value to change it to.
        case change(String, String)
    }

    mutating func handle(_ key: Key, rows height: Int) -> Outcome {
        notice = nil
        switch key {
        case .escape, .char("q", []), .char(",", []): return .close
        case .up, .char("k", []), .char("p", .ctrl), .tab(.shift): move(by: -1)
        case .down, .char("j", []), .char("n", .ctrl), .tab([]): move(by: 1)
        case .pageUp: move(by: -max(height - 4, 1))
        case .pageDown: move(by: max(height - 4, 1))
        case .home, .char("g", []): selected = 0
        case .end, .char("G", []): selected = max(rows.count - 1, 0)
        case .left, .char("h", []): return change(by: -1)
        case .right, .char("l", []), .char(" ", []), .enter([]): return change(by: 1)
        case .char("r", []): return checksAgents ? .recheck : .close
        default: return .ignored
        }
        return .handled
    }

    private mutating func move(by step: Int) {
        selected = min(max(selected + step, 0), max(rows.count - 1, 0))
    }

    // The next or previous choice of the setting under the pointer, going round at the
    // ends.
    private mutating func change(by step: Int) -> Outcome {
        guard let setting = selectedSetting, !setting.choices.isEmpty else { return .handled }
        // A setting with one choice cannot change; its detail says why.
        if setting.choices.count == 1 {
            notice = setting.detail
            return .handled
        }
        let current = setting.choices.firstIndex { $0.value == setting.value } ?? 0
        let count = setting.choices.count
        let next = setting.choices[((current + step) % count + count) % count]
        return next.value == setting.value ? .handled : .change(setting.id, next.value)
    }

    // MARK: - Drawing

    mutating func frame(size: TerminalSize) -> [String] {
        let width = max(size.cols, 10)
        let header = Style.bold + TerminalColumns.fit(" " + title, to: width) + Style.reset
        var lines: [String] = []
        if let update = settings.update {
            lines.append(Style.cyan + TerminalColumns.fit(
                "  ↑ Code Station \(update.version) is available (this is \(update.installed)). Update from the app.",
                to: width) + Style.reset)
        }
        var selectedLine = 0
        var index = 0
        for section in settings.sections {
            lines.append("")
            lines.append(Style.bold + TerminalColumns.fit(" " + section.title, to: width) + Style.reset)
            if let agent = section.agent, let readiness = settings.readiness(of: agent) {
                lines.append(readinessLine(readiness, width: width))
            }
            for setting in section.settings {
                if index == selected { selectedLine = lines.count }
                lines.append(row(setting, selected: index == selected, width: width))
                index += 1
            }
        }

        let height = max(size.rows - 2, 1)
        if selectedLine < top { top = selectedLine }
        if selectedLine >= top + height { top = selectedLine - height + 1 }
        top = min(max(top, 0), max(lines.count - height, 0))
        let shown = Array(lines[min(top, lines.count)..<min(lines.count, top + height)])
        let body = shown + Array(repeating: "", count: max(height - shown.count, 0))

        let keys = checksAgents ? " ↑↓ setting · ←→ change · r check agents again · ? keys · esc close"
            : " ↑↓ setting · ←→ change (from the next turn) · ? keys · esc close"
        let helpText = notice.map { " " + $0 } ?? keys
        let help = (notice == nil ? Style.dim : Style.red) + TerminalColumns.fit(helpText, to: width) + Style.reset
        return [header] + body + [help]
    }

    // Whether the agent can run a session, and what to type when it cannot.
    private func readinessLine(_ readiness: RemoteAgentReadiness, width: Int) -> String {
        if let problem = readiness.problem, let fix = readiness.fix {
            let verb = readiness.installed ? "Run" : "Install"
            return Style.yellow + TerminalColumns.fit("    ! \(problem) \(verb): \(fix)", to: width) + Style.reset
        }
        if readiness.signedIn == true {
            let who = readiness.account.map { " · \($0)" } ?? ""
            return Style.green + TerminalColumns.fit("    ✓ Signed in\(who)", to: width) + Style.reset
        }
        return Style.dim + TerminalColumns.fit("    Installed; sign-in not known yet", to: width) + Style.reset
    }

    private func row(_ setting: RemoteSetting, selected: Bool, width: Int) -> String {
        let marker = selected ? "  ▸ " : "    "
        let labelWidth = min(32, max(width / 3, 12))
        let lead = marker + TerminalColumns.pad(TerminalColumns.fit(setting.title, to: labelWidth - 1), to: labelWidth)
        let shown = "‹ \(setting.valueTitle) ›"
        let leadWidth = TerminalColumns.width(of: lead)
        guard leadWidth + TerminalColumns.width(of: shown) <= width else {
            return TerminalColumns.fit(lead + shown, to: width)
        }
        let value = selected ? Style.reverse + shown + Style.reset : Style.bold + shown + Style.reset
        let room = width - leadWidth - TerminalColumns.width(of: shown) - 2
        let detail = setting.detail.flatMap { room > 0 && selected ? $0 : nil }
            .map { "  " + Style.dim + TerminalColumns.fit($0, to: room) + Style.reset } ?? ""
        return lead + value + detail
    }
}
