import SwiftUI

// Framing a problem for the agent this session already has. Which projects, which agent
// and which model are settled the moment a session exists, so the tab asks one question
// and keeps the setup on the card's bottom edge: the deployment, the time window, the
// servers and the skills, each a pill with a menu behind it. One line under the card says whether the brief can go.
//
// The brief lands in Chat as an ordinary first message, which is what makes a second run
// from here a follow-up rather than a new session.
struct TroubleshootTabView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(ClaudeCodeManager.self) private var claude
    @Environment(CodexCodeManager.self) private var codex
    @Environment(CopilotCodeManager.self) private var copilot
    @Environment(ConfigStore.self) private var configs
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(SkillsManager.self) private var skills
    @Environment(Dictation.self) private var dictation: Dictation?

    let sessionID: UUID
    // Where the brief goes, so the tab can hand the screen over to the conversation that
    // now holds it.
    let openConversation: () -> Void

    @State private var selectedSkills = Preferences.troubleshootSkills()
    @State private var isStarting = false
    @State private var showingSkills = false
    @State private var showingServers = false
    @State private var hasStartedMCPConfigurationCheck = false
    @State private var dictationID = UUID()
    @State private var problemFocused = false
    // The time pill turns into a field while a window is typed in the person's own words.
    @State private var editingTime = false
    @FocusState private var timeFocused: Bool

    private static let timePresets = ["Last 30 minutes", "Last 2 hours", "Today"]

    // The half-written brief is the runner's, not this view's: the pane keeps only the
    // tab that is open, so anything held here would go the moment Chat is looked at.
    private var brief: SessionComposerStore.TroubleshootBrief { runner.composer.brief(sessionID) }

    private func entry<Value>(
        _ field: WritableKeyPath<SessionComposerStore.TroubleshootBrief, Value>
    ) -> Binding<Value> {
        Binding(get: { runner.composer.brief(sessionID)[keyPath: field] },
                set: { value in runner.composer.editBrief(sessionID) { $0[keyPath: field] = value } })
    }

    var body: some View {
        if let session = store.session(sessionID) {
            let readiness = readiness(session)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    heading
                    briefCard(session)
                    readinessLine(readiness)
                }
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 44)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .onAppear {
                refreshMCPConfiguration()
                problemFocused = true
            }
            .task { await skills.refresh() }
            .onChange(of: selectedSkills) { _, chosen in
                Preferences.setTroubleshootSkills(chosen)
            }
            .onChange(of: readiness.spoken) { _, message in
                guard let window = NSApp?.keyWindow else { return }
                NSAccessibility.post(element: window, notification: .announcementRequested,
                                     userInfo: [.announcement: message,
                                                .priority: NSAccessibilityPriorityLevel.low.rawValue])
            }
            .sheet(isPresented: $showingSkills, onDismiss: { problemFocused = true }) {
                SkillsView(manager: skills).appOverlays()
            }
            .sheet(isPresented: $showingServers, onDismiss: {
                refreshMCPConfiguration()
                problemFocused = true
            }) {
                ConfigManagerView().appOverlays()
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("What’s going wrong?").font(Typography.display)
            Text("Say it the way you would to a colleague. A trace id, a Grafana link or a time in the text is picked up and the agent starts there.")
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Space.md)
    }

    private func briefCard(_ session: ChatSession) -> some View {
        let projects = projectNames(session)
        return TroubleshootProblemEditor(
            problem: entry(\.problem),
            attachments: entry(\.attachments),
            focused: $problemFocused,
            isBrief: true,
            dictationID: dictationID,
            dictationDraft: runner.composer.problemBinding(sessionID),
            roots: store.workingDirectories(for: session),
            vocabulary: projects + [session.title] + [session.worktreeBranch].compactMap { $0 },
            projects: projects,
            footer: AnyView(setupBar(session)))
            .disabled(isStarting)
    }

    private func projectNames(_ session: ChatSession) -> [String] {
        store.checkoutProjects(for: session).compactMap { store.project($0.projectID)?.name }
    }

    // MARK: - Setup bar

    // The pills and the start button always share the card's bottom edge. When room runs
    // short the longest pill titles truncate, so a long skill or server name never pushes
    // the button onto a line of its own.
    private func setupBar(_ session: ChatSession) -> some View {
        HStack(spacing: Space.sm) {
            pills(session)
            Spacer(minLength: 12)
            startButton(session)
                .fixedSize()
                .layoutPriority(1)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    @ViewBuilder private func pills(_ session: ChatSession) -> some View {
        environmentPill
        timePill
        serversPill(session)
        skillsPill(session)
    }

    private func startButton(_ session: ChatSession) -> some View {
        ActionButton(title: isStarting ? "Preparing diagnosis" : "Start diagnosis",
                     tone: .green, height: ControlHeight.lg, size: Typography.Size.body, shortcut: "⌘↩",
                     keyboardShortcut: KeyboardShortcut(.return, modifiers: .command)) {
            startDiagnosis(session)
        }
        .disabled(!canStart(session))
        .accessibilityHint(readiness(session).spoken)
    }

    // MARK: Environment

    // The environment only tells the agent where to look first; it never hides a server.
    // A dangerous deployment carries the amber dot on the pill and an amber edge, so the
    // consequence is on the control rather than only in the line under the card.
    private var environmentPill: some View {
        let environment = brief.environment
        let title = environment?.title ?? "Any environment"
        let isDangerous = environment?.isDangerous ?? false
        return SetupPill(title: title,
                         dot: isDangerous ? Theme.attention : nil,
                         live: isDangerous)
            .appMenu { environmentMenu }
            .accessibilityLabel("Environment: \(title)")
            .accessibilityHint(isDangerous
                               ? "Live deployment. The diagnosis stays read-only."
                               : "Optional. Tells the agent where to look first.")
    }

    private var environmentMenu: [MenuEntry] {
        let options: [MenuEntry] = TroubleshootEnvironment.all().map { option in
            let name = option.title.lowercased() == option.name.lowercased() ? nil : option.name
            let danger = option.isDangerous
                ? "the agent is told to keep every check read-only" : nil
            let subtitle = [name, danger].compactMap { $0 }.joined(separator: " · ")
            return .item(option.title,
                         checked: option == brief.environment,
                         badge: option.isDangerous ? "live" : nil,
                         badgeTint: option.isDangerous ? Theme.attention : nil,
                         subtitle: subtitle.nilIfBlank) {
                runner.composer.editBrief(sessionID) { $0.environment = option }
            }
        }
        let any: MenuEntry = .item("Any environment", checked: brief.environment == nil,
                                   subtitle: "The agent works out where to look") {
            runner.composer.editBrief(sessionID) { $0.environment = nil }
        }
        return [any, .separator] + options
    }

    // MARK: Time window

    // Presets put the person's words in the brief, so the agent reads "Last 2 hours" the
    // same way it reads a time typed by hand. A time found in the problem text is offered
    // too, and the field is there for anything else.
    private var timePill: some View {
        Group {
            if editingTime {
                HStack(spacing: Space.sm) {
                    Image(systemName: "clock")
                        .font(Typography.micro)
                        .foregroundStyle(.secondary)
                    TextField("Your own words: yesterday 09:00 to 09:30", text: entry(\.incidentTime))
                        .textFieldStyle(.plain)
                        .font(Typography.detail)
                        .focused($timeFocused)
                        .onSubmit { editingTime = false }
                        .onExitCommand { editingTime = false }
                        .accessibilityLabel("When did it happen?")
                        .accessibilityHint("Use your own words. No timezone is assumed.")
                }
                .padding(.horizontal, Space.md)
                .frame(width: 280, height: 28)
                .surface(Theme.field, cornerRadius: Radius.control, border: Theme.accent)
                .transition(.fadeIn)
                .onAppear { timeFocused = true }
                .onChange(of: timeFocused) { _, focused in
                    if !focused { editingTime = false }
                }
            } else {
                let window = brief.incidentTime.trimmed
                SetupPill(icon: "clock", title: window.isEmpty ? "Any time" : window)
                    .appMenu { timeMenu }
                    .accessibilityLabel(window.isEmpty ? "Time window: not set" : "Time window: \(window)")
                    .transition(.fadeIn)
            }
        }
        .motion(Motion.reveal, value: editingTime)
    }

    private var timeMenu: [MenuEntry] {
        let current = brief.incidentTime.trimmed
        var entries: [MenuEntry] = Self.timePresets.map { preset in
            .item(preset, checked: current == preset) { setTimeWindow(preset) }
        }
        if let found = TroubleshootRecognised.timeWindow(in: brief.problem),
           !Self.timePresets.contains(found) {
            entries.append(.item(found, checked: current == found,
                                 subtitle: "Read from the problem text") { setTimeWindow(found) })
        }
        if !current.isEmpty, !Self.timePresets.contains(current),
           current != TroubleshootRecognised.timeWindow(in: brief.problem) {
            entries.append(.item(current, checked: true, subtitle: "In your own words") {})
        }
        entries.append(.separator)
        entries.append(.item("Your own words…", icon: "pencil") { editingTime = true })
        if !current.isEmpty {
            entries.append(.item("No time window") { setTimeWindow("") })
        }
        return entries
    }

    private func setTimeWindow(_ window: String) {
        runner.composer.editBrief(sessionID) { $0.incidentTime = window }
        problemFocused = true
    }

    // MARK: Servers

    // The pill names the first server the diagnosis will see and counts the rest. A server
    // the agent has not registered puts the amber dot on the pill, since that is the one
    // thing here that stops the brief from going.
    private func serversPill(_ session: ChatSession) -> some View {
        let state = mcpConfigurationState(session)
        let servers = configs.servers
        let title: String
        if !brief.mcpServersEnabled {
            title = "MCP off"
        } else if servers.isEmpty {
            title = "\(session.agent.title)’s servers"
        } else {
            title = servers[0].name
        }
        let extra = brief.mcpServersEnabled && servers.count > 1 ? "+\(servers.count - 1)" : nil
        let needsLook: Bool = if case .unavailable = state { true } else { false }
        return SetupPill(icon: "server.rack", title: title, extra: extra,
                         dot: needsLook ? Theme.attention : nil)
            .appMenu(refreshOnOpen: { refreshMCPConfiguration() }) { serversMenu(session, state: state) }
            .accessibilityLabel("MCP servers: " + title + (extra.map { " and \($0.dropFirst()) more" } ?? ""))
    }

    private func serversMenu(_ session: ChatSession, state: TroubleshootMCPState) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .item("Use MCP servers",
                  checked: brief.mcpServersEnabled,
                  subtitle: "Logs, metrics and traces from every environment") {
                runner.composer.editBrief(sessionID) { $0.mcpServersEnabled.toggle() }
            },
        ]
        if brief.mcpServersEnabled {
            entries.append(.separator)
            if configs.servers.isEmpty {
                entries.append(.item(MenuItem(
                    label: "Any server configured for \(session.agent.title)",
                    icon: "server.rack")))
            } else {
                for server in configs.servers {
                    let status = state.configurationLabel(for: server.name)
                    entries.append(.item(MenuItem(
                        label: server.name, icon: "server.rack",
                        detail: status,
                        detailColour: status == "Configured" ? Theme.accent : Theme.attentionText)))
                }
            }
        }
        entries.append(.separator)
        entries.append(.item("Manage servers…", icon: "server.rack") { showingServers = true })
        return entries
    }

    // MARK: Skills

    // Amber when nothing is picked and there is something to pick: an agent left to guess
    // at Grafana or Postgres is rarely what was wanted.
    private func skillsPill(_ session: ChatSession) -> some View {
        let chosen = TroubleshootSkills.chosen(skills, for: session.agent, selected: selectedSkills)
        let needsSkill = chosen.isEmpty && skills.hasLoaded && !skills.isRefreshing
            && !TroubleshootSkills.available(skills, for: session.agent).isEmpty
        return SetupPill(icon: "sparkles",
                         title: chosen.first ?? "No skill",
                         extra: chosen.count > 1 ? "+\(chosen.count - 1)" : nil,
                         dot: needsSkill ? Theme.attention : nil)
            .appMenu {
                TroubleshootSkills.menu(skills, for: session.agent, selected: $selectedSkills) {
                    showingSkills = true
                }
            }
            .accessibilityLabel(chosen.isEmpty ? "Skills: none picked"
                                               : "Skills: " + chosen.joined(separator: ", "))
    }

    // MARK: - Readiness

    // The one place the tab says whether the brief can go, and what will happen when it
    // does. Everything that used to be its own notice ends up as this line's text.
    private struct Readiness: Equatable {
        enum Mood { case ready, waiting, checking, blocked }

        let mood: Mood
        let lead: String
        let rest: String

        var spoken: String { [lead, rest].filter { !$0.isEmpty }.joined(separator: " ") }
    }

    private func readiness(_ session: ChatSession) -> Readiness {
        let agent = session.agent.title
        if dictation?.isListening(dictationID) == true || dictation?.isPreparing(dictationID) == true {
            return Readiness(mood: .blocked, lead: "Stop dictating before starting the diagnosis.", rest: "")
        }
        if !runner.isAvailable(session.agent) {
            return Readiness(mood: .blocked, lead: "\(agent) CLI was not found on PATH.",
                             rest: "Sessions cannot run until it is installed.")
        }
        let state = mcpConfigurationState(session)
        if state == .checking {
            return Readiness(mood: .checking, lead: "Checking \(agent) MCP configuration…", rest: "")
        }
        if brief.problem.isBlank && brief.attachments.isEmpty {
            return Readiness(mood: .waiting, lead: "Describe the problem, or attach the evidence for it.",
                             rest: "")
        }
        var rest = "Findings arrive in this tab as the conversation. The traces, log lines and charts behind them are pinned to Evidence."
        // Every server goes with every diagnosis, so one the agent cannot reach is left
        // behind rather than stopping the rest.
        if case .unavailable(let configuration) = state {
            let missing = configuration.missing + configuration.disabled
            rest = "\(agent) cannot reach \(missing.joined(separator: ", ")), so the diagnosis goes without it. Sync it in MCP Servers to include it. " + rest
        }
        // A brief sent during a turn waits its turn like any other prompt, so the line
        // says so rather than refusing the click.
        if runner.state(sessionID).isBusy {
            rest += " The brief joins the queue after the running turn."
        }
        let lead = switch brief.environment {
        case .some(let environment) where environment.isDangerous:
            "\(environment.title) is live, so the agent only reads."
        case .some(let environment): "Ready, starting in \(environment.title)."
        case .none: "Ready."
        }
        return Readiness(mood: .ready, lead: lead, rest: rest)
    }

    private func readinessLine(_ readiness: Readiness) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            switch readiness.mood {
            case .ready:
                Image(systemName: "checkmark.circle")
                    .font(Typography.label)
                    .foregroundStyle(Theme.plan)
            case .waiting:
                Image(systemName: "text.cursor")
                    .font(Typography.label)
                    .foregroundStyle(.tertiary)
            case .checking:
                LoopSpinner(size: 10)
            case .blocked:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Typography.label)
                    .foregroundStyle(Theme.attentionText)
            }
            (Text(readiness.lead)
                .fontWeight(.semibold)
                .foregroundStyle(readiness.mood == .blocked ? Theme.attentionText : Color.primary)
                + Text(readiness.rest.isEmpty ? "" : " " + readiness.rest))
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(readiness.spoken)
        .accessibilityAddTraits(.updatesFrequently)
        .motion(Motion.reveal, value: readiness)
    }

    private func canStart(_ session: ChatSession) -> Bool {
        !isStarting
            && dictation?.isListening(dictationID) != true
            && dictation?.isPreparing(dictationID) != true
            && mcpConfigurationState(session) != .checking
            && (!brief.problem.isBlank || !brief.attachments.isEmpty)
            && runner.isAvailable(session.agent)
    }

    private func mcpConfigurationState(_ session: ChatSession) -> TroubleshootMCPState {
        .resolve(agent: session.agent, enabled: brief.mcpServersEnabled,
                 servers: configs.servers,
                 hasStartedCheck: hasStartedMCPConfigurationCheck,
                 claude: claude, codex: codex, copilot: copilot)
    }

    private func refreshMCPConfiguration() {
        claude.refresh()
        codex.refresh(configs.servers)
        copilot.refresh(configs.servers)
        hasStartedMCPConfigurationCheck = true
    }

    // MARK: - Starting

    // Three steps, each of which can stop the start: work out which servers to hide while
    // MCP is off, save that onto the session, then send the brief. The session already exists, so a failure
    // here leaves the tab as it was rather than a half-made conversation.
    private func startDiagnosis(_ session: ChatSession) {
        guard canStart(session) else { return }
        isStarting = true
        let sent = brief
        let chosenSkillNames = TroubleshootSkills.chosen(skills, for: session.agent,
                                                         selected: selectedSkills)
        let enableMCPServers = sent.mcpServersEnabled
        let projects = store.checkoutProjects(for: session).compactMap {
            store.project($0.projectID)
        }
        let directory = store.workingDirectories(for: session).first
        let unreachable: Set<String> = if case .unavailable(let configuration)
            = mcpConfigurationState(session) {
            Set(configuration.missing + configuration.disabled)
        } else { [] }

        Task {
            defer { isStarting = false }
            let managedServers = configs.servers
            var disabledServers: [DisabledMCPServer] = []
            if session.agent != .claudeCode, let directory, !enableMCPServers {
                do {
                    disabledServers = try await session.agent == .copilot
                        ? copilot.enabledServers(in: directory)
                        : codex.enabledServers(in: directory)
                } catch {
                    dialogs.show(.notice("Could not filter MCP servers",
                                         message: error.localizedDescription))
                    return
                }
            }

            // Claude is told about the servers added to it by hand as well, since they
            // pass through the filtered configuration and may also be deferred.
            let managedNames = Set(managedServers.map(\.name))
            let ownServerNames = session.agent == .claudeCode && !managedServers.isEmpty
                ? claude.entries.keys.filter { !managedNames.contains($0) }
                : []

            var settings = store.session(sessionID)?.settings ?? SessionSettings()
            settings.mcpServersEnabled = enableMCPServers
            settings.allowedMCPServerNames = enableMCPServers && !managedServers.isEmpty
                ? managedServers.map(\.name)
                : nil
            settings.disabledMCPServers = disabledServers.isEmpty ? nil : disabledServers
            settings.disabledMCPServerNames = nil
            store.setSettings(settings, for: sessionID)
            store.markTroubleshooting(sessionID, environment: sent.environment?.name,
                                      timeWindow: sent.incidentTime)

            let request = TroubleshootRequest(
                problem: sent.problem,
                incidentTime: sent.incidentTime,
                environment: sent.environment,
                projects: projects.map(\.name),
                skills: chosenSkillNames,
                mcpServersEnabled: enableMCPServers,
                mcpServerNames: enableMCPServers
                    ? managedServers.map(\.name).filter { !unreachable.contains($0) } + ownServerNames
                    : [],
                agent: session.agent)
            runner.send(request.userInput,
                        attachments: sent.attachments,
                        customInstructions: request.customInstructions,
                        dictated: sent.dictated,
                        sessionID: sessionID, store: store)
            // The form is left behind rather than kept: what it said is now in the
            // transcript, and a second brief is a new question about the same session.
            runner.composer.clearBrief(sessionID)
            dictation?.sent(dictationID)
            openConversation()
        }
    }
}

// One setting on the brief's bottom edge: what it is set to, with the menu that changes
// it behind a click. A dot in front carries a warning the pill wants seen - a live
// deployment, a server the agent cannot reach, no skill picked - and a live one also
// takes an amber edge.
private struct SetupPill: View {
    var icon: String? = nil
    let title: String
    var extra: String? = nil
    var dot: Color? = nil
    var live = false

    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.sm) {
            if let dot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            if let icon {
                Image(systemName: icon)
                    .font(Typography.micro)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(Typography.label)
                .lineLimit(1)
                .truncationMode(.middle)
            if let extra {
                Text(extra)
                    .font(Typography.detail.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            MenuChevron(size: 8)
        }
        .padding(.horizontal, Space.md)
        .frame(height: 28)
        .surface(hovering ? Theme.field : Theme.card, cornerRadius: Radius.control,
                 border: live ? Theme.attention.opacity(0.45) : Theme.border)
        .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
    }
}
