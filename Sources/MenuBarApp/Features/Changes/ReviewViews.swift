import SwiftUI
import CodeStationCore

// The pieces a review is drawn with, shared by both diff layouts, the review list, the
// send dialog and the cards in Chat, so a comment looks the same wherever it turns up.

// Who left a comment: you, or the reviewer's mark on a quiet tile.
struct ReviewAvatar: View {
    // Nil for you.
    let agent: AgentKind?
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: agent?.symbol ?? "person.fill")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(agent == nil ? Theme.accent : Color.secondary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3).fill(agent == nil ? Theme.userMessage : Theme.field))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3).stroke(Theme.border))
            .accessibilityHidden(true)
    }
}

// Every voice on a comment, overlapping, the way two reviewers on one finding read.
struct ReviewAvatars: View {
    let comment: ReviewComment
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: -size * 0.3) {
            if comment.reviewers.isEmpty {
                ReviewAvatar(agent: nil, size: size)
            } else {
                ForEach(Array(comment.reviewers.enumerated()), id: \.offset) { ReviewAvatar(agent: $0.element, size: size) }
            }
        }
    }
}

// How much a finding matters, said in words and a shape so it never rests on colour.
struct SeverityChip: View {
    let severity: ReviewComment.Severity
    // How many findings carry it, for a tally rather than a single finding.
    var count: Int?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(count.map { "\($0) \(severity.label.lowercased())" } ?? severity.label).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).fixedSize()
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(fill))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch severity {
        case .must: "exclamationmark.triangle.fill"
        case .should: "circle.fill"
        case .look: "eye"
        }
    }

    private var ink: Color {
        switch severity {
        case .must: Theme.warningText
        case .should: Theme.attentionText
        case .look: Color.secondary
        }
    }

    private var fill: Color {
        switch severity {
        case .must: Theme.warningBackground
        case .should: Theme.attention.opacity(0.14)
        case .look: Theme.field
        }
    }
}

struct QuestionTag: View {
    var body: some View {
        Text("Question")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.plan)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Theme.plan.opacity(0.12)))
            .fixedSize()
    }
}

// A key drawn as a cap, for the hints that teach the keyboard.
struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
    }
}

// A comment's words, with the `code` spans reviewers write drawn as code.
struct ReviewText: View {
    let text: String
    var size: CGFloat = 12.5
    var lineLimit: Int?

