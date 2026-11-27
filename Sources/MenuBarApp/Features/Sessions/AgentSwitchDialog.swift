import SwiftUI

// Reviews a switch to another agent and then shows it happening, on one screen. The relay
// at the top is the same in both: the agent handing over on the left, the one taking over
// on the right, and between them the thing that will travel, which sets off along the
// path once the handover starts.
struct AgentSwitchDialog: View {
    @Bindable var draft: AgentSwitchDraft
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var handoffThumb
    @FocusState private var focusedHandoff: AgentHandoff?
    @State private var continueHovered = false
    @State private var blockedClicks = 0

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
            framesItself: true, fitsWindow: true, hugsContent: true,
            // Escape, or a click outside, puts the explanation away before it closes the
            // dialog.
            canDismiss: {
                guard draft.showsWhy else { return true }
                draft.showsWhy = false
                return false
            }))
    }

    // The step between parts that arrive together when the dialog opens.
    private static let beat = Motion.stagger * 2

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Space.pane)
                .padding(.top, Space.pane)
                .padding(.bottom, Space.xl)
                // The explanation hangs from the header over what is below it.
                .zIndex(1)
            // The review fits without scrolling. The scroll view only matters in a window
            // too short to hold the dialog.
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
        .motion(Motion.reveal, value: draft.access.isUnrestricted)
        .task(id: draft.to) { await draft.catalog.discoverModels(for: draft.to) }
        .task { await draft.readWorktree() }
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
            "Your worktree, branch and uncommitted changes stay as they are. You can switch back any time."
        case .running, .finished:
            "This takes a few seconds. \(draft.from.title) keeps its conversation."
        case .failed:
            "Nothing changed. You are still in \(draft.from.title)."
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.md) {
                    Text(title)
                        .font(Typography.title)
                        .contentTransition(.opacity)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    if draft.phase == .review {
                        WhyButton(label: "What stays and what goes", isOpen: $draft.showsWhy) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(impactRows.enumerated()), id: \.offset) { index, row in
                                    ImpactRowView(row: row, compact: true,
                                                  start: Double(index) * Self.beat)
                                }
                            }
                        }
                        .transition(.opacity)
                    }
                }
                // The row keeps the button's height once the button has gone, so the
                // title does not move when the handover starts.
                .frame(height: ControlHeight.md)
                .zIndex(1)
                Text(subtitle)
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .zIndex(1)
            relay
        }
        .motion(Motion.reveal, value: draft.showsWhy)
    }

    private var relay: some View {
        HStack(spacing: Space.lg) {
            relayEnd(agent: draft.from, detail: [draft.fromModelTitle, draft.fromEffortTitle]
                .compactMap { $0 }.joined(separator: " · "), order: 0)
            RelayPath(progress: relayProgress, colour: draft.to.tint,
                      carried: draft.handoff.carried, size: carriedSize,
                      travelling: draft.phase != .review, failed: draft.isFailed,
                      ready: continueHovered && draft.phase == .review && draft.canStart)
            relayEnd(agent: draft.to,
                     detail: draft.installedVersion.map { "v\($0)" } ?? draft.to.vendor,
                     order: 1, landed: draft.phase == .finished)
        }
        .padding(Space.lg)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("From \(draft.from.title) to \(draft.to.title)")
        .accessibilityValue(carriedSize.map { "\(draft.handoff.carried), \($0) tokens" }
                            ?? draft.handoff.carried)
    }

    private func relayEnd(agent: AgentKind, detail: String, order: Int, landed: Bool = false) -> some View {
        HStack(spacing: Space.md) {
            ReviewAvatar(agent: agent, size: ControlHeight.lg)
                .arrives(after: Double(order) * Self.beat * 3, growing: 0.8, animation: Motion.pop)
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

    // The size of what travels, once there is something to measure.
    private var carriedSize: String? {
        switch draft.handoff {
        case .worktree: nil
        case .note: draft.isDrafting ? nil : formattedTokens(draft.handoffTokens)
        case .transcript: formattedTokens(draft.handoffTokens)
        }
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

    private var impactRows: [Dialog.Impact.Row] {
        let given = switch draft.handoff {
        case .note: "the note"
        case .transcript: "the transcript as text"
        case .worktree: "the worktree"
        }
        var rows: [Dialog.Impact.Row] = [
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
        if draft.returning {
            rows.append(.init(
                title: "\(draft.to.title)'s own conversation",
                detail: "It still remembers everything up to when it handed over. What it is given only covers what \(draft.from.title) did after that.",
                kept: true))
        }
        return rows
    }

    // MARK: - Review

    private var review: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("What \(draft.to.title) gets")
                    .font(Typography.label)
                    .foregroundStyle(.secondary)
                handoffTrack
            }
            .arrives(after: Self.beat, rising: Space.sm)
            preview
                .padding(.top, Space.md)
                .arrives(after: Self.beat * 2, rising: Space.sm)
            runSettings
                .padding(.top, Space.xl)
                .arrives(after: Self.beat * 3, rising: Space.sm)
            if draft.access.isUnrestricted {
                fullAccessWarning
                    .padding(.top, Space.lg)
                    .transition(.fold)
            }
        }
    }

    // Three choices on one track, from the least the next agent can be given to the most.
    // Each says how big it is, so there is no separate meter to read.
    private var handoffTrack: some View {
        HStack(spacing: Space.xs) {
            ForEach(AgentHandoff.allCases) { kind in
                ChoicePill(title: kind.title, selected: draft.handoff == kind, thumb: handoffThumb,
                           detail: kind.blurb, fills: true, icon: kind.icon,
                           reading: sizeLine(kind)) {
                    draft.handoff = kind
                }
                .focused($focusedHandoff, equals: kind)
            }
        }
        .padding(Space.xxs)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.control + Space.xxs))
        .motion(Motion.control, value: draft.handoff)
        .onKeyPress(.leftArrow) { moveHandoff(-1) }
        .onKeyPress(.upArrow) { moveHandoff(-1) }
        .onKeyPress(.rightArrow) { moveHandoff(1) }
        .onKeyPress(.downArrow) { moveHandoff(1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What \(draft.to.title) gets")
    }

    private func moveHandoff(_ step: Int) -> KeyPress.Result {
        let all = AgentHandoff.allCases
        guard let index = all.firstIndex(of: draft.handoff) else { return .ignored }
        let next = all[(index + step + all.count) % all.count]
        draft.handoff = next
        focusedHandoff = next
        return .handled
    }

    private func sizeLine(_ kind: AgentHandoff) -> String {
        switch kind {
        case .worktree:
            return "Nothing from the chat"
        case .note where draft.isDrafting:
            return "Being written"
        case .note, .transcript:
            let tokens = "\(formattedTokens(draft.tokens(of: kind))) tokens"
            guard let share = draft.share(of: kind) else { return tokens }
            return "\(tokens), \(percent(share)) of window"
        }
    }

    private func percent(_ share: Double) -> String {
        "\(max(1, Int((share * 100).rounded())))%"
    }

    // What the next agent will get, in the form picked. The pane keeps one height, so
    // nothing below it moves as the choice changes.
    private var preview: some View {
        Group {
            switch draft.handoff {
            case .worktree: worktreePreview
            case .note: notePreview
            case .transcript: transcriptPreview
            }
        }
        .id(draft.handoff)
        .transition(.fadeIn)
        .frame(height: AgentSwitchMetrics.previewHeight)
    }

    private func readBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .surface(Theme.sunken, cornerRadius: Radius.control)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
    }

    private func facts<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.lg) { content() }
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Typography.detail)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func figure(_ count: Int, _ noun: String) -> Text {
        Text("\(Text(verbatim: "\(count)").fontWeight(.semibold).foregroundStyle(Color.primary)) \(count == 1 ? noun : noun + "s")")
    }

    // MARK: Worktree

    private var worktreePreview: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            readBox {
                facts {
                    Image(systemName: AgentHandoff.worktree.icon)
                    if let branch = draft.branch {
                        Text(branch)
                            .font(Typography.data.weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .truncationMode(.middle)
                    }
                    Text(worktreeSummary)
                    Spacer(minLength: 0)
                    if case .files(let files) = draft.worktree, !files.isEmpty {
                        DiffPair(added: files.reduce(0) { $0 + ($1.added ?? 0) },
                                 removed: files.reduce(0) { $0 + ($1.removed ?? 0) })
                    }
                }
                worktreeFiles
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            caption("\(draft.to.title) sees the branch and these files, nothing else. Write your first prompt as if to someone new.")
        }
        .motion(Motion.reveal, value: draft.worktree)
    }

    private var worktreeSummary: String {
        switch draft.worktree {
        case .reading: "Reading the changes"
        case .unknown: "Changes could not be read"
        case .files(let files):
            files.isEmpty ? "Nothing changed since the last commit"
                          : "\(counted(files.count, "file")) changed, not committed"
        }
    }

    @ViewBuilder private var worktreeFiles: some View {
        switch draft.worktree {
        case .reading:
            LoopSpinner()
        case .unknown:
            quietLine("\(draft.to.title) still starts in this folder, on the files as they are.")
        case .files(let files) where files.isEmpty:
            quietLine("\(draft.to.title) starts from the last commit.")
        case .files(let files):
            // The biggest changes say most about where the work is, so they go first.
            let largest = files.sorted { size(of: $0) > size(of: $1) }
            let shown = Array(largest.prefix(AgentSwitchMetrics.previewFiles))
            let scale = shown.map(size(of:)).max() ?? 1
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, file in
                    if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    FileBarRow(name: file.path, added: file.added ?? 0, removed: file.removed ?? 0,
                               scale: scale, nameWidth: ReviewMetrics.fileNameWidth)
                        .frame(height: ControlHeight.sm)
                }
                if files.count > shown.count {
                    Text("and \(files.count - shown.count) more")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, Space.xs)
                }
            }
            .padding(.horizontal, Space.lg)
            .transition(.fadeIn)
        }
    }

    private func size(of file: GitChange) -> Int { (file.added ?? 0) + (file.removed ?? 0) }

    private func quietLine(_ text: String) -> some View {
        Text(text)
            .font(Typography.detail)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Space.lg)
    }

    // MARK: Note

    private var notePreview: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ZStack(alignment: .topLeading) {
                AppTextEditor(text: $draft.note,
                              placeholder: draft.isDrafting ? "" : "Write what \(draft.to.title) needs to know.",
                              minHeight: ControlHeight.xl)
                    .frame(maxHeight: .infinity)
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
            HStack(alignment: .firstTextBaseline, spacing: Space.lg) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(noteCaption)
                        .font(Typography.detail)
                        .foregroundStyle(draft.silentWriter == nil ? Theme.secondaryText : Theme.attentionText)
                        // The controls beside it keep their width, so a long line folds
                        // rather than losing its end.
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    // The outgoing agent may be the one that is down, so the one way on
                    // offered here is to ask the agent taking over.
                    if draft.silentWriter == .outgoing, draft.incomingCanWrite {
                        InlineLink(title: "Ask \(draft.to.title) instead") { draft.draftNote(by: .incoming) }
                            .transition(.fadeIn)
                    }
                }
                Spacer(minLength: 0)
                NoteWriterLabel(name: draft.title(of: draft.writer))
                    .appMenu { writerEntries }
                    .accessibilityLabel("Written by \(draft.title(of: draft.writer))")
                InlineLink(title: "Draft again") { draft.draftNote() }
                    .disabled(draft.isDrafting)
                    .opacity(draft.isDrafting ? 0.4 : 1)
                    .appTooltip("Throws away your edits")
            }
            .motion(Motion.reveal, value: noteCaption)
        }
    }

    private var noteCaption: String {
        if let silent = draft.silentWriter {
            return "\(draft.title(of: silent)) didn't answer. This is a plain list."
        }
        if draft.isDrafting { return "\(draft.title(of: draft.writer)) is writing the note." }
        if draft.noteEdited {
            return "Edited by you. \(draft.to.title) gets exactly what is written here."
        }
        return "Edit anything before it goes."
    }

    // The menu stays usable while a note is being written, so nobody has to wait out an
    // agent that is not answering.
    private var writerEntries: [MenuEntry] {
        func pick(_ writer: NoteWriter) {
            guard writer != draft.writer || draft.silentWriter != nil else { return }
            draft.draftNote(by: writer)
        }
        return [
            .heading("Who writes the note"),
            .item(draft.from.title, checked: draft.writer == .outgoing,
                  subtitle: "Knows the work best. Needs \(draft.from.title) to be reachable.") {
                pick(.outgoing)
            },
            .item(draft.to.title, checked: draft.writer == .incoming,
                  subtitle: draft.incomingCanWrite
                    ? "Reads the transcript and writes its own brief. Works when \(draft.from.title) is down."
                    : "Not installed, so it cannot write the note.",
                  disabled: !draft.incomingCanWrite) {
                pick(.incoming)
            },
            .item("Code Station", checked: draft.writer == .app,
                  subtitle: "No agent. Lists the first ask, the edits and the commands. Ready at once.") {
                pick(.app)
            },
        ]
    }

    // MARK: Transcript

    private var transcriptPreview: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            readBox {
                facts {
                    figure(draft.messageCount, "message")
                    figure(draft.toolCallCount, "tool call")
                    Spacer(minLength: 0)
                    if let share = draft.share(of: .transcript) {
                        Text("\(percent(share)) of \(draft.to.title)'s window")
                            .font(Typography.data)
                        Meter(fraction: share, colour: share > 0.4 ? Theme.attention : draft.to.tint,
                              height: Space.xs)
                            .frame(width: ReviewMetrics.receiptBarWidth)
                            .accessibilityHidden(true)
                    } else {
                        Text("\(formattedTokens(draft.transcriptTokens)) tokens")
                            .font(Typography.data)
                    }
                }
                if draft.transcriptTail.isEmpty {
                    quietLine("Nothing has been said yet.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TailBlock(lines: draft.transcriptTail, label: "The end of the transcript",
                              isHeading: Self.speakers.contains)
                        .padding(.horizontal, Space.lg)
                        .padding(.vertical, Space.md)
                }
            }
            caption("\(draft.to.title) starts slower and the first prompt costs more. The oldest messages are cut if it gets too long.")
        }
    }

    // The lines of a plain transcript that say whose turn follows.
    private static let speakers = Set(["Person:"] + AgentKind.allCases.map { "\($0.title):" })

    // MARK: Run settings

    // The same pills the composer uses, on one line. What each option does is said in its
    // menu, where it is picked.
    private var runSettings: some View {
        FlowRow(spacing: Space.md) {
            Text("\(draft.to.title) runs with")
                .font(Typography.label)
                .foregroundStyle(.secondary)
                .frame(height: ControlHeight.md)
            let modelTitle = draft.model.map { draft.catalog.modelTitle($0) } ?? "Default model"
            ModelPill(title: modelTitle)
                .appMenu { modelEntries }
                .accessibilityLabel("Model: \(modelTitle)")
            let levels = draft.effortLevels
            if !levels.isEmpty {
                let effortTitle = draft.effort.map {
                    draft.catalog.effortTitle($0, for: draft.to, model: draft.model)
                } ?? "Default effort"
                EffortPill(title: effortTitle, lit: EffortMeter.lit(for: draft.effort, among: levels))
                    .appMenu { effortEntries(levels) }
                    .accessibilityLabel("Effort: \(effortTitle)")
            }
            ShieldPill(tone: draft.access.tone, title: draft.access.title)
                .appMenu { accessEntries }
                .accessibilityLabel("Access: \(draft.access.title)")
        }
    }

    private var modelEntries: [MenuEntry] {
        var entries: [MenuEntry] = [
            .heading("\(draft.to.title) model"),
            .item("Default", checked: draft.model == nil,
                  subtitle: "Whatever \(draft.to.title) is set to use") { draft.model = nil },
            .separator,
        ]
        entries += draft.modelOptions.map { option in
            MenuEntry.item(option.title, checked: draft.model == option.id,
                           subtitle: option.detail.isEmpty ? nil : option.detail) {
                draft.model = option.id
            }
        }
        return entries
    }

    private func effortEntries(_ levels: [String]) -> [MenuEntry] {
        [.heading("Effort")] + levels.map { level in
            MenuEntry.item(draft.catalog.effortTitle(level, for: draft.to, model: draft.model),
                           meter: EffortMeter.lit(for: level, among: levels),
                           checked: draft.effort == level) {
                draft.effort = level
            }
        }
    }

    private var accessEntries: [MenuEntry] {
        [.heading("Access")] + AgentAccess.choices(for: draft.to).map { access in
            MenuEntry.item(access.title, kind: access.isUnrestricted ? .destructive : .plain,
                           icon: "shield", iconTint: access.tone.ink,
                           checked: draft.access == access, subtitle: access.detail) {
                draft.access = access
            }
        }
    }

    // The one warning the dialog keeps. It folds in under the pill that causes it.
    private var fullAccessWarning: some View {
        let warning = AgentSwitch.fullAccessWarning(for: draft.to)
        return HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(warning.title).font(Typography.label)
                Text(warning.detail)
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .warningCard()
        .accessibilityElement(children: .combine)
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
        SheetFooter(primary: primaryAction, dismissTitle: dismissTitle, dismissTone: .outlined,
                    dismissHint: "esc", primaryLast: true, dismiss: { dialogs.dismiss() }) {
            FooterNote(note: footerNote, replay: blockedClicks)
        }
    }

    private var primaryAction: SheetAction? {
        let key = KeyboardShortcut(.return, modifiers: .command)
        switch draft.phase {
        case .review:
            return SheetAction(title: "Continue in \(draft.to.title)", enabled: draft.canStart,
                               shortcut: key, hint: "⌘↩", tone: .dark,
                               blockedReason: blockedReason,
                               onBlockedClick: { blockedClicks += 1 },
                               onHover: { continueHovered = $0 },
                               action: start)
        case .failed:
            return SheetAction(title: "Try again", shortcut: key, hint: "⌘↩", tone: .dark, action: start)
        case .running, .finished:
            return nil
        }
    }

    private var dismissTitle: String {
        switch draft.phase {
        case .review: "Keep \(draft.from.title)"
        case .running: "Cancel"
        case .finished: "Done"
        case .failed: "Stay in \(draft.from.title)"
        }
    }

    // Why Continue is off. Only the note can hold it back, and only while the note is the
    // handoff picked.
    private var blockedReason: String? {
        guard draft.phase == .review, !draft.canStart else { return nil }
        return draft.isDrafting ? "\(draft.title(of: draft.writer)) is still writing the note"
                                : "Write a note, or pick another handoff"
    }

    private var footerNote: FooterNote.Note? {
        switch draft.phase {
        case .review: blockedReason.map { .init(text: $0, mark: draft.isDrafting ? .working : .none) }
        case .running: .init(text: "Working", mark: .working)
        case .finished: .init(text: "\(draft.to.title) is ready", mark: .done)
        case .failed: nil
        }
    }

    private func start() {
        let dialog = dialogs.current?.id
        draft.start {
            Task {
                // The rings on the new agent's tile are the answer to the click, so they
                // play out before the dialog leaves.
                if !reduceMotion {
                    try? await Task.sleep(for: .seconds(Motion.ringDuration + Motion.ringGap))
                }
                if dialogs.current?.id == dialog { dialogs.dismiss() }
            }
        }
    }
}

