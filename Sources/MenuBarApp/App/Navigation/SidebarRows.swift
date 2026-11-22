import SwiftUI

// One line per workspace. The stacked tile distinguishes it from a single project without
// introducing another icon language into the sidebar.
struct WorkspaceHeaderRow: View {
    let workspace: ProjectWorkspace
    let projects: [Project]
    let selected: Bool
    let activeSessionTitle: String?
    let isExpanded: Bool
    let sessionCount: Int
    let runningCount: Int
    let needsYouCount: Int
    let isRenaming: Bool
    let checked: Bool?
    // Shown in place of the session count while a project is carried or landing.
    var roster: SidebarRoster? = nil
    var carryAnchors = false
    // Set while the workspace removes itself once it sits empty.
    var lifeLine: (Date) -> EmptyWorkspaceSweep.LifeLine? = { _ in nil }
    var onKeepForGood: () -> Void = {}
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onNewSession: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @FocusState private var rowFocused: Bool
    @FocusState private var actionFocused: Bool

    private var showsNewSession: Bool {
        checked == nil && !isRenaming && (hovering || rowFocused || actionFocused)
    }

    var body: some View {
        TreeRow(selected: selected, isExpanded: isExpanded, hovering: hovering) {
            if sessionCount > 0 {
                SidebarDisclosure(name: workspace.name, expanded: isExpanded, action: onToggle)
            } else {
                Color.clear.frame(width: SidebarDisclosure.width)
            }
        } content: {
            if isRenaming {
                SidebarIdentityTile(
                    avatar: workspace.sidebarAvatar,
                    name: workspace.name,
                    tint: Theme.workspaceTint,
                    stacked: true,
                    pinned: workspace.isPinned)
                SidebarRenameField(name: workspace.name, onCommit: onRename, onCancel: onCancelRename)
            } else {
                Button(action: onOpen) {
                    HStack(spacing: Space.md) {
                        if let checked { SidebarCheckbox(isOn: checked) }
                        SidebarIdentityTile(
                            avatar: workspace.sidebarAvatar,
                            name: workspace.name,
                            tint: Theme.workspaceTint,
                            stacked: true,
                            pinned: workspace.isPinned)
                            .threadNod(running: runningCount)
                        Text(workspace.name)
                            .font(Typography.body.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sidebarFocusRing($rowFocused)
                .accessibilityLabel(checked == nil ? "Open \(workspace.name)" : workspace.name)
                .accessibilityValue(SidebarRowValue.text(
                    current: selected ? "Current workspace" : nil,
                    viewing: !isExpanded ? activeSessionTitle : nil,
                    pinned: workspace.isPinned))
                .accessibilityAddTraits(selected && activeSessionTitle == nil || checked == true
                                        ? [.isSelected] : [])

                // The count belongs to the row whether or not it is the current one:
                // the sidebar is read at a glance, and a row that drops its number
                // reads as a row with nothing in it. While a project is carried the
                // roster takes its place, at the same height.
                if let roster {
                    SidebarRosterView(roster: roster, anchorsActive: carryAnchors)
                        .transition(reduceMotion
                                    ? .opacity
                                    : .asymmetric(insertion: .opacity.combined(with: .offset(x: 6)),
                                                  removal: .opacity))
                } else if sessionCount > 0 || runningCount > 0 {
                    HStack(spacing: Space.sm) {
                        if !isExpanded, needsYouCount > 0 { NeedsYouChip(count: needsYouCount) }
                        if runningCount > 0 { RunningDot() }
                        if sessionCount > 0 {
                            Text(counted(sessionCount, "session"))
                                .font(Font.mono(Typography.Size.micro))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } trailing: { fill in
            TrailingRowAction(
                visible: showsNewSession, icon: "plus", title: "New", tone: .create,
                width: TrailingRowAction.newWidth, base: fill,
                accessibilityLabel: "New multi-project session in \(workspace.name)",
                tooltip: "New multi-project session",
                focus: $actionFocused, action: onNewSession)
        } footer: {
            if workspace.removeWhenEmptyAfterDays != nil {
                WorkspaceLifeLineRow(lifeLine: lifeLine, onKeepForGood: onKeepForGood,
                                     name: workspace.name)
            }
        }
        // A workspace that already holds the project in hand steps back, so the ones
        // that can take it stand out.
        .opacity(roster?.holdsCarried == true ? 0.55 : 1)
        .motion(Motion.reveal, value: roster == nil)
        .motion(Motion.hover, value: roster?.holdsCarried == true)
        .appTooltip {
            Tooltip(
                title: workspace.name,
                subtitle: projects.map(\.name).joined(separator: " + "),
                rows: [Tooltip.Row(label: "Sessions", value: "\(sessionCount)"),
                       Tooltip.Row(label: "Projects", value: "\(projects.count)")])
        }
        .onPointerHover {
            hovering = $0
            store.pointSidebarItem(workspace.id, $0)
        }
    }
}

// The second line of a workspace that removes itself when it sits empty. It turns amber
// in the final hour and offers to keep the workspace for good. The clock only moves the
// words once a minute, which is as fine as the line speaks.
private struct WorkspaceLifeLineRow: View {
    let lifeLine: (Date) -> EmptyWorkspaceSweep.LifeLine?
    let onKeepForGood: () -> Void
    let name: String

    // Lines the words up under the workspace name: the row's inset, the disclosure, and
    // the tile with the gaps around it.
    private static let indent: CGFloat = Space.md + SidebarDisclosure.width + Space.xs + 26 + Space.md

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let line = lifeLine(context.date) {
                HStack(spacing: Space.sm) {
                    Image(systemName: "hourglass")
                        .font(Typography.micro)
                        .foregroundStyle(line.isFinalHour ? Theme.attentionText : Theme.workspaceTint.ink)
                        .accessibilityHidden(true)
                    Text(line.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.numericText())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if line.isFinalHour {
                        KeepForGoodButton(name: name, action: onKeepForGood)
                            .transition(.fadeIn)
                    }
                }
                .font(Typography.caption)
                .foregroundStyle(line.isFinalHour ? Theme.attentionText : Color.secondary)
                .padding(.leading, Self.indent)
                .padding(.trailing, Space.md)
                .padding(.bottom, Space.sm)
                .motion(Motion.control, value: line)
                .accessibilityElement(children: .contain)
            }
        }
    }
}

private struct KeepForGoodButton: View {
    let name: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Keep for good")
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xxs)
                .background(Theme.accent.opacity(hovering ? 0.1 : 0),
                            in: RoundedRectangle(cornerRadius: Radius.inset))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onPointerHover { hovering = $0 }
        .hoverLift(hovering, amount: Motion.smallLift)
        .motion(Motion.hover, value: hovering)
        .accessibilityLabel("Keep \(name) for good")
    }
}

// The current container keeps its navigation marker even when its sessions are folded.
// Open means a block is drawn below, not that the flag is set: a row with nothing under
// it wears the plain fill, or the tint reads as a state the row does not have.
// The disclosure leads the row, so nothing sits beside the action that takes over its end.
private struct TreeRow<Leading: View, Content: View, Trailing: View, Footer: View>: View {
    let selected: Bool
    let isExpanded: Bool
    let hovering: Bool
    @ViewBuilder let leading: Leading
    @ViewBuilder let content: Content
    // Handed the row's fill, so what it lays over the row's end can cover what is there.
    @ViewBuilder let trailing: (Color) -> Trailing
    // A second line inside the row's card, under the name, for something the row has to
    // say that will not fit beside it.
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.xs) {
                leading
                HStack(spacing: Space.md) { content }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .overlay(alignment: .trailing) { trailing(fill) }
            footer
        }
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: Radius.card)
                .stroke(selected ? Theme.accent.opacity(0.14) : .clear, lineWidth: 1))
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(Theme.accent)
                        .frame(width: 3)
                        .padding(.vertical, Space.sm)
                        .accessibilityHidden(true)
                }
            }
    }

    private var fill: Color {
        if selected { return Theme.accent.opacity(0.085) }
        if isExpanded { return Theme.field }
        return hovering ? Theme.sunken : .clear
    }
}

