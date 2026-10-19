import Foundation

// An agent and everything it ran, as one span of the timeline. A task the CLI started on
// its own is carried here too: it has no actions to show, but it is work in flight that
// the sidebar has to account for.
public struct WorkingSetActivity: Identifiable, Equatable {
    public enum Kind: Equatable {
        case agent
        case backgroundTask

        public var label: String {
            switch self {
            case .agent: "agent"
            case .backgroundTask: "background task"
            }
        }

        public var symbol: String {
            switch self {
            case .agent: "person.fill"
            case .backgroundTask: "gearshape.fill"
            }
        }
    }

    public let id: String
    public let title: String
    public let kind: Kind
    public let state: WorkingSetToolCall.State
    public let actions: [WorkingSetToolCall]
    // When the agent was sent. Nil for work read back from a conversation written before
    // the app kept times, which is what leaves a row without a clock.
    public var startedAt: Date?
    public var sourceTool: ToolUse?
    public var messageID: UUID?
}

public struct WorkingSetToolCall: Identifiable, Equatable {
    public enum State: Equatable {
        case running
        case completed
        case failed
        case interrupted
        case finished

        public var label: String {
            switch self {
            case .running: "running"
            case .completed: "completed"
            case .failed: "failed"
            case .interrupted: "interrupted"
            case .finished: "finished"
            }
        }

        public var symbol: String {
            switch self {
            case .running: "ellipsis"
            case .completed: "checkmark"
            case .failed: "xmark"
            case .interrupted: "exclamationmark"
            case .finished: "minus"
            }
        }
    }

    public let id: String
    public let title: String
    public let state: State
    public let tool: ToolUse
    public var startedAt: Date?
}

// One thing that happened, in the order it happened: an agent with the work it did, or a
// single call the main loop made. The two are one stream because that is the order the
// person watching them saw.
public struct WorkingSetTimelineEntry: Identifiable, Equatable {
    public enum Content: Equatable {
        case agent(WorkingSetActivity)
        case call(WorkingSetToolCall)
    }

    public let content: Content
    // The message the work sits in, which is what ties it to the prompt that started it.
    // Nil for a task the CLI reported on its own.
    public var messageID: UUID? = nil

    public var id: String {
        switch content {
        case .agent(let activity): "agent\u{0}" + activity.id
        case .call(let call): "call\u{0}" + call.id
        }
    }

    var title: String {
        switch content {
        case .agent(let activity): activity.title
        case .call(let call): call.title
        }
    }

    var state: WorkingSetToolCall.State {
        switch content {
        case .agent(let activity): activity.state
        case .call(let call): call.state
        }
    }

    var startedAt: Date? {
        switch content {
        case .agent(let activity): activity.startedAt
        case .call(let call): call.startedAt
        }
    }
}

// One prompt and everything that happened because of it. The prompt is what the person
// remembers sending, so it is the handle they look back through the work by.
public struct WorkingSetTurn: Identifiable, Equatable {
    public let id: String
    public let prompt: String
    // Nil for work that ran before any prompt, which only an imported conversation has.
    public let sentAt: Date?
    public let entries: [WorkingSetTimelineEntry]
}

// One thing running this instant, and what it is doing.
public struct WorkingSetRunningItem: Identifiable, Equatable {
    public enum Origin: Equatable {
        case agent
        case mainThread
        case backgroundTask

        public var label: String {
            switch self {
            case .agent: "agent"
            case .mainThread: "main thread"
            case .backgroundTask: "background task"
            }
        }
    }

    public let id: String
    public let title: String
    public let origin: Origin
    // What the row says under its title: the agent's live child call where there is one,
    // and otherwise where the work is running.
    public let detail: String
    public let symbol: String
    public let startedAt: Date?
}

public struct WorkingSetToolCallVisibility {
    public static let limit = 5

    private var expandedLists: Set<String> = []

    public init() {}

    public func visible<Item>(_ items: [Item], in listID: String = "tools") -> [Item] {
        expandedLists.contains(listID) ? items : Array(items.suffix(Self.limit))
    }

    public mutating func showAll(in listID: String = "tools") {
        expandedLists.insert(listID)
    }

    public mutating func hideOlder(in listID: String = "tools") {
        expandedLists.remove(listID)
    }

    public mutating func reset() {
        expandedLists.removeAll()
    }
}

// Which spans and prompts are open. One nobody has touched follows its default: a span is
// open while its agent works and a prompt while it is the newest, so finished work folds
// itself away without ever hiding what is still moving. Opening or closing one by hand
// pins it that way for the session.
public struct WorkingSetExpansion {
    private var pinned: [String: Bool] = [:]

    public init() {}

    public func isExpanded(_ id: String, byDefault: Bool) -> Bool { pinned[id] ?? byDefault }

    public mutating func toggle(_ id: String, byDefault: Bool) {
        pinned[id] = !isExpanded(id, byDefault: byDefault)
    }

