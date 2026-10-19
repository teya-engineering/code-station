import CodeStationCore
import TerminalKit
import TerminalTranscript

// The new-session form: which project, which agent and model, and whether the session
// gets a worktree of its own. It holds view state only, the choices on screen, and
// hands the façade one `RemoteNewSession` when the person starts it. The worktree row
// is offered only for a git repository; a plain folder says why it has none.
struct NewSessionForm {
    enum Field: CaseIterable {
        case project, agent, model, checkout
    }

    private(set) var projects: [RemoteProject]
    private(set) var options: RemoteSessionOptions
    private(set) var field: Field = .project
    private var projectIndex = 0
    private(set) var agent: AgentKind?
    // The model picked for each agent, so going back to an agent keeps its pick.
    private var models: [AgentKind: String?] = [:]
    private(set) var worktree = false
    // Set while the façade makes the session, so a second Enter does not make two.
    var creating = false
    // Why the last try was turned down, until the next key.
    var notice: String?
    // Whether each agent can run, so the form can say what to fix for the one chosen.
    var readiness: [RemoteAgentReadiness] = []

    init(projects: [RemoteProject], options: RemoteSessionOptions, projectID: String?) {
        self.projects = projects
        self.options = options
        projectIndex = projects.firstIndex { $0.id == projectID } ?? 0
        agent = options.defaultAgent
        worktree = project?.isGit == true
    }

    var project: RemoteProject? {
        projects.indices.contains(projectIndex) ? projects[projectIndex] : nil
    }

    private var installedAgents: [AgentKind] {
        options.agents.filter(\.installed).map(\.agent)
    }

    private var agentChoice: RemoteAgentChoice? { agent.flatMap(options.agent) }

    var model: String? {
        guard let agent, let choice = agentChoice else { return nil }
        if let picked = models[agent] { return picked }
        return choice.defaultModel
    }

    private var modelChoice: RemoteModelChoice? {
        agentChoice?.models.first { $0.id == model } ?? agentChoice?.models.first
    }

    // The fields the person can move between. A plain folder has no checkout to choose.
    private var fields: [Field] {
        Field.allCases.filter { $0 != .checkout || project?.isGit == true }
    }

    // What to ask the façade for, or nil when there is nothing to start yet.
    var request: RemoteNewSession? {
        guard let project, let agent else { return nil }
        return RemoteNewSession(projectID: project.id, agent: agent, model: model,
                                worktree: worktree && project.isGit)
    }

    // Fresh options, after an agent's CLI has listed its models. A pick the agent no
    // longer offers falls back to its default.
    mutating func update(_ options: RemoteSessionOptions) {
        self.options = options
        if let agent, let picked = models[agent],
           options.agent(agent)?.models.contains(where: { $0.id == picked }) != true {
            models[agent] = nil
        }
        if agent == nil || options.agent(agent!)?.installed != true { agent = options.defaultAgent }
    }

    // MARK: - Moving

    mutating func moveField(by step: Int) {
        let all = fields
        let current = all.firstIndex(of: field) ?? 0
        field = all[min(max(current + step, 0), all.count - 1)]
    }

    // Changes the value of the field under the pointer, going round at the ends.
    mutating func change(by step: Int) {
        switch field {
        case .project:
            guard !projects.isEmpty else { return }
            projectIndex = wrap(projectIndex + step, projects.count)
            // As in the GUI's sheet, a git repository starts on a worktree of its own.
            worktree = project?.isGit == true
        case .agent:
            let all = installedAgents
            guard !all.isEmpty else { return }
            let current = agent.flatMap(all.firstIndex(of:)) ?? 0
            agent = all[wrap(current + step, all.count)]
        case .model:
            guard let agent, let all = agentChoice?.models, !all.isEmpty else { return }
            let current = all.firstIndex { $0.id == model } ?? 0
            models[agent] = .some(all[wrap(current + step, all.count)].id)
        case .checkout:
            if project?.isGit == true { worktree.toggle() }
        }
    }

    private func wrap(_ index: Int, _ count: Int) -> Int {
        (index % count + count) % count
    }

    // MARK: - Drawing

    func frame(size: TerminalSize) -> [String] {
        let width = max(size.cols, 10)
        let header = Style.bold + TerminalColumns.fit(" New session", to: width) + Style.reset
        var body: [String] = [""]
        if projects.isEmpty {
            body.append(Style.dim + "  No projects yet. Add one in the Code Station app." + Style.reset)
        } else {
            body.append(row(.project, label: "Project", value: project?.name ?? "",
                            detail: project.map { $0.isMissing ? "folder missing: \($0.path)" : $0.path } ?? "",
                            width: width))
            if installedAgents.isEmpty {
                body.append(Style.dim + TerminalColumns.fit("    Agent     No agent is installed. Install Claude Code, Codex or Copilot.",
                                                            to: width) + Style.reset)
            } else {
                body.append(row(.agent, label: "Agent", value: agentChoice?.title ?? "", detail: "", width: width))
                if let ready = readiness.first(where: { $0.agent == agent }), let problem = ready.problem,
                   let fix = ready.fix {
                    body.append(Style.yellow + TerminalColumns.fit("              \(problem) Run: \(fix)", to: width)
                                + Style.reset)
                }
                body.append(row(.model, label: "Model", value: modelChoice?.title ?? "Default",
                                detail: modelChoice?.detail ?? "", width: width))
            }
            if project?.isGit == true {
                body.append(row(.checkout, label: "Checkout",
                                value: worktree ? "Own worktree" : "Project folder",
                                detail: worktree ? "on a new code-station/… branch" : "", width: width))
            } else {
                body.append(Style.dim + TerminalColumns.fit("    Checkout  Project folder  (not a git repository, so no worktree)",
                                                            to: width) + Style.reset)
            }
            body.append("")
            let note = project?.isGit == true && worktree
                ? "  Worktrees are isolated checkouts. Deleting this session removes its worktree."
                : "  Changes land straight in your project folder."
            body.append(Style.dim + TerminalColumns.fit(note, to: width) + Style.reset)
        }
        // Everything between the heading and the key help, which sits on the bottom row.
        let bodyHeight = max(size.rows - 2, 1)
        body = Array(body.prefix(bodyHeight))
        body += Array(repeating: "", count: max(bodyHeight - body.count, 0))

        let helpText: String
        if let notice {
            helpText = " " + notice
        } else if creating {
            helpText = " Starting the session…"
        } else {
            helpText = " ↑↓ field · ←→ change · enter start · ? keys · esc cancel"
        }
        let help = (notice == nil ? Style.dim : Style.red) + TerminalColumns.fit(helpText, to: width) + Style.reset
        return [header] + body + [help]
    }

    private func row(_ row: Field, label: String, value: String, detail: String, width: Int) -> String {
        let selected = row == field
        let marker = selected ? "  ▸ " : "    "
        let name = TerminalColumns.pad(label, to: 10)
        let shown = "‹ \(value) ›"
        let lead = marker + name
        let valueText = selected ? Style.reverse + shown + Style.reset : Style.bold + shown + Style.reset
        let room = max(width - TerminalColumns.width(of: lead) - TerminalColumns.width(of: shown) - 2, 0)
        let rest = detail.isEmpty || room == 0 ? "" : "  " + Style.dim + TerminalColumns.fit(detail, to: room) + Style.reset
        if TerminalColumns.width(of: lead) + TerminalColumns.width(of: shown) > width {
            return TerminalColumns.fit(lead + shown, to: width)
        }
        return lead + valueText + rest
    }
}
