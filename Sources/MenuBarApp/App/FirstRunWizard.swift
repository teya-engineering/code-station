import SwiftUI
import CodeStationCore

struct FirstRunWizard: View {
    enum TerminalAction: Identifiable {
        case install(AgentKind)
        case signIn(AgentKind)

        var agent: AgentKind {
            switch self {
            case .install(let agent), .signIn(let agent): agent
            }
        }

        var id: String { title }

        var title: String {
            switch self {
            case .install: "Install \(agent.title)"
            case .signIn: "Sign in to \(agent.title)"
            }
        }

        var note: String {
            switch self {
            case .install: "The install command is running below. Close this terminal when it finishes."
            case .signIn: "Follow the CLI's login below, then close this terminal when it is done."
            }
        }

        var command: String {
            switch self {
            case .install: agent.installHint
            case .signIn: agent.loginCommand
            }
        }
    }

    @Environment(SessionRunner.self) private var runner
    @Environment(ProjectStore.self) private var store
    @State private var setup: FirstRunSetup
    @State private var claude = ClaudeAgentInfo()
    @State private var codex = CodexAgentInfo()
    @State private var copilot = CopilotAgentInfo()
    @State private var terminalAction: TerminalAction?
    @State private var terminalAgent: AgentKind?
    @State private var terminalReturn = 0

    let onSiteConfigurationLoaded: () -> Void
    let onFinish: () -> Void

    init(initialAgent: AgentKind,
         onSiteConfigurationLoaded: @escaping () -> Void,
         onFinish: @escaping () -> Void) {
        _setup = State(initialValue: FirstRunSetup(initialAgent: initialAgent))
        self.onSiteConfigurationLoaded = onSiteConfigurationLoaded
        self.onFinish = onFinish
    }

    var body: some View {
        FirstRunWizardContent(
            setup: setup,
            readiness: [.claudeCode: claude.readiness, .codex: codex.readiness,
                        .copilot: copilot.readiness],
            terminalReturn: terminalReturn,
            refresh: refresh,
            openTerminal: {
                terminalAgent = $0.agent
                terminalAction = $0
            },
            applyConfiguration: onSiteConfigurationLoaded,
            finish: finish)
            .sheet(item: $terminalAction, onDismiss: {
                refresh(terminalAgent)
                terminalReturn += 1
            }) { action in
                AgentCommandSheet(title: action.title, note: action.note, command: action.command)
                    .appOverlays()
            }
    }

    private func refresh(_ agent: AgentKind?) {
        runner.refreshAvailableAgents()
        if agent == nil || agent == .claudeCode { claude.refresh() }
        if agent == nil || agent == .codex { codex.refresh() }
        if agent == nil || agent == .copilot { copilot.refresh() }
    }

    private func finish(openProject: Bool) {
        guard setup.finish(in: store, openProject: openProject) else { return }
        runner.refreshAvailableAgents()
        if !setup.agentWasDeferred, runner.isAvailable(setup.selectedAgent) {
            runner.agent = setup.selectedAgent
        }
        onFinish()
    }
}

