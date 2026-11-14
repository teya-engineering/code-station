import Foundation
import SwiftUI

// The sidebar that says what a session is doing and what it has done. The header carries
// the state and the one thing running now; below it, the work is grouped under the prompt
// that started it, so looking back means finding the request rather than counting rows.
// Changed files are left to the Changes tab, which already lists them.
struct SessionWorkingSet: View {
    static let width: CGFloat = 304

    // Rows sit under the prompt text rather than under the chevron, so a turn reads as one
    // block. An agent's actions step in once more, past the rail and the avatar.
    fileprivate static let chevronWidth: CGFloat = 10
    fileprivate static let rowIndent: CGFloat = Space.lg + chevronWidth + Space.md
    fileprivate static let childIndent: CGFloat = rowIndent + Space.xxl
    fileprivate static let railInset: CGFloat = Space.xl

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        let headline = WorkingSetSummary.headline(in: entries)
        let groups = WorkingSetSummary.turns(in: session.messages, entries: entries)
        VStack(spacing: 0) {
            header(headline: headline, runningCount: running.count)
            ScrollView {
                if groups.isEmpty {
                    emptyState
                } else {
                    WorkingSetHistory(groups: groups, projectPath: projectPath,
                                      headline: headline)
                    if let started = session.messages.first?.date {
                        Text("Session started at \(started.formatted(date: .omitted, time: .shortened))")
                            .font(Typography.caption)
                            .foregroundStyle(.tertiary)
                            .padding(Space.lg)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(width: Self.width)
        .background(Theme.sidebar)
        .id(session.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Working set")
    }

    // MARK: - Header

    private func header(headline: WorkingSetRunningItem?, runningCount: Int) -> some View {
        let status = headerStatus(headline: headline)
        return HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.sm) {
                    if tone == .running {
                        PulsingDot(size: 7)
                    } else {
                        StateLight(tone: status.isNew ? .idle : tone, size: 7)
                    }
                    Text(status.word)
                        .contentTransition(.opacity)
                        .motion(Motion.control, value: status.word)
                        .font(Typography.body.weight(.semibold))
                        .foregroundStyle(status.isNew ? Color.primary : tone.wordColour)
                    if let since = status.elapsedSince {
                        ElapsedTime(since: since, size: 10.5)
                    }
                }
                HStack(spacing: Space.sm) {
                    lineText(status)
                        .font(Typography.data)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if runningCount > 1 {
                        Text("+\(runningCount - 1)")
                            .font(Typography.data.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                .padding(.leading, Space.lg)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .appTooltip(status.line ?? "Finished")
            .accessibilityElement(children: .combine)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: Radius.inset).fill(Theme.field))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.inset))
            }
            .buttonStyle(.plain)
            .hoverLift(amount: Motion.smallLift)
            .appTooltip("Close working set")
            .accessibilityLabel("Close working set")
        }
        .padding(.leading, Space.lg)
        .padding(.trailing, Space.md)
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
            if let activity = runner.completionActivity(live) {
                return HeaderStatus(word: activity.label, line: activity.detail,
                                    elapsedSince: runner.turnStarted(live))
            }
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
        VStack(spacing: Space.xxs) {
            Text("Nothing has run yet")
                .font(Typography.body.weight(.semibold))
            Text("Each prompt you send starts a new group here.")
                .font(Typography.detail)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.xxxl)
        .frame(maxWidth: .infinity)
    }

}

// The full sidebar and the glance card share the same prompt and agent rows.
struct WorkingSetHistory: View {
    let groups: [WorkingSetTurn]
    let projectPath: String
    let headline: WorkingSetRunningItem?
    var compact = false

    private static let rowIndent = SessionWorkingSet.rowIndent
    private static let childIndent = SessionWorkingSet.childIndent
    private static let railInset = SessionWorkingSet.railInset

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibility = WorkingSetToolCallVisibility()
    @State private var spans = WorkingSetExpansion()
    @State private var turns = WorkingSetExpansion()
    @FocusState private var focusedAgent: String?

