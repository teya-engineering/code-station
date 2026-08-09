import ServiceManagement
import SwiftUI

// Whether macOS launches the app when the user logs in. The system owns this state, so
// it is read back from the service rather than stored by us.
@MainActor
@Observable
final class LoginItem {
    private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    private(set) var failure: String?

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    // Registering only works for an app bundle, so a binary run straight from the build
    // folder gets an error here rather than a toggle that silently does nothing.
    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        refresh()
    }
}

// What the app itself does, as opposed to what a session runs with. It is observed
// rather than read from UserDefaults where it is needed, so the sidebar's offer to clear
// old sessions follows the threshold the moment it is changed.
@MainActor
@Observable
final class AppSettings {
    var oldSessionDays = Preferences.oldSessionDays {
        didSet { Preferences.oldSessionDays = oldSessionDays }
    }

    var skillsRefreshInterval = Preferences.skillsRefreshInterval {
        didSet { Preferences.skillsRefreshInterval = skillsRefreshInterval }
    }

    var projectSort = Preferences.projectSort {
        didSet { Preferences.projectSort = projectSort }
    }
}

// Settings is a setup job rather than somewhere to sit, so it is a sheet over the
// window, the way the MCP config manager is.
struct SettingsView: View {
    @Environment(LoginItem.self) private var loginItem
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var reviewingOldSessions = false
    @State private var showingLog = false
    @State private var tab = SettingsTab.general

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch tab {
                    case .general:
                        oldSessions
                        skillRefresh
                        defaultAgent
                        startAtLogin
                        log
                    case .agents:
                        AgentSettingsView()
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 560)
            SheetFooter { dismiss() }
        }
        .frame(width: 520)
        .background(Theme.background)
        .onAppear { loginItem.refresh() }
        .sheet(isPresented: $reviewingOldSessions) { OldSessionsView().appOverlays() }
        .sheet(isPresented: $showingLog) { LogView().appOverlays() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Settings").font(.serif(16))
            Text(tab.note)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { choice in
                ChoicePill(title: choice.title, selected: tab == choice) { tab = choice }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .headerBand(height: Theme.subHeaderHeight)
    }

    // MARK: - The app itself

    // The threshold only decides what gets offered up for review. Nothing acts on it on
    // its own, which is why the number can be moved freely without asking what it will do.
    private var oldSessions: some View {
        let days = settings.oldSessionDays
        let stale = OldSessions.olderThan(days, in: store.sessions).count

        return ChoiceBlock("OLD SESSIONS") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Count a session as old after")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Counted from its last turn. The sidebar offers to clear them; nothing is ever deleted without asking.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        Text(dayTitle(days))
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
                    .contentShape(Rectangle())
                    .appMenu(matchWidth: true) {
                        OldSessions.dayOptions.map { days in
                            .item(dayTitle(days), checked: settings.oldSessionDays == days) {
                                settings.oldSessionDays = days
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))

                HStack(spacing: 10) {
                    Text(stale == 0
                         ? "Nothing is older than that right now."
                         : "\(stale) session\(stale == 1 ? " is" : "s are") older than that right now.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Review them…") { reviewingOldSessions = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .disabled(stale == 0)
                        .opacity(stale == 0 ? 0.4 : 1)
                }
            }
        }
    }

    private func dayTitle(_ days: Int) -> String {
        "\(days) day\(days == 1 ? "" : "s")"
    }

    private var skillRefresh: some View {
        ChoiceBlock("SKILLS") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Refresh the skills list")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Checks the marketplace for new versions. You can still refresh it from Skills at any time.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Text(settings.skillsRefreshInterval.title)
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
                .contentShape(Rectangle())
                .appMenu(matchWidth: true) {
                    SkillsRefreshInterval.allCases.map { interval in
                        .item(interval.title,
                              checked: settings.skillsRefreshInterval == interval) {
                            settings.skillsRefreshInterval = interval
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
        }
    }

    private var startAtLogin: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { loginItem.isEnabled },
                                 set: { loginItem.set($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start at login")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Opens Teya Conductor when you log in, so sessions are there waiting.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.appSwitch)

            if let failure = loginItem.failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var defaultAgent: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Default agent")
                    .font(.system(size: 13, weight: .semibold))
                Text("New sessions use this agent unless you choose a different one when creating them.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text(runner.agent.title)
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
            .contentShape(Rectangle())
            .appMenu(matchWidth: true) {
                AgentKind.allCases.map { agent in
                    .item(agent.title,
                          checked: runner.agent == agent,
                          subtitle: agent == .codex
                              ? "OpenAI's coding agent."
                              : "Anthropic's coding agent.") {
                        runner.agent = agent
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // A turn that stops moving looks the same as one that is working, and the transcript
    // keeps no record of the difference. This is where that record is.
    private var log: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Session log")
                    .font(.system(size: 13, weight: .semibold))
                Text("Every line Claude Code sent, and what the app did with it. Worth opening when a turn seems stuck.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Open") { showingLog = true }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Button("Reveal") { SessionLog.revealInFinder() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum SettingsTab: CaseIterable {
    case general
    case agents

    var title: String {
        switch self {
        case .general: "General"
        case .agents: "Agents"
        }
    }

    var note: String {
        switch self {
        case .general: "Settings for Teya Conductor."
        case .agents: "Choose an agent and set how it runs."
        }
    }
}

// The permission modes the CLI takes, minus the ones that have no place in a desktop app:
// nothing here can turn every check off.
enum PermissionMode {
    static let all: [(mode: String, title: String, short: String, detail: String)] = [
        ("acceptEdits", "Accept edits, ask about the rest", "Accept edits",
         "Edits to files go through on their own. Commands and anything else are asked about."),
        ("manual", "Ask about everything", "Ask everything",
         "Every edit and every command waits for an answer. The slowest, and the one that shows the most."),
        ("auto", "Ask only about risky things", "Ask risky only",
         "Claude Code judges each step and only asks about the ones that can do damage."),
    ]

    static func title(of mode: String?) -> String {
        all.first { $0.mode == mode }?.title ?? mode ?? "Accept edits, ask about the rest"
    }

    // What the mode is called where a sentence does not fit, like the composer bar.
    static func shortTitle(of mode: String?) -> String {
        all.first { $0.mode == mode }?.short ?? mode ?? "Accept edits"
    }

    static func explanation(of mode: String?) -> String {
        all.first { $0.mode == mode }?.detail ?? ""
    }
}
