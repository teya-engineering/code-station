import SwiftUI

// The pane is about the agents the app can run: which one sessions use, whether its CLI
// is there, who it is signed in as, and where its own files live. The account details
// come straight from each CLI's own files rather than from asking the CLI, which keeps
// opening the pane instant. Versions and Codex account usage need a process, so they
// arrive when they arrive.
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
    @ObservationIgnored private var versionTask: Task<Void, Never>?

    init() { refresh() }

    func refresh() {
        versionTask?.cancel()
        path = ProcessManager.resolve("claude")
        account = Self.readAccount()
        version = nil
        guard let path else { return }
        let searchPath = ProcessManager.searchPath
        versionTask = Task {
            // The CLI prints "2.1.220 (Claude Code)"; the number is the part worth keeping.
            let version = await cliVersion(at: path, searchPath: searchPath)?
                .split(separator: " ").first.map(String.init)
            guard !Task.isCancelled else { return }
            self.version = version
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
    private(set) var usage: CodexUsage?
    private(set) var isRefreshingUsage = false
    private var refreshID = UUID()
    @ObservationIgnored private var versionTask: Task<Void, Never>?
    @ObservationIgnored private var usageTask: Task<Void, Never>?

    init() { refresh() }

    func refresh() {
        versionTask?.cancel()
        usageTask?.cancel()
        path = ProcessManager.resolve("codex")
        account = Self.readAccount()
        version = nil
        usage = nil
        isRefreshingUsage = false
        refreshID = UUID()
        guard let path else { return }
        let searchPath = ProcessManager.searchPath
        let id = refreshID
        versionTask = Task {
            // The CLI prints "codex-cli 0.52.0"; the number is the part worth keeping.
            let version = await cliVersion(at: path, searchPath: searchPath)?
                .split(separator: " ").last.map(String.init)
            guard !Task.isCancelled, refreshID == id else { return }
            self.version = version
        }
        guard account != nil else { return }
        isRefreshingUsage = true
        usageTask = Task {
            let usage = await CodexUsageReader.read(at: path, searchPath: searchPath)
            guard !Task.isCancelled, refreshID == id else { return }
            self.usage = usage
            self.isRefreshingUsage = false
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

// Runs "<cli> --version" and hands back the line it printed.
private nonisolated func cliVersion(at path: String, searchPath: String) async -> String? {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = searchPath
    guard let output = try? await CommandRunner.run(
        executable: path,
        arguments: ["--version"],
        environment: env,
        timeout: .seconds(5),
        outputByteLimit: 65_536
    ), output.succeeded else { return nil }
    let trimmed = output.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

// The Agents tab keeps both CLIs one click apart while their defaults and account
// details stay with the agent they belong to.
struct AgentSettingsView: View {
    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var appSettings
    @State private var claude = ClaudeAgentInfo()
    @State private var codex = CodexAgentInfo()
    @State private var loggingIn: AgentKind?

    private var defaults: SessionSettings { runner.defaults }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            agentTabs
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

    // MARK: - Agent tabs

    private var agentTabs: some View {
        ChoiceBlock("AGENT", note: "New sessions use this agent by default. A session keeps the agent and model it starts with for its whole conversation.") {
            HStack(spacing: 4) {
                ForEach(AgentKind.allCases) { kind in
                    ChoicePill(title: kind.title, selected: runner.agent == kind) {
                        runner.agent = kind
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func change(_ edit: (inout SessionSettings) -> Void) {
        var updated = defaults
        edit(&updated)
        runner.defaults = updated
    }

    private func model(for agent: AgentKind) -> some View {
        ChoiceBlock("MODEL", note: "Applies from each session's next turn on.") {
            VStack(spacing: 4) {
                ForEach(ModelChoice.options(for: agent), id: \.title) { choice in
                    OptionRow(title: choice.title,
                              detail: choice.detail,
                              selected: ModelChoice.valid(defaults.model, for: agent) == choice.id) {
                        change { $0.model = choice.id }
                    }
                }
            }
        }
    }

    private func effort(for agent: AgentKind) -> some View {
        ChoiceBlock("EFFORT", note: "How long the model thinks before it answers. More effort costs more tokens and more time, so it is the first thing to turn down when a limit is close.") {
            HStack(spacing: 4) {
                ForEach(EffortChoice.all(for: agent), id: \.title) { choice in
                    ChoicePill(title: choice.title,
                               selected: EffortChoice.valid(defaults.effort, for: agent) == choice.id) {
                        change { $0.effort = choice.id }
                    }
                }
            }
        }
    }

    // Hiding it only takes the figure off the screen. Sessions still record what they
    // spent, so turning this back on shows the full total rather than starting again.
    private func cost(for agent: AgentKind) -> some View {
        ChoiceBlock("COST", note: agent == .codex
                    ? "Codex reports no cost of its own, so its sessions have nothing to show until it does."
                    : nil) {
            Toggle(isOn: Binding(get: { appSettings.showsCost(for: agent) },
                                 set: { appSettings.setShowsCost($0, for: agent) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show what a session has spent")
                        .font(.system(size: 13, weight: .semibold))
                    Text("The dollar figure on the session bar, and the Spent line in the hints.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.appSwitch)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
        }
    }

    private var claudePermissions: some View {
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

    private var codexPermissions: some View {
        ChoiceBlock("PERMISSIONS", note: "Used by every Codex session unless that session has its own choice. Changes apply from its next turn.") {
            VStack(spacing: 4) {
                ForEach(CodexSandboxMode.allCases, id: \.rawValue) { mode in
                    OptionRow(title: mode.title,
                              detail: mode.detail,
                              selected: CodexSandboxMode.resolved(defaults.codexSandboxMode) == mode,
                              warning: mode == .fullAccess) {
                        change { $0.codexSandboxMode = mode.rawValue }
                    }
                }
            }
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
            accountUsage(windows: claudeUsage,
                         checkedAt: runner.rateLimitsUpdatedAt[.claudeCode],
                         isLoading: false,
                         emptyMessage: "Run a Claude Code turn to receive its account usage here.",
                         note: "Claude Code sends account limits while a turn is running. This is the latest report from this app.")
            Divider().overlay(Theme.hairline)
            model(for: .claudeCode)
            effort(for: .claudeCode)
            claudePermissions
            cost(for: .claudeCode)
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
            codexPermissions
            accountUsage(windows: codex.usage?.windows ?? [],
                         checkedAt: codex.usage?.checkedAt,
                         isLoading: codex.isRefreshingUsage,
                         emptyMessage: codex.account == nil
                             ? "Sign in to Codex to view account usage."
                             : "Codex did not return account usage details.",
                         note: "Read directly from your Codex account when this page opens or refreshes.")
            Divider().overlay(Theme.hairline)
            model(for: .codex)
            effort(for: .codex)
            cost(for: .codex)
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

    private var claudeUsage: [AccountUsageWindow] {
        (runner.rateLimits[.claudeCode] ?? [:]).values.compactMap { limit in
            guard let utilization = limit.utilization else { return nil }
            return AccountUsageWindow(id: limit.kind,
                                      title: limit.title,
                                      usedPercent: Int((utilization * 100).rounded()),
                                      resetsAt: limit.resetsAt)
        }
        .sorted { $0.title < $1.title }
    }

    private func accountUsage(windows: [AccountUsageWindow], checkedAt: Date?, isLoading: Bool,
                              emptyMessage: String, note: String) -> some View {
        ChoiceBlock("CURRENT USAGE", note: note) {
            if isLoading {
                usageMessage("Checking current usage…")
            } else if windows.isEmpty {
                usageMessage(emptyMessage)
            } else {
                VStack(spacing: 8) {
                    ForEach(windows) { window in
                        usageRow(window)
                    }
                    if let checkedAt {
                        Text("Updated \(checkedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func usageMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
    }

    private func usageRow(_ window: AccountUsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(window.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(window.usedPercent)% used")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Meter(fraction: window.usedFraction, colour: usageColor(for: window), height: 5)
            if let resetsAt = window.resetsAt {
                Text("Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
    }

    private func usageColor(for window: AccountUsageWindow) -> Color {
        if window.usedPercent >= 90 { return Theme.deletion }
        if window.usedPercent >= 75 { return Theme.attention }
        return Theme.dotOn
    }

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
