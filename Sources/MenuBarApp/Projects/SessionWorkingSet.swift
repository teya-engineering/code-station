import Foundation
import SwiftUI

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
}

struct WorkingSetToolCallVisibility {
    static let limit = 5

    private var expandedLists: Set<String> = []

    func visible(_ toolCalls: [WorkingSetToolCall], in listID: String = "tools")
        -> [WorkingSetToolCall] {
        expandedLists.contains(listID) ? toolCalls : Array(toolCalls.suffix(Self.limit))
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

enum WorkingSetSummary {
    private struct PresentedOccurrence {
        let messageID: UUID
        let call: WorkingSetToolCall
    }

    static func toolCalls(in messages: [ChatMessage], activeTools: [ToolUse],
                          projectPath: String) -> [WorkingSetToolCall] {
        let occurrences = presentedOccurrences(in: messages, activeTools: activeTools,
                                                projectPath: projectPath)
        let agentIDs = Dictionary(grouping: occurrences.filter { $0.call.tool.startsAgents },
                                  by: \.messageID)
            .mapValues { Set($0.map(\.call.tool.id)) }

        return occurrences.compactMap { occurrence in
            let tool = occurrence.call.tool
            let belongsToAgent = if let parentID = tool.parentID {
                agentIDs[occurrence.messageID]?.contains(parentID) == true
            } else {
                false
            }
            guard !tool.startsAgents, !belongsToAgent else { return nil }
            return occurrence.call
        }
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
                            actions: existing.actions + ownedActions)
                    } else {
                        collaborationPositions[id] = activities.count
                        activities.append(WorkingSetActivity(
                            id: id, title: name, kind: .agent,
                            state: state, actions: ownedActions))
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
                actions: actions))
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
                                      state: .running, actions: [])
        }
        return activities
    }

    private static func presentedOccurrences(in messages: [ChatMessage],
                                             activeTools: [ToolUse], projectPath: String)
        -> [PresentedOccurrence] {
        let occurrences: [(id: String, messageID: UUID, tool: ToolUse)] = messages.flatMap { message in
            message.tools.enumerated().map { index, tool in
                (message.id.uuidString + "\u{0}" + String(index), message.id, tool)
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
                    tool: occurrence.tool))
        }
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

struct SessionWorkingSet: View {
    static let width: CGFloat = 304

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(GitStatsCache.self) private var gitStats

    @State private var toolCallVisibility = WorkingSetToolCallVisibility()

    let session: ChatSession
    let close: () -> Void
    let openChange: (_ projectID: UUID, _ root: String, _ path: String) -> Void

    private struct TouchedFile: Identifiable {
        let projectID: UUID
        let projectName: String
        let root: String
        let change: GitChange

        var id: String { root + "\u{0}" + change.path }
    }

