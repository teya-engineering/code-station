import SwiftUI
import UniformTypeIdentifiers

// The first launch explains the app, imports any shared team setup, and connects a coding
// agent. Agent installation and sign-in still belong to the CLI, so setup runs those
// commands in a real terminal and reads their state back afterwards.
struct FirstRunWizard: View {
    private enum Step: Int, CaseIterable {
        case welcome
        case features
        case configuration
        case agent

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .features: "What you can do"
            case .configuration: "Team configuration"
            case .agent: "Coding agent"
            }
        }
    }

    private enum TerminalAction: Identifiable {
        case install(AgentKind)
        case signIn(AgentKind)

        var id: String {
            switch self {
            case .install(let agent): "install-\(agent.rawValue)"
            case .signIn(let agent): "sign-in-\(agent.rawValue)"
            }
        }

        var agent: AgentKind {
            switch self {
            case .install(let agent), .signIn(let agent): agent
            }
        }

        var title: String {
            switch self {
            case .install(let agent): "Install \(agent.title)"
            case .signIn(let agent): "Sign in to \(agent.title)"
            }
        }

        var note: String {
            switch self {
            case .install:
                "The install command is running below. Close this terminal when it finishes."
            case .signIn:
                "Follow the CLI's login below, then close this terminal when it is done."
            }
        }

        var command: String {
            switch self {
            case .install(let agent): agent.installHint
            case .signIn(let agent): agent.loginCommand
            }
        }
    }

    private struct Feature: Identifiable {
        let icon: String
        let title: String
        let detail: String

        var id: String { title }
    }

    private let features = [
        Feature(icon: "arrow.triangle.branch",
                title: "Run work in parallel",
                detail: "Give each session its own Git worktree and branch, or work directly in the project folder."),
        Feature(icon: "text.bubble.fill",
                title: "Keep the whole conversation",
                detail: "Follow replies, tool activity, permissions, token use and background work in one timeline."),
        Feature(icon: "doc.text.magnifyingglass",
                title: "Review every change",
                detail: "Browse project files and inspect the full diff without leaving the session."),
        Feature(icon: "wrench.and.screwdriver.fill",
                title: "Use the tools around the work",
                detail: "Open terminals, manage Git, inspect Docker, send API requests and connect MCP servers."),
    ]

    @Environment(SessionRunner.self) private var runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step = Step.welcome
    @State private var selectedAgent: AgentKind
    @State private var claude = ClaudeAgentInfo()
    @State private var codex = CodexAgentInfo()
    @State private var terminalAction: TerminalAction?
    @State private var repositoryURL = ""
    @State private var siteConfiguration: SiteConfigurationSelection?
    @State private var siteConfigurationError: String?
    @State private var loadingRepository = false

    let onSiteConfigurationLoaded: () -> Void
    let onFinish: () -> Void

    init(initialAgent: AgentKind,
         onSiteConfigurationLoaded: @escaping () -> Void,
         onFinish: @escaping () -> Void) {
        _selectedAgent = State(initialValue: initialAgent)
        self.onSiteConfigurationLoaded = onSiteConfigurationLoaded
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                switch step {
                case .welcome: welcome.transition(.fadeIn)
                case .features: featureTour.transition(.fadeIn)
                case .configuration: configurationSetup.transition(.fadeIn)
                case .agent: agentSetup.transition(.fadeIn)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 760, height: 590)
        .background(Theme.background)
        .interactiveDismissDisabled()
        .sheet(item: $terminalAction, onDismiss: refreshAgentState) { action in
            AgentCommandSheet(agent: action.agent,
                              title: action.title,
                              note: action.note,
                              command: action.command)
                .appOverlays()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppMark()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Teya Code Station")
                    .font(.logo(16, weight: 650))
                Text(step.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            stepIndicator
        }
        .padding(.horizontal, 24)
        .headerBand()
    }

    private var stepIndicator: some View {
        HStack(spacing: 7) {
            ForEach(Step.allCases, id: \.rawValue) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? Theme.accent : Theme.border)
                    .frame(width: item == step ? 28 : 9, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count): \(step.title)")
    }

    private var welcome: some View {
        HStack(spacing: 48) {
            AppMark()
                .frame(width: 190, height: 190)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 18) {
                Text("Your coding agents,\nworking in the open.")
                    .font(.serif(34, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Code Station brings Codex and Claude Code together with your projects, Git state, files and terminals. You stay in control while the agent does the work.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 390, alignment: .leading)
                HStack(spacing: 8) {
                    welcomeChip("Local projects")
                    welcomeChip("Real CLIs")
                    welcomeChip("Your Git history")
                }
            }
        }
        .padding(52)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func welcomeChip(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.mono(9.5, .semibold))
            .kerning(0.7)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.09)))
    }

    private var featureTour: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Everything around the agent, in one place")
                    .font(.serif(25))
                Text("A session keeps the work, the conversation and the result together.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(features) { feature in
                    featureCard(feature)
                }
            }
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func featureCard(_ feature: Feature) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: feature.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.accent.opacity(0.09)))
            VStack(alignment: .leading, spacing: 5) {
                Text(feature.title)
                    .font(.serif(16))
                Text(feature.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

    private var configurationSetup: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add your team's configuration")
                    .font(.serif(25))
                Text("One JSON file gives Code Station the shared setup that belongs to your organisation: Dispatch sign-in and starter requests, MCP presets, the skills marketplace, and useful command shortcuts. Personal tokens and passwords are never stored in it.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 12) {
                configurationCard(
                    icon: "doc.badge.plus",
                    title: "Choose a file",
                    detail: "Load a site defaults JSON file already on this Mac.") {
                        ActionButton(title: "Choose JSON file", tone: .outlined,
                                     icon: "folder", action: chooseConfigurationFile)
                            .disabled(loadingRepository)
                            .opacity(loadingRepository ? 0.6 : 1)
                    }

                configurationCard(
                    icon: "arrow.triangle.branch",
                    title: "Load from GitHub",
                    detail: "Clone a repository using your existing Git access and read its root configuration file.") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("https://github.com/org/settings", text: $repositoryURL)
                                .textFieldStyle(.plain)
                                .font(.mono(11.5))
                                .padding(.horizontal, 10)
                                .frame(height: 34)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                                .onSubmit(loadGitHubRepository)
                            ActionButton(title: loadingRepository ? "Loading…" : "Load repository",
                                         tone: .outlined,
                                         icon: loadingRepository ? nil : "arrow.down.circle",
                                         action: loadGitHubRepository)
                                .disabled(loadingRepository
                                    || repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .opacity(loadingRepository ? 0.6 : 1)
                        }
                    }
            }

            Text("A repository can provide site-defaults.json, teya-defaults.json, or one root-level JSON file.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if let siteConfiguration {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.addition)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(siteConfiguration.sourceName)
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(siteConfiguration.summary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.addition.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.addition.opacity(0.28)))
            } else if let siteConfigurationError {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.deletion)
                    Text(siteConfigurationError)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(4)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.deletion.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.deletion.opacity(0.25)))
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func configurationCard<Content: View>(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.accent.opacity(0.09)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.serif(16))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.border))
    }

    private func chooseConfigurationFile() {
        guard !loadingRepository else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Load"
        panel.message = "Choose the JSON file containing your organisation's shared Code Station setup."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            siteConfiguration = try SiteConfigurationImporter.load(file: url)
            siteConfigurationError = nil
        } catch {
            siteConfiguration = nil
            siteConfigurationError = error.localizedDescription
        }
    }

    private func loadGitHubRepository() {
        let repository = repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !loadingRepository, !repository.isEmpty else { return }
        loadingRepository = true
        siteConfigurationError = nil
        Task {
            do {
                siteConfiguration = try await SiteConfigurationImporter.load(
                    gitHubRepository: repository)
            } catch {
                siteConfiguration = nil
                siteConfigurationError = error.localizedDescription
            }
            loadingRepository = false
        }
    }

    private var agentSetup: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose your coding agent")
                    .font(.serif(25))
                Text("Code Station runs the agent's own CLI and uses its existing account. You can add the other agent later in Settings.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                ForEach(AgentKind.allCases) { agent in
                    agentChoice(agent)
                }
            }

            setupCard
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func agentChoice(_ agent: AgentKind) -> some View {
        let selected = selectedAgent == agent
        return Button {
            selectedAgent = agent
        } label: {
            HStack(spacing: 11) {
                Image(systemName: agent == .codex ? "sparkles" : "brain.head.profile")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(selected ? Color.white.opacity(0.13)
                                                       : Theme.accent.opacity(0.09)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.title)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(agent == .codex ? "OpenAI" : "Anthropic")
                        .font(.system(size: 11.5))
                        .opacity(0.72)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(RoundedRectangle(cornerRadius: 11)
                .fill(selected ? Theme.accentFill : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(selected ? .clear : Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColour)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.system(size: 14, weight: .semibold))
                    Text(statusDetail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                setupAction
            }

            if !isInstalled {
                HStack(spacing: 9) {
                    Text(selectedAgent.installHint)
                        .font(.mono(11.5))
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    InlineLink(title: "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(selectedAgent.installHint, forType: .string)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(statusColour.opacity(0.35)))
    }

    @ViewBuilder private var setupAction: some View {
        if !isInstalled {
            ActionButton(title: "Install in terminal", tone: .green, icon: "terminal") {
                terminalAction = .install(selectedAgent)
            }
        } else if !isSignedIn {
            ActionButton(title: "Sign in", tone: .green, icon: "person.crop.circle") {
                terminalAction = .signIn(selectedAgent)
            }
        } else {
            ActionButton(title: "Refresh", tone: .outlined, icon: "arrow.clockwise",
                         action: refreshAgentState)
        }
    }

    private var isInstalled: Bool {
        switch selectedAgent {
        case .claudeCode: claude.path != nil
        case .codex: codex.path != nil
        }
    }

    private var isSignedIn: Bool {
        switch selectedAgent {
        case .claudeCode: claude.account != nil
        case .codex: codex.account != nil
        }
    }

    private var statusTitle: String {
        if !isInstalled { return "\(selectedAgent.title) is not installed" }
        if !isSignedIn { return "\(selectedAgent.title) is ready to sign in" }
        return "\(selectedAgent.title) is connected"
    }

    private var statusDetail: String {
        if !isInstalled {
            return "Install the CLI in an embedded terminal, or run the command below yourself."
        }
        if !isSignedIn {
            return "The CLI is installed. Connect the account you want your sessions to use."
        }
        return "Code Station found the CLI and its account. New sessions can use it now."
    }

    private var statusColour: Color {
        if !isInstalled { return Theme.dotOff }
        if !isSignedIn { return Theme.attention }
        return Theme.dotOn
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step == .configuration && !loadingRepository {
                InlineLink(title: "Skip and use defaults") {
                    siteConfiguration = nil
                    siteConfigurationError = nil
                    move(to: .agent)
                }
            } else if step == .agent && !isSignedIn {
                InlineLink(title: "Set up later", action: finish)
            }
            Spacer(minLength: 12)
            if step != .welcome {
                ActionButton(title: "Back", tone: .outlined) {
                    move(to: Step(rawValue: step.rawValue - 1) ?? .welcome)
                }
            }
            if step == .agent {
                ActionButton(title: "Start using Code Station", tone: .green, action: finish)
                    .disabled(!isSignedIn)
                    .opacity(isSignedIn ? 1 : 0.45)
            } else if step == .configuration {
                ActionButton(title: "Continue", tone: .green) { move(to: .agent) }
                    .disabled(siteConfiguration == nil || loadingRepository)
                    .opacity(siteConfiguration == nil || loadingRepository ? 0.45 : 1)
            } else {
                ActionButton(title: "Continue", tone: .green) {
                    move(to: Step(rawValue: step.rawValue + 1) ?? .agent)
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 58)
        .background(Theme.card)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func move(to next: Step) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            step = next
        }
    }

    private func refreshAgentState() {
        runner.refreshAvailableAgents()
        claude.refresh()
        codex.refresh()
    }

    private func finish() {
        if let siteConfiguration {
            do {
                try SiteConfigurationImporter.install(siteConfiguration)
            } catch {
                siteConfigurationError = error.localizedDescription
                move(to: .configuration)
                return
            }
            // Stores already read bundled defaults during startup. They only need another
            // application pass when this wizard installed a different file.
            onSiteConfigurationLoaded()
        }
        runner.refreshAvailableAgents()
        if runner.isAvailable(selectedAgent) {
            runner.agent = selectedAgent
        }
        onFinish()
    }
}
