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

    var projectSort = Preferences.projectSort {
        didSet { Preferences.projectSort = projectSort }
    }
}

// Settings is a setup job rather than somewhere to sit, so it is a sheet over the
// window, the way the MCP config manager is.
//
// Everything about how the agent runs is decided here once, for every session. A session
// can still step away from any of it in its own Settings tab, which is why the same
// choices appear in both places: this is the default, that is the exception.
struct SettingsView: View {
    @Environment(LoginItem.self) private var loginItem
    @Environment(SessionRunner.self) private var runner
    @Environment(ProjectStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var reviewingOldSessions = false
    @State private var showingLog = false

    private var defaults: SessionSettings { runner.defaults }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    model
                    effort
                    permissions
                    Divider().overlay(Theme.hairline)
                    oldSessions
                    startAtLogin
                    log
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
            Text("What every session runs with. A session can override any of it for itself.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    private func change(_ edit: (inout SessionSettings) -> Void) {
        var updated = runner.defaults
        edit(&updated)
        runner.defaults = updated
    }

    // MARK: - How the agent runs

    private var model: some View {
        ChoiceBlock("MODEL", note: "Applies from each session's next turn on.") {
            VStack(spacing: 4) {
                ForEach(ModelChoice.all, id: \.title) { choice in
                    OptionRow(title: choice.title,
                              detail: choice.detail,
                              selected: defaults.model == choice.id) {
                        change { $0.model = choice.id }
                    }
                }
            }
        }
    }

    private var effort: some View {
        ChoiceBlock("EFFORT", note: "How long the model thinks before it answers. More effort costs more tokens and more time, so it is the first thing to turn down when a limit is close.") {
            HStack(spacing: 4) {
                ForEach(EffortChoice.all, id: \.title) { choice in
                    ChoicePill(title: choice.title, selected: defaults.effort == choice.id) {
                        change { $0.effort = choice.id }
                    }
                }
            }
        }
    }

    // How much the agent asks before it acts. Whatever it does ask goes to the session it
    // is running in, so a stricter mode means more cards in the chat, not a stuck turn.
    private var permissions: some View {
        ChoiceBlock("PERMISSIONS") {
            VStack(spacing: 4) {
                ForEach(PermissionMode.all, id: \.mode) { choice in
                    OptionRow(title: choice.title,
                              detail: choice.detail,
                              selected: (defaults.permissionMode ?? "acceptEdits") == choice.mode) {
                        change { $0.permissionMode = choice.mode }
                    }
                }
            }
        }
    }

    // MARK: - The app itself

    // The threshold only decides what gets offered up for review. Nothing acts on it on
    // its own, which is why the number can be moved freely without asking what it will do.
    private var oldSessions: some View {
        @Bindable var settings = settings
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
                    DayStepper(days: $settings.oldSessionDays)
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
                        .controlSize(.small)
                        .disabled(stale == 0)
                }
            }
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
            .toggleStyle(.switch)

            if let failure = loginItem.failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
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
                .controlSize(.small)
            Button("Reveal") { SessionLog.revealInFinder() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// A number small enough to nudge rather than type. The value sits between its two
// buttons so the strip reads as one control rather than as a label with controls beside it.
private struct DayStepper: View {
    @Binding var days: Int

    var body: some View {
        HStack(spacing: 0) {
            button("minus", by: -1, enabled: days > OldSessions.dayRange.lowerBound)
            Divider().overlay(Theme.hairline).frame(height: 26)
            Text("\(days)d")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .frame(width: 46)
            Divider().overlay(Theme.hairline).frame(height: 26)
            button("plus", by: 1, enabled: days < OldSessions.dayRange.upperBound)
        }
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    private func button(_ symbol: String, by step: Int, enabled: Bool) -> some View {
        Button {
            days = min(max(days + step, OldSessions.dayRange.lowerBound),
                       OldSessions.dayRange.upperBound)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// The permission modes the CLI takes, minus the ones that have no place in a desktop app:
// nothing here can turn every check off.
enum PermissionMode {
    static let all: [(mode: String, title: String, detail: String)] = [
        ("acceptEdits", "Accept edits, ask about the rest",
         "Edits to files go through on their own. Commands and anything else are asked about."),
        ("manual", "Ask about everything",
         "Every edit and every command waits for an answer. The slowest, and the one that shows the most."),
        ("auto", "Ask only about risky things",
         "Claude Code judges each step and only asks about the ones that can do damage."),
    ]

    static func title(of mode: String?) -> String {
        all.first { $0.mode == mode }?.title ?? mode ?? "Accept edits, ask about the rest"
    }

    static func explanation(of mode: String?) -> String {
        all.first { $0.mode == mode }?.detail ?? ""
    }
}