    private var tone: SessionTone { SessionTone(session.id, store: store, runner: runner) }
    private var projectPath: String { store.workingDirectory(for: session) ?? "" }
    private var activities: [WorkingSetActivity] {
        WorkingSetSummary.activities(in: session.messages,
                                     activeTools: runner.runningTools(session.id),
                                     backgroundTasks: runner.activeBackgroundTasks(session.id),
                                     runningAgentIDs: runner.runningAgents(session.id),
                                     projectPath: projectPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 11) {
                    if !activities.isEmpty { activityPanel }
                    toolCallsPanel
                    filesPanel
                }
                .padding(11)
            }
        }
        .frame(width: Self.width)
        .background(Theme.sidebar)
        .onChange(of: session.id) { _, _ in toolCallVisibility.reset() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Working set")
    }

    private var header: some View {
        HStack(spacing: 8) {
            StateLight(tone: tone)
            Text("WORKING SET")
                .font(.mono(9.5, .semibold))
                .kerning(1)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .appTooltip("Close working set")
            .accessibilityLabel("Close working set")
        }
        .padding(.horizontal, 14)
        .headerBand(height: Theme.subHeaderHeight)
    }

    private var activityPanel: some View {
        WorkingSetPanel(title: "AGENTS & TASKS",
                        trailing: counted(activities.count, "item")) {
            LazyVStack(spacing: 0) {
                ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                    if index > 0 { Divider().overlay(Theme.hairline) }
                    VStack(spacing: 0) {
                        activityRow(activity)
                        if !activity.actions.isEmpty {
                            let visible = toolCallVisibility.visible(
                                activity.actions, in: activity.id)
                            let hidden = activity.actions.count - visible.count
                            Divider().overlay(Theme.hairline).padding(.leading, 29)
                            if activity.actions.count > WorkingSetToolCallVisibility.limit {
                                if hidden > 0 {
                                    WorkingSetToolCallVisibilityRow(
                                        icon: "ellipsis",
                                        title: "See \(hidden) more…",
                                        accessibilityLabel:
                                            "Show \(hidden) older actions for \(activity.title)"
                                    ) {
                                        toolCallVisibility.showAll(in: activity.id)
                                    }
                                    .padding(.leading, 18)
                                } else {
                                    WorkingSetToolCallVisibilityRow(
                                        icon: "chevron.up",
                                        title: "Hide",
                                        accessibilityLabel:
                                            "Show only the five newest actions for \(activity.title)"
                                    ) {
                                        toolCallVisibility.hideOlder(in: activity.id)
                                    }
                                    .padding(.leading, 18)
                                }
                                Divider().overlay(Theme.hairline).padding(.leading, 29)
                            }
                            ForEach(Array(visible.enumerated()), id: \.element.id) {
                                actionIndex, action in
                                if actionIndex > 0 {
                                    Divider().overlay(Theme.hairline).padding(.leading, 29)
                                }
                                WorkingSetToolCallRow(call: action, projectPath: projectPath)
                                    .padding(.leading, 18)
                            }
                        }
                    }
                }
            }
        }
    }

    private func activityRow(_ activity: WorkingSetActivity) -> some View {
        HStack(spacing: 8) {
            Image(systemName: activity.kind.symbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(activity.state.colour)
                .frame(width: 18, height: 18)
                .background(Circle().fill(activity.state.colour.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.mono(10.5, .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(activity.kind.label)
                    .font(.mono(8.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if activity.state == .running {
                RunningWord()
            } else {
                Text(activity.state.label)
                    .font(.mono(8.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private var toolCallsPanel: some View {
        let toolCalls = WorkingSetSummary.toolCalls(
            in: session.messages,
            activeTools: runner.runningTools(session.id),
            projectPath: projectPath)
        let visible = toolCallVisibility.visible(toolCalls)
        let hidden = toolCalls.count - visible.count
        return WorkingSetPanel(title: "TOOL CALLS",
                               trailing: toolCalls.isEmpty ? nil : counted(toolCalls.count, "call")) {
            if toolCalls.isEmpty {
                emptyRow("No tool calls yet.")
            } else {
                LazyVStack(spacing: 0) {
                    if toolCalls.count > WorkingSetToolCallVisibility.limit {
                        if hidden > 0 {
                            WorkingSetToolCallVisibilityRow(
                                icon: "ellipsis",
                                title: "See \(hidden) more…",
                                accessibilityLabel: "Show \(hidden) older tool calls"
                            ) {
                                toolCallVisibility.showAll()
                            }
                        } else {
                            WorkingSetToolCallVisibilityRow(
                                icon: "chevron.up",
                                title: "Hide",
                                accessibilityLabel: "Show only the five newest tool calls"
                            ) {
                                toolCallVisibility.hideOlder()
                            }
                        }
                        Divider().overlay(Theme.hairline)
                    }
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, toolCall in
                        if index > 0 { Divider().overlay(Theme.hairline) }
                        WorkingSetToolCallRow(call: toolCall, projectPath: projectPath)
                    }
                }
            }
        }
    }

    private var filesPanel: some View {
        let files = touchedFiles
        return WorkingSetPanel(title: "TOUCHED FILES",
                               trailing: files.isEmpty ? nil : "\(files.count)") {
            if files.isEmpty {
                emptyRow("No uncommitted files.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        if index > 0 { Divider().overlay(Theme.hairline) }
                        Button {
                            openChange(file.projectID, file.root, file.change.path)
                        } label: {
                            HStack(spacing: 8) {
                                workingSetStatus(file.change.kind)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.change.fileName)
                                        .font(.mono(10.5, .semibold))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(file.projectName)
                                        .font(.mono(8.5))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                DiffPair(added: file.change.added ?? 0,
                                         removed: file.change.removed ?? 0,
                                         size: 8.5, spacing: 5)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .appTooltip("Open \(file.change.path) in Changes")
                        .accessibilityLabel("Open \(file.change.path) in Changes")
                    }
                }
            }
        }
    }

    private var touchedFiles: [TouchedFile] {
        store.checkoutProjects(for: session).flatMap { checkout -> [TouchedFile] in
            guard let project = store.project(checkout.projectID) else { return [] }
            let root = checkout.worktreePath ?? project.path
            guard let snapshot = gitStats.snapshot(at: root) else { return [] }
            return snapshot.files.map {
                TouchedFile(projectID: project.id, projectName: project.name,
                            root: root, change: $0)
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func workingSetStatus(_ kind: GitStatusKind) -> some View {
        let colour: Color = switch kind {
        case .modified: Theme.secret
        case .added, .untracked: Theme.dotOn
        case .deleted, .conflicted: Theme.deletion
        case .renamed: Theme.accent
        }
        return Text(kind.letter)
            .font(.mono(8.5, .bold))
            .foregroundStyle(colour)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(colour.opacity(0.14)))
            .accessibilityLabel(kind.label)
    }

}

private struct WorkingSetToolCallVisibilityRow: View {
    let icon: String
    let title: String
    let accessibilityLabel: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .bold))
                Text(title)
                    .font(.mono(9.5, .semibold))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(hovering ? Theme.field : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct WorkingSetToolCallRow: View {
    @Environment(ToolCallDetailPresenter.self) private var details

    let call: WorkingSetToolCall
    let projectPath: String

    @State private var anchor = FrameAnchor()
    @State private var hovering = false

    var body: some View {
        Button(action: showDetails) {
            HStack(alignment: .top, spacing: 8) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(call.title)
                        .font(.mono(10))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(call.state.label)
                        .font(.mono(8.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(hovering ? Theme.field : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(FrameAnchorView(anchor: anchor))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onChange(of: call) { _, call in
            details.refresh(call, projectPath: projectPath)
        }
        .onDisappear { details.dismiss(callID: call.id) }
        .accessibilityLabel(call.title)
        .accessibilityValue(call.state.label)
        .accessibilityHint("Shows the tool call input and output")
    }

    private var icon: some View {
        let colour = call.state.colour
        return Image(systemName: call.state.symbol)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(colour)
            .frame(width: 18, height: 18)
            .background(Circle().fill(colour.opacity(0.12)))
            .overlay(Circle().stroke(colour.opacity(call.state == .running ? 0.35 : 0)))
            .accessibilityHidden(true)
    }

    private func showDetails() {
        guard let frame = anchor.frame() else { return }
        details.toggle(call, projectPath: projectPath, from: frame)
    }
}

extension WorkingSetToolCall.State {
    var colour: Color {
        switch self {
        case .running, .completed: Theme.dotOn
        case .failed: Theme.deletion
        case .interrupted: Theme.secret
        }
    }
}

private struct WorkingSetPanel<Content: View>: View {
    let title: String
    let trailing: String?
    @ViewBuilder let content: Content

    init(title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.mono(8.5, .semibold))
                    .kerning(1)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if let trailing {
                    Text(trailing)
                        .font(.mono(8.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
            content
        }
        .cardSurface(cornerRadius: 11)
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }
}
