import Foundation
import SwiftUI

// The sidebar that says what a session is doing and what it has done: what is running
// this instant, the stream of everything that happened, and the files it left changed.
struct SessionWorkingSet: View {
    static let width: CGFloat = 304

    // The timeline is one list, so one name is enough to remember how far it is opened.
    private static let timelineList = "timeline"

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(GitStatsCache.self) private var gitStats

    @State private var visibility = WorkingSetToolCallVisibility()
    @State private var spans = WorkingSetSpanExpansion()

    let session: ChatSession
    let close: () -> Void
    let openChange: (_ projectID: UUID, _ root: String, _ path: String) -> Void

    private struct TouchedFile: Identifiable {
        let projectID: UUID
        let projectName: String
        let root: String
        let change: GitChange
        let author: WorkingSetAttribution

        var id: String { root + "\u{0}" + change.path }
    }

    private var tone: SessionTone { SessionTone(session.id, store: store, runner: runner) }
    private var projectPath: String { store.workingDirectory(for: session) ?? "" }
    private var timeline: [WorkingSetTimelineEntry] {
        WorkingSetSummary.timeline(in: session.messages,
                                   activeTools: runner.runningTools(session.id),
                                   backgroundTasks: runner.activeBackgroundTasks(session.id),
                                   runningAgentIDs: runner.runningAgents(session.id),
                                   projectPath: projectPath)
    }