// One line per project: who it is, and the way in. The sessions themselves carry the
// detail, so the row stays a heading rather than competing with the cards under it, and
// its numbers live in the hint where they cost the line no room.
struct ProjectHeaderRow: View {
    let project: Project
    let selected: Bool
    let activeSessionTitle: String?
    let isExpanded: Bool
    let isMissing: Bool
    let sessionCount: Int
    let runningCount: Int
    let unreadCount: Int
    let needsYouCount: Int
    let cost: Double
    let canRunTask: Bool
    let isRenaming: Bool
    let checked: Bool?
    // Set while a project is carried or landing, so the tile can be flown home to.
    var carryAnchors = false
    // The project tucked behind this one's tile after a drop, while the New workspace
    // sheet is open.
    var stackedBehind: String? = nil
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onNewSession: () -> Void
    let onRunTask: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(\.keyBindings) private var keyBindings
    @State private var hovering = false
    @FocusState private var rowFocused: Bool
    @FocusState private var actionFocused: Bool

    private var isTask: Bool { project.kind == .adHoc }
    private var showsNeedsYou: Bool { !isExpanded && needsYouCount > 0 }
    private var showsNewSession: Bool {
        !isTask && checked == nil && !isRenaming && (hovering || rowFocused || actionFocused)
    }

