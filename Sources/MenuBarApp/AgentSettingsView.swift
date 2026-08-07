import SwiftUI

// The pane is about the agents the app can run: which one sessions use, whether its CLI
// is there, who it is signed in as, and where its own files live. The account details
// come straight from each CLI's own files rather than from asking the CLI, which keeps
// opening the pane instant; only the versions need a process, and they arrive when they
// arrive.
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
        guard let path else { return }
        let info = self
        let searchPath = ProcessManager.searchPath
        Task.detached {
            // The CLI prints "2.1.220 (Claude Code)"; the number is the part worth keeping.
            let version = cliVersion(at: path, searchPath: searchPath)?
                .split(separator: " ").first.map(String.init)
            await MainActor.run { info.version = version }
        }
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
}

// The same story for Codex. Its sign-in lives in ~/.codex/auth.json: a ChatGPT login
// leaves OAuth tokens there, an API-key login leaves the key, and the account details
// ride inside the id token's claims.
@MainActor
@Observable
final class CodexAgentInfo {
    struct Account {
        var method: String
        var email: String?
        var plan: String?
    }

    private(set) var path: String?
    private(set) var version: String?
    private(set) var account: Account?

    init() { refresh() }

    func refresh() {
        path = ProcessManager.resolve("codex")
        account = Self.readAccount()
        version = nil
        guard let path else { return }
        let info = self
        let searchPath = ProcessManager.searchPath
        Task.detached {
            // The CLI prints "codex-cli 0.52.0"; the number is the part worth keeping.
            let version = cliVersion(at: path, searchPath: searchPath)?
                .split(separator: " ").last.map(String.init)
            await MainActor.run { info.version = version }
        }
    }

