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
    let trimmed = output.output.trimmed
    return trimmed.isEmpty ? nil : trimmed
}

// The Agents tab keeps both CLIs one click apart while their defaults and account
// details stay with the agent they belong to.
struct AgentSettingsView: View {
    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var appSettings
    @State private var selectedAgent: AgentKind
    @State private var claude = ClaudeAgentInfo()
    @State private var codex = CodexAgentInfo()
    @State private var loggingIn: AgentKind?

    let requestedAgent: AgentKind?

    private var defaults: SessionSettings { runner.defaults(for: selectedAgent) }

    init(selectedAgent: AgentKind,
         requestedAgent: AgentKind? = nil) {
        _selectedAgent = State(initialValue: requestedAgent ?? selectedAgent)
        self.requestedAgent = requestedAgent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            defaultAgent.id(SettingsSearchTarget.agentDefault.id)
            agentTabs.id(SettingsSearchTarget.agentConfigure.id)
            agentSection(for: selectedAgent)
        }
        .sheet(item: $loggingIn, onDismiss: { refresh() }) { agent in
            AgentLoginSheet(agent: agent).appOverlays()
        }
        .onChange(of: requestedAgent) { _, agent in
            if let agent { selectedAgent = agent }
        }
    }

    private func refresh() {
        runner.refreshAvailableAgents()
        claude.refresh()
        codex.refresh()
        Task { await runner.refreshCodexModels() }
    }

    // MARK: - Agent tabs

    private var defaultAgent: some View {
        ChoiceBlock("AGENT") {
            SettingsCard {
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
                    OptionMenu(value: runner.agent.title) {
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
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }
        }
    }

    private var agentTabs: some View {
        ChoiceBlock("CONFIGURE", note: "Choose which agent's account and settings to view. This does not change the default agent.") {
            SettingsCard {
                HStack(spacing: 4) {
                    ForEach(AgentKind.allCases) { kind in
                        ChoicePill(title: kind.title, selected: selectedAgent == kind) {
                            selectedAgent = kind
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private func change(_ edit: (inout SessionSettings) -> Void) {
        var updated = defaults
        edit(&updated)
        runner.setDefaults(updated, for: selectedAgent)
    }

    // MARK: - One agent

    // What the pane shows about an agent, read off whichever info object owns it, so
    // the screen itself is drawn once for both.
    private struct AgentProfile {
        let heading: String
        let path: String?
        let version: String?
        let account: String?
        let plan: String?
        let usage: [AccountUsageWindow]
        let usageCheckedAt: Date?
        let usageLoading: Bool
        let usageEmptyMessage: String
        let usageNote: String
        let fileTitle: String
        let configFile: String
        let refresh: () -> Void
    }

    private func profile(for agent: AgentKind) -> AgentProfile {
        switch agent {
        case .claudeCode:
            AgentProfile(
                heading: "CLAUDE CODE",
                path: claude.path,
                version: claude.version,
                account: claude.account.map { account in
                    account.name.map { "\($0) · \(account.email)" } ?? account.email
                },
                plan: claude.account?.plan,
                usage: claudeUsage,
                usageCheckedAt: runner.rateLimitsUpdatedAt[.claudeCode],
                usageLoading: false,
                usageEmptyMessage: "Run a Claude Code turn to receive its account usage here.",
                usageNote: "Claude Code sends account limits while a turn is running. This is the latest report from this app.",
                fileTitle: "Claude Code settings",
                configFile: ".claude/settings.json",
                refresh: { claude.refresh() })
        case .codex:
            AgentProfile(
                heading: "CODEX",
                path: codex.path,
                version: codex.version,
                account: codex.account.map { account in
                    account.email.map { "\(account.method) · \($0)" } ?? account.method
                },
                plan: codex.account?.plan,
                usage: codex.usage?.windows ?? [],
                usageCheckedAt: codex.usage?.checkedAt,
                usageLoading: codex.isRefreshingUsage,
                usageEmptyMessage: codex.account == nil
                    ? "Sign in to Codex to view account usage."
                    : "Codex did not return account usage details.",
                usageNote: "Read directly from your Codex account when this page opens or refreshes.",
                fileTitle: "Codex config",
                configFile: ".codex/config.toml",
                refresh: {
                    codex.refresh()
                    Task { await runner.refreshCodexModels() }
                })
        }
    }

    private func agentSection(for agent: AgentKind) -> some View {
        let profile = profile(for: agent)
        return VStack(alignment: .leading, spacing: 20) {
            ChoiceBlock(profile.heading) {
                SettingsCard {
                    statusRow(installed: profile.path != nil,
                              signedIn: profile.account != nil,
                              refresh: profile.refresh)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    SettingsRowDivider()
                    if profile.path == nil {
                        missingCard(agent)
                    } else {
                        details(profile)
                    }
                    SettingsRowDivider()
                    signInRow(agent)
                }
            }
            .id(SettingsSearchTarget.agentDetails.id)
            accountUsage(profile).id(SettingsSearchTarget.agentUsage.id)
            model(for: agent).id(SettingsSearchTarget.agentModel.id)
            effort(for: agent).id(SettingsSearchTarget.agentEffort.id)
            permissions(for: agent).id(SettingsSearchTarget.agentPermissions.id)
            cost(for: agent).id(SettingsSearchTarget.agentCost.id)
            files(title: profile.fileTitle,
                  note: "The CLI's own configuration, at ~/\(profile.configFile). It belongs to \(agent.title), so the app only points at it.",
                  path: FileManager.default.homeDirectoryForCurrentUser
                      .appendingPathComponent(profile.configFile).path)
                .id(SettingsSearchTarget.agentFiles.id)
        }
    }

    private func details(_ profile: AgentProfile) -> some View {
        Group {
            detailRow("Version", profile.version ?? "…")
            SettingsRowDivider()
            detailRow("Account", profile.account ?? "Signed out.")
            if let plan = profile.plan {
                SettingsRowDivider()
                detailRow("Plan", plan)
            }
            SettingsRowDivider()
            detailRow("Path", profile.path ?? "", mono: true)
        }
    }

    private func model(for agent: AgentKind) -> some View {
        ChoiceBlock("MODEL", note: "Applies from each session's next turn on.") {
            SettingsCard {
                let choices = runner.modelOptions(for: agent)
                ForEach(choices.indices, id: \.self) { index in
                    let choice = choices[index]
                    OptionRow(
                        title: choice.title,
                        detail: choice.detail,
                        selected: runner.validModel(defaults.model, for: agent) == choice.id) {
                            change {
                                $0.model = choice.id
                                if let effort = $0.effort,
                                   runner.validEffort(effort, for: agent,
                                                      model: choice.id) == nil {
                                    $0.effort = nil
                                }
                            }
                    }
                    if index < choices.count - 1 { SettingsRowDivider() }
                }
            }
        }
    }

    private func effort(for agent: AgentKind) -> some View {
        ChoiceBlock("EFFORT", note: "How long the model thinks before it answers. More effort costs more tokens and more time, so it is the first thing to turn down when a limit is close.") {
            SettingsCard {
                HStack(spacing: 4) {
                    ForEach(runner.effortOptions(for: agent, model: defaults.model),
                            id: \.title) { choice in
                        ChoicePill(
                            title: choice.title,
                            selected: runner.validEffort(defaults.effort, for: agent,
                                                         model: defaults.model) == choice.id) {
                                change { $0.effort = choice.id }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder private func permissions(for agent: AgentKind) -> some View {
        switch agent {
        case .claudeCode: claudePermissions
        case .codex: codexPermissions
        }
    }

    private var claudePermissions: some View {
        ChoiceBlock("PERMISSIONS") {
            SettingsCard {
                let modes = PermissionMode.allCases
                ForEach(modes.indices, id: \.self) { index in
                    let choice = modes[index]
                    OptionRow(title: choice.title,
                              detail: choice.detail,
                              selected: PermissionMode(stored: defaults.permissionMode) == choice) {
                        change { $0.permissionMode = choice.rawValue }
                    }
                    if index < modes.count - 1 { SettingsRowDivider() }
                }
            }
        }
    }

    private var codexPermissions: some View {
        ChoiceBlock("PERMISSIONS", note: "Used by every Codex session unless that session has its own choice. Changes apply from its next turn.") {
            SettingsCard {
                ForEach(CodexSandboxMode.allCases.indices, id: \.self) { index in
                    let mode = CodexSandboxMode.allCases[index]
                    OptionRow(title: mode.title,
                              detail: mode.detail,
                              selected: CodexSandboxMode.resolved(defaults.codexSandboxMode) == mode,
                              warning: mode == .fullAccess) {
                        change { $0.codexSandboxMode = mode.rawValue }
                    }
                    if index < CodexSandboxMode.allCases.count - 1 { SettingsRowDivider() }
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
            SettingsCard {
                SettingsToggleRow(
                    "Show what a session has spent",
                    detail: "The dollar figure on the session bar, and the Spent line in the hints.",
                    isOn: Binding(get: { appSettings.showsCost(for: agent) },
                                  set: { appSettings.setShowsCost($0, for: agent) }))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            }
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

    private func accountUsage(_ profile: AgentProfile) -> some View {
        ChoiceBlock("CURRENT USAGE", note: profile.usageNote) {
            SettingsCard {
                if profile.usageLoading {
                    usageMessage("Checking current usage…")
                } else if profile.usage.isEmpty {
                    usageMessage(profile.usageEmptyMessage)
                } else {
                    let windows = profile.usage
                    ForEach(windows.indices, id: \.self) { index in
                        usageRow(windows[index])
                        if index < windows.count - 1 || profile.usageCheckedAt != nil {
                            SettingsRowDivider()
                        }
                    }
                    if let checkedAt = profile.usageCheckedAt {
                        Text("Updated \(checkedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            InlineLink(title: "Refresh", action: refresh)
        }
    }

    private func missingCard(_ agent: AgentKind) -> some View {
        Text("Could not find the \"\(agent.command)\" command. Install \(agent.title) (\(agent.installHint)) and it will show up here; nothing in the app can run a session on it without that.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func signInRow(_ agent: AgentKind) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Sessions run whichever \"\(agent.command)\" is first on PATH. Signing in or out happens in the CLI itself; the button opens it right here, and Refresh picks the change up.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            ActionButton(title: "Run \(agent.loginCommand)", tone: .outlined, icon: "terminal") {
                loggingIn = agent
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func files(title: String, note: String, path: String) -> some View {
        ChoiceBlock("FILES") {
            SettingsCard {
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
                    InlineLink(title: "Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }
        }
    }
}

// Signing in belongs to the CLI, so the sheet does not imitate its login flow: it hosts
// a real shell, starts the CLI's own login command in it, and lets the CLI take it from
// there. The shell dies with the sheet, and whoever opened it re-reads the account
// afterwards.
struct AgentCommandSheet: View {
    let title: String
    let note: String
    let command: String
    @Environment(\.dismiss) private var dismiss
    @State private var terminal: TerminalSession?
    @State private var focused = true

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.serif(16))
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .headerBand()
            if let terminal {
                TerminalScreen(terminal: terminal, isFocused: $focused)
                    .frame(height: 420)
                    .transition(.fadeIn)
            }
            SheetFooter { dismiss() }
        }
        .smoothlyResizes(when: terminal != nil)
        .frame(width: 680)
        .background(Theme.background)
        .onAppear(perform: start)
        .onDisappear { terminal?.stop() }
    }

    private func start() {
        guard terminal == nil else { return }
        let session = TerminalSession(
            directory: FileManager.default.homeDirectoryForCurrentUser.path,
            name: command)
        session.start()
        // Queued into the pty now, run by the shell once it has read its rc files.
        session.send(command + "\n")
        terminal = session
    }
}

private struct AgentLoginSheet: View {
    let agent: AgentKind

    var body: some View {
        AgentCommandSheet(
            title: "Sign in to \(agent.title)",
            note: "Follow the CLI's login below, then close this when it is done.",
            command: agent.loginCommand)
    }
}