    var body: some View {
        TreeRow(selected: selected, isExpanded: isExpanded, hovering: hovering) {
            if sessionCount > 0 {
                SidebarDisclosure(name: project.name, expanded: isExpanded, action: onToggle)
            } else {
                Color.clear.frame(width: SidebarDisclosure.width)
            }
        } content: {
            if isRenaming {
                SidebarIdentityTile(
                    avatar: project.sidebarAvatar,
                    name: project.name,
                    tint: Theme.projectTint(for: project.name),
                    dashed: project.kind == .adHoc,
                    pinned: project.isPinned)
                SidebarRenameField(name: project.name, onCommit: onRename, onCancel: onCancelRename)
            } else {
                Button(action: onOpen) {
                    HStack(spacing: Space.md) {
                        if let checked { SidebarCheckbox(isOn: checked) }
                        SidebarIdentityTile(
                            avatar: project.sidebarAvatar,
                            name: project.name,
                            tint: Theme.projectTint(for: project.name),
                            dashed: project.kind == .adHoc,
                            pinned: project.isPinned)
                            .background(alignment: .center) {
                                if let stackedBehind {
                                    ProjectTileBack(tint: Theme.projectTint(for: stackedBehind))
                                        .transition(.opacity.animation(Motion.pop))
                                }
                            }
                            .motion(Motion.leave, value: stackedBehind)
                            .threadNod(running: runningCount)
                            .sidebarCarryAnchor(.tile(project.id), active: carryAnchors)
                        HStack(spacing: Space.xs) {
                            if isMissing {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(Font.system(size: Typography.Size.micro))
                                    .foregroundStyle(.secondary)
                            }
                            Text(project.name)
                                .font(Typography.body.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            // The only mark a snoozed project carries. Its tooltip gives
                            // the day its sessions come back into the cleanup list.
                            if let snoozedUntil = project.snoozedUntil,
                               ProjectSnooze.isActive(snoozedUntil) {
                                MonoChip(text: ProjectSnooze.badge(until: snoozedUntil), size: Typography.Size.micro)
                                    .appTooltip("Cleanup snoozed until \(ProjectSnooze.wakeDay(snoozedUntil))")
                            }
                            if let schedule = project.task?.schedule, schedule.isActive {
                                Image(systemName: "clock.fill")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(schedule.isWaitingForConfirmation
                                                     ? Theme.attentionText : Theme.accent)
                                    .appTooltip(schedule.isWaitingForConfirmation
                                        ? "Timer waiting for confirmation"
                                        : schedule.summary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sidebarFocusRing($rowFocused)
                .accessibilityLabel(checked == nil ? "Open \(project.name)" : project.name)
                .accessibilityValue(SidebarRowValue.text(
                    current: selected ? "Current project" : nil,
                    viewing: !isExpanded ? activeSessionTitle : nil,
                    pinned: project.isPinned))
                .accessibilityAddTraits(selected && activeSessionTitle == nil || checked == true
                                        ? [.isSelected] : [])

                // On a task the running light gives way under the pointer to Run. The
                // name gives way while the pointer is here, so the wider label does not
                // make the row grow. A project's New covers its end instead.
                if isTask {
                    if !selected || hovering || runningCount > 0 || showsNeedsYou {
                        ZStack(alignment: .trailing) {
                            status
                                .opacity(hovering ? 0 : 1)

                            // A task is run with its saved prompt rather than opened
                            // empty. The button waits while a run is still working in
                            // the task's folder.
                            if hovering, canRunTask, checked == nil {
                                RowAction(icon: "play.fill", title: "Run", compact: selected, action: onRunTask)
                                    .appTooltip("Run the task's saved prompt in a fresh session")
                                    .fixedSize()
                            }
                        }
                        .frame(minWidth: selected ? 0 : 30, alignment: .trailing)
                    }
                } else if runningCount > 0 || showsNeedsYou {
                    status
                }
            }
        } trailing: { fill in
            TrailingRowAction(
                visible: showsNewSession, icon: "plus", title: "New", tone: .create,
                width: TrailingRowAction.newWidth, base: fill,
                accessibilityLabel: "New session in \(project.name)",
                tooltip: "New session" + (keyBindings.keys(for: .newSession).map { " \($0.compactLabel)" } ?? ""),
                focus: $actionFocused, action: onNewSession)
        } footer: {}
        .appTooltip { tooltip }
        .onPointerHover {
            hovering = $0
            store.pointSidebarItem(project.id, $0)
        }
    }

    private var status: some View {
        HStack(spacing: Space.sm) {
            if showsNeedsYou { NeedsYouChip(count: needsYouCount) }
            if runningCount > 0 { RunningDot() }
        }
    }

    // The path is the only thing that tells two projects of the same name apart, so it
    // leads the hint. The counts under it are ones the row has no room to show.
    private var tooltip: Tooltip {
        var rows = [Tooltip.Row(label: isTask ? "Runs" : "Sessions", value: "\(sessionCount)")]
        if runningCount > 0 {
            rows.append(Tooltip.Row(label: "Running", value: "\(runningCount)"))
        }
        if unreadCount > 0 {
            rows.append(Tooltip.Row(label: "Unread", value: "\(unreadCount)"))
        }
        if cost > 0 {
            rows.append(Tooltip.Row(label: "Spent", value: Money.short(cost)))
        }
        if let schedule = project.task?.schedule, schedule.isActive {
            rows.append(Tooltip.Row(label: "Timer", value: schedule.summary))
            if schedule.isWaitingForConfirmation {
                rows.append(Tooltip.Row(label: "Next run", value: "Waiting for confirmation"))
            } else if let nextRunAt = schedule.nextRunAt {
                rows.append(Tooltip.Row(label: "Next run",
                                        value: nextRunAt.formatted(date: .abbreviated,
                                                                   time: .shortened)))
            }
        }
        return Tooltip(title: project.name,
                       subtitle: isTask ? nil : project.collapsedPath,
                       note: isMissing ? "This folder is no longer on disk." : promptNote,
                       rows: rows)
    }

    // The saved prompt is what the Run button would send, so it belongs in the hint. One
    // line of it is enough to recognise the task by.
    private var promptNote: String? {
        guard isTask else { return nil }
        let line = (project.task?.prompt ?? "").trimmed
            .split(separator: "\n").first.map(String.init) ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }
}

// A hover action on a task row: the glyph with its word beside it, so what the button
// does is read rather than guessed.
private struct RowAction: View {
    let icon: String
    let title: String
    var compact = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xxs) {
                Image(systemName: icon)
                    .font(Typography.micro)
                if !compact {
                    Text(title)
                        .font(Typography.caption.weight(.semibold))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, compact ? 4 : 7)
            .padding(.vertical, Space.xs)
            .overlay(Capsule().stroke(hovering ? Theme.border : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .sidebarFocusRing()
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
    }
}

// The end of a row given over to its main action while the row is pointed at or focused.
// It runs the full height of the row so it is easy to hit, and its word keeps its own
// colour in every state, so New always reads green and Delete always reads red. It lays
// the row's own fill over the sidebar to cover the status under it, which comes back when
// the pointer leaves, and a short fade lets the text it cuts off run out softly.
struct TrailingRowAction: View {
    enum Tone {
        case create, delete

        var colour: Color { self == .create ? Theme.accent : Theme.deletion }

        func tint(pressed: Bool, dark: Bool) -> Double {
            switch (self, pressed) {
            case (.create, false): dark ? 0.13 : 0.10
            case (.create, true): dark ? 0.21 : 0.17
            case (.delete, false): dark ? 0.13 : 0.09
            case (.delete, true): dark ? 0.21 : 0.16
            }
        }
    }

    static let newWidth: CGFloat = 84
    static let deleteWidth: CGFloat = 82
    private static let fadeWidth: CGFloat = 18

    let visible: Bool
    let icon: String
    let title: String
    let tone: Tone
    let width: CGFloat
    let base: Color
    var cornerRadius: CGFloat = 9
    let accessibilityLabel: String
    let tooltip: String
    let focus: FocusState<Bool>.Binding
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        ZStack {
            if visible {
                zone
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 10)))
            }
        }
        // Still a fade under Reduce Motion, so the action does not cut in over the status.
        .animation(Motion.hover, value: visible)
    }

    private var zone: some View {
        let cover = ZStack { Theme.sidebar; base }
        return HStack(spacing: 0) {
            cover
                .mask(LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing))
                .frame(width: Self.fadeWidth)
                .accessibilityHidden(true)
            Button(action: action) {
                HStack(spacing: Space.xs) {
                    Image(systemName: icon)
                        .font(Typography.caption.weight(.semibold))
                    Text(title)
                        .font(Typography.label)
                }
                .foregroundStyle(tone.colour)
            }
            .buttonStyle(TrailingActionStyle(tone: tone, hovering: hovering, dark: colorScheme == .dark))
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(cover)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1)
                    .padding(.vertical, Space.md)
                    .opacity(hovering ? 0 : 1)
                    .accessibilityHidden(true)
            }
            .sidebarFocusRing(focus)
            .accessibilityLabel(accessibilityLabel)
            .appTooltip(tooltip)
            .onPointerHover { hovering = $0 }
        }
        .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: cornerRadius,
                                          topTrailingRadius: cornerRadius))
    }
}

