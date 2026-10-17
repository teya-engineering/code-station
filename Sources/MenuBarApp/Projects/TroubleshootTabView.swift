import SwiftUI

// Framing a problem for the agent this session already has. Everything the sheet asks a
// new diagnosis for - which projects, which agent, which model - is settled the moment a
// session exists, so the tab reads those off the session and asks for the brief.
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

    let sessionID: UUID
    // Where the brief goes, so the tab can hand the screen over to the conversation that
    // now holds it.
    let openConversation: () -> Void

    @State private var selectedSkills = Preferences.troubleshootSkills()
    @State private var isStarting = false
    @State private var showingSkills = false
    @State private var hasStartedMCPConfigurationCheck = false
    @FocusState private var problemFocused: Bool
    @FocusState private var timeFocused: Bool

    // The half-written brief is the runner's, not this view's: the pane keeps only the
    // tab that is open, so anything held here would go the moment Chat is looked at.
    private var brief: SessionComposerStore.TroubleshootBrief { runner.composer.brief(sessionID) }
    private var services: [SiteDefaults.Service] { SiteDefaults.current.services ?? [] }

    private func entry<Value>(
        _ field: WritableKeyPath<SessionComposerStore.TroubleshootBrief, Value>
    ) -> Binding<Value> {
        Binding(get: { runner.composer.brief(sessionID)[keyPath: field] },
                set: { value in runner.composer.editBrief(sessionID) { $0[keyPath: field] = value } })
    }

    var body: some View {
        if let session = store.session(sessionID) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        heading
                        let wide = geometry.size.width >= 850
                        let layout = wide
                            ? AnyLayout(HStackLayout(alignment: .top, spacing: 28))
                            : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
                        layout {
                            VStack(alignment: .leading, spacing: 24) {
                                problemSection
                                traceStrip
                                optionsSection
                                Divider().overlay(Theme.hairline)
                                TroubleshootMCPOptions(agent: session.agent,
                                                       environment: brief.environment,
                                                       managedServers: configs.servers,
                                                       environmentServers: environmentMCPServers,
                                                       state: mcpConfigurationState(session),
                                                       enabled: entry(\.mcpServersEnabled),
                                                       showsServerDetails: true)
                                Divider().overlay(Theme.hairline)
                                skillsSection(session)
                                Divider().overlay(Theme.hairline)
                                startRow(session)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            contextPanel(session)
                                .frame(width: wide ? 270 : nil)
                        }
                    }
                    .frame(maxWidth: 1066, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, geometry.size.width >= 850 ? 42 : 24)
                    .padding(.vertical, 32)
                }
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
            .sheet(isPresented: $showingSkills) {
                SkillsView(manager: skills).appOverlays()
            }
        }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Troubleshoot").font(.serif(28))
                Text("Give your agent a starting point. Follow the diagnosis in Chat.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text("Read-only")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.accent.opacity(0.09)))
                .accessibilityHint("The brief instructs the agent to investigate without changing code or configuration.")
        }
    }

    private func contextPanel(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session context").font(.system(size: 15, weight: .semibold))
            Text("Already included in your diagnosis.")
                .foregroundStyle(.secondary)
            Text("Projects").foregroundStyle(.secondary).padding(.top, 8)
            ForEach(store.checkoutProjects(for: session), id: \.projectID) { checkout in
                if let project = store.project(checkout.projectID) {
                    projectChip(project, lead: checkout.projectID == session.projectID)
                }
            }
            Text("Agent").foregroundStyle(.secondary).padding(.top, 8)
            agentChip(session)
            Divider().overlay(Theme.hairline).padding(.vertical, 8)
            Text("What happens next").fontWeight(.semibold)
            Text("Your agent investigates the problem using these projects, the evidence you add, and your selected tools.")
                .foregroundStyle(.secondary)
            Text("Findings and suggested next steps appear in Chat. The brief instructs the agent not to change your code or environment.")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(21)
        .surface(Theme.sunken, cornerRadius: 12, border: .clear)
    }

    private func projectChip(_ project: Project, lead: Bool) -> some View {
        let tint = Theme.projectTint(for: project.name)
        return HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(tint.colour)
                .frame(width: 9, height: 9)
            Text(project.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if lead {
                Spacer(minLength: 0)
                Text("Lead")
                    .font(.mono(10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 26)
        .appTooltip { Tooltip(title: project.name, subtitle: project.collapsedPath) }
    }

    private func agentChip(_ session: ChatSession) -> some View {
        HStack(spacing: 7) {
            Text(session.agent.title)
                .font(.system(size: 12, weight: .semibold))
            if let model = modelTitle(session) {
                Text(model)
                    .font(.mono(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 26)
    }

    private func modelTitle(_ session: ChatSession) -> String? {
        let model = session.settings?.model
            ?? session.usage?.model(for: session.agent)
            ?? runner.defaults(for: session.agent).model
        return model.map { runner.modelTitle($0) }
    }

    // A trace handed over from the Trace tab, shown so the brief does not carry it silently.
    @ViewBuilder private var traceStrip: some View {
        if let trace = brief.trace {
            HStack(spacing: 9) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Following trace \(trace.shortID)… in \(trace.environment), across \(counted(trace.services.count, "service"))")
                    .font(.system(size: 12))
                Spacer(minLength: 8)
                Button { runner.composer.editBrief(sessionID) { $0.trace = nil } } label: {
                    Text("Remove")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .surface(Theme.field, cornerRadius: 10, border: Theme.border)
        }
    }

    private var problemSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What’s going wrong?").font(.system(size: 14, weight: .semibold))
            Text("Include what you expected and what you’ve already tried.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TroubleshootProblemEditor(problem: entry(\.problem),
                                      attachments: entry(\.attachments),
                                      focused: $problemFocused,
                                      isBrief: true)
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    environmentField
                    timeField.frame(minWidth: 220)
                }
                VStack(alignment: .leading, spacing: 18) {
                    environmentField
                    timeField
                }
            }
            if brief.environment.isDangerous { liveNotice }
            if !services.isEmpty { serviceField }
        }
    }

    private var serviceField: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Service").font(.system(size: 14, weight: .semibold))
            TroubleshootServicePicker(services: services, selected: entry(\.serviceName))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var environmentField: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Environment").font(.system(size: 14, weight: .semibold))
            TroubleshootEnvironmentPills(environment: entry(\.environment))
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeField: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Text("When did it happen?").fontWeight(.semibold)
                Text("Optional").foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            TextField("e.g. last 30 minutes, 14:00 UTC", text: entry(\.incidentTime))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(10)
                .surface(Theme.field, cornerRadius: 8,
                         border: timeFocused ? Theme.accent : Theme.border)
                .focused($timeFocused)
                .accessibilityLabel("When did it happen? Optional")
                .accessibilityHint("Use your own words. No timezone is assumed.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Named after the environment rather than after production, since a site file can
    // mark anything a mistake would be felt in.
    private var liveNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .padding(.top, 1)
            Text("\(brief.environment.title) is live. The brief instructs the agent to use read-only checks and make no changes.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.attentionText)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .surface(Theme.attention.opacity(0.10), cornerRadius: 9,
                 border: Theme.attention.opacity(0.38))
    }

    private func skillsSection(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Skills").font(.system(size: 14, weight: .semibold))
            TroubleshootSkillsBar(skills: skills, agent: session.agent,
                                  selected: $selectedSkills, showingSkills: $showingSkills)
        }
    }

    private func startRow(_ session: ChatSession) -> some View {
        HStack(spacing: 14) {
            ActionButton(title: isStarting ? "Preparing diagnosis" : "Start diagnosis",
                         tone: .green, height: 38, size: 13.5) {
                startDiagnosis(session)
            }
            .disabled(!canStart(session))
            Text(startNote(session))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private func startNote(_ session: ChatSession) -> String {
        if !runner.isAvailable(session.agent) {
            return "\(session.agent.title) CLI was not found on PATH."
        }
        if brief.problem.isBlank && brief.attachments.isEmpty {
            return "Describe the problem, or attach the evidence for it."
        }
        // A brief sent during a turn waits its turn like any other prompt, so the tab
        // says so rather than refusing the click.
        if runner.state(sessionID).isBusy {
            return "The brief joins the queue and goes to Chat after the running turn."
        }
        return session.hasAgentConversation
            ? "The brief goes to Chat as your next message."
            : "The brief goes to Chat as your first message."
    }

    private func canStart(_ session: ChatSession) -> Bool {
        !isStarting
            && mcpConfigurationState(session) == .ready
            && (!brief.problem.isBlank || !brief.attachments.isEmpty)
            && runner.isAvailable(session.agent)
    }

    private var environmentMCPServers: [Server] {
        configs.servers.filter { brief.environment.includes($0) }
    }

    private func mcpConfigurationState(_ session: ChatSession) -> TroubleshootMCPState {
        .resolve(agent: session.agent, enabled: brief.mcpServersEnabled,
                 servers: environmentMCPServers,
                 hasStartedCheck: hasStartedMCPConfigurationCheck,
                 claude: claude, codex: codex, copilot: copilot)
    }

    private func refreshMCPConfiguration() {
        claude.refresh()
        codex.refresh(configs.servers)
        copilot.refresh(configs.servers)
        hasStartedMCPConfigurationCheck = true
    }

    // Three steps, each of which can stop the start: work out which servers to hide, save
    // them onto the session, then send the brief. The session already exists, so a failure
    // here leaves the tab as it was rather than a half-made conversation.
    private func startDiagnosis(_ session: ChatSession) {
        guard canStart(session) else { return }
        isStarting = true
        let sent = brief
        let chosenEnvironment = sent.environment
        let chosenSkillNames = TroubleshootSkills.chosen(skills, for: session.agent,
                                                         selected: selectedSkills)
        let enableMCPServers = sent.mcpServersEnabled
        let projects = store.checkoutProjects(for: session).compactMap {
            store.project($0.projectID)
        }
        let directory = store.workingDirectories(for: session).first

        Task {
            defer { isStarting = false }
            let managedServers = configs.servers
            let selectedServers = managedServers.filter { chosenEnvironment.includes($0) }
            var disabledServers: [DisabledMCPServer] = []
            if session.agent != .claudeCode, let directory,
               !enableMCPServers || !managedServers.isEmpty {
                do {
                    disabledServers = try await serversToDisable(
                        for: session.agent, in: directory, keeping: selectedServers,
                        mcpEnabled: enableMCPServers)
                } catch {
                    dialogs.show(.notice("Could not filter MCP servers",
                                         message: error.localizedDescription))
                    return
                }
            }

            var settings = store.session(sessionID)?.settings ?? SessionSettings()
            settings.mcpServersEnabled = enableMCPServers
            settings.allowedMCPServerNames = enableMCPServers && !managedServers.isEmpty
                ? selectedServers.map(\.name)
                : nil
            settings.disabledMCPServers = disabledServers.isEmpty ? nil : disabledServers
            settings.disabledMCPServerNames = nil
            store.setSettings(settings, for: sessionID)
            store.markTroubleshooting(sessionID)

            let request = TroubleshootRequest(
                problem: sent.problem,
                incidentTime: sent.incidentTime,
                environment: chosenEnvironment,
                projects: projects.map(\.name),
                skills: chosenSkillNames,
                mcpServersEnabled: enableMCPServers,
                mcpServerNames: enableMCPServers ? selectedServers.map(\.name) : [],
                agent: session.agent,
                service: TroubleshootServicePicker.chosen(sent.serviceName, in: services),
                trace: sent.trace)
            runner.send(request.userInput,
                        attachments: sent.attachments,
                        customInstructions: request.customInstructions,
                        sessionID: sessionID, store: store)
            // The form is left behind rather than kept: what it said is now in the
            // transcript, and a second brief is a new question about the same session.
            runner.composer.clearBrief(sessionID)
            openConversation()
        }
    }

    // The servers the agent has switched on that the diagnosis must not see: all of them
    // while MCP is off, otherwise the ones outside the chosen environment. Claude Code
    // is handed a filtered configuration instead, so it never comes through here.
    private func serversToDisable(for agent: AgentKind, in directory: String,
                                  keeping selected: [Server],
                                  mcpEnabled: Bool) async throws -> [DisabledMCPServer] {
        let enabled = agent == .copilot
            ? try await copilot.enabledServers(in: directory)
            : try await codex.enabledServers(in: directory)
        guard mcpEnabled else { return enabled }
        let selectedNames = Set(selected.map(\.name))
        return enabled.filter { !selectedNames.contains($0.name) }
    }
}
