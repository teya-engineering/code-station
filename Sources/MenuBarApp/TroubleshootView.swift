import AppKit
import SwiftUI

enum TroubleshootEnvironment: String, CaseIterable, Identifiable {
    case dev
    case prod

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dev: "Dev"
        case .prod: "Prod"
        }
    }

    var promptTitle: String {
        switch self {
        case .dev: "development (dev)"
        case .prod: "production (prod)"
        }
    }

    // A server the site file does not know about is left in, since there is nothing to
    // say which environment it belongs to.
    func includes(_ server: Server, in defaults: SiteDefaults = .current) -> Bool {
        guard let preset = defaults.grafanaPreset(named: server.name) else {
            return true
        }
        return preset.serves(rawValue)
    }
}

struct TroubleshootRequest {
    let problem: String
    let environment: TroubleshootEnvironment
    let projects: [String]
    let skills: [String]
    let mcpServersEnabled: Bool
    let mcpServerNames: [String]

    init(problem: String, environment: TroubleshootEnvironment, projects: [String],
         skills: [String] = [], mcpServersEnabled: Bool, mcpServerNames: [String] = []) {
        self.problem = problem
        self.environment = environment
        self.projects = projects
        self.skills = skills
        self.mcpServersEnabled = mcpServersEnabled
        self.mcpServerNames = mcpServerNames
    }

    var userInput: String {
        let description = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty
            ? "Troubleshoot the problem shown in the attached files."
            : description
    }

    var customInstructions: String {
        let projectText = projects.joined(separator: ", ")
        let mcpText: String
        if !mcpServersEnabled {
            mcpText = "MCP servers are disabled for this diagnosis."
        } else if mcpServerNames.isEmpty {
            mcpText = "MCP servers are enabled. Use them when they provide relevant logs, metrics, or service context."
        } else {
            let names = mcpServerNames.sorted().joined(separator: ", ")
            mcpText = """
            MCP servers are enabled: \(names). Their tools may be deferred from the initial tool list. Search the available tool catalogue for these server names before concluding that a server or tool is unavailable.
            """
        }
        let skillText: String
        if skills.isEmpty {
            skillText = "No skills were picked for this diagnosis."
        } else {
            let names = skills.sorted().map { "`\($0)`" }.joined(separator: ", ")
            skillText = """
            Skills to use: \(names). Load each one before the first step it covers, whatever the agent calls skills.
            """
        }
        let productionText = environment == .prod
            ? " Treat production as live: do not mutate data, configuration, deployments, or running services."
            : ""

        return """
        Troubleshooting context:
        - Environment: \(environment.promptTitle)
        - Projects: \(projectText)
        - \(skillText)
        - \(mcpText)

        Investigate the problem and use read-only checks first. Do not change code or configuration.\(productionText) Explain the likely root cause, cite the evidence you found, and give concrete next steps. If a fix is needed, propose it and wait for a follow-up before applying it.
        """
    }
}

struct TroubleshootMCPConfiguration: Equatable {
    let missing: [String]
    let disabled: [String]

    init(requiredNames: [String], registeredNames: Set<String>,
         disabledNames: Set<String> = []) {
        let required = Set(requiredNames)
        missing = required.subtracting(registeredNames).sorted()
        disabled = required.intersection(registeredNames).intersection(disabledNames).sorted()
    }

    var isAvailable: Bool { missing.isEmpty && disabled.isEmpty }
}

