import SwiftUI

// Reviews a switch to another agent and then shows it happening. The relay at the top is
// the same in both: the agent handing over on the left, the one taking over on the right,
// and the path between them that the handoff travels along once it starts.
struct AgentSwitchDialog: View {
    @Bindable var draft: AgentSwitchDraft
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var handoffThumb
    @Namespace private var modelThumb
    @Namespace private var effortThumb
    @Namespace private var accessThumb

    // Opens the dialog for a switch from the session's current agent to `target`. Shared by
    // the agent menu and the "Go back" link on a marker, so both review the same way.
    @MainActor
    static func open(_ target: AgentKind, in sessionID: UUID, store: ProjectStore,
                     runner: SessionRunner, dialogs: DialogPresenter) {
        guard let draft = AgentSwitchDraft(sessionID: sessionID, to: target, store: store,
                                           runner: runner) else { return }
        draft.draftNote()
        dialogs.show(Dialog(
            title: "Continue in \(target.title)?",
            content: AnyView(AgentSwitchDialog(draft: draft)),
            actions: [], onCancel: { draft.cancel() },
            width: FormMetrics.sheetWidth, isModal: true,
            framesItself: true, fitsWindow: true, hugsContent: true))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Space.pane)
                .padding(.top, Space.pane)
                .padding(.bottom, Space.lg)
            ScrollView {
                Group {
                    if draft.phase == .review {
                        review.transition(.fadeIn)
                    } else {
                        progress.transition(.fadeIn)
                    }
                }
                .padding(.horizontal, Space.pane)
                .padding(.bottom, Space.pane)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .background(Theme.card)
        .focusBoundary()
        .motion(Motion.reveal, value: draft.phase)
        .motion(Motion.reveal, value: draft.handoff)
        .task(id: draft.to) { await draft.catalog.discoverModels(for: draft.to) }
    }

    // MARK: - Header and relay

    private var title: String {
        switch draft.phase {
        case .review: "Continue in \(draft.to.title)?"
        case .running, .finished: "Handing over to \(draft.to.title)"
        case .failed: "Handover stopped"
        }
    }