    var body: some View {
        Text(Self.attributed(text))
            .scaledText(size)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: lineLimit == nil)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

// MARK: - Cards

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
        VStack(alignment: .leading, spacing: 8) {
            header
            ReviewText(text: comment.body)
            ForEach(Array(comment.also.enumerated()), id: \.offset) { _, voice in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ReviewAvatar(agent: voice.agent, size: 16)
                        Text(voice.name).font(.system(size: 11, weight: .semibold))
                        Text("raised the same lines").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ReviewText(text: voice.body, size: 12)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 2) }
            }
            if comment.isPending { triage }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(comment.isPending ? Theme.attention.opacity(0.06) : Theme.card))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(comment.isPending ? Theme.attention.opacity(0.7) : Theme.border,
                              style: StrokeStyle(lineWidth: 1, dash: comment.isPending ? [4, 3] : []))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(focused ? Theme.accent : .clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(comment.spokenName)
    }

    private var header: some View {
        HStack(spacing: 7) {
            ReviewAvatars(comment: comment)
            Text(comment.authorName).scaledText(12, .semibold).lineLimit(1)
            if comment.kind == .question { QuestionTag() }
            if comment.reviewer != nil, let severity = comment.severity { SeverityChip(severity: severity) }
            if !comment.also.isEmpty {
                Label(comment.also.count == 1 ? "Both raised this" : "\(comment.voices.count) raised this",
                      systemImage: "person.2.fill")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.dotOnText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.dotOn.opacity(0.12)))
                    .lineLimit(1).fixedSize()
            }
            if showsLines {
                Text(comment.linesLabel).scaledMono(10.5).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if comment.reviewer != nil, !comment.isPending {
                Text(comment.edited ? "Edited and kept by you" : "Kept by you")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if !comment.isPending {
                HStack(spacing: 4) {
                    GlyphButton(icon: "pencil", side: 22, action: onEdit)
                        .appTooltip("Edit")
                        .accessibilityLabel("Edit comment")
                    GlyphButton(icon: "trash", side: 22, tint: Theme.deletion, action: onDelete)
                        .appTooltip("Delete")
                        .accessibilityLabel("Delete comment")
                }
                .opacity(hovering || focused ? 1 : 0)
            }
        }
    }

    private var triage: some View {
        HStack(spacing: 10) {
            ActionButton(title: "Keep", tone: .green, height: 26, size: 11.5, icon: "checkmark", action: onKeep)
            ActionButton(title: "Edit and keep", tone: .outlined, height: 26, size: 11.5, action: onEdit)
            InlineLink(title: "Dismiss", size: 11.5, tint: Color.secondary, action: onDismiss)
            Spacer(minLength: 0)
            if focused {
                HStack(spacing: 4) {
                    KeyCap(key: "K"); Text("keep")
                    KeyCap(key: "E"); Text("edit")
                    KeyCap(key: "D"); Text("dismiss")
                }
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            } else {
                Text("Not in your review until you keep it")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    ChoicePill(title: "Ask a question", selected: kind == .question) { kind = .question; focused = true }
                        .accessibilityAddTraits(kind == .question ? .isSelected : [])
                    ChoicePill(title: "Request a change", selected: kind == .change) { kind = .change; focused = true }
                        .accessibilityAddTraits(kind == .change ? .isSelected : [])
                    Spacer(minLength: 0)
                    Text(linesLabel).scaledMono(10.5).foregroundStyle(.secondary).lineLimit(1)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Kind of comment")
                field(asks ? "What do you want to know about these lines?" : "What should \(agentTitle) change here?")
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: asks ? "eye.slash" : "paperplane")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(asks ? Theme.plan : Theme.accent)
                        .padding(.top, 1)
                    Text(asks ? questionHint : "Goes to \(agentTitle) in the chat as soon as you send it.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    HStack(spacing: 4) {
                        KeyCap(key: "⌘↩"); Text(asks ? "ask" : "send")
                        Text("·"); KeyCap(key: "esc"); Text("cancel")
                        Text("· shift-click a number to cover more lines").lineLimit(1)
                    }
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    InlineLink(title: "Cancel", tint: Color.secondary, action: onCancel)
                    ActionButton(title: asks ? "Ask" : "Send", tone: asks ? .plan : .green, height: 28, size: 12,
                                 icon: asks ? "questionmark" : "paperplane",
                                 keyboardShortcut: KeyboardShortcut(.return, modifiers: .command), action: save)
                        .disabled(text.isBlank)
                }
            }
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke((asks ? Theme.plan : Theme.accent).opacity(0.55)))
    }

    private var questionHint: String {
        forksConversation
            ? "A side copy of this session answers here. It has read the chat, but it can't edit files and nothing it says is added to the chat."
            : "A read-only run of \(agentTitle) answers here, given the diff and the recent chat. It can't edit files and nothing it says is added to the chat."
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ReviewAvatar(agent: nil)
                Text(title).scaledText(12, .semibold).lineLimit(1)
                Text(linesLabel).scaledMono(10.5).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
            }
            field(kind == .question
                  ? "What should \(agentTitle) explain? It answers without changing the code."
                  : "What should \(agentTitle) change here?")
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    KeyCap(key: "↩"); Text("save")
                    Text("·"); KeyCap(key: "esc"); Text("cancel")
                }
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                if let onDelete {
                    InlineLink(title: "Delete", tint: Theme.deletion, action: onDelete)
                }
                InlineLink(title: "Cancel", tint: Color.secondary, action: onCancel)
                ActionButton(title: action, tone: .green, height: 28, size: 12,
                             keyboardShortcut: KeyboardShortcut(.return, modifiers: .command), action: save)
                    .disabled(text.isBlank)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.55)))
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

// The strip over a comment that says where it goes: blue for a question that stays on
// this screen, green for a change that goes to the agent. Always in words as well.
struct RouteBand: View {
    let place: String
    let stays: Bool
    let agentTitle: String

    var body: some View {
        HStack(spacing: 8) {
            Text(place).font(.mono(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Label(stays ? "Only in Changes" : "Goes to \(agentTitle)", systemImage: stays ? "eye.slash" : "paperplane")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(stays ? Theme.plan : Theme.accent)
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background((stays ? Theme.plan : Theme.accent).opacity(0.07))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

// A side copy of the session: the agent's mark in a dashed ring, so it reads as the same
// agent but not the same conversation. The ring turns while it answers.
struct SideCopyAvatar: View {
    let agent: AgentKind
    var size: CGFloat = 22
    var answering = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !answering || reduceMotion)) { context in
            let phase = answering && !reduceMotion
                ? CGFloat(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2) * -9 : 0
            ReviewAvatar(agent: agent, size: size - 6)
                .frame(width: size, height: size)
                .overlay {
                    Circle().strokeBorder(Theme.plan.opacity(0.75),
                                          style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2], dashPhase: phase))
                        .padding(-2)
                }
        }
        .accessibilityHidden(true)
    }
}

// A question as a thread under its lines: what was asked, the side copy's answer as it
// comes in, any follow-ups, and what can be done with a change it suggests. Nothing in it
// reaches the main chat unless the person turns the suggestion into a change and sends it.
struct QuestionThreadView: View {
    let question: ReviewQuestion
    let place: String
    var steps: [String] = []
    var showsBand = true
    var focused = false
    var projectPath = ""
    var textScale: CGFloat = 1
    // The change made from the suggestion, waiting in the review or already sent, and
    // when it went.
    var change: ReviewComment?
    var changeSent: Date?
    let followUp: (String) -> Void
    let resolve: () -> Void
    let reopen: () -> Void
    let retry: () -> Void
    let delete: () -> Void
    // Nil where there are no lines to hang a change from: a question on the whole change.
    var makeChange: (() -> Void)?
    var takeOut: () -> Void = {}
    var editChange: (String) -> Void = { _ in }
    var sendsQuestion: (Bool) -> Void = { _ in }

