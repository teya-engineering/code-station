import CodeStationCore
import TerminalKit
import TerminalTranscript

// The new-session form for a workspace, the terminal's version of the GUI's
// `NewWorkspaceSessionView`: each of its projects, the lead first, on a worktree of its
// own or in its folder (a plain folder has no choice), with any but the lead left out
// with `x`, then the agent and model. The checkouts start on the workspace's own
// defaults. View state only; the station gets one `RemoteNewWorkspaceSession`.
struct WorkspaceSessionForm {
    struct Member: Equatable {
        let id: String
        let name: String
        let isLead: Bool
        let isGit: Bool
        var worktree: Bool
        var attached = true
    }

    enum Field: Equatable {
        case member(Int), agent, model
    }

    let workspaceID: String
    let workspaceName: String
    private(set) var members: [Member]
    private(set) var options: RemoteSessionOptions
    private(set) var field: Field
    private(set) var agent: AgentKind?
    private var models: [AgentKind: String?] = [:]
    var creating = false
    var notice: String?

    init(workspaceID: String, name: String, members: [RemoteWorkspaceMember], options: RemoteSessionOptions) {
        self.workspaceID = workspaceID
        workspaceName = name
        let ordered = members.filter(\.isLead) + members.filter { !$0.isLead }
        self.members = ordered.map {
            let git = $0.isGit ?? ($0.checkout?.state == "ready")
            return Member(id: $0.projectID, name: $0.name, isLead: $0.isLead, isGit: git,
                          worktree: git && ($0.usesWorktree ?? true))
        }
        self.options = options
        agent = options.defaultAgent
        field = ordered.isEmpty ? .agent : .member(0)
    }

    private var fields: [Field] { members.indices.map(Field.member) + [.agent, .model] }

    private var installedAgents: [AgentKind] { options.agents.filter(\.installed).map(\.agent) }
    private var agentChoice: RemoteAgentChoice? { agent.flatMap(options.agent) }

    var model: String? {
        guard let agent, let choice = agentChoice else { return nil }
        if let picked = models[agent] { return picked }
        return choice.defaultModel
    }

    private var modelChoice: RemoteModelChoice? {
        agentChoice?.models.first { $0.id == model } ?? agentChoice?.models.first
    }

    // What to ask the station for, or nil when there is nothing to start yet.
    var request: RemoteNewWorkspaceSession? {
        guard let agent else { return nil }
        return RemoteNewWorkspaceSession(
            workspaceID: workspaceID, agent: agent, model: model,
            projects: members.filter(\.attached).map { .init(projectID: $0.id, worktree: $0.worktree && $0.isGit) })
    }

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

    mutating func change(by step: Int) {
        switch field {
        case .member(let index):
            guard members[index].isGit, members[index].attached else { return }
            members[index].worktree.toggle()
        case .agent:
            let all = installedAgents
            guard !all.isEmpty else { return }
            let current = agent.flatMap(all.firstIndex(of:)) ?? 0
            agent = all[wrap(current + step, all.count)]
        case .model:
            guard let agent, let all = agentChoice?.models, !all.isEmpty else { return }
            let current = all.firstIndex { $0.id == model } ?? 0
            models[agent] = .some(all[wrap(current + step, all.count)].id)
        }
    }

    // Leaves the project under the pointer out of this session, or attaches it again.
    // The lead is where the session runs, so it stays.
    mutating func toggleAttached() {
        guard case .member(let index) = field else { return }
        guard !members[index].isLead else {
            notice = "\(members[index].name) leads the workspace, so every session works in it."
            return
        }
        members[index].attached.toggle()
    }

    private func wrap(_ index: Int, _ count: Int) -> Int { (index % count + count) % count }

    // MARK: - Drawing

    func frame(size: TerminalSize) -> [String] {
        let width = max(size.cols, 10)
        var body: [String] = [
            Style.dim + TerminalColumns.fit("  The lead project is the agent's working directory. Attached projects are available to the same conversation.",
                                            to: width) + Style.reset,
            "",
            Style.bold + TerminalColumns.fit("  Projects · \(members.count { $0.attached })", to: width) + Style.reset,
        ]
        for (index, member) in members.enumerated() {
            body.append(memberRow(member, selected: field == .member(index), width: width))
        }
        body.append("")
        if installedAgents.isEmpty {
            body.append(Style.dim + TerminalColumns.fit("    Agent     No agent is installed. Install Claude Code, Codex or Copilot.",
                                                        to: width) + Style.reset)
        } else {
            body.append(row(.agent, label: "Agent", value: agentChoice?.title ?? "", detail: "", width: width))
            body.append(row(.model, label: "Model", value: modelChoice?.title ?? "Default",
                            detail: modelChoice?.detail ?? "", width: width))
        }
        body.append("")
        let trees = members.count { $0.attached && $0.isGit && $0.worktree }
        let note = members.count(where: \.attached) < 2
            ? "  Attach at least two projects to create a workspace session."
            : trees > 0 ? "  Worktrees are isolated checkouts. Deleting this session removes its worktrees."
            : "  Changes land straight in the project folders."
        body.append(Style.dim + TerminalColumns.fit(note, to: width) + Style.reset)

        let header = Style.bold + TerminalColumns.fit(" New session in \(workspaceName)", to: width) + Style.reset
        let bodyHeight = max(size.rows - 2, 1)
        body = Array(body.prefix(bodyHeight))
        body += Array(repeating: "", count: max(bodyHeight - body.count, 0))
        let helpText = notice.map { " " + $0 } ?? (creating ? " Starting the session…"
            : " ↑↓ field · ←→ change · x leave out · enter start · esc cancel")
        let help = (notice == nil ? Style.dim : Style.red) + TerminalColumns.fit(helpText, to: width) + Style.reset
        return [header] + body + [help]
    }

    // "  ▸ ■ alpha  LEAD   ‹ Own worktree ›".
    private func memberRow(_ member: Member, selected: Bool, width: Int) -> String {
        let marker = selected ? "  ▸ " : "    "
        let name = TerminalColumns.pad(TerminalColumns.fit(member.name, to: 16), to: 16)
        let lead = member.isLead ? "LEAD  " : "      "
        let checkout: String
        if !member.attached {
            checkout = "left out"
        } else if member.isGit {
            checkout = "‹ \(member.worktree ? "Own worktree" : "Project folder") ›"
        } else {
            checkout = "Project folder  (not a git repository)"
        }
        let style = !member.attached || !member.isGit ? Style.dim
            : selected ? Style.reverse : Style.bold
        return TerminalColumns.fit(marker + "■ " + name + " " + Style.cyan + lead + Style.reset
                                   + style + checkout + Style.reset, to: width)
    }

    private func row(_ row: Field, label: String, value: String, detail: String, width: Int) -> String {
        let selected = row == field
        let lead = (selected ? "  ▸ " : "    ") + TerminalColumns.pad(label, to: 10)
        let shown = "‹ \(value) ›"
        let valueText = selected ? Style.reverse + shown + Style.reset : Style.bold + shown + Style.reset
        let room = max(width - TerminalColumns.width(of: lead) - TerminalColumns.width(of: shown) - 2, 0)
        let rest = detail.isEmpty || room == 0 ? "" : "  " + Style.dim + TerminalColumns.fit(detail, to: room) + Style.reset
        if TerminalColumns.width(of: lead) + TerminalColumns.width(of: shown) > width {
            return TerminalColumns.fit(lead + shown, to: width)
        }
        return lead + valueText + rest
    }
}