    private var subtitle: String {
        switch draft.phase {
        case .review:
            "\(draft.to.title) takes over this session. The worktree, branch and uncommitted changes stay exactly as they are."
        case .running, .finished:
            "This takes a few seconds. \(draft.from.title) keeps its conversation."
        case .failed:
            "Nothing changed. You are still in \(draft.from.title)."
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title)
                    .font(Typography.title)
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            relay
        }
    }

    private var relay: some View {
        HStack(spacing: Space.lg) {
            relayEnd(agent: draft.from, detail: [draft.fromModelTitle, draft.fromEffortTitle]
                .compactMap { $0 }.joined(separator: " · "))
            RelayPath(progress: relayProgress, colour: draft.to.tint,
                      carried: draft.phase == .review ? nil : draft.handoff.carried,
                      failed: draft.isFailed)
            relayEnd(agent: draft.to,
                     detail: draft.installedVersion.map { "v\($0)" } ?? draft.to.vendor,
                     landed: draft.phase == .finished)
        }
        .padding(Space.lg)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("From \(draft.from.title) to \(draft.to.title)")
    }

    private func relayEnd(agent: AgentKind, detail: String, landed: Bool = false) -> some View {
        HStack(spacing: Space.md) {
            ReviewAvatar(agent: agent, size: ControlHeight.lg)
                .landingRings(landed ? 1 : nil, colour: agent.tint, cornerRadius: Radius.card)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(agent.title).font(Typography.label)
                Text(detail)
                    .font(Typography.data)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .fixedSize()
    }

    private var relayProgress: Double {
        switch draft.phase {
        case .review: 0
        case .running(let step), .failed(let step):
            switch step {
            case .save: 0.05
            case .note: 0.25
            case .start: 0.6
            case .read: 0.85
            }
        case .finished: 1
        }
    }

    // MARK: - Review

    private var review: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            handoffSection
            runSection
            let warnings = draft.warnings
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: Space.md) {
                    SectionRule("CHECK BEFORE YOU SWITCH")
                    ForEach(warnings) { WarningRow(warning: $0) }
                }
                .transition(.fadeIn)
            }
            VStack(alignment: .leading, spacing: 0) {
                SectionRule("WHAT CHANGES")
                ForEach(Array(impactRows.enumerated()), id: \.offset) { index, row in
                    ImpactRowView(row: row, compact: true, start: 0.12 + Double(index) * Motion.stagger * 3)
                }
            }
        }
    }

    private var handoffSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionRule(title: "WHAT \(draft.to.title.uppercased()) GETS") {
                Text(meterText)
                    .font(Typography.data)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .fixedSize()
            }
            HStack(spacing: Space.xs) {
                ForEach(AgentHandoff.allCases) { kind in
                    ChoicePill(title: kind.title, selected: draft.handoff == kind,
                               thumb: handoffThumb, fills: true) {
                        draft.handoff = kind
                    }
                }
            }
            .padding(Space.xxs)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.control))
            .motion(Motion.control, value: draft.handoff)
            Meter(fraction: draft.handoffShare ?? (draft.handoff == .worktree ? 0 : 0.01),
                  colour: (draft.handoffShare ?? 0) > 0.4 ? Theme.attention : draft.to.tint,
                  height: Space.xs)
                .motion(Motion.draw, value: draft.handoffTokens)
                .accessibilityHidden(true)
            Text(handoffHint)
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if draft.handoff == .note {
                noteEditor.transition(.fadeIn)
            }
        }
    }

    private var meterText: String {
        guard draft.handoff != .worktree else { return "Nothing from the chat" }
        let tokens = "\(formattedTokens(draft.handoffTokens)) tokens"
        guard let share = draft.handoffShare else { return tokens }
        return "\(tokens) · \(max(1, Int((share * 100).rounded())))% of the window"
    }

    private var handoffHint: String {
        switch draft.handoff {
        case .note:
            "\(draft.from.title) drafts this from the transcript. Edit anything before it goes."
        case .transcript:
            "\(draft.to.title) reads every message and tool call as plain text. It starts slower, costs more, and the oldest messages are cut if it is very long."
        case .worktree:
            "\(draft.to.title) starts cold. It sees the changed files and the branch, nothing else. Write your first prompt as if to someone new."
        }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            ZStack(alignment: .topLeading) {
                AppTextEditor(text: $draft.note, placeholder: draft.isDrafting ? "" : "Write what \(draft.to.title) needs to know.",
                              minHeight: AgentSwitchMetrics.noteHeight)
                    .frame(height: AgentSwitchMetrics.noteHeight)
                    .disabled(draft.isDrafting)
                    .accessibilityLabel("Handoff note")
                if draft.isDrafting {
                    DraftingLines()
                        .padding(Space.lg)
                        .allowsHitTesting(false)
                        .transition(.opacity.animation(Motion.leave))
                }
            }
            .motion(Motion.reveal, value: draft.isDrafting)
            HStack(spacing: Space.md) {
                Text(draft.isDrafting ? "\(draft.from.title) is writing the note…" : "Markdown")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
                InlineLink(title: "Draft again", size: Typography.Size.caption) { draft.draftNote() }
                    .disabled(draft.isDrafting)
                    .appTooltip("Throw away your edits and draft the note again")
            }
        }
    }

    private var runSection: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            SectionRule("HOW \(draft.to.title.uppercased()) RUNS")
            settingRow("Model") {
                FlowRow(spacing: Space.xs) {
                    ChoicePill(title: "Default", selected: draft.model == nil, thumb: modelThumb) {
                        draft.model = nil
                    }
                    ForEach(draft.modelOptions, id: \.id) { option in
                        ChoicePill(title: option.title, selected: draft.model == option.id,
                                   thumb: modelThumb) { draft.model = option.id }
                            .appTooltip(option.detail.isEmpty ? option.title : option.detail)
                    }
                }
                .motion(Motion.control, value: draft.model)
            }
            settingRow("Effort") {
                let levels = draft.effortLevels
                if levels.isEmpty {
                    Text("\(draft.to.title) doesn't offer an effort setting.")
                        .font(Typography.detail)
                        .foregroundStyle(.secondary)
                } else {
                    FlowRow(spacing: Space.xs) {
                        ForEach(levels, id: \.self) { level in
                            ChoicePill(title: draft.catalog.effortTitle(level, for: draft.to, model: draft.model),
                                       selected: draft.effort == level, thumb: effortThumb) {
                                draft.effort = level
                            }
                        }
                    }
                    .motion(Motion.control, value: draft.effort)
                }
            }
            settingRow("Access") {
                FlowRow(spacing: Space.xs) {
                    ForEach(AgentAccess.choices(for: draft.to), id: \.self) { access in
                        ChoicePill(title: access.title, selected: draft.access == access,
                                   dot: access.isUnrestricted ? Theme.deletion : nil,
                                   thumb: accessThumb) { draft.access = access }
                            .appTooltip(access.detail)
                    }
                }
                .motion(Motion.control, value: draft.access)
            }
        }
    }

    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.lg) {
            Text(label)
                .font(Typography.label)
                .foregroundStyle(.secondary)
                .frame(width: FormMetrics.rowLabelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var impactRows: [Dialog.Impact.Row] {
        let given = switch draft.handoff {
        case .note: "the note"
        case .transcript: "the transcript as text"
        case .worktree: "the worktree"
        }
        return [
            .init(title: "\(draft.from.title)'s working memory",
                  detail: "Files it read, its reasoning and tool results. \(draft.to.title) gets only \(given)."),
            .init(title: "Every change in the worktree",
                  detail: draft.branch.map { "Same folder, same branch: \($0). Nothing is committed or reset." }
                    ?? "Same folder and branch. Nothing is committed or reset.",
                  kept: true),
            .init(title: "\(draft.from.title)'s conversation",
                  detail: "Kept as it is. Switch back any time and it picks up where it stopped.",
                  kept: true),
            .init(title: "This transcript",
                  detail: "Both agents' turns stay in one session, split by a marker.",
                  kept: true),
        ]
    }

    // MARK: - Progress

    private var progress: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(AgentSwitchDraft.Step.allCases) { step in
                    StepRow(title: stepTitle(step), detail: stepDetail(step), state: state(of: step),
                            seconds: draft.stepSeconds[step])
                }
            }
            if let failure = draft.failure {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text(failure.title).font(Typography.label)
                    Text(failure.message)
                        .font(Typography.detail)
                        .fixedSize(horizontal: false, vertical: true)
                    if let command = failure.command {
                        HStack(spacing: Space.md) {
                            Text(command)
                                .font(Typography.code)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            CopyButton("Copy") { command }
                        }
                        .padding(Space.md)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: Radius.control))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .warningCard()
                .accessibilityElement(children: .combine)
            }
        }
        .motion(Motion.reveal, value: draft.failure)
    }

    private func state(of step: AgentSwitchDraft.Step) -> StepRow.State {
        switch draft.phase {
        case .review: .waiting
        case .finished: .done
        case .running(let current):
            step == current ? .working : step.rawValue < current.rawValue ? .done : .waiting
        case .failed(let current):
            step == current ? .failed : step.rawValue < current.rawValue ? .done : .waiting
        }
    }

    private func stepTitle(_ step: AgentSwitchDraft.Step) -> String {
        switch step {
        case .save: "Save \(draft.from.title)'s conversation"
        case .note: draft.handoff == .worktree ? "Skip the handoff" : "Finish the \(draft.handoff == .note ? "handoff note" : "transcript")"
        case .start: "Start \(draft.to.title)\(draft.installedVersion.map { " \($0)" } ?? "")"
        case .read: draft.handoff == .worktree ? "Hand the session to \(draft.to.title)" : "\(draft.to.title) reads the \(draft.handoff == .note ? "note" : "transcript")"
        }
    }

    private func stepDetail(_ step: AgentSwitchDraft.Step) -> String {
        switch step {
        case .save: "Kept, so you can switch back"
        case .note:
            switch draft.handoff {
            case .note: "\(formattedTokens(draft.handoffTokens)) tokens, your edits kept"
            case .transcript: "Whole transcript, \(formattedTokens(draft.handoffTokens)) tokens"
            case .worktree: "Just the worktree"
            }
        case .start: draft.settingsSummary
        case .read: draft.handoff == .worktree ? "Ready for your next prompt" : "Its first reply says what it took over"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Space.md) {
            footerNote
            Spacer(minLength: Space.md)
            switch draft.phase {
            case .review:
                ActionButton(title: "Keep \(draft.from.title)", tone: .outlined, height: ControlHeight.lg,
                             keyboardShortcut: .cancelAction) { dialogs.dismiss() }
                ActionButton(title: "Continue in \(draft.to.title)", tone: .dark, height: ControlHeight.lg) {
                    draft.start { dialogs.dismiss() }
                }
                .disabled(!draft.canStart)
            case .running, .finished:
                ActionButton(title: "Cancel", tone: .outlined, height: ControlHeight.lg,
                             keyboardShortcut: .cancelAction) { dialogs.dismiss() }
                    .disabled(draft.phase == .finished)
            case .failed:
                ActionButton(title: "Stay in \(draft.from.title)", tone: .outlined, height: ControlHeight.lg,
                             keyboardShortcut: .cancelAction) { dialogs.dismiss() }
                ActionButton(title: "Try again", tone: .dark, height: ControlHeight.lg) {
                    draft.start { dialogs.dismiss() }
                }
            }
        }
        .padding(.horizontal, Space.pane)
        .padding(.vertical, Space.lg)
        .background(Theme.field)
    }

    @ViewBuilder private var footerNote: some View {
        switch draft.phase {
        case .review:
            Text("Esc keeps \(draft.from.title)")
        case .running:
            HStack(spacing: Space.sm) {
                LoopSpinner()
                Text("Working")
            }
        case .finished:
            Text("\(draft.to.title) is ready")
        case .failed:
            Text("Handover stopped")
        }
    }
}