    @State private var asking = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var agent: AgentKind { question.agent }

    var body: some View {
        Group {
            if question.resolved && question.status == .answered { collapsed } else { full }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question.spokenName)
    }

    private var collapsed: some View {
        Button(action: reopen) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle").foregroundStyle(Theme.plan)
                (Text(question.text).fontWeight(.medium)
                 + Text(ReviewText.attributed(" - " + (question.exchanges.last?.answer ?? ""))).foregroundStyle(.secondary))
                    .font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 8)
                ReviewStatusChip(status: .answered)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the question again")
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsBand { RouteBand(place: place, stays: true, agentTitle: agent.title) }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(question.exchanges) { exchange in
                    you(exchange.question, first: exchange.id == question.exchanges.first?.id)
                    if let answer = exchange.answer {
                        sideCopy(meta: meta(exchange)) {
                            MarkdownProse(text: answer, projectPath: projectPath, textScale: textScale) { segment in
                                MarkdownCodeBlock(segment: segment).equatable()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if let failure = exchange.failure {
                        failed(failure)
                    } else {
                        answering
                    }
                }
                if question.status == .answered { outcome }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
            if asking { followUpBox }
            if question.status == .answered, !asking { actions }
        }
    }

    private func meta(_ exchange: ReviewQuestion.Exchange) -> String {
        let time = (exchange.answered ?? exchange.asked).formatted(date: .omitted, time: .shortened)
        return "side copy · \(time) · changed nothing"
    }

    private func you(_ text: String, first: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ReviewAvatar(agent: nil, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("You").font(.system(size: 12, weight: .semibold))
                    if first { QuestionTag() }
                }
                .frame(minHeight: 22)
                ReviewText(text: text, size: 13)
            }
        }
    }

    private func sideCopy<Content: View>(meta: String, answering: Bool = false,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SideCopyAvatar(agent: agent, answering: answering)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(agent.title).font(.system(size: 12, weight: .semibold))
                    Text(meta).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .frame(minHeight: 22)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var answering: some View {
        sideCopy(meta: "side copy · answering", answering: true) {
            VStack(alignment: .leading, spacing: 4) {
                let shown = steps.isEmpty ? ["Starting"] : steps
                ForEach(Array(shown.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 6) {
                        if index == shown.count - 1 {
                            ProgressView().controlSize(.mini).frame(width: 12)
                        } else {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.dotOn).frame(width: 12)
                        }
                        Text(step).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.top, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(agent.title) is answering. " + (steps.last ?? ""))
        }
    }

    private func failed(_ reason: String) -> some View {
        sideCopy(meta: "side copy") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    (Text("Couldn't answer. ").fontWeight(.semibold) + Text(reason))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12)).foregroundStyle(Theme.warningText)
                HStack(spacing: 12) {
                    ActionButton(title: "Try again", tone: .outlined, height: 26, size: 11.5,
                                 icon: "arrow.clockwise", action: retry)
                    InlineLink(title: "Delete", size: 11.5, tint: Theme.deletion, action: delete)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warningBackground))
        }
    }

    // What the answer leads to: a change to make, one already in the review or sent, or
    // nothing at all.
    @ViewBuilder private var outcome: some View {
        if let suggestion = question.suggestion {
            Group {
                if let change, let changeSent {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Sent to \(agent.title) at " + changeSent.formatted(date: .omitted, time: .shortened),
                              systemImage: "checkmark")
                            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.accent)
                        ReviewText(text: change.body, size: 12.5).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                } else if let change {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Change for \(agent.title) · in your review", systemImage: "pencil")
                            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.accent)
                        TextField("What should \(agent.title) change?",
                                  text: Binding(get: { change.body }, set: { editChange($0) }), axis: .vertical)
                            .lineLimit(1...6)
                            .appTextField()
                            .accessibilityLabel("Change for \(agent.title)")
                        HStack(spacing: 12) {
                            Toggle("Also send the question and answer",
                                   isOn: Binding(get: { change.why != nil }, set: { sendsQuestion($0) }))
                                .toggleStyle(.appCheckbox)
                                .font(.system(size: 11.5))
                            Spacer(minLength: 0)
                            InlineLink(title: "Take out of review", size: 11.5, tint: Color.secondary, action: takeOut)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.35)))
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Suggests a change", systemImage: "pencil")
                            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                        ReviewText(text: suggestion, size: 12.5)
                        if let makeChange {
                            HStack(spacing: 10) {
                                ActionButton(title: "Make this a change", tone: .green, height: 26, size: 11.5,
                                             icon: "pencil", action: makeChange)
                                Text("Goes to \(agent.title) straight away")
                                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
            }
            .padding(.leading, 32)
        } else {
            Label("No change suggested. Nothing here will reach the chat.", systemImage: "checkmark")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .padding(.leading, 32)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            ActionButton(title: "Ask a follow-up", tone: .outlined, height: 26, size: 11.5) {
                asking = true
                fieldFocused = true
            }
            Spacer(minLength: 0)
            InlineLink(title: "Resolve", size: 11.5, tint: Color.secondary, action: resolve)
        }
        .padding(.leading, 48).padding(.trailing, 16).padding(.bottom, 14)
    }

    private var followUpBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Ask \(agent.title) a follow-up. The answer stays here.", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(2...8)
                .focused($fieldFocused)
                .onSubmit(send)
                .onExitCommand(perform: cancel)
                .accessibilityLabel("Follow-up question")
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    KeyCap(key: "⌘↩"); Text("ask")
                    KeyCap(key: "esc"); Text("cancel")
                }
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                InlineLink(title: "Cancel", size: 11.5, tint: Color.secondary, action: cancel)
                ActionButton(title: "Ask", tone: .plan, height: 26, size: 11.5, icon: "questionmark",
                             keyboardShortcut: KeyboardShortcut(.return, modifiers: .command), action: send)
                    .disabled(draft.isBlank)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.plan.opacity(0.5)))
        .padding(.leading, 48).padding(.trailing, 16).padding(.bottom, 14)
        .onAppear { fieldFocused = true }
    }

    private func send() {
        guard !draft.isBlank else { return }
        followUp(draft.trimmed)
        draft = ""
        asking = false
    }

    private func cancel() {
        draft = ""
        asking = false
    }
}

