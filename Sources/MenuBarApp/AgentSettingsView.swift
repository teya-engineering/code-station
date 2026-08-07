import SwiftUI

// The one agent the app can run is Claude Code, so this pane is about that one thing:
// whether the CLI is there, who it is signed in as, and where its own files live. The
// account details come straight from ~/.claude.json rather than from asking the CLI,
// which keeps opening the pane instant; only the version needs a process, and it
// arrives when it arrives.
@MainActor
@Observable
final class ClaudeAgentInfo {
    struct Account {
        var name: String?
        var email: String
        var organization: String?
        var plan: String?
    }

    private(set) var path: String?
    private(set) var version: String?
    private(set) var account: Account?

    init() { refresh() }

    func refresh() {
        path = ProcessManager.resolve("claude")
        account = Self.readAccount()
        version = nil
        fetchVersion()
    }

    // MARK: - Private

    private static func readAccount() -> Account? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["oauthAccount"] as? [String: Any],
              let email = oauth["emailAddress"] as? String else { return nil }
        return Account(name: oauth["displayName"] as? String,
                       email: email,
                       organization: oauth["organizationName"] as? String,
                       plan: planName(oauth["organizationType"] as? String))
    }

    private static func planName(_ type: String?) -> String? {
        switch type {
        case "claude_max": "Claude Max"
        case "claude_pro": "Claude Pro"
        case "claude_team": "Claude Team"
        case "claude_enterprise": "Claude Enterprise"
        default: type?.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func fetchVersion() {
        guard let path else { return }
        let info = self
        let searchPath = ProcessManager.searchPath
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--version"]
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = searchPath
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            // The CLI prints "2.1.220 (Claude Code)"; the number is the part worth keeping.
            let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ").first.map(String.init)
            await MainActor.run { info.version = version }
        }
    }
}

// The Agents tab of the Settings sheet.
struct AgentSettingsView: View {
    @State private var claude = ClaudeAgentInfo()
    @State private var signingIn = false

    private var claudeSettingsPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ChoiceBlock("CLAUDE CODE") {
                VStack(alignment: .leading, spacing: 10) {
                    status
                    if claude.path == nil {
                        missing
                    } else {
                        details
                    }
                }
            }
            Divider().overlay(Theme.hairline)
            settingsFile
        }
        .sheet(isPresented: $signingIn, onDismiss: { claude.refresh() }) {
            ClaudeLoginSheet().appOverlays()
        }
    }

    private var status: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(claude.path == nil ? Theme.dotOff
                      : claude.account == nil ? Theme.attention : Theme.dotOn)
                .frame(width: 7, height: 7)
            Text(claude.path == nil ? "Not installed"
                 : claude.account == nil ? "Not signed in" : "Connected")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Button("Refresh") { claude.refresh() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
    }

    private var missing: some View {
        Text("Could not find the \"claude\" command. Install Claude Code and it will show up here; nothing in the app can run a session without it.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                row("Version", claude.version ?? "…")
                divider
                row("Account", claude.account.map { account in
                    account.name.map { "\($0) · \(account.email)" } ?? account.email
                } ?? "Signed out.")
                if let plan = claude.account?.plan {
                    divider
                    row("Plan", plan)
                }
                if let organization = claude.account?.organization {
                    divider
                    row("Organization", organization)
                }
                divider
                row("Path", claude.path ?? "", mono: true)
            }
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))

            Text("Sessions run whichever \"claude\" is first on PATH. Signing in or out happens in the CLI itself; the button opens it right here, and Refresh picks the change up.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                signingIn = true
            } label: {
                HStack(spacing: 6) {
                    Text(">_")
                        .font(.mono(11, .bold))
                    Text("Run claude /login")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var divider: some View {
        Divider().overlay(Theme.hairline).padding(.leading, 12)
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(mono ? .mono(12) : .system(size: 13))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var settingsFile: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code settings")
                    .font(.system(size: 13, weight: .semibold))
                Text("The CLI's own configuration, at ~/.claude/settings.json. It belongs to Claude Code, so the app only points at it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: claudeSettingsPath)])
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Signing in belongs to the CLI, so the sheet does not imitate its login flow: it hosts
// a real shell, starts "claude /login" in it, and lets the CLI take it from there. The
// shell dies with the sheet, and whoever opened it re-reads the account afterwards.
private struct ClaudeLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var terminal: TerminalSession?
    @State private var focused = true

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sign in to Claude Code").font(.serif(16))
                Text("Follow the CLI's login below, then close this when it is done.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .headerBand()
            if let terminal {
                TerminalScreen(terminal: terminal, isFocused: $focused)
                    .frame(height: 420)
            }
            SheetFooter { dismiss() }
        }
        .frame(width: 680)
        .background(Theme.background)
        .onAppear(perform: start)
        .onDisappear { terminal?.stop() }
    }

    private func start() {
        guard terminal == nil else { return }
        let session = TerminalSession(
            directory: FileManager.default.homeDirectoryForCurrentUser.path,
            name: "claude /login")
        session.start()
        // Queued into the pty now, run by the shell once it has read its rc files.
        session.send("claude /login\n")
        terminal = session
    }
}
