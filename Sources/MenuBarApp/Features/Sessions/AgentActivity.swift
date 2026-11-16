import Foundation

struct AgentActivity: Identifiable, Equatable {
    let id: String
    let title: String
    let state: AgentToolCall.State
    let actions: [AgentToolCall]
    // When the agent was sent. Nil for work read back from a conversation written before
    // the app kept times, which is what leaves a row without a clock.
    var startedAt: Date?
    var sourceTool: ToolUse?
    var messageID: UUID?
}

struct AgentToolCall: Identifiable, Equatable {
    enum State: Equatable {
        case running
        case completed
        case failed
        case interrupted
        case finished

        var label: String {
            switch self {
            case .running: "running"
            case .completed: "completed"
            case .failed: "failed"
            case .interrupted: "interrupted"
            case .finished: "finished"
            }
        }

        var symbol: String {
            switch self {
            case .running: "ellipsis"
            case .completed: "checkmark"
            case .failed: "xmark"
            case .interrupted: "exclamationmark"
            case .finished: "minus"
            }
        }
    }

    let id: String
    let title: String
    let state: State
    let tool: ToolUse
    var startedAt: Date?
}

enum AgentActivitySummary {
    private struct PresentedOccurrence {
        let messageID: UUID
        let call: AgentToolCall
    }

    static func activities(in messages: [ChatMessage], activeTools: [ToolUse],
                           runningAgentIDs: Set<String>,
                           projectPath: String) -> [AgentActivity] {
        let occurrences = presentedOccurrences(in: messages, activeTools: activeTools,
                                                runningAgentIDs: runningAgentIDs,
                                                projectPath: projectPath)
        let agents = occurrences.filter { $0.call.tool.startsAgents }
        var activities: [AgentActivity] = []
        var collaborationPositions: [String: Int] = [:]

        for agent in agents {
            let actions: [AgentToolCall] = occurrences.compactMap { occurrence in
                guard occurrence.messageID == agent.messageID,
                      occurrence.call.tool.parentID == agent.call.tool.id,
                      !occurrence.call.tool.startsAgents else { return nil }
                return occurrence.call
            }
            let state = agentState(agent.call, actions: actions,
                                   runningAgentIDs: runningAgentIDs)

            if let names = collaboratingAgentNames(in: agent.call.tool) {
                for name in names {
                    let id = "collaboration:\(name)"
                    let ownedActions = names.count == 1 ? actions : []
                    if let position = collaborationPositions[id] {
                        let existing = activities[position]
                        activities[position] = AgentActivity(
                            id: id,
                            title: name,
                            state: mergedAgentState(existing.state, state),
                            actions: existing.actions + ownedActions,
                            startedAt: existing.startedAt,
                            sourceTool: agent.call.tool, messageID: agent.messageID)
                    } else {
                        collaborationPositions[id] = activities.count
                        activities.append(AgentActivity(
                            id: id, title: name, state: state, actions: ownedActions,
                            startedAt: agent.call.startedAt,
                            sourceTool: agent.call.tool, messageID: agent.messageID))
                    }
                }
                continue
            }

            let presentation = ToolPresentationCache.presentation(
                for: agent.call.tool, projectPath: projectPath)
            activities.append(AgentActivity(
                id: agent.call.id,
                title: agent.call.tool.agentTask?.task.label
                    ?? (presentation.argument.isEmpty ? presentation.verb : presentation.argument),
                state: state,
                actions: actions,
                startedAt: agent.call.tool.agentTask?.task.startedAt ?? agent.call.startedAt,
                sourceTool: agent.call.tool, messageID: agent.messageID))
        }

        return activities
    }

    private static func presentedOccurrences(in messages: [ChatMessage],
                                             activeTools: [ToolUse], runningAgentIDs: Set<String>,
                                             projectPath: String)
        -> [PresentedOccurrence] {
        let occurrences: [(id: String, messageID: UUID, date: Date, tool: ToolUse)] =
            messages.flatMap { message in
                message.tools.enumerated().map { index, tool in
                    (message.id.uuidString + "\u{0}" + String(index), message.id,
                     message.date, tool)
                }
            }

        var activeCounts = activeTools.reduce(into: [:]) { counts, tool in
            counts[tool.id, default: 0] += 1
        }
        var activeOccurrences: Set<String> = []
        // A CLI can reuse an id in a later turn, while the runner only knows the raw id.
        // Matching from the end keeps an old unfinished call from looking live again.
        for occurrence in occurrences.reversed() where occurrence.tool.isRunning {
            guard let count = activeCounts[occurrence.tool.id], count > 0 else { continue }
            activeOccurrences.insert(occurrence.id)
            activeCounts[occurrence.tool.id] = count - 1
        }

        return occurrences.map { occurrence in
            let presentation = ToolPresentationCache.presentation(
                for: occurrence.tool, projectPath: projectPath)
            let state: AgentToolCall.State = if let task = occurrence.tool.agentTask {
                switch task.state {
                case .running:
                    runningAgentIDs.contains(task.task.id) ? .running : .interrupted
                case .finished: .finished
                case .completed: .completed
                case .failed: .failed
                case .interrupted: .interrupted
                }
            } else if !occurrence.tool.isRunning {
                occurrence.tool.isError ? .failed : .completed
            } else if activeOccurrences.contains(occurrence.id) {
                .running
            } else {
                .interrupted
            }
            return PresentedOccurrence(
                messageID: occurrence.messageID,
                call: AgentToolCall(
                    id: occurrence.id,
                    title: presentation.label,
                    state: state,
                    tool: occurrence.tool,
                    // A call from a conversation written before the app stamped them
                    // falls back to the turn it sits in, which is as close as anything
                    // gets after the fact.
                    startedAt: occurrence.tool.startedAt ?? occurrence.date))
        }
    }

    private static func agentState(_ agent: AgentToolCall,
                                   actions: [AgentToolCall],
                                   runningAgentIDs: Set<String>) -> AgentToolCall.State {
        if agent.tool.agentTask != nil { return agent.state }
        if agent.state == .running
            || actions.contains(where: { $0.state == .running })
            || agent.tool.backgroundAgentID.map(runningAgentIDs.contains) == true {
            return .running
        }
        if agent.state == .failed || actions.contains(where: { $0.state == .failed }) {
            return .failed
        }
        return agent.state
    }

    private static func mergedAgentState(_ earlier: AgentToolCall.State,
                                         _ later: AgentToolCall.State)
        -> AgentToolCall.State {
        earlier == .running || later == .running ? .running : later
    }

    // Codex reports one collaboration call for a whole team. Its synthetic tool input
    // carries the names as a comma-separated field, so repeated updates can be folded
    // into one durable row per agent.
    static func collaboratingAgentNames(in tool: ToolUse) -> [String]? {
        guard tool.name == "Agent", tool.agentTask == nil,
              let data = tool.input.data(using: .utf8),
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = input["description"] as? String,
              ["spawned", "resumed", "sent more work", "closed", "waiting"].contains(action),
              let names = input["name"] as? String else { return nil }
        let split = names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return split.isEmpty ? nil : split
    }
}