    public mutating func reset() {
        pinned.removeAll()
    }
}

public enum WorkingSetSummary {
    private struct PresentedOccurrence {
        let messageID: UUID
        let call: WorkingSetToolCall
    }

    // Everything that happened, oldest first, with each agent's work folded into the span
    // that started it.
    public static func timeline(in messages: [ChatMessage], activeTools: [ToolUse],
                         backgroundTasks: [AgentBackgroundTask], runningAgentIDs: Set<String>,
                         projectPath: String) -> [WorkingSetTimelineEntry] {
        let occurrences = presentedOccurrences(in: messages, activeTools: activeTools,
                                                runningAgentIDs: runningAgentIDs,
                                                projectPath: projectPath)
        let spans = activities(in: messages, activeTools: activeTools,
                               backgroundTasks: backgroundTasks,
                               runningAgentIDs: runningAgentIDs, projectPath: projectPath)
        let spansByID = Dictionary(spans.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        let agentIDs = Dictionary(grouping: occurrences.filter { $0.call.tool.startsAgents },
                                  by: \.messageID)
            .mapValues { Set($0.map(\.call.tool.id)) }

        var entries: [WorkingSetTimelineEntry] = []
        var placed: Set<String> = []
        for occurrence in occurrences {
            let tool = occurrence.call.tool
            guard !tool.startsAgents else {
                for id in spanIDs(startedBy: occurrence.call) where !placed.contains(id) {
                    guard let span = spansByID[id] else { continue }
                    placed.insert(id)
                    entries.append(WorkingSetTimelineEntry(content: .agent(span),
                                                           messageID: occurrence.messageID))
                }
                continue
            }
            let belongsToAgent = if let parentID = tool.parentID {
                agentIDs[occurrence.messageID]?.contains(parentID) == true
            } else {
                false
            }
            guard !belongsToAgent else { continue }
            entries.append(WorkingSetTimelineEntry(content: .call(occurrence.call),
                                                   messageID: occurrence.messageID))
        }
        // A task the CLI reported on its own has no call in the transcript to sit beside,
        // so it lands at the end, which is where the newest work belongs.
        entries += spans.filter { !placed.contains($0.id) }
            .map { WorkingSetTimelineEntry(content: .agent($0)) }
        return entries
    }

    // What the timeline holds, counted as the reader would count it: an agent is not an
    // event, the work it did is.
    public static func eventCount(in entries: [WorkingSetTimelineEntry]) -> Int {
        entries.reduce(0) { count, entry in
            switch entry.content {
            case .agent(let activity): count + max(1, activity.actions.count)
            case .call: count + 1
            }
        }
    }

    // The calls that failed, counted the way events are: inside an agent it is the agent's
    // own calls that count, and an agent with none counts once for itself.
    public static func failureCount(in entries: [WorkingSetTimelineEntry]) -> Int {
        entries.reduce(0) { count, entry in
            switch entry.content {
            case .agent(let activity) where activity.actions.isEmpty:
                count + (activity.state == .failed ? 1 : 0)
            case .agent(let activity):
                count + activity.actions.filter { $0.state == .failed }.count
            case .call(let call):
                count + (call.state == .failed ? 1 : 0)
            }
        }
    }

    // The timeline cut at each prompt, oldest first. A prompt with nothing to show still
    // gets its turn, since a question that only got an answer is part of the story too.
    public static func turns(in messages: [ChatMessage],
                      entries: [WorkingSetTimelineEntry]) -> [WorkingSetTurn] {
        var prompts: [(id: String, prompt: String, sentAt: Date?)] = []
        var turnOfMessage: [UUID: Int] = [:]
        for message in messages {
            if message.role == .user {
                prompts.append((message.id.uuidString, promptText(of: message), message.date))
            } else if prompts.isEmpty {
                prompts.append(("start", "Before the first prompt", nil))
            }
            turnOfMessage[message.id] = prompts.count - 1
        }
        if prompts.isEmpty, !entries.isEmpty {
            prompts.append(("start", "Before the first prompt", nil))
        }

        var grouped = Array(repeating: [WorkingSetTimelineEntry](), count: prompts.count)
        for entry in entries {
            // Work with no message of its own is happening now, so it joins the newest turn.
            let turn = entry.messageID.flatMap { turnOfMessage[$0] } ?? prompts.count - 1
            grouped[turn].append(entry)
        }
        return prompts.indices.map { index in
            WorkingSetTurn(id: prompts[index].id, prompt: prompts[index].prompt,
                           sentAt: prompts[index].sentAt, entries: grouped[index])
        }
    }

    private static func promptText(of message: ChatMessage) -> String {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        let files = (message.attachments ?? []).map { ($0 as NSString).lastPathComponent }
        return files.isEmpty ? "Empty prompt" : files.joined(separator: ", ")
    }

    public static func running(in entries: [WorkingSetTimelineEntry]) -> [WorkingSetRunningItem] {
        entries.compactMap { entry in
            switch entry.content {
            case .agent(let activity):
                guard activity.state == .running else { return nil }
                let origin: WorkingSetRunningItem.Origin =
                    activity.kind == .agent ? .agent : .backgroundTask
                let live = activity.actions.last { $0.state == .running }
                return WorkingSetRunningItem(
                    id: entry.id, title: activity.title, origin: origin,
                    detail: live.map { "now: \($0.title)" } ?? origin.label,
                    symbol: activity.kind.symbol, startedAt: activity.startedAt)
            case .call(let call):
                guard call.state == .running else { return nil }
                return WorkingSetRunningItem(
                    id: entry.id, title: call.title, origin: .mainThread,
                    detail: WorkingSetRunningItem.Origin.mainThread.label,
                    symbol: symbol(for: call.tool), startedAt: call.startedAt)
            }
        }
    }

    public static func activities(in messages: [ChatMessage], activeTools: [ToolUse],
                           backgroundTasks: [AgentBackgroundTask], runningAgentIDs: Set<String>,
                           projectPath: String) -> [WorkingSetActivity] {
        let occurrences = presentedOccurrences(in: messages, activeTools: activeTools,
                                                runningAgentIDs: runningAgentIDs,
                                                projectPath: projectPath)
        let agents = occurrences.filter { $0.call.tool.startsAgents }
        var activities: [WorkingSetActivity] = []
        var collaborationPositions: [String: Int] = [:]

        for agent in agents {
            let actions: [WorkingSetToolCall] = occurrences.compactMap { occurrence in
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
                        activities[position] = WorkingSetActivity(
                            id: id,
                            title: name,
                            kind: .agent,
                            state: mergedAgentState(existing.state, state),
                            actions: existing.actions + ownedActions,
                            startedAt: existing.startedAt,
                            sourceTool: agent.call.tool, messageID: agent.messageID)
                    } else {
                        collaborationPositions[id] = activities.count
                        activities.append(WorkingSetActivity(
                            id: id, title: name, kind: .agent,
                            state: state, actions: ownedActions,
                            startedAt: agent.call.startedAt,
                            sourceTool: agent.call.tool, messageID: agent.messageID))
                    }
                }
                continue
            }

            let presentation = ToolPresentationCache.presentation(
                for: agent.call.tool, projectPath: projectPath)
            activities.append(WorkingSetActivity(
                id: agent.call.id,
                title: agent.call.tool.agentTask?.task.label
                    ?? (presentation.argument.isEmpty ? presentation.verb : presentation.argument),
                kind: .agent,
                state: state,
                actions: actions,
                startedAt: agent.call.tool.agentTask?.task.startedAt ?? agent.call.startedAt,
                sourceTool: agent.call.tool, messageID: agent.messageID))
        }

