import Foundation

// An agent and everything it ran, as one span of the timeline. A task the CLI started on
// its own is carried here too: it has no actions to show, but it is work in flight that
// the sidebar has to account for.
struct WorkingSetActivity: Identifiable, Equatable {
    enum Kind: Equatable {
        case agent
        case backgroundTask

        var label: String {
            switch self {
            case .agent: "agent"
            case .backgroundTask: "background task"
            }
        }

        var symbol: String {
            switch self {
            case .agent: "person.fill"
            case .backgroundTask: "gearshape.fill"
            }
        }
    }

    let id: String
    let title: String
    let kind: Kind
    let state: WorkingSetToolCall.State
    let actions: [WorkingSetToolCall]
    // When the agent was sent. Nil for work read back from a conversation written before
    // the app kept times, which is what leaves a row without a clock.
    var startedAt: Date?
}

struct WorkingSetToolCall: Identifiable, Equatable {
    enum State: Equatable {
        case running
        case completed
        case failed
        case interrupted

        var label: String {
            switch self {
            case .running: "running"
            case .completed: "completed"
            case .failed: "failed"
            case .interrupted: "interrupted"
            }
        }

        var symbol: String {
            switch self {
            case .running: "ellipsis"
            case .completed: "checkmark"
            case .failed: "xmark"
            case .interrupted: "exclamationmark"
            }
        }
    }

    let id: String
    let title: String
    let state: State
    let tool: ToolUse
    var startedAt: Date?
}

// One thing that happened, in the order it happened: an agent with the work it did, or a
// single call the main loop made. The two are one stream because that is the order the
// person watching them saw.
struct WorkingSetTimelineEntry: Identifiable, Equatable {
    enum Content: Equatable {
        case agent(WorkingSetActivity)
        case call(WorkingSetToolCall)
    }

    let content: Content

    var id: String {
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

// A row of the NOW panel: one thing running this instant, and what it is doing.
struct WorkingSetRunningItem: Identifiable, Equatable {
    enum Origin: Equatable {
        case agent
        case mainThread
        case backgroundTask

        var label: String {
            switch self {
            case .agent: "agent"
            case .mainThread: "main thread"
            case .backgroundTask: "background task"
            }
        }
    }

    let id: String
    let title: String
    let origin: Origin
    // What the row says under its title: the agent's live child call where there is one,
    // and otherwise where the work is running.
    let detail: String
    let symbol: String
    let startedAt: Date?
}

// Who last wrote a file. Only agents are named; everything the main loop did reads as one
// worker, which is what lets the agent names stand out against it.
struct WorkingSetAttribution: Equatable {
    static let mainThread = WorkingSetAttribution(name: "main thread", isAgent: false)

    let name: String
    let isAgent: Bool
}

struct WorkingSetToolCallVisibility {
    static let limit = 5

    private var expandedLists: Set<String> = []

    func visible<Item>(_ items: [Item], in listID: String = "tools") -> [Item] {
        expandedLists.contains(listID) ? items : Array(items.suffix(Self.limit))
    }

    mutating func showAll(in listID: String = "tools") {
        expandedLists.insert(listID)
    }

    mutating func hideOlder(in listID: String = "tools") {
        expandedLists.remove(listID)
    }

    mutating func reset() {
        expandedLists.removeAll()
    }
}

// Which spans are open. A span nobody has touched follows its agent - open while it works,
// closed once it is done - so a finished fan-out folds itself away without ever hiding
// what is still moving. Opening or closing one by hand pins it that way for the session.
struct WorkingSetSpanExpansion {
    private var pinned: [String: Bool] = [:]

    func isExpanded(_ id: String, running: Bool) -> Bool { pinned[id] ?? running }

    mutating func toggle(_ id: String, running: Bool) {
        pinned[id] = !isExpanded(id, running: running)
    }

    mutating func reset() {
        pinned.removeAll()
    }
}

enum WorkingSetSummary {
    private struct PresentedOccurrence {
        let messageID: UUID
        let call: WorkingSetToolCall
    }

    // Everything that happened, oldest first, with each agent's work folded into the span
    // that started it.
    static func timeline(in messages: [ChatMessage], activeTools: [ToolUse],
                         backgroundTasks: [BackgroundTask], runningAgentIDs: Set<String>,
                         projectPath: String) -> [WorkingSetTimelineEntry] {
        let occurrences = presentedOccurrences(in: messages, activeTools: activeTools,
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
                    entries.append(WorkingSetTimelineEntry(content: .agent(span)))
                }
                continue
            }
            let belongsToAgent = if let parentID = tool.parentID {
                agentIDs[occurrence.messageID]?.contains(parentID) == true
            } else {
                false
            }
            guard !belongsToAgent else { continue }
            entries.append(WorkingSetTimelineEntry(content: .call(occurrence.call)))
        }
        // A task the CLI reported on its own has no call in the transcript to sit beside,
        // so it lands at the end, which is where the newest work belongs.
        entries += spans.filter { !placed.contains($0.id) }
            .map { WorkingSetTimelineEntry(content: .agent($0)) }
        return entries
    }

