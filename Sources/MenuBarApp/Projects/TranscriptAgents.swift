import SwiftUI

struct AgentTranscriptFocus: Equatable {
    let messageID: UUID
    let toolID: String
    var requestID = UUID()

    var anchor: String { "agents:\(messageID):\(toolID)" }
}

enum TranscriptAgents {
    static func summary(_ agents: [WorkingSetActivity]) -> String {
        let states: [WorkingSetToolCall.State] = [.running, .completed, .failed, .interrupted, .finished]
        return states.compactMap { state in
            let count = agents.count { $0.state == state }
            return count == 0 ? nil : "\(count) \(state.label)"
        }.joined(separator: " · ")
    }

    static func target(for agent: WorkingSetActivity, in messages: [ChatMessage]) -> AgentTranscriptFocus? {
        guard let message = messages.first(where: { $0.id == agent.messageID }),
              let toolID = agent.sourceTool?.id else { return nil }
        for block in message.blocks {
            guard case .tools(_, let nodes) = block else { continue }
            for entry in TranscriptActivityEntry.grouped(nodes) {
                guard case .agents(let agents) = entry,
                      ActivitySpine.flattened(agents).contains(where: { $0.id == toolID }),
                      let first = agents.first else { continue }
                return AgentTranscriptFocus(messageID: message.id, toolID: first.id)
            }
        }
        return nil
    }
}

struct SessionAgentIndicator: View {
    @Environment(SessionRunner.self) private var runner
    @Environment(ProjectStore.self) private var store

    let session: ChatSession
    let open: (AgentTranscriptFocus) -> Void

    var body: some View {
        let agents = WorkingSetSummary.activities(
            in: session.messages, activeTools: runner.runningTools(session.id),
            backgroundTasks: [], runningAgentIDs: runner.runningAgents(session.id),
            projectPath: store.workingDirectory(for: session) ?? "")
        let running = agents.filter { $0.state == .running }
        let latestPrompt = session.messages.last(where: { $0.role == .user })?.date ?? .distantPast
        let failed = agents.filter { $0.state == .failed && ($0.startedAt ?? .distantPast) >= latestPrompt }
        if let first = running.first ?? failed.first,
           let target = TranscriptAgents.target(for: first, in: session.messages) {
            let label = running.isEmpty
                ? "\(counted(failed.count, "agent")) failed"
                : "\(counted(running.count, "agent")) running"
            let colour = running.isEmpty ? Theme.deletion : Theme.accent
            Button { open(target) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "person.2.fill")
                    Text(label)
                }
                .font(.mono(10, .medium))
                .foregroundStyle(colour)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .surface(Theme.card, cornerRadius: 12)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .hoverLift()
            .fixedSize()
            .accessibilityLabel(label)
            .accessibilityHint("Shows delegated work in the transcript")
            .appTooltip("Show agents in the transcript")
        }
    }
}

struct TranscriptAgentGroup: View {
    @Environment(\.runningAgents) private var runningAgents
    @Environment(\.activeTranscriptTools) private var activeTools
    @Environment(\.agentTranscriptFocus) private var focus
    @State private var expanded: Bool?

    let nodes: [ToolNode]
    let messageID: UUID?
    let projectPath: String
    let openChange: ((String) -> Void)?
    let runInShell: ((String) -> Void)?

    private var anchor: String {
        "agents:\(messageID?.uuidString ?? "preview"):\(nodes[0].id)"
    }

