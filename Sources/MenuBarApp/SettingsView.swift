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

// Settings is a setup job rather than somewhere to sit, so it is a sheet over the
// window, the way the MCP config manager is.
//
// Everything about how the agent runs is decided here once, for every session. A session
// can still step away from any of it in its own Settings tab, which is why the same
// choices appear in both places: this is the default, that is the exception.
struct SettingsView: View {
    @Environment(LoginItem.self) private var loginItem
    @Environment(SessionRunner.self) private var runner
    @Environment(\.dismiss) private var dismiss

    private var defaults: SessionSettings { runner.defaults }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    model
                    effort
                    permissions
                    Divider().overlay(Theme.hairline)
                    startAtLogin
                }
                .padding(20)
            }
            .frame(maxHeight: 560)
            SheetFooter { dismiss() }
        }
        .frame(width: 520)
        .background(Theme.background)
        .onAppear { loginItem.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Settings").font(.serif(16))
            Text("What every session runs with. A session can override any of it for itself.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