    // What the timeline holds, counted as the reader would count it: an agent is not an
    // event, the work it did is.
    static func eventCount(in entries: [WorkingSetTimelineEntry]) -> Int {
        entries.reduce(0) { count, entry in
            switch entry.content {
            case .agent(let activity): count + max(1, activity.actions.count)
            case .call: count + 1
            }
        }
    }

    static func running(in entries: [WorkingSetTimelineEntry]) -> [WorkingSetRunningItem] {
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

    // Which agent last wrote each file, keyed by the path the call named. Only an edit
    // says which file it changed in its own input; what a command changed was measured
    // off the working tree afterwards and cannot be traced back to a path, so a file no
    // edit names reads as the main loop's own work.
    static func attribution(in entries: [WorkingSetTimelineEntry],
                            projectPath: String) -> [String: WorkingSetAttribution] {
        var written: [String: WorkingSetAttribution] = [:]
        for entry in entries {
            switch entry.content {
            case .agent(let activity):
                let author = WorkingSetAttribution(name: activity.title,
                                                   isAgent: activity.kind == .agent)
                for action in activity.actions {
                    guard let path = editedPath(action.tool, projectPath: projectPath)
                    else { continue }
                    written[path] = author
                }
            case .call(let call):
                guard let path = editedPath(call.tool, projectPath: projectPath) else { continue }
                written[path] = .mainThread
            }
        }
        return written
    }

    // A change git reports names a path inside its own repository, while a call names the
    // file wherever it sits on disk. Matching the tail of the two is what joins them,
    // since a worktree puts the same repository path under a different root.
    static func attributor(of path: String, in root: String,
                           from written: [String: WorkingSetAttribution])
        -> WorkingSetAttribution {
        if let exact = written[(root as NSString).appendingPathComponent(path)] { return exact }
        let tail = "/" + path
        let match = written.keys.sorted().first { $0.hasSuffix(tail) }
        return match.flatMap { written[$0] } ?? .mainThread
    }

    static func activities(in messages: [ChatMessage], activeTools: [ToolUse],
                           backgroundTasks: [BackgroundTask], runningAgentIDs: Set<String>,
                           projectPath: String) -> [WorkingSetActivity] {
        let occurrences = presentedOccurrences(in: messages, activeTools: activeTools,
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
                            startedAt: existing.startedAt)
                    } else {
                        collaborationPositions[id] = activities.count
                        activities.append(WorkingSetActivity(
                            id: id, title: name, kind: .agent,
                            state: state, actions: ownedActions,
                            startedAt: agent.call.startedAt))
                    }
                }
                continue
            }

            let presentation = ToolPresentationCache.presentation(
                for: agent.call.tool, projectPath: projectPath)
            activities.append(WorkingSetActivity(
                id: agent.call.id,
                title: presentation.argument.isEmpty ? presentation.verb : presentation.argument,
                kind: .agent,
                state: state,
                actions: actions,
                startedAt: agent.call.startedAt))
        }

        let representedBackgroundIDs = Set(agents.flatMap { agent in
            [agent.call.tool.id, agent.call.tool.backgroundAgentID].compactMap { $0 }
        })
        activities += backgroundTasks.compactMap { task in
            let isAgent = task.agentName?.isBlank == false
                || task.kind == "local_agent" || task.kind == "local_workflow"
            guard !isAgent || !representedBackgroundIDs.contains(task.id) else { return nil }
            return WorkingSetActivity(id: "background:\(task.id)", title: task.label,
                                      kind: isAgent ? .agent : .backgroundTask,
                                      state: .running, actions: [],
                                      startedAt: task.startedAt)
        }
        return activities
    }

    private static func presentedOccurrences(in messages: [ChatMessage],
                                             activeTools: [ToolUse], projectPath: String)
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
            let state: WorkingSetToolCall.State = if !occurrence.tool.isRunning {
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

    private static func editedPath(_ tool: ToolUse, projectPath: String) -> String? {
        guard ToolUse.editTools.contains(tool.name) || tool.name == "NotebookEdit",
              let path = ToolPresentationCache
                  .presentation(for: tool, projectPath: projectPath).filePath
        else { return nil }
        return (path as NSString).isAbsolutePath
            ? path
            : (projectPath as NSString).appendingPathComponent(path)
    }

    private static func agentState(_ agent: WorkingSetToolCall,
                                   actions: [WorkingSetToolCall],
                                   runningAgentIDs: Set<String>) -> WorkingSetToolCall.State {
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
    private static func collaboratingAgentNames(in tool: ToolUse) -> [String]? {
        guard tool.name == "Agent", let data = tool.input.data(using: .utf8),
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = input["description"] as? String,
              ["spawned", "resumed", "sent more work", "closed", "waiting"].contains(action),
              let names = input["name"] as? String else { return nil }
        let split = names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return split.isEmpty ? nil : split
    }
}
