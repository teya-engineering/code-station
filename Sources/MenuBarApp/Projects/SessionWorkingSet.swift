import SwiftUI

struct WorkingSetCommand: Identifiable, Equatable {
    enum State: Equatable {
        case running
        case completed
        case failed

        var label: String {
            switch self {
            case .running: "running"
            case .completed: "completed"
            case .failed: "failed"
            }
        }

        var symbol: String {
            switch self {
            case .running: "ellipsis"
            case .completed: "checkmark"
            case .failed: "xmark"
            }
        }
    }

    let id: String
    let command: String
    let state: State
}

enum WorkingSetSummary {
    static func verificationCommands(in messages: [ChatMessage], projectPath: String,
                                     limit: Int = 4) -> [WorkingSetCommand] {
        messages.flatMap(\.tools)
            .filter { $0.name == "Bash" }
            .suffix(max(0, limit))
            .map { tool in
                let presentation = ToolPresentation(tool: tool, projectPath: projectPath)
                let state: WorkingSetCommand.State = if tool.isRunning {
                    .running
                } else if tool.isError {
                    .failed
                } else {
                    .completed
                }
                return WorkingSetCommand(id: tool.id,
                                         command: presentation.argument.isEmpty
                                            ? presentation.label
                                            : presentation.argument,
                                         state: state)
            }
    }
}

struct SessionWorkingSet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(GitStatsCache.self) private var gitStats

    let session: ChatSession
    let close: () -> Void
    let editQueuedPrompt: (SessionRunner.QueuedPrompt) -> Void
    let openChange: (_ projectID: UUID, _ root: String, _ path: String) -> Void

    private struct TouchedFile: Identifiable {
        let projectID: UUID
        let projectName: String
        let root: String
        let change: GitChange

        var id: String { root + "\u{0}" + change.path }
    }

    private var state: SessionState { runner.state(session.id) }
    private var tone: SessionTone { SessionTone(session.id, store: store, runner: runner) }
    private var projectPath: String { store.workingDirectory(for: session) ?? "" }
    private var queued: [SessionRunner.QueuedPrompt] { runner.queued(session.id) }
    private var commands: [WorkingSetCommand] {
        WorkingSetSummary.verificationCommands(in: session.messages, projectPath: projectPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 11) {
                    nowPanel
                    nextPanel
                    filesPanel
                    verificationPanel
                }
                .padding(11)
            }
        }
        .frame(width: 304)
        .background(Theme.sidebar)
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

    private var nowPanel: some View {
        WorkingSetPanel(title: "NOW", trailing: nowTrailing) {
            if state.isBusy {
                VStack(alignment: .leading, spacing: 9) {
                    Text(currentActivity)
                        .font(.mono(10.5))
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Running in \((projectPath as NSString).lastPathComponent)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Text(state == .stopping ? "Stopping the current turn" : "Output stays in the conversation")
                            .font(.mono(8.5))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if state != .stopping {
                            ActionButton(title: "Stop", tone: .danger, height: 25, size: 10) {
                                runner.stop(session.id)
                            }
                        }
                    }
                }
                .padding(11)
            } else {
                emptyRow("No turn is running.")
            }
        }
    }

    private var nowTrailing: String? {
        guard state.isBusy, let started = runner.turnStarted(session.id) else { return nil }
        return RelativeTime.duration(since: started)
    }

    private var currentActivity: String {
        if let tool = runner.runningTool(session.id) {
            return ToolPresentation(tool: tool, projectPath: projectPath).label
        }
        if state == .waiting {
            return "Waiting for \(BackgroundTaskPhrase.of(runner.backgroundTasks(session.id)))"
        }
        return "\(session.agent.title) is working"
    }

    private var nextPanel: some View {
        WorkingSetPanel(title: "NEXT",
                        trailing: queued.isEmpty ? nil : counted(queued.count, "queued prompt")) {
            if queued.isEmpty {
                emptyRow("Nothing is queued.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(queued.enumerated()), id: \.element.id) { index, prompt in
                        if index > 0 { Divider().overlay(Theme.hairline) }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(prompt.text.isBlank ? "Prompt with attachments" : prompt.text)
                                .font(.system(size: 11.5))
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 12) {
                                inlineButton("Edit") { editQueuedPrompt(prompt) }
                                inlineButton("Remove", tint: .secondary) {
                                    runner.unqueue(prompt.id, sessionID: session.id)
                                }
                            }
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var verificationPanel: some View {
        let completed = commands.count { $0.state == .completed }
        let trailing = commands.isEmpty ? nil : "\(completed) of \(commands.count) completed"
        return WorkingSetPanel(title: "VERIFICATION", trailing: trailing) {
            if commands.isEmpty {
                emptyRow("No commands have run yet.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        if index > 0 { Divider().overlay(Theme.hairline) }
                        HStack(alignment: .top, spacing: 8) {
                            verificationIcon(command.state)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(command.command)
                                    .font(.mono(10))
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                Text(command.state.label)
                                    .font(.mono(8.5))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
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

    private func inlineButton(_ title: String, tint: Color = Theme.accent,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private func verificationIcon(_ state: WorkingSetCommand.State) -> some View {
        let colour: Color = switch state {
        case .running, .completed: Theme.dotOn
        case .failed: Theme.deletion
        }
        return Image(systemName: state.symbol)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(colour)
            .frame(width: 18, height: 18)
            .background(Circle().fill(colour.opacity(0.12)))
            .overlay(Circle().stroke(colour.opacity(state == .running ? 0.35 : 0)))
            .accessibilityLabel(state.label)
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