    var body: some View {
        let entries = timeline
        let running = WorkingSetSummary.running(in: entries)
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 11) {
                    if !running.isEmpty { nowPanel(running) }
                    timelinePanel(entries)
                    filesPanel(entries)
                }
                .padding(11)
            }
        }
        .frame(width: Self.width)
        .background(Theme.sidebar)
        .onChange(of: session.id) { _, _ in
            visibility.reset()
            spans.reset()
        }
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

    // MARK: - Now

    private func nowPanel(_ running: [WorkingSetRunningItem]) -> some View {
        WorkingSetPanel(title: "NOW", accent: Theme.dotOn) {
            PanelReading("\(running.count) running")
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(running.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().overlay(Theme.hairline) }
                    runningRow(item)
                }
            }
        }
    }

    private func runningRow(_ item: WorkingSetRunningItem) -> some View {
        let ink = WorkingSetInk.of(item)
        return HStack(spacing: 8) {
            Image(systemName: item.symbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(ink.ink)
                .frame(width: 18, height: 18)
                .background(Circle().fill(ink.fill))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.mono(10.5, .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(.mono(8.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let startedAt = item.startedAt { ElapsedTime(since: startedAt) }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Timeline

    private func timelinePanel(_ entries: [WorkingSetTimelineEntry]) -> some View {
        // Newest first: what just happened is what the sidebar was opened for, and the
        // older work trails off below it.
        let visible = Array(visibility.visible(entries, in: Self.timelineList).reversed())
        let hidden = entries.count - visible.count
        return WorkingSetPanel(title: "TIMELINE") {
            PanelReading(entries.isEmpty
                         ? nil
                         : counted(WorkingSetSummary.eventCount(in: entries), "event"))
        } content: {
            if entries.isEmpty {
                emptyRow("No activity yet.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().overlay(Theme.hairline) }
                        switch entry.content {
                        case .agent(let activity):
                            spanView(activity)
                        case .call(let call):
                            WorkingSetTimelineRow(call: call, projectPath: projectPath)
                        }
                    }
                    if entries.count > WorkingSetToolCallVisibility.limit {
                        Divider().overlay(Theme.hairline)
                        if hidden > 0 {
                            WorkingSetVisibilityRow(
                                icon: "ellipsis",
                                title: "See \(hidden) earlier…",
                                accessibilityLabel: "Show \(hidden) earlier events"
                            ) {
                                visibility.showAll(in: Self.timelineList)
                            }
                        } else {
                            WorkingSetVisibilityRow(
                                icon: "chevron.up",
                                title: "Hide",
                                accessibilityLabel: "Show only the five newest events"
                            ) {
                                visibility.hideOlder(in: Self.timelineList)
                            }
                        }
                    }
                }
            }
        }
    }

    private func spanView(_ activity: WorkingSetActivity) -> some View {
        let ink = WorkingSetInk.of(activity)
        let running = activity.state == .running
        let expanded = spans.isExpanded(activity.id, running: running)
        return VStack(spacing: 0) {
            spanHeader(activity, ink: ink, expanded: expanded, running: running)
            if expanded, !activity.actions.isEmpty {
                Divider().overlay(Theme.hairline)
                spanActions(activity)
            }
        }
        // The rail runs the whole height of the span, which is what says where the
        // agent's work starts and stops.
        .overlay(alignment: .leading) {
            Rectangle().fill(ink.rail).frame(width: 2)
        }
    }

    private func spanHeader(_ activity: WorkingSetActivity, ink: WorkingSetInk,
                            expanded: Bool, running: Bool) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                spans.toggle(activity.id, running: running)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Image(systemName: activity.kind.symbol)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(ink.ink)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(ink.fill))
                Text(activity.title)
                    .font(.mono(10.5, .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                spanSummary(activity, ink: ink, expanded: expanded)
            }
            .padding(.leading, 9)
            .padding(.trailing, 11)
            .padding(.vertical, 8)
            .background(expanded ? ink.rail.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(activity.title)
        .accessibilityValue(activity.state.label)
        .accessibilityHint(expanded ? "Hides what this agent ran" : "Shows what this agent ran")
    }

    private func spanSummary(_ activity: WorkingSetActivity, ink: WorkingSetInk,
                             expanded: Bool) -> some View {
        HStack(spacing: 4) {
            if !activity.actions.isEmpty {
                Text(counted(activity.actions.count, "action") + (expanded ? "" : " ·"))
                    .font(.mono(8.5, expanded ? .semibold : .regular))
                    .foregroundStyle(expanded ? ink.ink : Color.secondary)
            }
            if !expanded {
                Image(systemName: activity.state.symbol)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(activity.state.colour)
            }
        }
        .accessibilityHidden(true)
    }

    private func spanActions(_ activity: WorkingSetActivity) -> some View {
        let visible = visibility.visible(activity.actions, in: activity.id)
        let hidden = activity.actions.count - visible.count
        return VStack(spacing: 0) {
            if activity.actions.count > WorkingSetToolCallVisibility.limit {
                if hidden > 0 {
                    WorkingSetVisibilityRow(
                        icon: "ellipsis",
                        title: "See \(hidden) more…",
                        indent: WorkingSetTimelineRow.childIndent,
                        accessibilityLabel:
                            "Show \(hidden) older actions for \(activity.title)"
                    ) {
                        visibility.showAll(in: activity.id)
                    }
                } else {
                    WorkingSetVisibilityRow(
                        icon: "chevron.up",
                        title: "Hide",
                        indent: WorkingSetTimelineRow.childIndent,
                        accessibilityLabel:
                            "Show only the five newest actions for \(activity.title)"
                    ) {
                        visibility.hideOlder(in: activity.id)
                    }
                }
                Divider().overlay(Theme.hairline)
                    .padding(.leading, WorkingSetTimelineRow.childIndent)
            }
            ForEach(visible) { action in
                WorkingSetTimelineRow(call: action, projectPath: projectPath,
                                      indent: WorkingSetTimelineRow.childIndent)
            }
        }
    }

    // MARK: - Files

    private func filesPanel(_ entries: [WorkingSetTimelineEntry]) -> some View {
        let files = touchedFiles(entries)
        // Named in every row once more than one repository is in play; a single-project
        // session would only be told its own name over and over.
        let namesProject = Set(files.map(\.projectID)).count > 1
        return WorkingSetPanel(title: "TOUCHED FILES") {
            if !files.isEmpty {
                DiffPair(added: files.compactMap(\.change.added).reduce(0, +),
                         removed: files.compactMap(\.change.removed).reduce(0, +),
                         size: 8.5, spacing: 5)
            }
        } content: {
            if files.isEmpty {
                emptyRow("No uncommitted files.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        if index > 0 { Divider().overlay(Theme.hairline) }
                        fileRow(file, namesProject: namesProject)
                    }
                }
            }
        }
    }

    private func fileRow(_ file: TouchedFile, namesProject: Bool) -> some View {
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
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(WorkingSetInk.of(file.author).rail)
                            .frame(width: 7, height: 7)
                        Text(namesProject
                             ? "\(file.author.name) · \(file.projectName)"
                             : file.author.name)
                            .font(.mono(8.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
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
        .accessibilityValue("last touched by \(file.author.name)")
    }

    private func touchedFiles(_ entries: [WorkingSetTimelineEntry]) -> [TouchedFile] {
        let written = WorkingSetSummary.attribution(in: entries, projectPath: projectPath)
        return store.checkoutProjects(for: session).flatMap { checkout -> [TouchedFile] in
            guard let project = store.project(checkout.projectID) else { return [] }
            let root = checkout.worktreePath ?? project.path
            guard let snapshot = gitStats.snapshot(at: root) else { return [] }
            return snapshot.files.map { change in
                TouchedFile(projectID: project.id, projectName: project.name,
                            root: root, change: change,
                            author: WorkingSetSummary.attributor(of: change.path, in: root,
                                                                 from: written))
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

// How a row is coloured. An agent carries a tint of its own so its work can be picked out
// of the stream at a glance, while everything the main loop did stays neutral - which is
// what makes a tint mean something in the first place.
private struct WorkingSetInk {
    let fill: Color
    let ink: Color
    let rail: Color

    static let neutral = WorkingSetInk(fill: Theme.field, ink: .secondary,
                                       rail: .primary.opacity(0.35))

    static func agent(_ name: String) -> WorkingSetInk {
        let tint = Theme.projectTint(for: name)
        return WorkingSetInk(fill: tint.fill, ink: tint.ink, rail: tint.colour)
    }

    static func of(_ item: WorkingSetRunningItem) -> WorkingSetInk {
        item.origin == .agent ? agent(item.title) : neutral
    }

    static func of(_ activity: WorkingSetActivity) -> WorkingSetInk {
        activity.kind == .agent ? agent(activity.title) : neutral
    }

    static func of(_ author: WorkingSetAttribution) -> WorkingSetInk {
        author.isAgent ? agent(author.name) : neutral
    }
}

// The quiet reading at the right of a panel header.
private struct PanelReading: View {
    let text: String?

    init(_ text: String?) { self.text = text }

    var body: some View {
        if let text {
            Text(text)
                .font(.mono(8.5))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct WorkingSetVisibilityRow: View {
    let icon: String
    let title: String
    var indent: CGFloat = 11
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
            .padding(.leading, indent)
            .padding(.trailing, 11)
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

// One line of the timeline: a call the main loop made, or one of the actions inside an
// agent's span. The running one is the only row that moves, so it is the only one anybody
// has to look for.
private struct WorkingSetTimelineRow: View {
    // Clears the rail and the span header's avatar, so an agent's actions read as sitting
    // under the agent rather than beside it.
    static let childIndent: CGFloat = 30

    @Environment(ToolCallDetailPresenter.self) private var details

    let call: WorkingSetToolCall
    let projectPath: String
    var indent: CGFloat = 11

    @State private var anchor = FrameAnchor()
    @State private var hovering = false

    private var running: Bool { call.state == .running }

    var body: some View {
        Button(action: showDetails) {
            HStack(spacing: 8) {
                glyph
                Text(call.title)
                    .font(.mono(10, running ? .semibold : .regular))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.leading, indent)
            .padding(.trailing, 11)
            .padding(.vertical, 7)
            .background(background)
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

    private var glyph: some View {
        Group {
            if running {
                PulsingDot()
            } else {
                Image(systemName: call.state.symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(call.state.colour)
            }
        }
        .frame(width: 8)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailing: some View {
        if running {
            Text("now")
                .font(.mono(8.5, .semibold))
                .foregroundStyle(Theme.addition)
        } else if let startedAt = call.startedAt {
            Text(startedAt.formatted(date: .omitted, time: .shortened))
                .font(.mono(8.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var background: Color {
        if hovering { return Theme.field }
        return running ? Theme.dotOn.opacity(0.06) : .clear
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

private struct WorkingSetPanel<Trailing: View, Content: View>: View {
    let title: String
    // The live tint on the NOW panel: it borders the card and backs the header, so the one
    // panel that is still moving does not read as another record of what is over.
    var accent: Color?
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    init(title: String, accent: Color? = nil,
         @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.accent = accent
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if accent != nil { PulsingDot() }
                Text(title)
                    .font(.mono(8.5, .semibold))
                    .kerning(1)
                    .foregroundStyle(accent == nil
                                     ? AnyShapeStyle(.secondary)
                                     : AnyShapeStyle(Theme.addition))
                Spacer(minLength: 6)
                trailing
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(accent?.opacity(0.05) ?? .clear)
            .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
            content
        }
        .surface(Theme.card, cornerRadius: 11, border: accent?.opacity(0.28) ?? Theme.border)
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }
}
