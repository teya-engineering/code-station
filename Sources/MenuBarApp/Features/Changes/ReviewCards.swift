import SwiftUI

// A comment as a card under its lines: who left it, which lines, whether it asks for a
// change or an answer, and what it says. A finding still waiting to be sorted wears a
// dashed amber edge and carries its Keep, Edit and keep and Dismiss buttons; anything
// already in the review offers edit and delete on hover.
struct ReviewCommentCard: View {
    let comment: ReviewComment
    var focused = false
    var showsLines = true
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
    var onKeep: () -> Void = {}
    var onDismiss: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header
            ReviewText(text: comment.body)
            ForEach(Array(comment.also.enumerated()), id: \.offset) { _, voice in
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.sm) {
                        ReviewAvatar(agent: voice.agent, size: 16)
                        Text(voice.name).font(Typography.caption.weight(.semibold))
                        Text("raised the same lines").font(Typography.caption).foregroundStyle(.secondary)
                    }
                    ReviewText(text: voice.body, size: 12)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, Space.md)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 2) }
            }
            if comment.isPending { triage }
        }
        .padding(Space.lg)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(comment.isPending ? Theme.attention.opacity(0.06) : Theme.card))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card)
                .strokeBorder(comment.isPending ? Theme.attention.opacity(0.7) : Theme.border,
                              style: StrokeStyle(lineWidth: 1, dash: comment.isPending ? [4, 3] : []))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card).stroke(focused ? Theme.accent : .clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        .onPointerHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(comment.spokenName)
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            ReviewAvatars(comment: comment)
            Text(comment.authorName).scaledText(Typography.Size.detail, .semibold).lineLimit(1)
            if comment.kind == .question { QuestionTag() }
            if comment.reviewer != nil, let severity = comment.severity { SeverityChip(severity: severity) }
            if !comment.also.isEmpty {
                Label(comment.also.count == 1 ? "Both raised this" : "\(comment.voices.count) raised this",
                      systemImage: "person.2.fill")
                    .font(Typography.caption.weight(.semibold)).foregroundStyle(Theme.dotOnText)
                    .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs)
                    .background(Capsule().fill(Theme.dotOn.opacity(0.12)))
                    .lineLimit(1).fixedSize()
            }
            if showsLines {
                Text(comment.linesLabel).scaledMono(Typography.Size.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if comment.reviewer != nil, !comment.isPending {
                Text(comment.edited ? "Edited and kept by you" : "Kept by you")
                    .font(Typography.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            if !comment.isPending {
                HStack(spacing: Space.xs) {
                    GlyphButton(icon: "pencil", side: ControlHeight.xs, action: onEdit)
                        .appTooltip("Edit")
                        .accessibilityLabel("Edit comment")
                    GlyphButton(icon: "trash", side: ControlHeight.xs, tint: Theme.deletion, action: onDelete)
                        .appTooltip("Delete")
                        .accessibilityLabel("Delete comment")
                }
                .opacity(hovering || focused ? 1 : 0)
                .motion(Motion.hover, value: hovering || focused)
            }
        }
    }

    private var triage: some View {
        HStack(spacing: Space.md) {
            ActionButton(title: "Keep", tone: .green, height: ControlHeight.sm, size: Typography.Size.detail, icon: "checkmark", action: onKeep)
            ActionButton(title: "Edit and keep", tone: .outlined, height: ControlHeight.sm, size: Typography.Size.detail, action: onEdit)
            InlineLink(title: "Dismiss", size: Typography.Size.detail, tint: Color.secondary, action: onDismiss)
            Spacer(minLength: 0)
            if focused {
                HStack(spacing: Space.xs) {
                    KeyCap(key: "K"); Text("keep")
                    KeyCap(key: "E"); Text("edit")
                    KeyCap(key: "D"); Text("dismiss")
                }
                .font(Typography.caption).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            } else {
                Text("Not in your review until you keep it")
                    .font(Typography.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}

// Where a comment is written, opened right under the lines it is about. A new one is
// either a question, answered here by a side copy and never sent, or a change, which
// goes to the agent at once. The band, the hint and the button all say which.
struct ReviewComposer: View {
    @Binding var text: String
    @Binding var kind: ReviewComment.Kind
    let title: String
    let linesLabel: String
    let agentTitle: String
    let action: String
    // Shown only for a new comment, where shift-click still stretches the lines.
    var stretches = true
    // The file and lines, for the band over a new comment.
    var place = ""
    // The side copy is a fork of the conversation, so it has read the chat itself.
    var forksConversation = true
    var onDelete: (() -> Void)?
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    private var asks: Bool { stretches && kind == .question }

    var body: some View {
        Group {
            if stretches { newComment } else { editor }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .onAppear { focused = true }
    }

    private var newComment: some View {
        VStack(alignment: .leading, spacing: 0) {
            RouteBand(place: place, stays: asks, agentTitle: agentTitle)
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.xs) {
                    ChoicePill(title: "Ask a question", selected: kind == .question) { kind = .question; focused = true }
                        .accessibilityAddTraits(kind == .question ? .isSelected : [])
                    ChoicePill(title: "Request a change", selected: kind == .change) { kind = .change; focused = true }
                        .accessibilityAddTraits(kind == .change ? .isSelected : [])
                    Spacer(minLength: 0)
                    Text(linesLabel).scaledMono(Typography.Size.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Kind of comment")
                field(asks ? "What do you want to know about these lines?" : "What should \(agentTitle) change here?")
                HStack(alignment: .top, spacing: Space.sm) {
                    Image(systemName: asks ? "eye.slash" : "paperplane")
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(asks ? Theme.plan : Theme.accent)
                        .padding(.top, 1)
                    Text(asks ? questionHint : "Goes to \(agentTitle) in the chat as soon as you send it.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Typography.detail).foregroundStyle(.secondary)
                HStack(spacing: Space.lg) {
                    HStack(spacing: Space.xs) {
                        KeyCap(key: "⌘↩"); Text(asks ? "ask" : "send")
                        Text("·"); KeyCap(key: "esc"); Text("cancel")
                        Text("· shift-click a number to cover more lines").lineLimit(1)
                    }
                    .font(Typography.caption).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    InlineLink(title: "Cancel", tint: Color.secondary, action: onCancel)
                    ActionButton(title: asks ? "Ask" : "Send", tone: asks ? .plan : .green, height: ControlHeight.md, size: Typography.Size.detail,
                                 icon: asks ? "questionmark" : "paperplane",
                                 keyboardShortcut: KeyboardShortcut(.return, modifiers: .command), action: save)
                        .disabled(text.isBlank)
                }
            }
            .padding(Space.lg)
        }
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.card))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke((asks ? Theme.plan : Theme.accent).opacity(0.55)))
    }

    private var questionHint: String {
        forksConversation
            ? "A side copy of this session answers here. It has read the chat, but it can't edit files and nothing it says is added to the chat."
            : "A read-only run of \(agentTitle) answers here, given the diff and the recent chat. It can't edit files and nothing it says is added to the chat."
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                ReviewAvatar(agent: nil)
                Text(title).scaledText(Typography.Size.detail, .semibold).lineLimit(1)
                Text(linesLabel).scaledMono(Typography.Size.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
            }
            field(kind == .question
                  ? "What should \(agentTitle) explain? It answers without changing the code."
                  : "What should \(agentTitle) change here?")
            HStack(spacing: Space.lg) {
                HStack(spacing: Space.xs) {
                    KeyCap(key: "↩"); Text("save")
                    Text("·"); KeyCap(key: "esc"); Text("cancel")
                }
                .font(Typography.caption).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                if let onDelete {
                    InlineLink(title: "Delete", tint: Theme.deletion, action: onDelete)
                }
                InlineLink(title: "Cancel", tint: Color.secondary, action: onCancel)
                ActionButton(title: action, tone: .green, height: ControlHeight.md, size: Typography.Size.detail,
                             keyboardShortcut: KeyboardShortcut(.return, modifiers: .command), action: save)
                    .disabled(text.isBlank)
            }
        }
        .padding(Space.lg)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(Theme.accent.opacity(0.55)))
    }

    private func field(_ prompt: String) -> some View {
        TextField(prompt, text: $text, axis: .vertical)
            .lineLimit(2...8)
            .appTextField()
            .focused($focused)
            .onSubmit(save)
            .onExitCommand(perform: onCancel)
            .accessibilityLabel(asks ? "Question" : "Comment")
    }

    private func save() {
        guard !text.isBlank else { return }
        onSave()
    }
}

// MARK: - In Chat

// A sent review as it sits in the conversation: one card, posted when the review goes
// and updated in place as the agent works, with each comment as a thread.
struct ReviewCard: View {
    let round: ReviewRound
    let agent: AgentKind
    // The turn that took the review is still running.
    let working: Bool
    let checker: AgentKind?
    var projectPath = ""
    var textScale: CGFloat = 1
    let fileName: (ReviewComment) -> String
    let openInChanges: () -> Void
    let reply: (ReviewComment, String) -> Void
    let resolve: (ReviewComment) -> Void
    let reopen: (ReviewComment) -> Void
    let showInDiff: (ReviewComment) -> Void
    let reviewWhatChanged: () -> Void
    let checkFixes: () -> Void

    private var settling: Bool { working && !round.isSettled }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(round.comments) { comment in
                ReviewThreadView(round: round, comment: comment, agent: agent, fileName: fileName(comment),
                                 working: working, projectPath: projectPath, textScale: textScale,
                                 reply: { reply(comment, $0) },
                                 resolve: { resolve(comment) },
                                 reopen: { reopen(comment) },
                                 showInDiff: round.outcomes?[comment.id] == .changed && !comment.onFile
                                    ? { showInDiff(comment) } : nil)
                if comment.id != round.comments.last?.id {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
            }
            if !round.note.isBlank {
                (Text("Also: ").foregroundStyle(.secondary) + Text(round.note))
                    .font(Typography.detail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.xl).padding(.bottom, Space.lg)
            }
            footer
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.floating))
        .cardSurface(cornerRadius: Radius.floating)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your review, \(counted(round.comments.count, "comment"))")
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            ReviewAvatar(agent: nil, size: 22)
            Text("Your review").font(Typography.title)
            subtitle.font(Typography.detail).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            tally
            InlineLink(title: "Open in Changes", size: Typography.Size.detail, action: openInChanges)
        }
        .padding(.horizontal, Space.xl).padding(.vertical, Space.lg)
        .background(Theme.userMessage)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.userMessageRing).frame(height: 1) }
    }

    private var subtitle: Text {
        let count = counted(round.comments.count, "comment")
        let resolved = round.comments.count { round.resolved.contains($0.id) }
        if resolved == round.comments.count { return Text(count + " · all resolved") }
        if resolved > 0 { return Text(count + " · \(resolved) resolved") }
        return Text(count + " · sent ") + Text(round.sent, format: .relative(presentation: .named))
    }

    @ViewBuilder private var tally: some View {
        if settling {
            HStack(spacing: Space.sm) {
                LoopSpinner(size: 10)
                Text("\(agent.title) is working through it")
            }
            .font(Typography.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, Space.md).padding(.vertical, Space.xxs)
            .background(Capsule().fill(Theme.field))
        } else {
            HStack(spacing: Space.sm) {
                ForEach([ReviewRound.Status.changed, .answered, .unchanged, .waiting], id: \.label) { status in
                    let count = round.comments.count { round.status($0.id) == status }
                    if count > 0 { ReviewStatusChip(status: status, label: "\(count) " + status.label.lowercased()) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Space.md) {
            ActionButton(title: "Review what changed", tone: .green, height: ControlHeight.md, size: Typography.Size.detail,
                         icon: "plusminus", action: reviewWhatChanged)
            if let checker {
                ActionButton(title: "Ask \(checker.title) to check the fixes", tone: .outlined, height: ControlHeight.md,
                             size: Typography.Size.detail, icon: "person.2", action: checkFixes)
                    .disabled(round.trees.isEmpty)
            }
            Spacer(minLength: 0)
            if let checker {
                Text("\(checker.title) reads only what changed since you sent the review")
                    .font(Typography.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(settling)
        .padding(.horizontal, Space.xl).padding(.vertical, Space.lg)
        .background(Theme.sunken)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