struct FirstRunWizardContent: View {
    @Bindable var setup: FirstRunSetup
    let readiness: [AgentKind: AgentReadiness]
    var terminalReturn = 0
    let refresh: (AgentKind?) -> Void
    let openTerminal: (FirstRunWizard.TerminalAction) -> Void
    let applyConfiguration: () -> Void
    let finish: (Bool) -> Void

    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.textScale) private var textScale
    @FocusState private var focused: Focus?
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var returnsFocusToAgentAction = false

    private enum Focus: Hashable {
        case agent(AgentKind), tour, terminal, primary, folder
    }

    private var state: AgentReadiness { readiness[setup.selectedAgent] ?? .checking }
    private var scale: CGFloat { max(1, textScale) }

    var body: some View {
        VStack(spacing: 0) {
            header
            stepIndicator
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Color.clear.frame(height: 0).id("top")
                        switch setup.step {
                        case .agent: agentSetup
                        case .configuration: configurationSetup
                        case .project: projectSetup
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 9)
                    .padding(.bottom, 28)
                }
                .onChange(of: setup.step) { _, _ in
                    scroll.scrollTo("top", anchor: .top)
                    headingFocused = true
                    focused = .primary
                    announce("Step \(setup.step.rawValue + 1) of 3: \(setup.step.title)")
                }
                .onChange(of: setup.loader.failure) { _, failure in
                    if let failure {
                        scroll.scrollTo("import-result", anchor: .bottom)
                        announce(failure)
                    }
                }
                .onChange(of: setup.loader.selection) { _, selection in
                    if let selection {
                        scroll.scrollTo("import-result", anchor: .bottom)
                        announce("Team settings loaded. \(selection.summary)")
                    }
                }
                .onChange(of: setup.projectFailure) { _, failure in
                    if let failure {
                        scroll.scrollTo("project-error", anchor: .bottom)
                        announce(failure)
                    }
                }
            }
            footer
        }
        .frame(width: 860)
        .frame(idealHeight: 620, maxHeight: 620)
        .background(Theme.background)
        .interactiveDismissDisabled()
        .disabled(dialogs.current != nil)
        .accessibilityHidden(dialogs.current != nil)
        .onChange(of: readiness) { old, new in
            if returnsFocusToAgentAction, state != .checking {
                focused = .terminal
                returnsFocusToAgentAction = false
            }
            guard setup.step == .agent, dialogs.current == nil else { return }
            let updates = AgentKind.allCases.filter { old[$0] != new[$0] }
                .map { "\($0.title): \(new[$0]?.label ?? "Checking…")" }
            if !updates.isEmpty { announce(updates.joined(separator: ". ")) }
        }
        .onChange(of: setup.loader.isLoading) { _, loading in
            if loading { announce("Loading team settings") }
        }
        .onChange(of: terminalReturn) { _, _ in
            returnsFocusToAgentAction = state == .checking
            if !returnsFocusToAgentAction { focused = .terminal }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppMark().frame(width: 37, height: 37).accessibilityHidden(true)
            Text("Teya Code Station").font(.logo(14, weight: 650))
            Spacer()
            Text("Step \(setup.step.rawValue + 1) of 3")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 26)
        .headerBand()
    }

    private var stepIndicator: some View {
        HStack(spacing: 24) {
            ForEach(FirstRunSetup.Step.allCases, id: \.rawValue) { step in
                HStack(spacing: 7) {
                    Text(step.rawValue < setup.step.rawValue ? "✓" : "\(step.rawValue + 1)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(step == setup.step ? Color.white : Theme.accent)
                        .frame(width: 19, height: 19)
                        .background(Circle().fill(step == setup.step ? Theme.accentFill : Theme.field))
                    Text(step.title)
                        .font(.system(size: 11, weight: step == setup.step ? .semibold : .regular))
                        .foregroundStyle(step == setup.step ? Theme.accent : Color.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.top, 20)
        .padding(.bottom, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(setup.step.rawValue + 1) of 3: \(setup.step.title)")
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.serif(31 * scale, .semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            Text(detail)
                .font(.system(size: 13 * scale))
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var agentSetup: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Connect your coding agent",
                    detail: "Use Claude Code, Codex, or Copilot with your local projects. Code Station uses the agent's own CLI and account.")
            HStack(spacing: 12) {
                ForEach(AgentKind.allCases) { agent in agentChoice(agent) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Coding agent")
            setupCard
            HStack {
                Text("You can change agents for each session.")
                    .font(.system(size: 11 * scale)).foregroundStyle(.secondary)
                Spacer()
                InlineLink(title: "Check all agents again") { refresh(nil) }
                    .padding(.vertical, 5)
            }
            notice("Keep the conversation, files, Git changes, and terminal together in one workspace.")
        }
    }

    private func agentChoice(_ agent: AgentKind) -> some View {
        let selected = setup.selectedAgent == agent
        let status = readiness[agent] ?? .checking
        return Button { setup.selectedAgent = agent } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 9) {
                    Image(systemName: agent.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(agent.title).font(.system(size: 13 * scale, weight: .semibold))
                        Text(agent.vendor).font(.system(size: 11 * scale)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "record.circle" : "circle")
                        .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.4))
                        .accessibilityHidden(true)
                }
                HStack(spacing: 6) {
                    if status == .connected {
                        Image(systemName: "checkmark").font(.system(size: 10))
                    } else {
                        Circle().frame(width: 5, height: 5)
                    }
                    Text(status.label).font(.system(size: 11 * scale))
                }
                .foregroundStyle(colour(for: status))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(Theme.card, cornerRadius: 10, border: selected ? Theme.accent : Theme.border)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Theme.accent : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .focused($focused, equals: .agent(agent))
        .accessibilityLabel("\(agent.title), \(agent.vendor), \(status.label)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 13) {
                Image(systemName: statusIcon)
                    .font(.system(size: 18))
                    .foregroundStyle(colour(for: state))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(colour(for: state).opacity(0.08)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle).font(.system(size: 13 * scale, weight: .semibold))
                    Text(statusDetail)
                        .font(.system(size: 12 * scale)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                setupAction
            }
            if state == .notInstalled {
                HStack(spacing: 9) {
                    Text(setup.selectedAgent.installHint)
                        .font(.mono(11.5 * scale)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    CopyButton("Copy", size: 12) { setup.selectedAgent.installHint }
                }
                .padding(10)
                .fieldSurface()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 98, alignment: .leading)
        .surface(Theme.card, cornerRadius: 11,
                 border: state == .connected ? Theme.addition.opacity(0.35) : Theme.border)
    }

    @ViewBuilder private var setupAction: some View {
        switch state {
        case .notInstalled:
            ActionButton(title: "Install in terminal", tone: .green) {
                openTerminal(.install(setup.selectedAgent))
            }
            .focused($focused, equals: .terminal)
        case .signInNeeded:
            ActionButton(title: "Sign in", tone: .green) {
                openTerminal(.signIn(setup.selectedAgent))
            }
            .focused($focused, equals: .terminal)
        case .connected, .failed:
            VStack(spacing: 8) {
                ActionButton(title: state == .failed ? "Try again" : "Check again", tone: .outlined,
                             icon: "arrow.clockwise") { refresh(setup.selectedAgent) }
                    .focused($focused, equals: .terminal)
                if state == .failed {
                    InlineLink(title: "Sign in through CLI") { openTerminal(.signIn(setup.selectedAgent)) }
                }
            }
        case .checking:
            Text("Checking…").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        let title = setup.selectedAgent.title
        switch state {
        case .notInstalled: return "\(title) is not installed"
        case .signInNeeded: return "Sign in to \(title)"
        case .checking: return "Checking \(title)…"
        case .connected: return "\(title) is ready to use"
        case .failed: return "We could not verify \(title)"
        }
    }

    private var statusDetail: String {
        switch state {
        case .notInstalled: "Install the CLI in an embedded terminal, or run the command yourself."
        case .signInNeeded: "The CLI is installed. Connect the account you want your sessions to use."
        case .checking: "Looking for the CLI and checking its account. This can take a moment."
        case .connected: "Code Station found the CLI and an existing account on this Mac."
        case .failed: "Try checking again, or sign in through the CLI and return here."
        }
    }

    private var statusIcon: String {
        switch state {
        case .connected: "checkmark"
        case .checking: "clock"
        case .failed: "exclamationmark.triangle"
        case .notInstalled: "terminal"
        case .signInNeeded: "person.crop.circle"
        }
    }

    private func colour(for readiness: AgentReadiness) -> Color {
        switch readiness {
        case .connected: Theme.addition
        case .signInNeeded: Theme.attentionText
        case .failed: Theme.warningText
        case .checking, .notInstalled: Color.secondary
        }
    }

    private var configurationSetup: some View {
        @Bindable var loader = setup.loader
        return VStack(alignment: .leading, spacing: 18) {
            heading("Do you have team settings?",
                    detail: "Bring in your team's tools and shortcuts, or start with your own setup.")
            SettingsCard {
                OptionRow(title: "Use my own setup", detail: "Add tools and team settings later in Settings.",
                          selected: !setup.usesTeamSettings) { setup.usesTeamSettings = false }
                    .disabled(loader.isLoading || setup.appliedConfiguration != nil)
                    .accessibilityAddTraits(!setup.usesTeamSettings ? [.isSelected] : [])
                SettingsRowDivider()
                OptionRow(title: "Load my team's settings",
                          detail: "Optional. Import from a GitHub repository or a JSON file.",
                          selected: setup.usesTeamSettings) { setup.usesTeamSettings = true }
                    .disabled(loader.isLoading)
                    .accessibilityAddTraits(setup.usesTeamSettings ? [.isSelected] : [])
            }
            if setup.usesTeamSettings {
                SourcePicker(repositoryURL: $loader.repositoryURL,
                             repositoryTitle: "Load from GitHub",
                             repositoryDetail: "Use your existing Git access.",
                             placeholder: "https://github.com/your-team/settings",
                             fileTitle: "Choose a file", fileDetail: "Choose a settings file on this Mac.",
                             fileButton: "Choose JSON file", isLoading: loader.isLoading,
                             loadRepository: loader.loadRepository,
                             chooseFile: {
                                 loader.chooseFile(message: "Choose your team's Code Station settings JSON file.")
                             }, showsOneSource: true)
                Group {
                    if let failure = loader.failure {
                        SourceFailure(failure, lineLimit: nil)
                    } else if let selection = loader.selection {
                        SourceLoaded(title: setup.appliedConfiguration == selection
                                     ? "Team settings applied" : "Team settings loaded",
                                     detail: "\(selection.sourceName): \(selection.summary)"
                                     + (setup.appliedConfiguration == selection ? "" : ". Applied when you continue."))
                    }
                }
                .id("import-result")
                if setup.appliedConfiguration != nil {
                    notice("Team settings have been applied. You can load another file here or adjust them later in Settings.")
                }
            } else {
                notice("Team settings can include MCP presets, a skills marketplace, API setup, starter requests, and shortcuts. You do not need them to use Code Station.")
            }
        }
    }

    private var projectSetup: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Open your first project",
                    detail: "Choose a local folder. Your conversations, files, and changes will stay together here.")
            if let url = setup.projectURL {
                let project = Project(url: url)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 13) {
                        Image(systemName: "folder").font(.system(size: 27)).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(project.name).font(.system(size: 14 * scale, weight: .semibold))
                            Text(project.collapsedPath)
                                .font(.system(size: 11 * scale)).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        InlineLink(title: "Change folder", action: chooseProject)
                            .focused($focused, equals: .folder)
                    }
                    .padding(20)
                    HStack(spacing: 22) {
                        Text(project.isGitRepository ? "Git repository" : "Local folder")
                        if let branch = GitHead.branch(at: project.path) { Text("Branch: \(branch)") }
                        Text("No changes to your files")
                    }
                    .font(.system(size: 11 * scale)).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Theme.field)
                }
                .cardSurface(cornerRadius: 12)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 20) {
                    Label(setup.agentWasDeferred ? "Agent setup deferred" : "\(setup.selectedAgent.title) selected",
                          systemImage: setup.agentWasDeferred ? "clock" : "checkmark")
                    Label(setup.appliedConfiguration == nil ? "Personal setup" : "Team settings applied",
                          systemImage: "checkmark")
                }
                .font(.system(size: 11 * scale)).foregroundStyle(.secondary)
                notice("Your project opens next. Create a session when you are ready to ask for your first change.")
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 34)).foregroundStyle(Theme.accent)
                    Text("Start with a folder on this Mac").font(.serif(21 * scale))
                    Text("Use an existing repository or any project folder.")
                        .font(.system(size: 12 * scale)).foregroundStyle(.secondary)
                    ActionButton(title: "Choose project folder", tone: .green, height: 36, action: chooseProject)
                        .focused($focused, equals: .folder)
                }
                .padding(28)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.4),
                                                                 style: StrokeStyle(dash: [5, 4])))
                Text("You can add more projects and group related repositories into a workspace later.")
                    .font(.system(size: 11 * scale)).foregroundStyle(.secondary)
            }
            if let failure = setup.projectFailure {
                SourceFailure(failure, lineLimit: nil).id("project-error")
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(.system(size: 11 * scale)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if setup.step == .agent {
                InlineLink(title: "See how it works", action: showTour)
                    .focused($focused, equals: .tour)
            } else if setup.step == .project {
                InlineLink(title: "Add a project later") { finish(false) }
            }
            Spacer(minLength: 12)
            if setup.step == .agent {
                if state != .connected {
                    InlineLink(title: "Set up later") {
                        setup.continueFromAgent(readiness: state, deferSetup: true)
                    }
                }
                ActionButton(title: "Continue with \(setup.selectedAgent.title)", tone: .green, height: 36) {
                    setup.continueFromAgent(readiness: state)
                }
                .disabled(state != .connected)
                .focused($focused, equals: .primary)
            } else {
                ActionButton(title: "Back", tone: .outlined, height: 36) {
                    setup.step = setup.step == .project ? .configuration : .agent
                }
                .disabled(setup.loader.isLoading)
                if setup.step == .configuration {
                    ActionButton(title: "Continue", tone: .green, height: 36) {
                        setup.continueFromConfiguration(didInstall: applyConfiguration)
                    }
                    .disabled(!setup.canContinueConfiguration)
                    .focused($focused, equals: .primary)
                } else {
                    ActionButton(title: "Open project", tone: .green, height: 36) { finish(true) }
                        .disabled(setup.projectURL == nil)
                        .focused($focused, equals: .primary)
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 15)
        .background(Theme.card)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func chooseProject() {
        guard let url = FilePicker.chooseFolder(prompt: "Choose project",
                                               message: "Choose a local project folder.",
                                               directory: setup.projectURL) else { return }
        setup.projectURL = url.standardizedFileURL
        setup.projectFailure = nil
        focused = .folder
        announce("Project selected: \(url.lastPathComponent)")
    }

    private func showTour() {
        dialogs.show(FirstRunTour.dialog(closeTitle: "Back to setup") { focused = .tour })
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}