// A focused front door for incident investigation. Submitting creates a regular session,
// so the evidence, answer, and any follow-up questions stay with the selected projects.
struct TroubleshootView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(ClaudeCodeManager.self) private var claude
    @Environment(CodexCodeManager.self) private var codex
    @Environment(ConfigStore.self) private var configs
    @Environment(DialogPresenter.self) private var dialogs

    let skills: SkillsManager

    @State private var problem = ""
    @State private var attachments: [Attachment] = []
    @State private var selectedProjects: Set<UUID> = []
    @State private var projectFilter = ""
    @State private var environment = TroubleshootEnvironment.dev
    @State private var selectedSkills = Preferences.troubleshootSkills
    @State private var mcpServersEnabled = true
    @State private var agent: AgentKind?
    @State private var dropTargeted = false
    @State private var isStarting = false
    @State private var showingSkills = false
    @State private var showingNewWorkspace = false
    @State private var hasStartedMCPConfigurationCheck = false
    @FocusState private var problemFocused: Bool

    private var selectedAgent: AgentKind { agent ?? runner.agent }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if environment == .prod { productionNotice }
                    problemSection
                    optionsSection
                    skillsSection
                    projectsSection
                }
                .padding(20)
            }
            footer
        }
        .frame(width: 760, height: 680)
        .background(Theme.background)
        .onAppear {
            refreshMCPConfiguration()
            problemFocused = true
        }
        .task { await skills.refresh() }
        .onChange(of: selectedSkills) { _, chosen in
            Preferences.troubleshootSkills = chosen
        }
        .sheet(isPresented: $showingSkills) {
            SkillsView(manager: skills).appOverlays()
        }
        .sheet(isPresented: $showingNewWorkspace) {
            NewWorkspaceView(initialProjectIDs: orderedSelectedProjects.map(\.id)) { workspace in
                showingNewWorkspace = false
                startDiagnosis(in: workspace)
            }
            .appOverlays()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent.opacity(0.10)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Troubleshoot").font(.serif(19))
                Text("Give an agent the problem, evidence, and project context.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    private var productionNotice: some View {
        HStack(spacing: 9) {
            Circle().fill(Theme.deletion).frame(width: 7, height: 7)
            Text("PRODUCTION")
                .font(.mono(10.5, .bold))
                .kerning(0.8)
                .foregroundStyle(Theme.deletion)
            Text("The agent is told to keep all checks read-only.")
                .font(.system(size: 12))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.deletion.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.deletion.opacity(0.18)))
    }

    // The skills the diagnosis is told to use. Only what the chosen agent already has
    // installed is offered, since naming anything else just sends it looking.
    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SectionLabel(text: "SKILLS")
                Spacer()
                if !chosenSkills.isEmpty {
                    Text("\(chosenSkills.count) selected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Button {
                    showingSkills = true
                } label: {
                    HStack(spacing: 5) {
                        Text("Manage skills")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Skills to install or enable a skill")
            }

            Group {
                if !skills.hasLoaded || skills.isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading the skills \(selectedAgent.title) has installed…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if skills.hostFailure(skillHost) != nil {
                    skillsNotice("The \(selectedAgent.title) plugin status could not be read, so no skill can be offered. Open Skills to retry.")
                } else if availableSkills.isEmpty {
                    skillsNotice("No skill is installed for \(selectedAgent.title). The diagnosis runs without one until you install skills.")
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(availableSkills) { plugin in
                                Toggle(isOn: skillSelection(plugin.name)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(plugin.name)
                                            .font(.system(size: 13, weight: .medium))
                                        Text(plugin.description)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .toggleStyle(.appCheckbox)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)

                                if plugin.id != availableSkills.last?.id {
                                    Divider().overlay(Theme.hairline).padding(.leading, 36)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        }
    }

    private func skillsNotice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var skillHost: SkillHost {
        switch selectedAgent {
        case .claudeCode: .claude
        case .codex: .codex
        }
    }

    private var availableSkills: [SkillMarketplace.Plugin] {
        skills.plugins.filter { skills.installation(of: $0, on: skillHost)?.enabled == true }
    }

    // A skill picked for one agent stays picked while the other is selected, so switching
    // agents and back keeps the choice. Only what this agent can load is sent to it.
    private var chosenSkills: [String] {
        availableSkills.map(\.name).filter { selectedSkills.contains($0) }
    }

    private func skillSelection(_ name: String) -> Binding<Bool> {
        Binding(get: { selectedSkills.contains(name) },
                set: { selected in
                    if selected {
                        selectedSkills.insert(name)
                    } else {
                        selectedSkills.remove(name)
                    }
                })
    }

    private var problemSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "PROBLEM AND EVIDENCE")
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $problem)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(height: 120)
                        .focused($problemFocused)
                    if problem.isEmpty {
                        Text("Describe what is failing, what you expected, and anything you already checked.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }

                Divider().overlay(Theme.hairline)

                HStack(spacing: 10) {
                    if attachments.isEmpty {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(dropTargeted ? "Drop files here" : "Drag or paste files here, or add them from Finder")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(attachments) { attachment in
                                    AttachmentChip(url: attachment.url) {
                                        attachments.removeAll { $0.id == attachment.id }
                                    }
                                }
                            }
                            .padding(.vertical, 1)
                        }
                    }
                    Spacer(minLength: 8)
                    Button(action: chooseFiles) {
                        HStack(spacing: 5) {
                            Image(systemName: "paperclip")
                            Text("Add files")
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(dropTargeted ? Theme.accent : Theme.border,
                        lineWidth: dropTargeted ? 2 : 1))
            .dropDestination(for: URL.self) { urls, _ in
                attach(Attachments.fromDrop(urls))
                return true
            } isTargeted: { dropTargeted = $0 }
            // Only while the description has the cursor: the filter box below is a plain
            // text field, and a file path pasted into it was meant as text.
            .pasteAttachments(enabled: problemFocused) { attach($0) }
        }
    }

    private var optionsSection: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "ENVIRONMENT")
                HStack(spacing: 6) {
                    ForEach(TroubleshootEnvironment.allCases) { option in
                        ChoicePill(title: option.title, selected: environment == option) {
                            environment = option
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "MCP SERVERS")
                Toggle(isOn: $mcpServersEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable MCP servers")
                            .font(.system(size: 13, weight: .medium))
                        Text(configs.servers.isEmpty
                             ? "Use any servers configured for the selected agent."
                             : "\(environmentMCPServers.count) managed server\(environmentMCPServers.count == 1 ? "" : "s") available for \(environment.title).")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.appSwitch)

                switch mcpConfigurationState {
                case .ready:
                    EmptyView()
                case .checking:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking \(selectedAgent.title) MCP configuration...")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                case let .unavailable(configuration):
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .padding(.top, 1)
                        Text(mcpConfigurationError(configuration))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.deletion)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.border))
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "PROJECTS")
                Spacer()
                if !selectedProjects.isEmpty {
                    Text("\(selectedProjects.count) selected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if store.regularProjects.isEmpty {
                Text("Create a workspace and add projects to it to start the diagnosis.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
            } else {
                projectFilterField

                Group {
                    if filteredProjects.isEmpty {
                        Text("No project matches \"\(projectFilter.trimmingCharacters(in: .whitespacesAndNewlines))\".")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(filteredProjects) { project in
                                    Toggle(isOn: projectSelection(project.id)) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(project.name)
                                                .font(.system(size: 13, weight: .medium))
                                            Text(project.collapsedPath)
                                                .font(.mono(10.5))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .toggleStyle(.appCheckbox)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)

                                    if project.id != filteredProjects.last?.id {
                                        Divider().overlay(Theme.hairline).padding(.leading, 36)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 170)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
            }
        }
    }

    private var projectFilterField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("Filter projects by name or path", text: $projectFilter)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !projectFilter.isEmpty {
                Button { projectFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .appTooltip("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    private var filteredProjects: [Project] {
        Self.projects(store.regularProjects, matching: projectFilter)
    }

    private var environmentMCPServers: [Server] {
        configs.servers.filter { environment.includes($0) }
    }

    private var mcpConfigurationState: MCPConfigurationState {
        guard mcpServersEnabled, !environmentMCPServers.isEmpty else { return .ready }
        guard hasStartedMCPConfigurationCheck else { return .checking }
        if selectedAgent == .codex, codex.isRefreshing { return .checking }

        let registeredNames: Set<String>
        let disabledNames: Set<String>
        switch selectedAgent {
        case .claudeCode:
            registeredNames = Set(claude.entries.keys)
            disabledNames = []
        case .codex:
            registeredNames = Set(codex.entries.keys)
            disabledNames = Set(codex.entries.compactMap { $0.value.enabled ? nil : $0.key })
        }
        let configuration = TroubleshootMCPConfiguration(
            requiredNames: environmentMCPServers.map(\.name),
            registeredNames: registeredNames,
            disabledNames: disabledNames)
        return configuration.isAvailable
            ? .ready
            : .unavailable(configuration)
    }

    static func projects(_ projects: [Project], matching filter: String) -> [Project] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projects }
        return projects.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if !runner.isAvailable(selectedAgent) {
                        Text("\(selectedAgent.title) CLI was not found on PATH.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.deletion)
                    } else {
                        Text(diagnosisDestinationText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 9)
                Spacer(minLength: 12)
                Button { dismiss() } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                diagnoseButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.card)
        }
    }

    private var diagnosisDestinationText: String {
        switch selectedProjects.count {
        case 0:
            "Select a project for the diagnosis."
        case 1:
            "The diagnosis opens as a session in the selected project."
        default:
            "Create a workspace for the selected projects before the diagnosis starts."
        }
    }

    private var diagnoseButton: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 0) {
                Button { diagnose() } label: {
                    HStack(spacing: 7) {
                        if isStarting { ProgressView().controlSize(.small) }
                        Text(isStarting ? "Preparing diagnosis" : "Diagnose problem")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canDiagnose)

                Rectangle()
                    .fill(.white.opacity(0.35))
                    .frame(width: 1, height: 17)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
                    .appMenu { agentMenu }
                    .accessibilityLabel("Choose coding agent")
            }
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentFill))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(canDiagnose ? 1 : 0.45)

            Text("Will use \(selectedAgent.title)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    private var canDiagnose: Bool {
        !isStarting
            && mcpConfigurationState == .ready
            && !selectedProjects.isEmpty
            && (!problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
            && runner.isAvailable(selectedAgent)
    }

    private var agentMenu: [MenuEntry] {
        AgentKind.allCases.map { option in
            .item(option.title,
                  checked: selectedAgent == option,
                  subtitle: option == .codex
                      ? "OpenAI's coding agent."
                      : "Anthropic's coding agent.") {
                agent = option
            }
        }
    }

    private func projectSelection(_ id: UUID) -> Binding<Bool> {
        Binding(get: { selectedProjects.contains(id) },
                set: { selected in
                    if selected {
                        selectedProjects.insert(id)
                    } else {
                        selectedProjects.remove(id)
                    }
                })
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.message = "Choose files that help explain the problem."
        guard panel.runModal() == .OK else { return }
        attach(panel.urls.map(Attachment.init(url:)))
    }

    private func attach(_ found: [Attachment]) {
        for item in found where !attachments.contains(where: { $0.url == item.url }) {
            attachments.append(item)
        }
        problemFocused = true
    }

    private func refreshMCPConfiguration() {
        claude.refresh()
        codex.refresh(configs.servers)
        hasStartedMCPConfigurationCheck = true
    }

    private func mcpConfigurationError(_ configuration: TroubleshootMCPConfiguration) -> String {
        var messages: [String] = []
        if !configuration.missing.isEmpty {
            messages.append("Not configured for \(selectedAgent.title): \(configuration.missing.joined(separator: ", ")).")
        }
        if !configuration.disabled.isEmpty {
            messages.append("Disabled in \(selectedAgent.title): \(configuration.disabled.joined(separator: ", ")).")
        }
        messages.append("Sync the listed servers in MCP Servers before diagnosing.")
        return messages.joined(separator: " ")
    }

    private func diagnose() {
        guard canDiagnose else { return }
        let projects = orderedSelectedProjects
        guard projects.count == selectedProjects.count else {
            dialogs.show(Dialog(
                title: "Could not start the diagnosis",
                message: "One of the selected projects is no longer available.",
                actions: [.init(label: "OK", kind: .cancel)]))
            return
        }
        guard let project = Self.projectSessionTarget(projects) else {
            showingNewWorkspace = true
            return
        }
        startDiagnosis(in: project)
    }

    static func projectSessionTarget(_ projects: [Project]) -> Project? {
        projects.count == 1 ? projects[0] : nil
    }

    private func startDiagnosis(in project: Project) {
        startDiagnosis(projects: [project], workspace: nil)
    }

    private func startDiagnosis(in workspace: ProjectWorkspace) {
        let projects = workspace.projectIDs.compactMap(store.project)
        guard projects.count == workspace.projectIDs.count else {
            dialogs.show(Dialog(
                title: "Could not start the diagnosis",
                message: "One of the workspace projects is no longer available.",
                actions: [.init(label: "OK", kind: .cancel)]))
            return
        }
        startDiagnosis(projects: projects, workspace: workspace)
    }

    private func startDiagnosis(projects: [Project], workspace: ProjectWorkspace?) {
        guard let lead = projects.first else { return }
        isStarting = true
        let chosenAgent = selectedAgent
        let chosenEnvironment = environment
        let chosenSkillNames = chosenSkills
        let enableMCPServers = mcpServersEnabled

        Task {
            let managedServers = configs.servers
            let selectedServers = managedServers.filter { chosenEnvironment.includes($0) }
            var disabledServers: [String] = []
            if chosenAgent == .codex, !enableMCPServers || !managedServers.isEmpty {
                do {
                    let enabledServers = try await codex.enabledServerNames(in: lead.path)
                    let selectedNames = Set(selectedServers.map(\.name))
                    disabledServers = enableMCPServers
                        ? enabledServers.filter { !selectedNames.contains($0) }
                        : enabledServers
                } catch {
                    isStarting = false
                    dialogs.show(Dialog(
                        title: "Could not filter MCP servers",
                        message: error.localizedDescription,
                        actions: [.init(label: "OK", kind: .cancel)]))
                    return
                }
            }

            let sessionResult: Result<ChatSession, PersistenceFailure>
            if let workspace {
                let checkouts = projects.map {
                    SessionProject(projectID: $0.id, worktreePath: nil, worktreeBranch: nil)
                }
                sessionResult = store.insertSession(in: workspace.id,
                                                    projects: checkouts,
                                                    agent: chosenAgent,
                                                    model: runner.defaults(for: chosenAgent).model,
                                                    isTroubleshooting: true)
            } else {
                sessionResult = store.insertSession(
                    in: lead.id,
                    agent: chosenAgent,
                    model: runner.defaults(for: chosenAgent).model,
                    isTroubleshooting: true)
            }
            let session: ChatSession
            switch sessionResult {
            case .success(let created):
                session = created
            case .failure(let failure):
                isStarting = false
                dialogs.show(Dialog(
                    title: "Could not start the diagnosis",
                    message: failure.message,
                    actions: [.init(label: "OK", kind: .cancel)]))
                return
            }

            var settings = session.settings ?? SessionSettings()
            settings.mcpServersEnabled = enableMCPServers
            settings.allowedMCPServerNames = enableMCPServers && !managedServers.isEmpty
                ? selectedServers.map(\.name)
                : nil
            settings.disabledMCPServerNames = disabledServers.isEmpty ? nil : disabledServers
            store.setSettings(settings, for: session.id)

            let request = TroubleshootRequest(
                problem: problem,
                environment: chosenEnvironment,
                projects: projects.map(\.name),
                skills: chosenSkillNames,
                mcpServersEnabled: enableMCPServers,
                mcpServerNames: enableMCPServers ? selectedServers.map(\.name) : [])
            runner.send(request.userInput,
                        attachments: attachments,
                        customInstructions: request.customInstructions,
                        sessionID: session.id, store: store)
            dismiss()
        }
    }

    private var orderedSelectedProjects: [Project] {
        let selected = store.regularProjects.filter { selectedProjects.contains($0.id) }
        guard let current = store.selectedProjectID,
              let lead = selected.first(where: { $0.id == current }) else { return selected }
        return [lead] + selected.filter { $0.id != current }
    }

    private enum MCPConfigurationState: Equatable {
        case ready
        case checking
        case unavailable(TroubleshootMCPConfiguration)
    }
}