// MARK: - Reviewer lanes

// One reviewer's lane on a plan, an answer or a design: what it is reading and for how
// long while it works, and what it came to once it stops. A running lane names the model it runs on; a finished one drops
// that to save room and keeps it in the tooltip.
struct ReviewLane: View {
    typealias State = ReviewLaneState

    let reviewer: SecondOpinion.Reviewer
    let started: Date
    var ended: Date?
    var activity = ""
    let state: State
    let stop: () -> Void
    let retry: () -> Void
    var dismiss: (() -> Void)?
    // A lane in a narrow column takes the column's width and wraps a failure, where a lane in
    // a row keeps to one line at its own width.
    var fillsWidth = false

    init(reviewer: SecondOpinion.Reviewer, started: Date, ended: Date? = nil, activity: String,
         state: State, fillsWidth: Bool = false,
         stop: @escaping () -> Void, retry: @escaping () -> Void, dismiss: (() -> Void)? = nil) {
        self.reviewer = reviewer
        self.started = started
        self.ended = ended
        self.activity = activity
        self.state = state
        self.fillsWidth = fillsWidth
        self.stop = stop
        self.retry = retry
        self.dismiss = dismiss
    }

    private var name: String { reviewer.label() }

    var body: some View {
        Group {
            if fillsWidth, case .failed(let message) = state {
                failure(message)
            } else {
                line
                    .padding(.leading, 8).padding(.trailing, 4)
                    .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 30, maxHeight: 30, alignment: .leading)
            }
        }
        .font(.system(size: 11.5))
        .surface(fill, cornerRadius: 8, border: border)
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .appTooltip(name)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var line: some View {
        HStack(spacing: 7) {
            switch state {
            case .running:
                ProgressView().controlSize(.mini)
                Text(reviewer.agent.title).font(.system(size: 12, weight: .semibold)).fixedSize()
                if let seat = reviewer.seatLabel {
                    Text(seat)
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.sunken))
                        .fixedSize()
                }
                Text(activity).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: fillsWidth ? .infinity : 170, alignment: .leading)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.clock(from: started, to: context.date)).font(.mono(11)).foregroundStyle(.tertiary)
                }
                GlyphButton(icon: "stop.fill", side: 20, action: stop)
                    .appTooltip("Stop")
                    .accessibilityLabel("Stop \(name)")
            case .finished(let outcome):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.dotOn)
                Text(reviewer.agent.title).font(.system(size: 12, weight: .semibold)).fixedSize()
                Text(outcome + " · " + Self.clock(from: started, to: ended ?? Date()))
                    .foregroundStyle(.secondary).lineLimit(1)
                if fillsWidth { Spacer(minLength: 0) }
                if let dismiss { GlyphButton(icon: "xmark", side: 20, action: dismiss).accessibilityLabel("Hide") }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warningText)
                Text("\(reviewer.agent.title) could not finish").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.warningText).lineLimit(1)
                Text(message).foregroundStyle(Theme.warningText.opacity(0.8)).lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
                    .appTooltip(message)
                InlineLink(title: "Try again", tint: Theme.warningText, action: retry)
                if let dismiss { GlyphButton(icon: "xmark", side: 20, action: dismiss).accessibilityLabel("Hide") }
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("\(reviewer.agent.title) could not finish").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if let dismiss { GlyphButton(icon: "xmark", side: 20, action: dismiss).accessibilityLabel("Hide") }
            }
            Text(message).foregroundStyle(Theme.warningText.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            InlineLink(title: "Try again", tint: Theme.warningText, action: retry)
        }
        .foregroundStyle(Theme.warningText)
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fill: Color {
        switch state {
        case .running: Theme.field
        case .finished: Theme.dotOn.opacity(0.08)
        case .failed: Theme.warningBackground
        }
    }

    private var border: Color {
        switch state {
        case .failed: Theme.warningText.opacity(0.3)
        default: Theme.border
        }
    }

    private var spoken: String {
        switch state {
        case .running: "\(name) is reviewing. \(activity)"
        case .finished(let outcome): "\(name) finished. \(outcome)"
        case .failed(let message): "\(name) could not finish. \(message)"
        }
    }

    static func clock(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

// The small menu pill on a seat, for its model and its effort.
struct SeatPill<Content: View>: View {
    @ViewBuilder let content: Content

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            content
            MenuChevron(size: 7)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .lineLimit(1)
        .padding(.horizontal, 8).frame(height: 24)
        .background(Capsule().fill(hovering ? Theme.border : Theme.field))
        .contentShape(Capsule())
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

// The way into a second opinion on a plan or a design. It shows the usual reviewers'
// avatars, so the lineup the dialog will start from is visible before it opens.
struct SecondOpinionButton: View {
    let usual: [AgentKind]
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "person.2").font(.system(size: 11, weight: .semibold))
                Text("Second opinion").font(.system(size: 12, weight: .semibold))
                if !usual.isEmpty {
                    HStack(spacing: -5) {
                        ForEach(Array(usual.enumerated()), id: \.offset) { ReviewAvatar(agent: $0.element, size: 16) }
                    }
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.field : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .hoverLift(hovering)
        .onHover { hovering = $0 }
        .accessibilityLabel("Ask for a second opinion")
    }
}

// Three steps for how far a reviewer stands from the author, always beside words that
// say the same. A seat whose model is chosen for it shows dashed steps.
struct IndependenceMeter: View {
    let independence: SecondOpinion.Independence

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { step in
                if independence == .unknown {
                    Capsule().strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                        .frame(width: 10, height: 4)
                } else {
                    Capsule().fill(step < independence.steps ? tint : Theme.border)
                        .frame(width: 10, height: 4)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var tint: Color {
        switch independence {
        case .differentMaker: Theme.dotOn
        case .otherModel: Theme.dotOn.opacity(0.65)
        case .sameModel, .unknown: Theme.attention
        }
    }
}

// MARK: - Sending

// The send dialog's body: a checklist by file, a note for the round, and on request the
// exact words the agent will read. Anything unticked stays in the review.
struct SendReviewSheet: View {
    let agentTitle: String
    let comments: [ReviewComment]
    let pendingCount: Int
    let busy: Bool
    // Questions asked on the Changes screen whose answers do not go with this message.
    var questionsLeftOut = 0
    let fileName: (ReviewComment) -> String
    let prompt: ([ReviewComment], String) -> String
    let lookFirst: () -> Void
    let send: ([ReviewComment], String) -> Void

    @Environment(DialogPresenter.self) private var dialogs
    @State private var picked: Set<UUID>
    @State private var note = ""
    @State private var showsPrompt = false
    // The checklist is as tall as what it lists, up to a cap, rather than always the cap.
    @State private var listHeight: CGFloat = 120

    init(agentTitle: String, comments: [ReviewComment], pendingCount: Int, busy: Bool,
         questionsLeftOut: Int = 0, startsOnMessage: Bool = false,
         fileName: @escaping (ReviewComment) -> String,
         prompt: @escaping ([ReviewComment], String) -> String,
         lookFirst: @escaping () -> Void, send: @escaping ([ReviewComment], String) -> Void) {
        self.agentTitle = agentTitle
        self.comments = comments
        self.pendingCount = pendingCount
        self.busy = busy
        self.questionsLeftOut = questionsLeftOut
        self.fileName = fileName
        self.prompt = prompt
        self.lookFirst = lookFirst
        self.send = send
        _picked = State(initialValue: Set(comments.map(\.id)))
        _showsPrompt = State(initialValue: startsOnMessage)
    }

    private var chosen: [ReviewComment] { comments.filter { picked.contains($0.id) } }

    private var groups: [(file: String, comments: [ReviewComment])] {
        var result: [(file: String, comments: [ReviewComment])] = []
        for comment in comments {
            let key = ReviewRound.fileKey(root: comment.root, path: comment.path)
            if let index = result.firstIndex(where: { $0.file == key }) {
                result[index].comments.append(comment)
            } else {
                result.append((key, [comment]))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if pendingCount > 0 {
                callout(icon: "exclamationmark.triangle.fill", tint: Theme.attentionText, fill: Theme.attention.opacity(0.12),
                        bold: "\(counted(pendingCount, "finding")) still to look at.",
                        text: (pendingCount == 1 ? "It is" : "They are") + " not part of this review and will wait here.") {
                    InlineLink(title: "Look first", tint: Theme.attentionText) {
                        dialogs.dismiss()
                        lookFirst()
                    }
                }
            }
            if busy {
                callout(icon: "clock", tint: Theme.plan, fill: Theme.plan.opacity(0.1),
                        bold: "\(agentTitle) is in the middle of a turn.",
                        text: "Your review goes in as soon as it ends, so nothing it is doing now is interrupted.") {
                    EmptyView()
                }
            }
            HStack(spacing: 4) {
                ChoicePill(title: "Comments \(chosen.count)", selected: !showsPrompt) { showsPrompt = false }
                ChoicePill(title: "What \(agentTitle) reads", selected: showsPrompt) { showsPrompt = true }
                Spacer(minLength: 0)
                if !showsPrompt {
                    InlineLink(title: picked.count == comments.count ? "Untick all" : "Tick all", tint: Color.secondary) {
                        picked = picked.count == comments.count ? [] : Set(comments.map(\.id))
                    }
                }
            }
            ScrollView {
                if showsPrompt {
                    Text(chosen.isEmpty ? "Tick at least one comment to send." : prompt(chosen, note))
                        .font(.mono(11))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(groups, id: \.file) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text(fileName(group.comments[0])).font(.system(size: 12, weight: .semibold))
                                    Text(counted(group.comments.count, "comment"))
                                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                                }
                                ForEach(group.comments) { comment in row(comment) }
                            }
                        }
                    }
                    .padding(12)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
                }
            }
            .frame(height: min(300, listHeight))
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            if questionsLeftOut > 0 {
                Label(questionsLeftOut == 1 ? "Your question and its answer are left out. They stay in Changes."
                      : "Your \(questionsLeftOut) questions and their answers are left out. They stay in Changes.",
                      systemImage: "eye.slash")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.plan)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Anything else for this round?").font(.system(size: 12, weight: .semibold))
                TextField("For example: run the tests when you are done", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                    .appTextField()
            }
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                Button { dialogs.dismiss() } label: {
                    Text("Cancel").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                ActionButton(title: "\(busy ? "Queue" : "Send") \(counted(chosen.count, "comment"))",
                             tone: .green, height: 32, size: 12.5, icon: "paperplane.fill",
                             keyboardShortcut: .defaultAction) {
                    let list = chosen
                    let words = note
                    dialogs.dismiss()
                    send(list, words)
                }
                .disabled(chosen.isEmpty)
            }
            .padding(.top, 4)
        }
    }

    private func row(_ comment: ReviewComment) -> some View {
        Toggle(isOn: Binding(get: { picked.contains(comment.id) },
                             set: { on in if on { picked.insert(comment.id) } else { picked.remove(comment.id) } })) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ReviewAvatars(comment: comment, size: 16)
                    Text(comment.authorName).font(.system(size: 11.5, weight: .semibold))
                    Text(comment.linesLabel).font(.mono(10.5)).foregroundStyle(.secondary)
                    if comment.kind == .question { QuestionTag() }
                    if let severity = comment.severity { SeverityChip(severity: severity) }
                }
                ReviewText(text: comment.body, size: 12, lineLimit: 3)
            }
            .padding(.top, -2)
        }
        .toggleStyle(.appCheckbox)
        .accessibilityLabel(comment.spokenName + ". " + comment.body)
    }

    private func callout<Action: View>(icon: String, tint: Color, fill: Color, bold: String, text: String,
                                       @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            (Text(bold).fontWeight(.semibold) + Text(" " + text))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            action()
        }
        .foregroundStyle(tint)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(fill))
    }
}