enum AgentSwitchMetrics {
    static let noteHeight: CGFloat = 168
    // Wide enough for "Handoff note", tall enough for the chip to sit on the line.
    static let relayHeight: CGFloat = ControlHeight.sm
}

// The line between the two agents. It draws in up to where the handover has got, with the
// thing being handed over riding on its leading end.
private struct RelayPath: View {
    let progress: Double
    let colour: Color
    let carried: String?
    let failed: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.border)
                    .frame(height: 2)
                Capsule()
                    .fill(failed ? Theme.deletion : colour)
                    .frame(width: max(0, width * progress), height: 2)
                if let carried {
                    Text(carried)
                        .font(Typography.micro)
                        .foregroundStyle(failed ? Theme.secondaryText : Theme.onFill)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, Space.xxs)
                        .background(failed ? Theme.field : colour, in: Capsule())
                        .fixedSize()
                        .alignmentGuide(.leading) { chip in
                            -(width * progress) + chip.width * progress
                        }
                        .opacity(failed ? 0.6 : 1)
                        .transition(.fadeIn)
                }
            }
            .frame(height: geometry.size.height)
        }
        .frame(height: AgentSwitchMetrics.relayHeight)
        .frame(minWidth: ControlHeight.xl)
        .motion(Motion.draw, value: progress)
        .motion(Motion.reveal, value: failed)
    }
}

