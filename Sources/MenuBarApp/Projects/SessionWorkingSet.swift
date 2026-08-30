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

    private var showingAll = false

    func visible(_ toolCalls: [WorkingSetToolCall]) -> [WorkingSetToolCall] {
        showingAll ? toolCalls : Array(toolCalls.suffix(Self.limit))
    }

    mutating func showAll() {
        showingAll = true
    }

    mutating func reset() {
        showingAll = false
    }
}

enum WorkingSetSummary {
    static func toolCalls(in messages: [ChatMessage], activeTools: [ToolUse],
                          projectPath: String) -> [WorkingSetToolCall] {
        let occurrences: [(id: String, tool: ToolUse)] = messages.flatMap { message in
            message.tools.enumerated().map { index, tool in
                (message.id.uuidString + "\u{0}" + String(index), tool)
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
            return WorkingSetToolCall(
                id: occurrence.id,
                title: presentation.label,
                state: state,
                tool: occurrence.tool)
        }
    }

    static func activities(runningTools: [ToolUse], backgroundTasks: [BackgroundTask],
                           projectPath: String) -> [WorkingSetActivity] {
        let agents = runningTools.filter(\.startsAgents).flatMap { tool in
            if let names = collaboratingAgentNames(in: tool) {
                return names.enumerated().map { index, name in
                    WorkingSetActivity(id: "\(tool.id)#\(index)", title: name, kind: .agent)
                }
            }

            let presentation = ToolPresentation(tool: tool, projectPath: projectPath)
            return [WorkingSetActivity(id: tool.id,
                                       title: presentation.argument.isEmpty
                                        ? presentation.verb
                                        : presentation.argument,
                                       kind: .agent)]
        }

        let tasks = backgroundTasks.map { task in
            let isAgent = task.agentName?.isBlank == false
                || task.kind == "local_agent" || task.kind == "local_workflow"
            return WorkingSetActivity(id: "background:\(task.id)", title: task.label,
                                      kind: isAgent ? .agent : .backgroundTask)
        }
        return agents + tasks
    }

    // Codex reports one collaboration call for a whole team. Its synthetic tool input
    // carries the names as a comma-separated field, so each live agent can have its own row.
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
        WorkingSetSummary.activities(runningTools: runner.runningTools(session.id),
                                     backgroundTasks: runner.activeBackgroundTasks(session.id),
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
                        trailing: counted(activities.count, "active item")) {
            VStack(spacing: 0) {
                ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                    if index > 0 { Divider().overlay(Theme.hairline) }
                    HStack(spacing: 8) {
                        Image(systemName: activity.kind.symbol)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.dotOn)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Theme.dotOn.opacity(0.12)))
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
                        RunningWord()
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .combine)
                }
            }
        }
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
                    if hidden > 0 {
                        WorkingSetSeeMoreRow(count: hidden) {
                            toolCallVisibility.showAll()
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

private struct WorkingSetSeeMoreRow: View {
    let count: Int
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 8, weight: .bold))
                Text("See \(count) more…")
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
        .accessibilityLabel("Show \(count) older tool calls")
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