// The tint answers the pointer and deepens under a press. The press scales the label only,
// never the button, since the button carries AppKit-backed tooltip views.
private struct TrailingActionStyle: ButtonStyle {
    let tone: TrailingRowAction.Tone
    let hovering: Bool
    let dark: Bool

    func makeBody(configuration: Configuration) -> some View {
        let tinted = hovering || configuration.isPressed
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tone.colour.opacity(tinted ? tone.tint(pressed: configuration.isPressed, dark: dark) : 0))
            .contentShape(Rectangle())
            .motion(Motion.hover, value: configuration.isPressed)
    }
}

private struct SidebarDisclosure: View {
    static let width: CGFloat = 14

    let name: String
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: SidebarDisclosure.width, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift(amount: Motion.smallLift)
        .sidebarFocusRing()
        .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(name) sessions")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .appTooltip("\(expanded ? "Collapse" : "Expand") \(name) sessions")
    }
}

// What VoiceOver hears after a row's name. The pin on the tile is decoration, so the row
// says it is pinned here.
enum SidebarRowValue {
    static func text(current: String?, viewing: String?, pinned: Bool) -> String {
        var parts: [String] = []
        if let current {
            parts.append(current + (viewing.map { ". Viewing \($0)" } ?? ""))
        }
        if pinned { parts.append("Pinned") }
        return parts.joined(separator: ", ")
    }
}

// The box a row wears while several rows are being picked. It slides in from the edge the
// row starts at, so the row reads as making room for it.
struct SidebarCheckbox: View {
    let isOn: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CheckboxMark(isOn: isOn)
            .motion(Motion.control, value: isOn)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .leading)))
            .accessibilityHidden(true)
    }
}

// The field a row or a card shows in place of its name while it is being renamed. It
// starts from the current name and takes the keyboard as it arrives.
struct SidebarRenameField: View {
    let name: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .padding(Space.xs)
            .fieldSurface(cornerRadius: Radius.inset)
            .font(Typography.body.weight(.semibold))
            .focused($focused)
            .onSubmit { onCommit(draft) }
            .onExitCommand(perform: onCancel)
            .onAppear {
                draft = name
                focused = true
            }
    }
}
