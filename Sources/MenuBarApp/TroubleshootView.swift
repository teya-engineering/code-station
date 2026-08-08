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

    func includes(_ server: Server) -> Bool {
        guard let (_, serverEnvironment) = Grafana.parts(from: server.name) else { return true }
        let selectedEnvironment: DeployEnv = switch self {
        case .dev: .dev
        case .prod: .prd
        }
        return serverEnvironment == selectedEnvironment || serverEnvironment == .shared
    }
}

struct TroubleshootRequest {
    let problem: String
    let environment: TroubleshootEnvironment
    let projects: [String]
    let mcpServersEnabled: Bool

    var prompt: String {
        let description = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        let problemText = description.isEmpty
            ? "Troubleshoot the problem shown in the attached files."
            : description
        let projectText = projects.joined(separator: ", ")
        let mcpText = mcpServersEnabled
            ? "MCP servers are enabled. Use them when they provide relevant logs, metrics, or service context."
            : "MCP servers are disabled for this diagnosis."
        let productionText = environment == .prod
            ? " Treat production as live: do not mutate data, configuration, deployments, or running services."
            : ""

        return """
        \(problemText)

        Troubleshooting context:
        - Environment: \(environment.promptTitle)
        - Projects: \(projectText)
        - \(mcpText)

        Investigate the problem and use read-only checks first. Do not change code or configuration.\(productionText) Explain the likely root cause, cite the evidence you found, and give concrete next steps. If a fix is needed, propose it and wait for a follow-up before applying it.
        """
    }
}

// A focused front door for incident investigation. Submitting creates a regular session,
// so the evidence, answer, and any follow-up questions stay with the selected projects.
struct TroubleshootView: View {
    private static let requiredSkillName = "grafana-specialist"

    @Environment(\.dismiss) private var dismiss
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(CodexCodeManager.self) private var codex
    @Environment(ConfigStore.self) private var configs
    @Environment(DialogPresenter.self) private var dialogs

    let skills: SkillsManager

    @State private var problem = ""
    @State private var attachments: [Attachment] = []
    @State private var selectedProjects: Set<UUID> = []
    @State private var projectFilter = ""
    @State private var environment = TroubleshootEnvironment.dev
    @State private var mcpServersEnabled = true
    @State private var agent: AgentKind?
    @State private var dropTargeted = false
    @State private var isStarting = false
    @State private var showingSkills = false
    @State private var showingNewWorkspace = false
    @FocusState private var problemFocused: Bool

    private var selectedAgent: AgentKind { agent ?? runner.agent }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if requiredSkillState != .available {
                        requiredSkillNotice
                    }
                    Group {
                        if environment == .prod { productionNotice }
                        problemSection
                        optionsSection
                        projectsSection
                    }
                    .disabled(requiredSkillState != .available)
                    .allowsHitTesting(requiredSkillState == .available)
                    .opacity(requiredSkillState == .available ? 1 : 0.5)
                }
                .padding(20)
            }
            footer
        }
        .frame(width: 760, height: 680)
        .background(Theme.background)
        .onAppear {
            problemFocused = requiredSkillState == .available
        }
        .task { await skills.refresh() }
        .onChange(of: requiredSkillState) { _, state in
            if state == .available { problemFocused = true }
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

    private var requiredSkillNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if requiredSkillState == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
            }
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(requiredSkillTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(requiredSkillDetail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if requiredSkillState != .checking {
                Button {
                    showingSkills = true
                } label: {
                    HStack(spacing: 5) {
                        Text("Open Skills")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the Skills menu to install grafana-specialist")
            }
        }
        .foregroundStyle(Theme.secret)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.secret.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.secret.opacity(0.25)))
    }

    private var requiredSkillTitle: String {
        switch requiredSkillState {
        case .checking: "Checking the Grafana specialist skill"
        case .available: ""
        case .missing: "Grafana specialist skill required"
        case .disabled: "Grafana specialist skill is disabled"
        case .unavailable: "Could not check the Grafana specialist skill"
        }
    }

    private var requiredSkillDetail: String {
        switch requiredSkillState {
        case .checking:
            "Troubleshoot will unlock when the required skill check is complete."
        case .available:
            ""
        case .missing:
            "Install grafana-specialist for \(selectedAgent.title) in Skills before using Troubleshoot."
        case .disabled:
            "Enable grafana-specialist for \(selectedAgent.title) in Skills before using Troubleshoot."
        case .unavailable:
            "Troubleshoot is locked because the \(selectedAgent.title) plugin status could not be read. Open Skills to retry."
        }
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
                        .frame(height: 190)
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
                        Text(dropTargeted ? "Drop files here" : "Drag files here or add them from Finder")
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

            if store.projects.isEmpty {
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
        Self.projects(store.projects, matching: projectFilter)
    }

    private var environmentMCPServers: [Server] {
        configs.servers.filter(environment.includes)
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
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(canDiagnose ? 1 : 0.45)

            Text("Will use \(selectedAgent.title)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    private var canDiagnose: Bool {
        !isStarting
            && requiredSkillState == .available
            && !selectedProjects.isEmpty
            && (!problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
            && runner.isAvailable(selectedAgent)
    }

    private var requiredSkillState: RequiredSkillState {
        guard skills.hasLoaded, !skills.isRefreshing else { return .checking }
        let host: SkillHost = switch selectedAgent {
        case .claudeCode: .claude
        case .codex: .codex
        }
        guard skills.hostFailure(host) == nil else { return .unavailable }
        guard let installation = skills.installation(named: Self.requiredSkillName, on: host)
        else { return .missing }
        return installation.enabled ? .available : .disabled
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
        let enableMCPServers = mcpServersEnabled

        Task {
            let managedServers = configs.servers
            let selectedServers = managedServers.filter(chosenEnvironment.includes)
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

            let session: ChatSession
            if let workspace {
                let checkouts = projects.map {
                    SessionProject(projectID: $0.id, worktreePath: nil, worktreeBranch: nil)
                }
                guard let workspaceSession = store.newSession(in: workspace.id,
                                                              projects: checkouts,
                                                              isTroubleshooting: true) else {
                    isStarting = false
                    dialogs.show(Dialog(
                        title: "Could not start the diagnosis",
                        message: "The workspace no longer has a valid lead project.",
                        actions: [.init(label: "OK", kind: .cancel)]))
                    return
                }
                session = workspaceSession
            } else {
                session = store.newSession(in: lead.id, isTroubleshooting: true)
            }

            var settings = SessionSettings()
            settings.mcpServersEnabled = enableMCPServers
            settings.allowedMCPServerNames = enableMCPServers && !managedServers.isEmpty
                ? selectedServers.map(\.name)
                : nil
            settings.disabledMCPServerNames = disabledServers.isEmpty ? nil : disabledServers
            store.setSettings(settings, for: session.id)
            runner.agent = chosenAgent

            let request = TroubleshootRequest(
                problem: problem,
                environment: chosenEnvironment,
                projects: projects.map(\.name),
                mcpServersEnabled: enableMCPServers)
            runner.send(request.prompt, attachments: attachments,
                        sessionID: session.id, store: store)
            dismiss()
        }
    }

    private var orderedSelectedProjects: [Project] {
        let selected = store.projects.filter { selectedProjects.contains($0.id) }
        guard let current = store.selectedProjectID,
              let lead = selected.first(where: { $0.id == current }) else { return selected }
        return [lead] + selected.filter { $0.id != current }
    }

    private enum RequiredSkillState: Equatable {
        case checking
        case available
        case missing
        case disabled
        case unavailable
    }
}