        let representedBackgroundIDs = Set(agents.flatMap { agent in
            [agent.call.tool.id, agent.call.tool.backgroundAgentID].compactMap { $0 }
        })
        activities += backgroundTasks.compactMap { task in
            let isAgent = task.isAgent
            guard !isAgent || !representedBackgroundIDs.contains(task.id) else { return nil }
            return WorkingSetActivity(id: "background:\(task.id)", title: task.label,
                                      kind: isAgent ? .agent : .backgroundTask,
                                      state: .running, actions: [],
                                      startedAt: task.startedAt)
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
            let state: WorkingSetToolCall.State = if let task = occurrence.tool.agentTask {
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
                call: WorkingSetToolCall(
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

    // The spans one agent call stands for. A team reported as a single collaboration call
    // is several agents, and each of them keeps a span of its own.
    private static func spanIDs(startedBy agent: WorkingSetToolCall) -> [String] {
        collaboratingAgentNames(in: agent.tool)?.map { "collaboration:\($0)" } ?? [agent.id]
    }

    // The glyph on a running main-thread row. Only a few kinds are worth telling apart at
    // this size; everything else reads as a command.
    private static func symbol(for tool: ToolUse) -> String {
        switch tool.name {
        case "Read", "NotebookRead": "doc.text"
        case "Edit", "Write", "Delete", "NotebookEdit": "pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        default: "terminal"
        }
    }

    private static func agentState(_ agent: WorkingSetToolCall,
                                   actions: [WorkingSetToolCall],
                                   runningAgentIDs: Set<String>) -> WorkingSetToolCall.State {
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

    private static func mergedAgentState(_ earlier: WorkingSetToolCall.State,
                                         _ later: WorkingSetToolCall.State)
        -> WorkingSetToolCall.State {
        earlier == .running || later == .running ? .running : later
    }

    // Codex reports one collaboration call for a whole team. Its synthetic tool input
    // carries the names as a comma-separated field, so repeated updates can be folded
    // into one durable row per agent.
    public static func collaboratingAgentNames(in tool: ToolUse) -> [String]? {
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