    static func readAccount() -> Account? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return account(from: obj)
    }

    // Split from the file read so the parsing is testable.
    static func account(from obj: [String: Any]) -> Account? {
        if let tokens = obj["tokens"] as? [String: Any],
           let idToken = tokens["id_token"] as? String,
           let claims = claims(fromJWT: idToken) {
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
            return Account(method: "ChatGPT login",
                           email: claims["email"] as? String,
                           plan: planName(auth?["chatgpt_plan_type"] as? String))
        }
        if let key = obj["OPENAI_API_KEY"] as? String, !key.isEmpty {
            return Account(method: "API key", email: nil, plan: nil)
        }
        return nil
    }

    // The middle piece of a JWT is the claims, base64url-encoded JSON. No signature
    // check: this is the CLI's own file being read back, not something to verify.
    static func claims(fromJWT token: String) -> [String: Any]? {
        let pieces = token.split(separator: ".")
        guard pieces.count == 3 else { return nil }
        var body = String(pieces[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while body.count % 4 != 0 { body += "=" }
        guard let data = Data(base64Encoded: body) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func planName(_ type: String?) -> String? {
        switch type {
        case "plus": "ChatGPT Plus"
        case "pro": "ChatGPT Pro"
        case "team": "ChatGPT Team"
        case "free": "Free"
        default: type?.capitalized
        }
    }
}

// Runs "<cli> --version" and hands back the line it printed. Blocking, so it is called
// off the main thread.
private nonisolated func cliVersion(at path: String, searchPath: String) -> String? {
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
    guard (try? process.run()) != nil else { return nil }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

// The Agents tab of the Settings sheet: the dropdown that picks which agent runs the
// sessions, and the details of whichever one is picked.
struct AgentSettingsView: View {
    @Environment(SessionRunner.self) private var runner
    @State private var claude = ClaudeAgentInfo()
    @State private var codex = CodexAgentInfo()
    @State private var loggingIn: AgentKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            picker
            Divider().overlay(Theme.hairline)
            switch runner.agent {
            case .claudeCode: claudeSection
            case .codex: codexSection
            }
        }
        .sheet(item: $loggingIn, onDismiss: { refresh() }) { agent in
            AgentLoginSheet(agent: agent).appOverlays()
        }
    }

    private func refresh() {
        claude.refresh()
        codex.refresh()
    }

    // MARK: - Picking the agent

    private var picker: some View {
        ChoiceBlock("AGENT", note: "Every session runs on this agent from its next turn. Each agent keeps a conversation history of its own, so a session switched over starts the other agent without the context so far.") {
            HStack(spacing: 8) {
                Text(runner.agent.title)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
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
                AgentKind.allCases.map { kind in
                    .item(kind.title, checked: runner.agent == kind,
                          subtitle: subtitle(of: kind)) {
                        runner.agent = kind
                    }
                }
            }
        }
    }

    private func subtitle(of kind: AgentKind) -> String {
        switch kind {
        case .claudeCode: "Anthropic's CLI, signed in through Claude."
        case .codex: "OpenAI's CLI, signed in through ChatGPT or an API key."
        }
    }

    // MARK: - Claude Code

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            ChoiceBlock("CLAUDE CODE") {
                VStack(alignment: .leading, spacing: 10) {
                    statusRow(installed: claude.path != nil,
                              signedIn: claude.account != nil) { claude.refresh() }
                    if claude.path == nil {
                        missingCard(.claudeCode)
                    } else {
                        claudeDetails
                    }
                }
            }
            Divider().overlay(Theme.hairline)
            configRow(title: "Claude Code settings",
                      note: "The CLI's own configuration, at ~/.claude/settings.json. It belongs to Claude Code, so the app only points at it.",
                      path: FileManager.default.homeDirectoryForCurrentUser
                          .appendingPathComponent(".claude/settings.json").path)
        }
    }

    private var claudeDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                detailRow("Version", claude.version ?? "…")
                rowDivider
                detailRow("Account", claude.account.map { account in
                    account.name.map { "\($0) · \(account.email)" } ?? account.email
                } ?? "Signed out.")
                if let plan = claude.account?.plan {
                    rowDivider
                    detailRow("Plan", plan)
                }
                if let organization = claude.account?.organization {
                    rowDivider
                    detailRow("Organization", organization)
                }
                rowDivider
                detailRow("Path", claude.path ?? "", mono: true)
            }
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))

            signInNote(.claudeCode)
            loginButton(.claudeCode)
        }
    }

    // MARK: - Codex

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            ChoiceBlock("CODEX") {
                VStack(alignment: .leading, spacing: 10) {
                    statusRow(installed: codex.path != nil,
                              signedIn: codex.account != nil) { codex.refresh() }
                    if codex.path == nil {
                        missingCard(.codex)
                    } else {
                        codexDetails
                    }
                }
            }
            Divider().overlay(Theme.hairline)
            configRow(title: "Codex config",
                      note: "The CLI's own configuration, at ~/.codex/config.toml. It belongs to Codex, so the app only points at it.",
                      path: FileManager.default.homeDirectoryForCurrentUser
                          .appendingPathComponent(".codex/config.toml").path)
        }
    }

    private var codexDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                detailRow("Version", codex.version ?? "…")
                rowDivider
                detailRow("Auth", codex.account?.method ?? "Signed out.")
                if let email = codex.account?.email {
                    rowDivider
                    detailRow("Account", email)
                }
                if let plan = codex.account?.plan {
                    rowDivider
                    detailRow("Plan", plan)
                }
                rowDivider
                detailRow("Path", codex.path ?? "", mono: true)
            }
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))

            signInNote(.codex)
            loginButton(.codex)
        }
    }

    // MARK: - Shared pieces

    private func statusRow(installed: Bool, signedIn: Bool, refresh: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(!installed ? Theme.dotOff : !signedIn ? Theme.attention : Theme.dotOn)
                .frame(width: 7, height: 7)
            Text(!installed ? "Not installed" : !signedIn ? "Not signed in" : "Connected")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Button("Refresh", action: refresh)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
    }

    private func missingCard(_ agent: AgentKind) -> some View {
        Text("Could not find the \"\(agent.command)\" command. Install \(agent.title) (\(agent.installHint)) and it will show up here; nothing in the app can run a session on it without that.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
    }

    private func signInNote(_ agent: AgentKind) -> some View {
        Text("Sessions run whichever \"\(agent.command)\" is first on PATH. Signing in or out happens in the CLI itself; the button opens it right here, and Refresh picks the change up.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func loginButton(_ agent: AgentKind) -> some View {
        Button {
            loggingIn = agent
        } label: {
            HStack(spacing: 6) {
                Text(">_")
                    .font(.mono(11, .bold))
                Text("Run \(agent.loginCommand)")
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

    private var rowDivider: some View {
        Divider().overlay(Theme.hairline).padding(.leading, 12)
    }

    private func detailRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
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

    private func configRow(title: String, note: String, path: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Signing in belongs to the CLI, so the sheet does not imitate its login flow: it hosts
// a real shell, starts the CLI's own login command in it, and lets the CLI take it from
// there. The shell dies with the sheet, and whoever opened it re-reads the account
// afterwards.
private struct AgentLoginSheet: View {
    let agent: AgentKind
    @Environment(\.dismiss) private var dismiss
    @State private var terminal: TerminalSession?
    @State private var focused = true

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sign in to \(agent.title)").font(.serif(16))
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
            name: agent.loginCommand)
        session.start()
        // Queued into the pty now, run by the shell once it has read its rc files.
        session.send(agent.loginCommand + "\n")
        terminal = session
    }
}