enum AgentSwitchMetrics {
    // The preview of what the next agent gets, with the line under it. One height for all
    // three, so picking another handoff moves nothing else.
    static let previewHeight: CGFloat = 194
    // The changed files shown before "and n more".
    static let previewFiles = 4
    // Tall enough for the chip that rides the path.
    static let relayHeight: CGFloat = ControlHeight.sm
}

// What the footer says beside its buttons: why Continue is off, or how the handover is
// going. A click on the dead button plays the line in again.
private struct FooterNote: View {
    struct Note: Equatable {
        enum Mark { case none, working, done }

        let text: String
        var mark: Mark = .none
    }

    let note: Note?
    let replay: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            if let note {
                HStack(spacing: Space.sm) {
                    switch note.mark {
                    case .none: EmptyView()
                    case .working: LoopSpinner()
                    case .done:
                        Image(systemName: "checkmark")
                            .font(Typography.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .accessibilityHidden(true)
                    }
                    Text(note.text)
                        .font(Typography.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .id("\(note.text)#\(replay)")
                .transition(.asymmetric(insertion: .popover(reduceMotion: reduceMotion),
                                        removal: .identity))
            }
        }
        .motion(Motion.reveal, value: note)
        .motion(Motion.reveal, value: replay)
    }
}

// "Written by" and the writer's name, as the label of the menu that changes it.
private struct NoteWriterLabel: View {
    let name: String

