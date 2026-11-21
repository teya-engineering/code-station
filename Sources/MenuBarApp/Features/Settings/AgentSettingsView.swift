import SwiftUI

// The Agents tab keeps the agent CLIs one click apart while their defaults and account
// details stay with the agent they belong to.
struct AgentSettingsView: View {
    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var appSettings
    @Environment(AccountUsageMonitor.self) private var usageMonitor: AccountUsageMonitor?
    @Environment(\.settingsNote) private var settingsNote
    @State private var selectedAgent: AgentKind
    @State private var claude = ClaudeAgentInfo()
    @State private var codex = CodexAgentInfo()
    @State private var copilot = CopilotAgentInfo()
    @State private var loggingIn: AgentKind?

    let requestedAgent: AgentKind?

    private var defaults: SessionSettings { runner.defaults(for: selectedAgent) }

    init(selectedAgent: AgentKind,
         requestedAgent: AgentKind? = nil) {
        _selectedAgent = State(initialValue: requestedAgent ?? selectedAgent)
        self.requestedAgent = requestedAgent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            defaultAgent.id(SettingsSearchTarget.agentDefault.id)
            agentTabs.id(SettingsSearchTarget.agentConfigure.id)
            agentSection(for: selectedAgent)
                .id(selectedAgent)
                .transition(.fadeIn)
        }
        .motion(Motion.reveal, value: selectedAgent)
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
        copilot.refresh()
        Task { await runner.refreshDiscoveredModels() }
    }

    // MARK: - Agent tabs

    private var defaultAgent: some View {
        ChoiceBlock("AGENT") {
            SettingsCard {
                HStack(alignment: .top, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("Default agent")
                            .font(Typography.body.weight(.semibold))
                        Text("New sessions use this agent unless you choose a different one when creating them.")
                            .font(Typography.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    OptionMenu(value: runner.agent.title) {
                        AgentKind.allCases.map { agent in
                            .item(agent.title,
                                  checked: runner.agent == agent,
                                  subtitle: agent.blurb) {
                                runner.agent = agent
                            }
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)
            }
        }
    }

    private var agentTabs: some View {
        ChoiceBlock("CONFIGURE", note: "Choose which agent's account and settings to view. This does not change the default agent.") {
            SettingsCard {
                HStack(spacing: Space.xs) {
                    ForEach(AgentKind.allCases) { kind in
                        ChoicePill(title: kind.title, selected: selectedAgent == kind) {
                            selectedAgent = kind
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)
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
    // the screen itself is drawn once for all of them.
    private struct AgentProfile {
        let heading: String
        let path: String?
        let version: String?
        let account: String?
        // Kept apart from the account text: a check still under way has words on the
        // row but no sign-in to show for them yet.
        let signedIn: Bool
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
                account: AgentAccount.claudeCode(claude).summary,
                signedIn: claude.account != nil,
                plan: claude.account?.plan,
                usage: usageMonitor?.usage[.claudeCode]?.windows
                    ?? runner.latestRateLimit[.claudeCode].map(AccountUsageMonitor.liveWindows) ?? [],
                usageCheckedAt: usageMonitor?.usage[.claudeCode]?.checkedAt
                    ?? runner.rateLimitsUpdatedAt[.claudeCode],
                usageLoading: usageMonitor?.usage[.claudeCode] == nil
                    && usageMonitor?.refreshing.contains(.claudeCode) == true,
                usageEmptyMessage: usageMonitor?.problems[.claudeCode]
                    ?? "Sign in to Claude Code to view account usage.",
                usageNote: "The same limits Claude Code's /usage shows, read from your Claude account and moved on by each turn.",
                fileTitle: "Claude Code settings",
                configFile: ".claude/settings.json",
                refresh: {
                    claude.refresh()
                    Task { await usageMonitor?.refresh(.claudeCode) }
                })
        case .codex:
            AgentProfile(
                heading: "CODEX",
                path: codex.path,
                version: codex.version,
                account: AgentAccount.codex(codex).summary,
                signedIn: codex.account != nil,
                plan: codex.account?.plan,
                usage: codex.usage?.windows ?? usageMonitor?.usage[.codex]?.windows ?? [],
                usageCheckedAt: codex.usage?.checkedAt ?? usageMonitor?.usage[.codex]?.checkedAt,
                usageLoading: codex.isRefreshingUsage,
                usageEmptyMessage: codex.account == nil
                    ? "Sign in to Codex to view account usage."
                    : "Codex did not return account usage details.",
                usageNote: "Read directly from your Codex account when this page opens or refreshes.",
                fileTitle: "Codex config",
                configFile: ".codex/config.toml",
                refresh: {
                    codex.refresh()
                    Task { await runner.refreshDiscoveredModels() }
                })
        case .copilot:
            AgentProfile(
                heading: "COPILOT",
                path: copilot.path,
                version: copilot.version,
                account: copilot.account?.summary
                    ?? (copilot.isCheckingAccount ? "Checking…" : nil),
                signedIn: copilot.account != nil,
                plan: nil,
                usage: usageMonitor?.usage[.copilot]?.windows ?? [],
                usageCheckedAt: usageMonitor?.usage[.copilot]?.checkedAt,
                usageLoading: usageMonitor?.usage[.copilot] == nil
                    && usageMonitor?.refreshing.contains(.copilot) == true,
                usageEmptyMessage: usageMonitor?.problems[.copilot]
                    ?? "Sign in with the GitHub CLI (gh auth login) to view Copilot's allowances.",
                usageNote: "Copilot's monthly allowances, read from GitHub with the gh CLI's login.",
                fileTitle: "Copilot config",
                configFile: ".copilot/config.json",
                refresh: {
                    copilot.refresh()
                    Task { await usageMonitor?.refresh(.copilot) }
                    Task { await runner.refreshDiscoveredModels() }
                })
        }
    }

    private func agentSection(for agent: AgentKind) -> some View {
        let profile = profile(for: agent)
        return VStack(alignment: .leading, spacing: Space.xxl) {
            ChoiceBlock(profile.heading) {
                SettingsCard {
                    statusRow(installed: profile.path != nil,
                              signedIn: profile.signedIn,
                              refresh: profile.refresh)
                        .padding(.horizontal, Space.lg)
                        .padding(.vertical, Space.lg)
                    SettingsRowDivider()
                    if profile.path == nil {
                        missingCard(agent)
                    } else {
                        details(profile, agent: agent)
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

    private func details(_ profile: AgentProfile, agent: AgentKind) -> some View {
        Group {
            detailRow("Version", profile.version ?? "…")
            // A warning, not a block: the minimum is the app's best reading of each CLI's
            // history, and most of an older CLI may still work.
            if let version = profile.version, agent.isOutdated(version) == true {
                Text("The app needs \(agent.title) \(agent.minimumVersion) or newer. Some sessions may fail until the CLI is updated.")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .warningCard()
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.md)
            }
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
        .task(id: agent) { await runner.discoverModels(for: agent) }
    }

    private func effort(for agent: AgentKind) -> some View {
        ChoiceBlock("EFFORT", note: "How long the model thinks before it answers. More effort costs more tokens and more time. Default uses \(agent.title)'s own effort settings for the selected model.") {
            SettingsCard {
                HStack(spacing: Space.xs) {
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
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)
            }
        }
    }

    @ViewBuilder private func permissions(for agent: AgentKind) -> some View {
        switch agent {
        case .claudeCode: claudePermissions
        case .codex: codexPermissions
        case .copilot: copilotPermissions
        }
    }

    private var claudePermissions: some View {
        ChoiceBlock("PERMISSIONS") {
            SettingsCard {
                let modes = PermissionMode.defaultChoices
                ForEach(modes.indices, id: \.self) { index in
                    let choice = modes[index]
                    OptionRow(title: choice.title,
                              detail: choice.detail,
                              selected: (defaults.permissionMode ?? .fallback) == choice) {
                        change { $0.permissionMode = choice }
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
                              selected: (defaults.codexSandboxMode ?? .workspaceWrite) == mode,
                              warning: mode == .fullAccess) {
                        change { $0.codexSandboxMode = mode }
                    }
                    if index < CodexSandboxMode.allCases.count - 1 { SettingsRowDivider() }
                }
            }
        }
    }

    private var copilotPermissions: some View {
        ChoiceBlock("PERMISSIONS", note: "Used by every Copilot session unless that session has its own choice. Changes apply from its next turn.") {
            SettingsCard {
                ForEach(CopilotAccessMode.allCases.indices, id: \.self) { index in
                    let mode = CopilotAccessMode.allCases[index]
                    OptionRow(title: mode.title,
                              detail: mode.detail,
                              selected: (defaults.copilotAccessMode ?? .workspace) == mode,
                              warning: mode == .fullAccess) {
                        change { $0.copilotAccessMode = mode }
                    }
                    if index < CopilotAccessMode.allCases.count - 1 { SettingsRowDivider() }
                }
            }
        }
    }

    // Hiding it only takes the figure off the screen. Sessions still record what they
    // spent, so turning this back on shows the full total rather than starting again.
    private func cost(for agent: AgentKind) -> some View {
        ChoiceBlock("COST", note: agent == .claudeCode
                    ? nil
                    : "\(agent.title) reports no cost of its own, so its sessions have nothing to show until it does.") {
            SettingsCard {
                SettingsToggleRow(
                    "Show what a session has spent",
                    detail: "The dollar figure on the session bar, and the Spent line in the hints.",
                    isOn: Binding(get: { appSettings.showsCost(for: agent) },
                                  set: { appSettings.setShowsCost($0, for: agent) }))
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.lg)
            }
        }
    }

    // MARK: - Shared pieces

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
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Space.lg)
                            .padding(.vertical, Space.md)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func usageMessage(_ text: String) -> some View {
        Text(text)
            .font(Typography.detail)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func usageRow(_ window: AccountUsageWindow) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.lg) {
                Text(window.title)
                    .font(Typography.body.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(window.usedPercent)% used")
                    .font(Typography.detail.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Meter(fraction: window.usedFraction, colour: window.colour, height: 5)
            if let resetsAt = window.resetsAt {
                Text("Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusRow(installed: Bool, signedIn: Bool, refresh: @escaping () -> Void) -> some View {
        HStack(spacing: Space.md) {
            Circle()
                .fill(!installed ? Theme.dotOff : !signedIn ? Theme.attention : Theme.dotOn)
                .frame(width: 7, height: 7)
            Text(!installed ? "Not installed" : !signedIn ? "Not signed in" : "Connected")
                .font(Typography.body.weight(.semibold))
            Spacer(minLength: 0)
            InlineLink(title: "Refresh", action: refresh)
        }
    }

    private func missingCard(_ agent: AgentKind) -> some View {
        Text("Could not find the \"\(agent.command)\" command. Install \(agent.title) (\(agent.installHint)) and it will show up here; nothing in the app can run a session on it without that.")
            .font(Typography.detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func signInRow(_ agent: AgentKind) -> some View {
        HStack(alignment: .center, spacing: Space.lg) {
            Text("Sessions run whichever \"\(agent.command)\" is first on PATH. Signing in or out happens in the CLI itself; the button opens it right here, and Refresh picks the change up.")
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            ActionButton(title: "Run \(agent.loginCommand)", tone: .outlined, icon: "terminal") {
                loggingIn = agent
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.lg)
    }

    private func detailRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.lg) {
            Text(label)
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(mono ? Typography.code : Typography.body)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    private func files(title: String, note: String, path: String) -> some View {
        ChoiceBlock("FILES") {
            SettingsCard {
                HStack(alignment: .top, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(title)
                            .font(Typography.body.weight(.semibold))
                        Text(note)
                            .font(Typography.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    InlineLink(title: "Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        settingsNote("Revealed \(title) in Finder", "folder")
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)
            }
        }
    }
}

extension AccountUsageWindow {
    var colour: Color {
        if usedPercent >= Self.criticalPercent { return Theme.deletion }
        if usedPercent >= Self.warningPercent { return Theme.attention }
        return Theme.dotOn
    }
}
