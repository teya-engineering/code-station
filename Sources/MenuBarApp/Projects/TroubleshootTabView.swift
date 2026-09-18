import SwiftUI

// Framing a problem for the agent this session already has. Everything the sheet asks a
// new diagnosis for - which projects, which agent, which model - is settled the moment a
// session exists, so the tab reads those off the session and only asks the four things
// that are still open: the problem, the deployment, the servers and the skills.
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

    @State private var problem = ""
    @State private var attachments: [Attachment] = []
    @State private var environment = TroubleshootEnvironment.first()
    @State private var selectedSkills = Preferences.troubleshootSkills()
    @State private var mcpServersEnabled = true
    @State private var isStarting = false
    @State private var showingSkills = false
    @State private var hasStartedMCPConfigurationCheck = false
    @FocusState private var problemFocused: Bool

    var body: some View {
        if let session = store.session(sessionID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heading
                    contextStrip(session)
                    problemSection
                    optionsSection(session)
                    skillsSection(session)
                    startRow(session)
                }
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
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
        VStack(alignment: .leading, spacing: 5) {
            Text("Troubleshoot").font(.serif(21))
            Text("Frame a problem for this session's agent. It investigates read-only and answers in Chat.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // What the tab is not asking about, said once so the omission reads as settled rather
    // than as missing: the checkouts the diagnosis can see, and the agent that will run it.
    private func contextStrip(_ session: ChatSession) -> some View {
        HStack(spacing: 10) {
            ForEach(store.checkoutProjects(for: session), id: \.projectID) { checkout in
                if let project = store.project(checkout.projectID) {
                    projectChip(project, lead: checkout.projectID == session.projectID)
                }
            }
            agentChip(session)
            Spacer(minLength: 10)
            Text("Inherited from the session")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .surface(Theme.sunken, cornerRadius: 11)
        .accessibilityElement(children: .combine)
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
                Text("lead")
                    .font(.mono(10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .cardSurface(cornerRadius: 7)
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
        .padding(.horizontal, 10)
        .frame(height: 26)
        .cardSurface(cornerRadius: 7)
    }

    private func modelTitle(_ session: ChatSession) -> String? {
        let model = session.settings?.model
            ?? session.usage?.model(for: session.agent)
            ?? runner.defaults(for: session.agent).model
        return model.map { runner.modelTitle($0) }
    }

    private var problemSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("PROBLEM AND EVIDENCE")
            TroubleshootProblemEditor(problem: $problem, attachments: $attachments,
                                      focused: $problemFocused)
        }
    }

    private func optionsSection(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("ENVIRONMENT")
                    TroubleshootEnvironmentPills(environment: $environment)
                    if environment.isDangerous { liveNotice }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("MCP SERVERS")
                    TroubleshootMCPOptions(agent: session.agent,
                                           environment: environment,
                                           managedServers: configs.servers,
                                           environmentServers: environmentMCPServers,
                                           state: mcpConfigurationState(session),
                                           enabled: $mcpServersEnabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(15)
        }
        .cardSurface(cornerRadius: 11)
    }

    // Named after the environment rather than after production, since a site file can
    // mark anything a mistake would be felt in.
    private var liveNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .padding(.top, 1)
            Text("\(environment.title) is live. The agent reads logs, metrics and config, and changes nothing.")
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
            SectionLabel("SKILLS")
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
        if problem.isBlank && attachments.isEmpty {
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
            && (!problem.isBlank || !attachments.isEmpty)
            && runner.isAvailable(session.agent)
    }

    private var environmentMCPServers: [Server] {
        configs.servers.filter { environment.includes($0) }
    }

    private func mcpConfigurationState(_ session: ChatSession) -> TroubleshootMCPState {
        .resolve(agent: session.agent, enabled: mcpServersEnabled,
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
        let chosenEnvironment = environment
        let chosenSkillNames = TroubleshootSkills.chosen(skills, for: session.agent,
                                                         selected: selectedSkills)
        let enableMCPServers = mcpServersEnabled
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
                problem: problem,
                environment: chosenEnvironment,
                projects: projects.map(\.name),
                skills: chosenSkillNames,
                mcpServersEnabled: enableMCPServers,
                mcpServerNames: enableMCPServers ? selectedServers.map(\.name) : [],
                agent: session.agent)
            runner.send(request.userInput,
                        attachments: attachments,
                        customInstructions: request.customInstructions,
                        sessionID: sessionID, store: store)
            // The form is left behind rather than kept: what it said is now in the
            // transcript, and a second brief is a new question about the same session.
            problem = ""
            attachments = []
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