    @State private var hovering = false
    @Environment(\.menuIsOpen) private var open

    var body: some View {
        HStack(spacing: Space.xs) {
            Text("Written by").foregroundStyle(.secondary)
            Text(name)
                .fontWeight(.semibold)
                .foregroundStyle(hovering || open ? Theme.accent : Color.primary)
                .contentTransition(.opacity)
            MenuChevron(size: 8)
        }
        .font(Typography.detail)
        .lineLimit(1)
        .fixedSize()
        .contentShape(Rectangle())
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .motion(Motion.reveal, value: name)
    }
}

// The path between the two agents: a dotted line until the handover starts, then a line
// that draws in up to where the handover has got. What is being handed over rides on its
// leading end, named and sized before it sets off.
private struct RelayPath: View {
    let progress: Double
    let colour: Color
    let carried: String
    let size: String?
    // The handover has started, so the chip takes the next agent's colour.
    let travelling: Bool
    let failed: Bool
    // The pointer is on Continue: the chip leans forward and the arrowhead lights.
    let ready: Bool

    private var reach: Double { ready ? 0.05 : progress }
    private var filled: Bool { travelling && !failed }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let reach = reach
            ZStack(alignment: .leading) {
                DottedLine()
                    .stroke(Theme.settingsBorder,
                            style: StrokeStyle(lineWidth: Space.xxs, dash: [Space.xs, Space.xs]))
                    .frame(height: Space.xxs)
                    // The line starts under the chip and stops short of the arrowhead.
                    .padding(.horizontal, Space.md)
                    .draws(after: Motion.stagger * 4)
                Capsule()
                    .fill(failed ? Theme.deletion : colour)
                    .frame(width: max(0, width * reach), height: Space.xxs)
                    .opacity(reach > 0 ? 1 : 0)
                Image(systemName: "chevron.right")
                    .font(Typography.micro)
                    .foregroundStyle(filled || ready ? colour : Theme.settingsBorder)
                    .offset(x: ready ? Space.xxs : 0)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                chip
                    .alignmentGuide(.leading) { chip in
                        -(width * reach) + chip.width * reach
                    }
                    .arrives(after: Motion.stagger * 12, rising: -Space.sm, animation: Motion.pop)
            }
            .frame(height: geometry.size.height)
        }
        .frame(height: AgentSwitchMetrics.relayHeight)
        .frame(minWidth: ControlHeight.xl)
        .motion(Motion.draw, value: progress)
        .motion(Motion.control, value: ready)
        .motion(Motion.reveal, value: failed)
        .motion(Motion.reveal, value: travelling)
        .motion(Motion.reveal, value: carried)
    }

    private var chip: some View {
        HStack(spacing: Space.sm) {
            Circle()
                .fill(filled ? Theme.onFill : failed ? Theme.deletion : colour)
                .frame(width: Space.sm, height: Space.sm)
            Text(carried)
                .font(Typography.micro)
                .contentTransition(.opacity)
            if let size {
                Text(size)
                    .font(Typography.data)
                    .opacity(0.75)
                    .contentTransition(.numericText())
                    .transition(.fadeIn)
            }
        }
        .foregroundStyle(filled ? Theme.onFill : failed ? Theme.secondaryText : Color.primary)
        .padding(.horizontal, Space.md)
        .frame(height: ControlHeight.xs)
        .surface(filled ? colour : Theme.card, cornerRadius: Radius.control,
                 border: filled ? .clear : Theme.settingsBorder)
        .fixedSize()
    }
}

private struct DottedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

// Placeholder lines that breathe while the note is being written.
private struct DraftingLines: View {
    var body: some View {
        Breathing {
            VStack(alignment: .leading, spacing: Space.md) {
                ForEach([0.22, 0.92, 0.74, 0.26, 0.88, 0.61], id: \.self) { share in
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