// MARK: - Toast

// A short word about what just happened, with the one thing worth doing next. It is read
// out as well, since it goes away on its own.
struct ReviewToast: Identifiable {
    let id = UUID()
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
}

struct ReviewToastView: View {
    let toast: ReviewToast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(toast.text).font(.system(size: 12.5)).foregroundStyle(.primary).lineLimit(2)
            if let title = toast.actionTitle, let action = toast.action {
                InlineLink(title: title) {
                    dismiss()
                    action()
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .floatingCard(cornerRadius: 10)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Threads

// Where a sent comment stands, in a word and an icon so it never rests on colour.
struct ReviewStatusChip: View {
    let status: ReviewRound.Status
    var label: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(label ?? status.label).lineLimit(1).fixedSize()
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(ink)
        .padding(.horizontal, status == .resolved ? 0 : 8).padding(.vertical, 3)
        .background(Capsule().fill(fill))
    }

    private var icon: String {
        switch status {
        case .waiting: "clock"
        case .answered: "bubble.left"
        case .changed, .resolved: "checkmark"
        case .unchanged: "minus"
        }
    }

    private var ink: Color {
        switch status {
        case .waiting: Color.secondary
        case .answered: Theme.plan
        case .changed: Theme.dotOnText
        case .unchanged: Theme.attentionText
        case .resolved: Color.secondary.opacity(0.7)
        }
    }

    private var fill: Color {
        switch status {
        case .waiting: Theme.field
        case .answered: Theme.plan.opacity(0.12)
        case .changed: Theme.dotOn.opacity(0.14)
        case .unchanged: Theme.attention.opacity(0.14)
        case .resolved: .clear
        }
    }
}

// A sent comment as a thread: its file and lines, the code it quotes, the comment, the
// agent's answer and every reply after. Chat and Changes draw the same one, so a thread
// reads the same wherever it is opened.
struct ReviewThreadView: View {
    let round: ReviewRound
    let comment: ReviewComment
    let agent: AgentKind
    let fileName: String
    // The turn that took the review is still running, so no answer is in yet.
    var working = false
    // Changes draws the thread right under its lines, which already show the code.
    var showsQuote = true
    var focused = false
    var projectPath = ""
    var textScale: CGFloat = 1
    let reply: (String) -> Void
    let resolve: () -> Void
    let reopen: () -> Void
    var showInDiff: (() -> Void)?

    @State private var replying = false
    @State private var draft = ""
    @State private var showsAllLines = false
    @FocusState private var fieldFocused: Bool

    private var status: ReviewRound.Status {
        working && !round.isSettled && !round.resolved.contains(comment.id) ? .waiting : round.status(comment.id)
    }

    private var replies: [ReviewReply] { round.replies(comment.id) }

    private var lines: String {
        comment.onFile ? "" : comment.lastLine.map { "\(comment.line)–\($0)" } ?? "\(comment.line)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            if status != .resolved {
                if showsQuote, !comment.excerpt.isBlank { quote.padding(.horizontal, 16).padding(.top, 8) }
                VStack(alignment: .leading, spacing: 12) {
                    message(agent: nil, when: nil) {
                        ReviewText(text: comment.body, size: 13)
                    }
                    if replies.first?.author != .agent { firstAnswer }
                    ForEach(replies) { reply in
                        if reply.author == .you {
                            message(agent: nil, when: Text(reply.sent, format: .relative(presentation: .named))) {
                                ReviewText(text: reply.body, size: 13)
                            }
                        } else {
                            agentReply(reply)
                        }
                    }
                    if round.isAwaitingReply(comment.id) {
                        message(agent: agent, when: Text("replying")) {
                            ProgressView().controlSize(.small).padding(.vertical, 2)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 14)
                if replying { replyBox }
                if status != .waiting { actions }
            }
        }
        .background(focused ? Theme.accent.opacity(0.05) : .clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.spokenName(status: status, comment: comment, fileName: fileName,
                                            unread: round.unread.contains(comment.id)))
    }

    static func spokenName(status: ReviewRound.Status, comment: ReviewComment, fileName: String, unread: Bool) -> String {
        let place = comment.onFile ? "\(fileName), whole file"
            : comment.lastLine.map { "\(fileName) lines \(comment.line) to \($0)" } ?? "\(fileName) line \(comment.line)"
        return "\(status.label), \(place), \(comment.body)" + (unread ? ", new reply" : "")
    }

    private var bar: some View {
        HStack(spacing: 10) {
            (Text(fileName).foregroundStyle(.primary).fontWeight(.medium) + Text(lines.isEmpty ? "" : " " + lines))
                .font(.mono(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if status == .resolved {
                ReviewText(text: comment.body, size: 12, lineLimit: 1)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420, alignment: .leading)
            }
            Spacer(minLength: 0)
            ReviewStatusChip(status: status)
            if status == .resolved {
                InlineLink(title: "Reopen", size: 11.5, tint: Color.secondary, action: reopen)
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, status == .resolved ? 12 : 0)
    }

    // The quoted code: three lines, with the rest a click away.
    private var quote: some View {
        let code = comment.excerpt.components(separatedBy: "\n")
        let offsets = comment.excerptOffsets ?? Array(code.indices)
        let numbered = zip(offsets, code).map { (number: comment.line + $0, code: $1) }
        let shown = showsAllLines ? numbered : Array(numbered.prefix(3))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown, id: \.number) { line in
                codeLine(number: line.number, text: line.code, ink: .secondary,
                         numberInk: Theme.attentionText, fill: Theme.brand.opacity(0.22))
            }
            if numbered.count > shown.count {
                Button { showsAllLines = true } label: {
                    Text("Show all \(numbered.count) lines")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .padding(.leading, 52).padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            }
        }
        .codeBox()
    }

    private func codeLine(number: Int, text: String, ink: Color, numberInk: Color, fill: Color) -> some View {
        HStack(spacing: 12) {
            Text("\(number)").foregroundStyle(numberInk).frame(width: 28, alignment: .trailing)
            Text(text).foregroundStyle(ink).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.mono(11))
        .padding(.vertical, 1.5)
        .padding(.trailing, 12)
        .background(fill)
    }

    // The agent's first word on the comment, or where it will go while the turn runs.
    @ViewBuilder private var firstAnswer: some View {
        if !round.isSettled {
            message(agent: agent, when: Text("working on it")) {
                VStack(alignment: .leading, spacing: 7) {
                    RoundedRectangle(cornerRadius: 5).fill(Theme.field).frame(width: 280, height: 9)
                    RoundedRectangle(cornerRadius: 5).fill(Theme.field).frame(width: 190, height: 9)
                }
                .padding(.top, 4)
                .accessibilityLabel("\(agent.title) is working on it")
            }
        } else {
            message(agent: agent, when: Text(firstWhen(changedFile: round.outcomes?[comment.id] == .changed))) {
                Text("No answer of its own. What \(agent.title) said is in the conversation.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        }
    }

    private func firstWhen(changedFile: Bool) -> String {
        switch round.outcomes?[comment.id] {
        case .answered: changedFile ? "answered · changed the file" : "answered · no files changed"
        case .changed: "changed the file"
        case .unchanged: "left it as it is"
        case nil: "answered"
        }
    }

    private func agentReply(_ reply: ReviewReply) -> some View {
        let first = replies.first?.id == reply.id
        let when = first ? firstWhen(changedFile: reply.changedFile) : reply.changedFile ? "changed the file" : "replied"
        return message(agent: agent, when: Text(when)) {
            VStack(alignment: .leading, spacing: 8) {
                if !reply.body.isBlank {
                    MarkdownProse(text: reply.body, projectPath: projectPath, textScale: textScale) { segment in
                        MarkdownCodeBlock(segment: segment).equatable()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !reply.diff.isEmpty { diff(reply.diff) }
            }
        }
    }

    private func diff(_ lines: [ReviewDiffLine]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text((comment.path as NSString).lastPathComponent)
                Text("+\(lines.count { $0.kind == .addition })").font(.mono(11)).foregroundStyle(Theme.addition)
                Text("−\(lines.count { $0.kind == .deletion })").font(.mono(11)).foregroundStyle(Theme.deletion)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let added = line.kind == .addition
                codeLine(number: line.number, text: (added ? "+ " : "- ") + line.text,
                         ink: added ? Theme.addition : Theme.deletion, numberInk: Color.secondary.opacity(0.6),
                         fill: (added ? Theme.addition : Theme.deletion).opacity(0.08))
            }
        }
        .codeBox()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Changed lines")
    }

    // One voice in the thread: you, or the agent when one is given.
    private func message<Content: View>(agent: AgentKind?, when: Text?,
                                        @ViewBuilder content: () -> Content) -> some View {
        let isYou = agent == nil
        return HStack(alignment: .top, spacing: 10) {
            ReviewAvatar(agent: agent, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(isYou ? "You" : agent?.title ?? "").font(.system(size: 12, weight: .semibold))
                    if isYou, when == nil {
                        if comment.kind == .question {
                            QuestionTag()
                        } else {
                            Text("Change")
                                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.accent.opacity(0.09)))
                                .fixedSize()
                        }
                    }
                    if let when { when.font(.system(size: 11)).foregroundStyle(.tertiary) }
                }
                .frame(minHeight: 22)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var suggestion: String? {
        guard let last = replies.last, last.author == .agent else { return nil }
        return last.suggestion
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let suggestion, !replying {
                Button { reply(suggestion) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        Text(suggestion).lineLimit(1)
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.plan)
                    .padding(.horizontal, 11).frame(height: 26)
                    .background(Capsule().fill(Theme.card))
                    .overlay(Capsule().strokeBorder(Theme.plan.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .appTooltip("Send this reply")
                .accessibilityLabel("Suggested reply: \(suggestion)")
            }
            if !replying {
                ActionButton(title: "Reply", tone: .outlined, height: 26, size: 11.5) {
                    replying = true
                    fieldFocused = true
                }
            }
            if let showInDiff {
                InlineLink(title: "Show in diff", size: 11.5, tint: Color.secondary, action: showInDiff)
            }
            Spacer(minLength: 0)
            InlineLink(title: "Resolve", size: 11.5, tint: Color.secondary, action: resolve)
        }
        .padding(.leading, 48).padding(.trailing, 16).padding(.bottom, 14)
    }

    private var replyBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Reply to \(agent.title) about these lines", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(2...8)
                .focused($fieldFocused)
                .onSubmit(send)
                .onExitCommand(perform: cancel)
                .accessibilityLabel("Reply to \(agent.title)")
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    KeyCap(key: "↩"); Text("send")
                    KeyCap(key: "esc"); Text("cancel")
                }
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                InlineLink(title: "Cancel", size: 11.5, tint: Color.secondary, action: cancel)
                ActionButton(title: "Send reply", tone: .green, height: 26, size: 11.5, action: send)
                    .disabled(draft.isBlank)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.5)))
        .padding(.leading, 48).padding(.trailing, 16).padding(.bottom, 14)
        .onAppear { fieldFocused = true }
    }

    private func send() {
        guard !draft.isBlank else { return }
        reply(draft.trimmed)
        draft = ""
        replying = false
    }

    private func cancel() {
        draft = ""
        replying = false
    }
}

private extension View {
    func codeBox() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 8))
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sunken))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
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
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            footer
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .cardSurface(cornerRadius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your review, \(counted(round.comments.count, "comment"))")
    }

    private var header: some View {
        HStack(spacing: 10) {
            ReviewAvatar(agent: nil, size: 22)
            Text("Your review").font(.serif(15, .semibold))
            subtitle.font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            tally
            InlineLink(title: "Open in Changes", size: 11.5, action: openInChanges)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
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
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("\(agent.title) is working through it")
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Theme.field))
        } else {
            HStack(spacing: 6) {
                ForEach([ReviewRound.Status.changed, .answered, .unchanged, .waiting], id: \.label) { status in
                    let count = round.comments.count { round.status($0.id) == status }
                    if count > 0 { ReviewStatusChip(status: status, label: "\(count) " + status.label.lowercased()) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            ActionButton(title: "Review what changed", tone: .green, height: 30, size: 12,
                         icon: "plusminus", action: reviewWhatChanged)
            if let checker {
                ActionButton(title: "Ask \(checker.title) to check the fixes", tone: .outlined, height: 30,
                             size: 12, icon: "person.2", action: checkFixes)
                    .disabled(round.trees.isEmpty)
            }
            Spacer(minLength: 0)
            if let checker {
                Text("\(checker.title) reads only what changed since you sent the review")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(settling)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.sunken)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
