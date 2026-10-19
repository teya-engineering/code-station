import Foundation
import SwiftUI
import CodeStationCore

// The sidebar that says what a session is doing and what it has done. The header carries
// the state and the one thing running now; below it, the work is grouped under the prompt
// that started it, so looking back means finding the request rather than counting rows.
// Changed files are left to the Changes tab, which already lists them.
struct SessionWorkingSet: View {
    static let width: CGFloat = 304

    // Rows sit under the prompt text rather than under the chevron, so a turn reads as one
    // block. An agent's actions step in once more, past the rail and the avatar.
    fileprivate static let rowIndent: CGFloat = 32
    fileprivate static let childIndent: CGFloat = 52
    fileprivate static let railInset: CGFloat = 18

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner

    @State private var visibility = WorkingSetToolCallVisibility()
    @State private var spans = WorkingSetExpansion()
    @State private var turns = WorkingSetExpansion()

    let session: ChatSession
    let close: () -> Void

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
        // The call the header names. A main-thread call is what the session itself is
        // waiting on, so it wins over an agent working beside it.
        let headline = running.last { $0.origin == .mainThread } ?? running.last
        let groups = WorkingSetSummary.turns(in: session.messages, entries: entries)
        VStack(spacing: 0) {
            header(headline: headline, runningCount: running.count)
            ScrollView {
                if groups.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(groups.enumerated().reversed()), id: \.element.id) { index, turn in
                            // An agent stays in the list: its span holds the live call,
                            // and the header only names the agent.
                            turnView(turn, isLatest: index == groups.count - 1,
                                     hiding: headline?.origin == .mainThread
                                         ? headline?.id : nil)
                        }
                        if let started = session.messages.first?.date {
                            Text("Session started at \(started.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(14)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .frame(width: Self.width)
        .background(Theme.sidebar)
        .onChange(of: session.id) { _, _ in
            visibility.reset()
            spans.reset()
            turns.reset()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Working set")
    }

    // MARK: - Header

    private func header(headline: WorkingSetRunningItem?, runningCount: Int) -> some View {
        let status = headerStatus(headline: headline)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    if tone == .running {
                        PulsingDot(size: 7)
                    } else {
                        StateLight(tone: status.isNew ? .idle : tone, size: 7)
                    }
                    Text(status.word)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(status.isNew ? Color.primary : tone.wordColour)
                    if let since = status.elapsedSince {
                        ElapsedTime(since: since, size: 10.5)
                    }
                }
                HStack(spacing: 6) {
                    lineText(status)
                        .font(.mono(10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if runningCount > 1 {
                        Text("+\(runningCount - 1)")
                            .font(.mono(10.5, .semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                .padding(.leading, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .appTooltip(status.line ?? "Finished")
            .accessibilityElement(children: .combine)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .hoverLift(amount: Motion.smallLift)
            .appTooltip("Close working set")
            .accessibilityLabel("Close working set")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(headerTint)
        .headerBand(Theme.sidebar, height: Theme.subHeaderHeight)
    }

    private var headerTint: Color {
        switch tone {
        case .running: Theme.dotOn.opacity(0.07)
        case .needsYou: Theme.attention.opacity(0.1)
        case .waiting, .idle: .clear
        }
    }

    private struct HeaderStatus {
        let word: String
        // Nil when the line says how long ago the session finished, which has to keep
        // counting while nothing else redraws the header.
        var line: String?
        var elapsedSince: Date? = nil
        var isNew = false
    }

    @ViewBuilder
    private func lineText(_ status: HeaderStatus) -> some View {
        if let line = status.line {
            Text(line)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("Finished " + CommandRunSummary.ago(
                    context.date.timeIntervalSince(session.lastActivity)))
            }
        }
    }

    private func headerStatus(headline: WorkingSetRunningItem?) -> HeaderStatus {
        let live = LiveConversation.id(of: session.id, store: store, runner: runner)
        let turnStart = session.messages.last { $0.role == .user }?.date
        if session.messages.isEmpty, tone != .running {
            return HeaderStatus(word: "New session", line: "Waiting for the first prompt",
                                isNew: true)
        }
        switch tone {
        case .running:
            let doing = headline?.title ?? "Thinking"
            return HeaderStatus(word: "Running", line: doing, elapsedSince: turnStart ?? headline?.startedAt)
        case .waiting:
            let doing = SessionActivity.line(for: session, store: store, runner: runner)
            return HeaderStatus(word: "Waiting", line: doing, elapsedSince: turnStart)
        case .needsYou:
            if let request = runner.question(live) {
                return HeaderStatus(word: "Needs you", line: Self.ask(request))
            }
            if runner.state(live).isBusy {
                let doing = SessionActivity.line(for: session, store: store, runner: runner)
                return HeaderStatus(word: "Needs you", line: doing)
            }
            return HeaderStatus(word: "Needs you")
        case .idle:
            return HeaderStatus(word: "Idle")
        }
    }

    private static func ask(_ request: PermissionRequest) -> String {
        if request.isQuestion { return request.title }
        let subject = request.subject.split(separator: "\n").first.map(String.init) ?? ""
        return "Asked to approve " + (subject.isBlank ? request.toolName : subject)
    }

    // MARK: - Activity

    private var emptyState: some View {
        VStack(spacing: 3) {
            Text("Nothing has run yet")
                .font(.system(size: 12.5, weight: .semibold))
            Text("Each prompt you send starts a new group here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 18)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    private func turnView(_ turn: WorkingSetTurn, isLatest: Bool, hiding hiddenID: String?)
        -> some View {
        let key = "turn\u{0}" + turn.id
        let expanded = turns.isExpanded(key, byDefault: isLatest)
        // The running call already has the header to itself.
        let entries = turn.entries.filter { $0.id != hiddenID }
        return VStack(spacing: 0) {
            WorkingSetTurnHeader(turn: turn, expanded: expanded) {
                withAnimation(.easeOut(duration: 0.15)) {
                    turns.toggle(key, byDefault: isLatest)
                }
            }
            if expanded { turnRows(entries, key: key) }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    @ViewBuilder
    private func turnRows(_ entries: [WorkingSetTimelineEntry], key: String) -> some View {
        // Newest first: what just happened is what the sidebar was opened for, and the
        // older work trails off below it.
        let visible = Array(visibility.visible(entries, in: key).reversed())
        let hidden = entries.count - visible.count
        ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
            if index > 0 { Divider().overlay(Theme.hairline) }
            switch entry.content {
            case .agent(let activity):
                spanView(activity)
            case .call(let call):
                WorkingSetTimelineRow(call: call, projectPath: projectPath,
                                      indent: Self.rowIndent)
            }
        }
        if entries.count > WorkingSetToolCallVisibility.limit {
            Divider().overlay(Theme.hairline)
            if hidden > 0 {
                WorkingSetVisibilityRow(
                    icon: "ellipsis",
                    title: "Show \(hidden) earlier in this prompt",
                    indent: Self.rowIndent,
                    accessibilityLabel: "Show \(hidden) earlier events in this prompt"
                ) {
                    visibility.showAll(in: key)
                }
            } else {
                WorkingSetVisibilityRow(
                    icon: "chevron.up",
                    title: "Show fewer",
                    indent: Self.rowIndent,
                    accessibilityLabel: "Show only the five newest events in this prompt"
                ) {
                    visibility.hideOlder(in: key)
                }
            }
        }
    }

    private func spanView(_ activity: WorkingSetActivity) -> some View {
        let ink = WorkingSetInk.of(activity)
        let running = activity.state == .running
        let expanded = spans.isExpanded(activity.id, byDefault: running)
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
                .padding(.leading, Self.railInset)
        }
    }

    private func spanHeader(_ activity: WorkingSetActivity, ink: WorkingSetInk,
                            expanded: Bool, running: Bool) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                spans.toggle(activity.id, byDefault: running)
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
            .padding(.leading, Self.rowIndent - 4)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .background(expanded ? ink.rail.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(activity.title), \(activity.kind.label)")
        .accessibilityValue("\(activity.state.label), \(expanded ? "expanded" : "collapsed")")
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
                        title: "Show \(hidden) earlier",
                        indent: Self.childIndent,
                        accessibilityLabel:
                            "Show \(hidden) older actions for \(activity.title)"
                    ) {
                        visibility.showAll(in: activity.id)
                    }
                } else {
                    WorkingSetVisibilityRow(
                        icon: "chevron.up",
                        title: "Show fewer",
                        indent: Self.childIndent,
                        accessibilityLabel:
                            "Show only the five newest actions for \(activity.title)"
                    ) {
                        visibility.hideOlder(in: activity.id)
                    }
                }
                Divider().overlay(Theme.hairline)
                    .padding(.leading, Self.childIndent)
            }
            ForEach(visible) { action in
                WorkingSetTimelineRow(call: action, projectPath: projectPath,
                                      indent: Self.childIndent)
            }
        }
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

    static func of(_ activity: WorkingSetActivity) -> WorkingSetInk {
        activity.kind == .agent ? agent(activity.title) : neutral
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
            .padding(.trailing, 14)
            .padding(.vertical, 9)
            .background(hovering ? Theme.field : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .accessibilityLabel(accessibilityLabel)
    }
}

// The header of one prompt's group. Closed it is one line, so a long session folds down to
// a list of what was asked; open it gives the prompt a second line, which is usually
// enough to tell two similar requests apart.
private struct WorkingSetTurnHeader: View {
    let turn: WorkingSetTurn
    let expanded: Bool
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        let events = WorkingSetSummary.eventCount(in: turn.entries)
        let failures = WorkingSetSummary.failureCount(in: turn.entries)
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10, height: 15)
                VStack(alignment: .leading, spacing: 3) {
                    Text(turn.prompt)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(expanded ? 2 : 1)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 10) {
                        if let sentAt = turn.sentAt {
                            Text(sentAt.formatted(date: .omitted, time: .shortened))
                        }
                        Text(events == 0 ? "No activity" : counted(events, "event"))
                        if failures > 0 {
                            Text("\(failures) failed").foregroundStyle(Theme.deletion)
                        }
                    }
                    .font(.mono(10))
                    .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .appTooltip(turn.prompt)
        .accessibilityLabel("Prompt: \(turn.prompt)")
        .accessibilityValue([counted(events, "event"),
                             failures > 0 ? "\(failures) failed" : nil,
                             expanded ? "expanded" : "collapsed"]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(expanded ? "Hides what this prompt did" : "Shows what this prompt did")
    }

    private var background: Color {
        switch (expanded, hovering) {
        case (true, true): Theme.dotOn.opacity(0.14)
        case (true, false): Theme.dotOn.opacity(0.09)
        case (false, true): Theme.field
        case (false, false): .clear
        }
    }
}

// One line of activity: a call the main loop made, or one of the actions inside an agent's
// span. The tool's name is set in the UI font so a column of them can be skimmed, and the
// command beside it in mono, cut to one line with the whole of it on hover.
private struct WorkingSetTimelineRow: View {
    @Environment(ToolCallDetailPresenter.self) private var details

    let call: WorkingSetToolCall
    let projectPath: String
    let indent: CGFloat

    @State private var anchor = FrameAnchor()
    @State private var hovering = false

    private var running: Bool { call.state == .running }

    var body: some View {
        let presentation = ToolPresentationCache.presentation(for: call.tool,
                                                              projectPath: projectPath)
        Button(action: showDetails) {
            HStack(spacing: 8) {
                glyph
                HStack(spacing: 6) {
                    Text(presentation.verb)
                        .font(.system(size: 11.5, weight: .semibold))
                        .fixedSize()
                    Text(presentation.argument)
                        .font(.mono(11, running ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.leading, indent)
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .frame(minHeight: 30)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(FrameAnchorView(anchor: anchor))
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .appTooltip(presentation.command.map { "\(presentation.verb) \($0)" } ?? call.title)
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
        .frame(width: 10)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailing: some View {
        if running {
            Text("now")
                .font(.mono(10, .semibold))
                .foregroundStyle(Theme.addition)
        } else if let startedAt = call.startedAt {
            Text(startedAt.formatted(date: .omitted, time: .shortened))
                .font(.mono(10))
                .foregroundStyle(.tertiary)
        }
    }

    private var background: Color {
        if hovering { return Theme.field }
        return running ? Theme.dotOn.opacity(0.07) : .clear
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
        case .finished: .secondary
        case .failed: Theme.deletion
        case .interrupted: Theme.secret
        }
    }
}