    var body: some View {
        if compact {
            VStack(spacing: 0) { promptGroups }
        } else {
            LazyVStack(spacing: 0) { promptGroups }
        }
    }

    private var promptGroups: some View {
        ForEach(Array((compact ? WorkingSetSummary.previewTurns(in: groups) : groups).reversed())) { turn in
            turnView(turn, isLatest: turn.id == groups.last?.id
                     || (compact && turn.entries.contains { $0.state == .running }),
                     hiding: headline?.origin == .mainThread ? headline?.id : nil)
        }
    }

    private func turnView(_ turn: WorkingSetTurn, isLatest: Bool, hiding hiddenID: String?)
        -> some View {
        let key = "turn\u{0}" + turn.id
        let expanded = turns.isExpanded(key, byDefault: isLatest)
        // The running call already has the header to itself.
        let entries = turn.entries.filter { $0.id != hiddenID }
        return VStack(spacing: 0) {
            WorkingSetTurnHeader(turn: turn, expanded: expanded, compact: compact) {
                turns.toggle(key, byDefault: isLatest)
            }
            if expanded {
                VStack(spacing: 0) { turnRows(entries, key: key) }
                    .transition(reduceMotion ? .opacity : .fold)
            }
        }
        .motion(expanded ? Motion.reveal : Motion.leave, value: turns)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    @ViewBuilder
    private func turnRows(_ entries: [WorkingSetTimelineEntry], key: String) -> some View {
        // Newest first: what just happened is what the sidebar was opened for, and the
        // older work trails off below it.
        let selected = compact && !visibility.isExpanded(key)
            ? WorkingSetSummary.previewEntries(in: entries)
            : visibility.visible(entries, in: key)
        let visible = Array(selected.reversed())
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
        if hidden > 0 || visibility.isExpanded(key) {
            Divider().overlay(Theme.hairline)
            if hidden > 0 {
                WorkingSetVisibilityRow(
                    icon: "ellipsis",
                    title: "Show \(hidden) earlier in this prompt",
                    indent: Self.rowIndent,
                    accessibilityLabel: "Show \(hidden) earlier events in this prompt"
                ) {
                    showAll(in: key)
                }
            } else {
                WorkingSetVisibilityRow(
                    icon: "chevron.up",
                    title: "Show fewer",
                    indent: Self.rowIndent,
                    accessibilityLabel: "Show only the five newest events in this prompt"
                ) {
                    hideOlder(in: key)
                }
            }
        }
    }

    private func showAll(in key: String) {
        withAnimation(reduceMotion ? nil : Motion.reveal) { visibility.showAll(in: key) }
    }

    private func hideOlder(in key: String) {
        withAnimation(reduceMotion ? nil : Motion.leave) { visibility.hideOlder(in: key) }
    }

    private func spanView(_ activity: WorkingSetActivity) -> some View {
        let ink = WorkingSetInk.of(activity)
        let running = activity.state == .running
        let expanded = spans.isExpanded(activity.id, byDefault: !compact && running)
        return VStack(spacing: 0) {
            spanHeader(activity, ink: ink, expanded: expanded, running: running)
            if expanded, !activity.actions.isEmpty {
                Divider().overlay(Theme.hairline)
                spanActions(activity)
                    .transition(reduceMotion ? .opacity : .fold)
            }
        }
        .motion(expanded ? Motion.reveal : Motion.leave, value: spans)
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
            spans.toggle(activity.id, byDefault: !compact && running)
        } label: {
            HStack(spacing: Space.sm) {
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
                    .font(Typography.data.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                spanSummary(activity, ink: ink, expanded: expanded)
            }
            .padding(.leading, Self.rowIndent - 4)
            .padding(.trailing, Space.lg)
            .padding(.vertical, Space.md)
            .background(expanded ? ink.rail.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedAgent, equals: activity.id)
        .focusEffectDisabled()
        .overlay(FocusRingStroke(focused: focusedAgent == activity.id))
        .hoverFill(cornerRadius: 0)
        .accessibilityLabel("\(activity.title), \(activity.kind.label)")
        .accessibilityValue("\(activity.state.label), \(expanded ? "expanded" : "collapsed")")
        .accessibilityHint(expanded ? "Hides what this agent ran" : "Shows what this agent ran")
    }
    private func spanSummary(_ activity: WorkingSetActivity, ink: WorkingSetInk,
                             expanded: Bool) -> some View {
        HStack(spacing: Space.xs) {
            if !activity.actions.isEmpty {
                Text(counted(activity.actions.count, "action") + (expanded ? "" : " ·"))
                    .font(Font.mono(Typography.Size.micro, expanded ? .semibold : .regular))
                    .foregroundStyle(expanded ? ink.ink : Color.secondary)
            }
            if compact {
                Text(activity.state.label.capitalized)
                    .font(Font.system(size: Typography.Size.micro))
                    .foregroundStyle(activity.state.colour)
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
        let selected = visibility.visible(activity.actions, in: activity.id)
        let visible = compact ? Array(selected.reversed()) : selected
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
                        showAll(in: activity.id)
                    }
                } else {
                    WorkingSetVisibilityRow(
                        icon: "chevron.up",
                        title: "Show fewer",
                        indent: Self.childIndent,
                        accessibilityLabel:
                            "Show only the five newest actions for \(activity.title)"
                    ) {
                        hideOlder(in: activity.id)
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
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .bold))
                Text(title)
                    .font(Typography.caps)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, indent)
            .padding(.trailing, Space.lg)
            .padding(.vertical, Space.md)
            .background(hovering ? Theme.field : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .overlay(FocusRingStroke(focused: focused))
        .onPointerHover { hovering = $0 }
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
    var compact = false
    let toggle: () -> Void

    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        let events = WorkingSetSummary.eventCount(in: turn.entries)
        let failures = WorkingSetSummary.failureCount(in: turn.entries)
        Button(action: toggle) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: SessionWorkingSet.chevronWidth, height: 15)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(turn.prompt)
                        .font(Typography.label)
                        .lineLimit(expanded ? 2 : 1)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                    if !compact {
                        HStack(spacing: Space.md) {
                            if let sentAt = turn.sentAt {
                                Text(sentAt.formatted(date: .omitted, time: .shortened))
                            }
                            Text(events == 0 ? "No activity" : counted(events, "event"))
                            if failures > 0 {
                                Text("\(failures) failed").foregroundStyle(Theme.deletion)
                            }
                        }
                        .font(Font.mono(Typography.Size.micro))
                        .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if compact {
                    Text(expanded ? turn.sentAt?.formatted(date: .omitted, time: .shortened) ?? ""
                         : counted(events, "event"))
                        .font(Font.mono(Typography.Size.micro))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, compact ? 7 : 10)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .overlay(FocusRingStroke(focused: focused))
        .onPointerHover { hovering = $0 }
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
struct WorkingSetTimelineRow: View {
    @Environment(ToolCallDetailPresenter.self) private var details

    let call: WorkingSetToolCall
    let projectPath: String
    let indent: CGFloat

    @State private var anchor = FrameAnchor()
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var running: Bool { call.state == .running }

    var body: some View {
        let presentation = ToolPresentationCache.presentation(for: call.tool,
                                                              projectPath: projectPath)
        Button(action: showDetails) {
            HStack(spacing: Space.md) {
                glyph
                HStack(spacing: Space.sm) {
                    Text(presentation.verb)
                        .font(Typography.label)
                        .fixedSize()
                    Text(presentation.argument)
                        .font(Typography.data.weight(running ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.leading, indent)
            .padding(.trailing, Space.lg)
            .padding(.vertical, Space.sm)
            .frame(minHeight: 30)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .overlay(FocusRingStroke(focused: focused))
        .background(FrameAnchorView(anchor: anchor))
        .onPointerHover { hovering = $0 }
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
                .font(Typography.caps)
                .foregroundStyle(Theme.addition)
        } else if let startedAt = call.startedAt {
            Text(startedAt.formatted(date: .omitted, time: .shortened))
                .font(Font.mono(Typography.Size.micro))
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