    var body: some View {
        let message = ChatMessage(id: messageID ?? UUID(), role: .assistant,
                                  tools: ActivitySpine.flattened(nodes).map(\.tool))
        let roots = Set(nodes.map(\.id))
        let agents = WorkingSetSummary.activities(
            in: [message], activeTools: activeTools, backgroundTasks: [],
            runningAgentIDs: runningAgents, projectPath: projectPath)
            .filter { $0.sourceTool.map { roots.contains($0.id) } == true }
        let running = agents.contains { $0.state == .running }
        let isExpanded = expanded ?? running

        VStack(alignment: .leading, spacing: 0) {
            Button { expanded = !isExpanded } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 9) {
                        heading(agents.count)
                        Spacer(minLength: 8)
                        reading(agents)
                        chevron(isExpanded)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { heading(agents.count); Spacer(); chevron(isExpanded) }
                        reading(agents)
                    }
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverFill(cornerRadius: 10)
            .accessibilityLabel("Delegated to \(counted(agents.count, "agent")), \(TranscriptAgents.summary(agents))")
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")

            if isExpanded {
                ForEach(agents) { agent in
                    Divider().overlay(Theme.hairline)
                    TranscriptAgentRow(
                        activity: agent,
                        children: nodes.first(where: { $0.id == agent.sourceTool?.id })?.children ?? [],
                        messageID: messageID, projectPath: projectPath,
                        openChange: openChange, runInShell: runInShell,
                        onExpand: { expanded = true })
                }
            }
        }
        .cardSurface(cornerRadius: 10)
        .id(anchor)
        .smoothlyResizes(when: isExpanded)
        .onChange(of: focus, initial: true) {
            if focus?.anchor == anchor { expanded = true }
        }
    }

    private func heading(_ count: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "person.2.fill").foregroundStyle(Theme.accent)
            Text("Delegated to \(counted(count, "agent"))")
        }
        .scaledMono(11.5, .semibold)
    }

    private func reading(_ agents: [WorkingSetActivity]) -> some View {
        Text(TranscriptAgents.summary(agents))
            .scaledMono(10)
            .foregroundStyle(agents.contains { $0.state == .failed } ? Theme.deletion : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chevron(_ expanded: Bool) -> some View {
        Text(expanded ? "▾" : "▸").scaledMono(11).foregroundStyle(.secondary)
    }
}

private struct TranscriptAgentRow: View {
    @State private var expanded = false

    let activity: WorkingSetActivity
    let children: [ToolNode]
    let messageID: UUID?
    let projectPath: String
    let openChange: ((String) -> Void)?
    let runInShell: ((String) -> Void)?
    let onExpand: () -> Void

    private var identity: (task: String, name: String?) {
        guard let tool = activity.sourceTool else { return (activity.title, nil) }
        let fields = (try? JSONSerialization.jsonObject(with: Data(tool.input.utf8))) as? [String: Any]
        let name = tool.agentTask?.task.agentName ?? fields?["name"] as? String
            ?? fields?["subagent_type"] as? String
        let task = tool.agentTask?.task.description ?? fields?["description"] as? String
        if WorkingSetSummary.collaboratingAgentNames(in: tool) != nil { return (activity.title, nil) }
        let title = task.flatMap { $0.isBlank ? nil : $0 } ?? activity.title
        return (title, name?.isBlank == false ? name : nil)
    }

    private var stateColour: Color {
        switch activity.state {
        case .running, .completed: Theme.accent
        case .failed: Theme.deletion
        case .interrupted: Theme.secret
        case .finished: .secondary
        }
    }

    var body: some View {
        let identity = identity
        let tint = Theme.projectTint(for: activity.title)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
                if expanded { onExpand() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint.ink)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(tint.fill))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identity.task).scaledMono(11.5, .medium)
                            .fixedSize(horizontal: false, vertical: true)
                        if let name = identity.name, name != identity.task {
                            Text(name).scaledMono(10).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 2) {
                        Label(activity.state.label, systemImage: activity.state.symbol)
                            .scaledMono(10).foregroundStyle(stateColour)
                        elapsed
                    }
                    .fixedSize()
                    Text(expanded ? "▾" : "▸").scaledMono(11).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverFill(cornerRadius: 8)
            .accessibilityLabel("\(activity.title), \(activity.state.label)")
            .accessibilityValue(expanded ? "expanded" : "collapsed")

            if expanded {
                if !children.isEmpty {
                    AnyView(ActivitySpine(nodes: children, projectPath: projectPath,
                                          messageID: messageID, openChange: openChange,
                                          runInShell: runInShell))
                }
                if let tool = reportTool {
                    ToolCallExpandedDetail(tool: tool, projectPath: projectPath, isRunning: false)
                } else if let status = activity.sourceTool?.status, !status.isBlank {
                    Text(status).scaledMono(11).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if children.isEmpty {
                    Text(activity.state == .running ? "Waiting for agent activity…" : "No agent report was recorded.")
                        .scaledMono(11).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .smoothlyResizes(when: expanded)
    }

    private var reportTool: ToolUse? {
        guard var tool = activity.sourceTool else { return nil }
        if let task = tool.agentTask {
            tool.result = task.report
            tool.isError = task.state == .failed
        } else if activity.state == .running {
            return nil
        }
        return tool.result?.isBlank == false ? tool : nil
    }

    @ViewBuilder private var elapsed: some View {
        if let start = activity.startedAt {
            if activity.state == .running {
                ElapsedTime(since: start, size: 10, scaled: true)
                    .foregroundStyle(.secondary)
            } else if let end = activity.sourceTool?.agentTask?.finishedAt ?? activity.sourceTool?.finishedAt {
                Text(ElapsedTime.duration(max(0, end.timeIntervalSince(start))))
                    .scaledMono(10).foregroundStyle(.secondary)
            }
        }
    }
}