// Placeholder lines that breathe while the outgoing agent writes the note.
private struct DraftingLines: View {
    var body: some View {
        Breathing {
            VStack(alignment: .leading, spacing: Space.md) {
                ForEach([0.4, 0.9, 0.75, 0.85, 0.5], id: \.self) { share in
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Theme.border)
                            .frame(width: geometry.size.width * share, height: Space.md)
                    }
                    .frame(height: Space.md)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct WarningRow: View {
    let warning: AgentSwitchWarning

    private var ink: Color {
        switch warning.tone {
        case .info: Theme.secondaryText
        case .caution: Theme.attentionText
        case .danger: Theme.warningText
        }
    }

    private var fill: Color {
        switch warning.tone {
        case .info: Theme.field
        case .caution: Theme.attention.opacity(0.12)
        case .danger: Theme.warningBackground
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Image(systemName: warning.tone == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .font(Typography.detail)
                .foregroundStyle(ink)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(warning.title)
                    .font(Typography.label)
                    .foregroundStyle(warning.tone == .info ? Color.primary : ink)
                Text(warning.detail)
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.card)
        .background(fill, in: RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityElement(children: .combine)
    }
}

private struct StepRow: View {
    enum State { case waiting, working, done, failed }

    let title: String
    let detail: String
    let state: State
    let seconds: Double?

    var body: some View {
        HStack(spacing: Space.lg) {
            ZStack {
                switch state {
                case .waiting:
                    Circle().strokeBorder(Theme.border, lineWidth: 1.5)
                case .working:
                    LoopSpinner(colour: Theme.accent, size: Space.xl)
                case .done:
                    Image(systemName: "checkmark")
                        .font(Typography.label)
                        .foregroundStyle(Theme.accent)
                        .transition(.opacity.combined(with: .offset(y: Space.xxs)))
                case .failed:
                    Image(systemName: "xmark")
                        .font(Typography.label)
                        .foregroundStyle(Theme.deletion)
                        .transition(.fadeIn)
                }
            }
            .frame(width: Space.xl, height: Space.xl)
            .motion(Motion.pop, value: state)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title)
                    .font(Typography.body.weight(.medium))
                    .foregroundStyle(state == .waiting ? Color.secondary : Color.primary)
                Text(detail)
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let seconds, state == .done || state == .failed {
                Text(String(format: "%.1fs", seconds))
                    .font(Typography.data)
                    .foregroundStyle(.tertiary)
                    .transition(.fadeIn)
            }
        }
        .padding(.vertical, Space.md)
        .accessibilityElement(children: .combine)
        .accessibilityValue(spokenState)
    }

    private var spokenState: String {
        switch state {
        case .waiting: "Waiting"
        case .working: "In progress"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
}
