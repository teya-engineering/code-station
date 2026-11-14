import AppKit
import SwiftUI

// The pieces a review is drawn with, shared by both diff layouts, the review list, the
// send dialog and the cards in Chat, so a comment looks the same wherever it turns up.

// Who left a comment: you, or the reviewer's mark on a quiet tile.
struct ReviewAvatar: View {
    // Nil for you.
    let agent: AgentKind?
    var size: CGFloat = 20
    // Amber while the reviewer has findings waiting to be looked at.
    var hasFindings = false
    // Counts up each time the reviewer's symbol should play its own move.
    var move = 0

    var body: some View {
        Image(systemName: agent?.symbol ?? "person.fill")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(hasFindings ? Theme.attentionText : agent == nil ? Theme.accent : Color.secondary)
            .modifier(SymbolMove(agent: agent, size: size, trigger: move))
            .frame(width: size, height: size)
            // A symbol that flies out of its tile leaves through the edge, not over its neighbour.
            .clipped()
            .background(RoundedRectangle(cornerRadius: size * 0.3)
                .fill(hasFindings ? Theme.attention.opacity(0.16) : agent == nil ? Theme.userMessage : Theme.field))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3).stroke(hasFindings ? Theme.attention : Theme.border))
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
        HStack(spacing: Space.xs) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(count.map { "\($0) \(severity.label.lowercased())" } ?? severity.label).font(Typography.caption.weight(.semibold)).lineLimit(1).fixedSize()
        }
        .foregroundStyle(ink)
        .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs)
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
            .font(Typography.caption.weight(.semibold))
            .foregroundStyle(Theme.plan)
            .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs)
            .background(Capsule().fill(Theme.plan.opacity(0.12)))
            .fixedSize()
    }
}

// A key drawn as a cap, for the hints that teach the keyboard.
struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(Typography.caps)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Space.xs).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: Radius.tag).stroke(Theme.border))
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

// The strip over a comment that says where it goes: blue for a question that stays on
// this screen, green for a change that goes to the agent. Always in words as well.
struct RouteBand: View {
    let place: String
    let stays: Bool
    let agentTitle: String

    var body: some View {
        HStack(spacing: Space.md) {
            Text(place).font(Typography.data).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Label(stays ? "Only in Changes" : "Goes to \(agentTitle)", systemImage: stays ? "eye.slash" : "paperplane")
                .font(Typography.label)
                .foregroundStyle(stays ? Theme.plan : Theme.accent)
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
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
        ReviewAvatar(agent: agent, size: size - 6)
            .frame(width: size, height: size)
            .overlay {
                Group {
                    if answering && !reduceMotion {
                        MarchingRing(colour: Theme.plan.opacity(0.75))
                    } else {
                        Circle().strokeBorder(Theme.plan.opacity(0.75),
                                              style: StrokeStyle(lineWidth: MarchingRingView.lineWidth,
                                                                 dash: MarchingRingView.dash))
                    }
                }
                .padding(-2)
            }
            .accessibilityHidden(true)
    }
}

private struct MarchingRing: NSViewRepresentable {
    let colour: Color

    func makeNSView(context: Context) -> MarchingRingView { MarchingRingView() }

    func updateNSView(_ view: MarchingRingView, context: Context) {
        view.update(colour: colour.resolve(in: context.environment).cgColor)
    }
}

// The dashed ring, turning: its dashes travel two whole patterns round the circle each
// period.
final class MarchingRingView: LoopLayerView {
    static let lineWidth: CGFloat = 1.2
    static let dash: [CGFloat] = [2.5, 2]
    static let period: CFTimeInterval = 1.2

    private let ring = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        ring.fillColor = nil
        ring.lineWidth = Self.lineWidth
        ring.lineDashPattern = Self.dash.map { NSNumber(value: Double($0)) }
        layer?.addSublayer(ring)
    }

    var loops: [String] { ring.animationKeys() ?? [] }

    func update(colour: CGColor) {
        LayerLoop.still { ring.strokeColor = colour }
    }

    // Inset by half the line, so the stroke sits inside the frame the way a SwiftUI
    // stroked border does.
    override func layoutLayers() {
        ring.frame = bounds
        let inset = Self.lineWidth / 2
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
    }

    override func restartLoops() {
        ring.removeAnimation(forKey: "march")
        let march = CABasicAnimation(keyPath: "lineDashPhase")
        march.fromValue = 0
        march.toValue = -2 * Self.dash.reduce(0, +)
        march.duration = Self.period
        ring.add(LayerLoop.repeating(march, period: Self.period), forKey: "march")
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
    var stop: () -> Void = {}
    var askAgain: () -> Void = {}
    // Nil where there are no lines to hang a change from: a question on the whole change.
    var makeChange: (() -> Void)?
    var takeOut: () -> Void = {}
    var editChange: (String) -> Void = { _ in }
    var sendsQuestion: (Bool) -> Void = { _ in }
    // Set where the follow-up is typed in a field of the host's own, rather than in a box
    // under the thread.
    var startFollowUp: (() -> Void)?
    // Set where a stopped question can go back to that field to be asked in other words.
    var editQuestion: (() -> Void)?
    // The changed files an answer points at, each drawn as a chip that opens it.
    var references: (String) -> [AnswerReference] = { _ in [] }
    var showReference: (ChangeCitation) -> Void = { _ in }
    var hoverReference: (ChangeCitation?) -> Void = { _ in }

    @State private var asking = false
    @State private var copied = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    @AccessibilityFocusState private var askAgainFocused: Bool

    private var agent: AgentKind { question.agent }

    var body: some View {
        Group {
            if question.resolved && question.status == .answered {
                collapsed.transition(.fadeIn)
            } else {
                full.transition(.fadeIn)
            }
        }
        // Keyed on resolved alone, which only the person changes. An answer landing from
        // the side copy does not move the thread.
        .smoothlyResizes(when: question.resolved)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question.spokenName)
        .onChange(of: question.status) { _, status in
            if status == .stopped { askAgainFocused = true }
        }
    }

    private var collapsed: some View {
        Button(action: reopen) {
            HStack(spacing: Space.md) {
                Image(systemName: "questionmark.circle").foregroundStyle(Theme.plan)
                (Text(question.text).fontWeight(.medium)
                 + Text(ReviewText.attributed(" - " + (question.exchanges.last?.answer ?? ""))).foregroundStyle(.secondary))
                    .font(Typography.detail).lineLimit(1)
                Spacer(minLength: 8)
                ReviewStatusChip(status: .answered)
            }
            .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 0)
        .accessibilityHint("Opens the question again")
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsBand { RouteBand(place: place, stays: true, agentTitle: agent.title) }
            VStack(alignment: .leading, spacing: Space.lg) {
                ForEach(question.exchanges) { exchange in
                    you(exchange.question, first: exchange.id == question.exchanges.first?.id)
                    if let answer = exchange.answer {
                        sideCopy(meta: meta(exchange)) {
                            VStack(alignment: .leading, spacing: Space.md) {
                                MarkdownProse(text: answer, projectPath: projectPath, textScale: textScale) { segment in
                                    MarkdownCodeBlock(segment: segment).equatable()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                referenceChips(references(answer))
                            }
                        }
                    } else if let failure = exchange.failure {
                        failed(failure)
                    } else if let stoppedAt = exchange.stopped {
                        stopped(exchange.stoppedSteps ?? [], at: stoppedAt)
                    } else {
                        answering
                    }
                }
                if question.status == .answered { outcome }
            }
            .padding(.horizontal, Space.xl).padding(.top, Space.lg).padding(.bottom, Space.lg)
            if asking { followUpBox }
            if question.status == .answered, !asking { actions }
        }
    }

    private func meta(_ exchange: ReviewQuestion.Exchange) -> String {
        let time = (exchange.answered ?? exchange.asked).formatted(date: .omitted, time: .shortened)
        return "side copy · \(time) · changed nothing"
    }

    private func you(_ text: String, first: Bool) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            ReviewAvatar(agent: nil, size: 22)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.sm) {
                    Text("You").font(Typography.label)
                    if first { QuestionTag() }
                }
                .frame(minHeight: 22)
                ReviewText(text: text, size: 13)
            }
        }
    }

    private func sideCopy<Content: View>(meta: String, answering: Bool = false,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            SideCopyAvatar(agent: agent, answering: answering)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.sm) {
                    Text(agent.title).font(Typography.label)
                    Text(meta).font(Typography.caption).foregroundStyle(.tertiary)
                    if answering {
                        Spacer(minLength: 8)
                        StopAnsweringButton(showsTitle: true, action: stop)
                    }
                }
                .frame(minHeight: 22)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var answering: some View {
        sideCopy(meta: "side copy · answering", answering: true) {
            VStack(alignment: .leading, spacing: Space.xs) {
                let shown = steps.isEmpty ? ["Starting"] : steps
                ForEach(Array(shown.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: Space.sm) {
                        if index == shown.count - 1 {
                            LoopSpinner(size: 10).frame(width: 12)
                        } else {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.dotOn).frame(width: 12)
                        }
                        Text(index == shown.count - 1 ? step : WholeChangeThreads.finishedStep(step))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .transition(.fadeIn)
                }
            }
            .font(Typography.detail).foregroundStyle(.secondary)
            .padding(.top, Space.xxs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(agent.title) is answering. " + (steps.last ?? ""))
        }
    }

    // The steps it had finished keep their tick and the one it was on is marked as where it
    // stopped. Nothing is struck through: stopping is the person's choice, not a failure.
    private func stopped(_ reached: [String], at time: Date) -> some View {
        sideCopy(meta: "side copy · stopped at " + time.formatted(date: .omitted, time: .shortened)) {
            VStack(alignment: .leading, spacing: Space.md) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    let shown = reached.isEmpty ? ["Starting"] : reached
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, step in
                        HStack(spacing: Space.sm) {
                            if index == shown.count - 1 {
                                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary)
                                    .frame(width: 7, height: 7).frame(width: 12)
                                Text(step).lineLimit(1).truncationMode(.middle)
                                Text("Stopped here")
                                    .font(Typography.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, Space.sm).padding(.vertical, 1.5)
                                    .background(Capsule().fill(Theme.sunken))
                                    .fixedSize()
                            } else {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.dotOn).frame(width: 12)
                                Text(WholeChangeThreads.finishedStep(step)).foregroundStyle(Color.primary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                .font(Typography.detail).foregroundStyle(.secondary)
                .padding(.top, Space.xxs)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Stopped at: " + (reached.last ?? "Starting"))
                VStack(alignment: .leading, spacing: Space.md) {
                    (Text("You stopped this answer. ").fontWeight(.semibold).foregroundStyle(Color.primary)
                     + Text("Nothing in the session or the review changed."))
                        .font(Typography.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: Space.md) {
                        ActionButton(title: "Ask again", tone: .plan, height: ControlHeight.sm, size: Typography.Size.detail,
                                     icon: "arrow.clockwise", action: askAgain)
                            .accessibilityFocused($askAgainFocused)
                        if let editQuestion {
                            ActionButton(title: "Edit question", tone: .outlined, height: ControlHeight.sm, size: Typography.Size.detail,
                                         icon: "pencil", action: editQuestion)
                        }
                        Spacer(minLength: 0)
                        QuietRemoveLink(action: delete)
                    }
                }
                .padding(Space.md)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.border))
            }
        }
    }

    private func failed(_ reason: String) -> some View {
        sideCopy(meta: "side copy") {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .top, spacing: Space.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    (Text("Couldn't answer. ").fontWeight(.semibold) + Text(reason))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Typography.detail).foregroundStyle(Theme.warningText)
                HStack(spacing: Space.lg) {
                    ActionButton(title: "Try again", tone: .outlined, height: ControlHeight.sm, size: Typography.Size.detail,
                                 icon: "arrow.clockwise", action: retry)
                    Spacer(minLength: 0)
                    QuietRemoveLink(action: delete)
                }
            }
            .padding(Space.md)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.warningBackground))
        }
    }

    // What the answer leads to: a change to make, one already in the review or sent, or
    // nothing at all.
    @ViewBuilder private var outcome: some View {
        if let suggestion = question.suggestion {
            Group {
                if let change, let changeSent {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Label("Sent to \(agent.title) at " + changeSent.formatted(date: .omitted, time: .shortened),
                              systemImage: "checkmark")
                            .font(Typography.label).foregroundStyle(Theme.accent)
                        ReviewText(text: change.body, size: 12.5).foregroundStyle(.secondary)
                    }
                    .padding(Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.field))
                } else if let change {
                    VStack(alignment: .leading, spacing: Space.md) {
                        Label("Change for \(agent.title) · in your review", systemImage: "pencil")
                            .font(Typography.label).foregroundStyle(Theme.accent)
                        TextField("What should \(agent.title) change?",
                                  text: Binding(get: { change.body }, set: { editChange($0) }), axis: .vertical)
                            .lineLimit(1...6)
                            .appTextField()
                            .accessibilityLabel("Change for \(agent.title)")
                        HStack(spacing: Space.lg) {
                            Toggle("Also send the question and answer",
                                   isOn: Binding(get: { change.why != nil }, set: { sendsQuestion($0) }))
                                .toggleStyle(.appCheckbox)
                                .font(Typography.detail)
                            Spacer(minLength: 0)
                            InlineLink(title: "Take out of review", size: Typography.Size.detail, tint: Color.secondary, action: takeOut)
                        }
                    }
                    .padding(Space.md)
                    .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.accent.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.accent.opacity(0.35)))
                } else {
                    VStack(alignment: .leading, spacing: Space.md) {
                        Label("Suggests a change", systemImage: "pencil")
                            .font(Typography.label).foregroundStyle(.secondary)
                        ReviewText(text: suggestion, size: 12.5)
                        if let makeChange {
                            HStack(spacing: Space.md) {
                                ActionButton(title: "Make this a change", tone: .green, height: ControlHeight.sm, size: Typography.Size.detail,
                                             icon: "pencil", action: makeChange)
                                Text("Goes to \(agent.title) straight away")
                                    .font(Typography.caption).foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(Space.md)
                    .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
            }
            .padding(.leading, 32)
        } else {
            Label("No change suggested. Nothing here will reach the chat.", systemImage: "checkmark")
                .font(Typography.detail).foregroundStyle(.secondary)
                .padding(.leading, 32)
        }
    }

    private var actions: some View {
        HStack(spacing: Space.md) {
            ActionButton(title: "Ask a follow-up", tone: .outlined, height: ControlHeight.sm, size: Typography.Size.detail) {
                if let startFollowUp {
                    startFollowUp()
                } else {
                    asking = true
                    fieldFocused = true
                }
            }
            Spacer(minLength: 0)
            InlineLink(title: "Resolve", size: Typography.Size.detail, tint: Color.secondary, action: resolve)
            GlyphButton(icon: copied ? "checkmark" : "doc.on.doc", side: ControlHeight.sm, tint: copied ? Theme.dotOn : nil,
                        action: copyAnswer)
                .appTooltip("Copy the answer")
                .accessibilityLabel(copied ? "Copied" : "Copy the answer")
        }
        .padding(.leading, 48).padding(.trailing, Space.xl).padding(.bottom, Space.lg)
    }

    private func copyAnswer() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(question.exchanges.compactMap(\.answer).last ?? "", forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }

    // Each reference drawn as its own chip. The prose is a text view, which cannot hold
    // a button among its words, so the chips sit in a row under it.
    @ViewBuilder private func referenceChips(_ found: [AnswerReference]) -> some View {
        if !found.isEmpty {
            FlowRow(spacing: Space.sm) {
                ForEach(Array(found.enumerated()), id: \.offset) { _, reference in
                    AnswerReferenceChip(reference: reference,
                                        show: { showReference(reference.citation) },
                                        hover: { hoverReference($0 ? reference.citation : nil) })
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Files the answer points at")
        }
    }


    private var followUpBox: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            TextField("Ask \(agent.title) a follow-up. The answer stays here.", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .lineLimit(2...8)
                .focused($fieldFocused)
                .onSubmit(send)
                .onExitCommand(perform: cancel)
                .accessibilityLabel("Follow-up question")
            HStack(spacing: Space.md) {
                HStack(spacing: Space.xs) {
                    KeyCap(key: "⌘↩"); Text("ask")
                    KeyCap(key: "esc"); Text("cancel")
                }
                .font(Typography.caption).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                InlineLink(title: "Cancel", size: Typography.Size.detail, tint: Color.secondary, action: cancel)
                ActionButton(title: "Ask", tone: .plan, height: ControlHeight.sm, size: Typography.Size.detail, icon: "questionmark",
                             keyboardShortcut: KeyboardShortcut(.return, modifiers: .command), action: send)
                    .disabled(draft.isBlank)
            }
        }
        .padding(.horizontal, Space.md).padding(.vertical, Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(Theme.plan.opacity(0.5)))
        .padding(.leading, 48).padding(.trailing, Space.xl).padding(.bottom, Space.lg)
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

// A changed file an answer names, with the colour of the project it belongs to.
struct AnswerReference {
    let citation: ChangeCitation
    let tint: Theme.ProjectTint
}

// A file an answer names, as a chip: the project's colour, the file and its lines. A click
// opens the file under the card with the lines marked.
struct AnswerReferenceChip: View {
    let reference: AnswerReference
    let show: () -> Void
    let hover: (Bool) -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: show) {
            HStack(spacing: Space.xs) {
                ProjectDot(tint: reference.tint, size: 7)
                (Text(reference.citation.fileName).foregroundStyle(Color.primary)
                 + Text(reference.citation.linesSuffix).foregroundStyle(.secondary))
                    .font(Typography.data).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, Space.sm).frame(height: 22)
            .surface(hovering ? Theme.plan.opacity(0.10) : Theme.sunken, cornerRadius: Radius.inset,
                     border: hovering ? Theme.plan.opacity(0.4) : Theme.border)
            .contentShape(RoundedRectangle(cornerRadius: Radius.inset))
        }
        .buttonStyle(.plain)
        .hoverLift(hovering, amount: Motion.smallLift)
        .motion(Motion.hover, value: hovering)
        .onPointerHover { on in
            hovering = on
            hover(on)
        }
        .onDisappear { if hovering { hover(false) } }
        .appTooltip("Show in the diff")
        .accessibilityLabel(reference.citation.spokenName)
    }
}

// Remove, said quietly: grey words that turn red under the pointer, for a removal that an
// undo can take back.
struct QuietRemoveLink: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Remove")
                .font(Typography.label)
                .foregroundStyle(hovering ? Theme.deletion : Color.secondary)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .motion(Motion.hover, value: hovering)
        .onPointerHover { hovering = $0 }
    }
}

// Stops a side copy while it answers. The full pill carries the Esc cap; the square one
// fits beside a chip in a list.
struct StopAnsweringButton: View {
    var showsTitle = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                RoundedRectangle(cornerRadius: 2).frame(width: 8, height: 8)
                if showsTitle {
                    Text("Stop").font(Typography.label).fixedSize()
                    KeyCap(key: "esc")
                }
            }
            .foregroundStyle(hovering ? Theme.warningText : Color.primary)
            .padding(.horizontal, showsTitle ? 9 : 0)
            .frame(width: showsTitle ? nil : 22, height: showsTitle ? 24 : 22)
            .surface(hovering ? Theme.warningBackground : Theme.card, cornerRadius: Radius.inset,
                     border: hovering ? Theme.warningText.opacity(0.3) : Theme.border)
            .contentShape(RoundedRectangle(cornerRadius: Radius.inset))
        }
        .buttonStyle(.plain)
        .hoverLift(hovering, amount: Motion.smallLift)
        .motion(Motion.hover, value: hovering)
        .onPointerHover { hovering = $0 }
        .appTooltip("Stop answering  esc")
        .accessibilityLabel("Stop answering")
    }
}

// MARK: - Reviewer lanes

// One reviewer's lane on a plan, an answer or a design: what it is reading and for how
// long while it works, and what it came to once it stops. A running lane names the model it runs on; a finished one drops
// that to save room and keeps it in the tooltip.
struct ReviewLane: View {
    enum State: Equatable {
        case running
        case finished(String)
        case failed(String)
    }

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
                    .padding(.leading, Space.md).padding(.trailing, Space.xs)
                    .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 30, maxHeight: 30, alignment: .leading)
            }
        }
        .font(Typography.detail)
        .surface(fill, cornerRadius: Radius.control, border: border)
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .appTooltip(name)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var line: some View {
        HStack(spacing: Space.sm) {
            switch state {
            case .running:
                LoopSpinner(size: 10)
                Text(reviewer.agent.title).font(Typography.label).fixedSize()
                if let seat = reviewer.seatLabel {
                    Text(seat)
                        .font(Typography.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, Space.xs).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.sunken))
                        .fixedSize()
                }
                Text(activity).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: fillsWidth ? .infinity : 170, alignment: .leading)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.clock(from: started, to: context.date)).font(Typography.data).foregroundStyle(.tertiary)
                }
                GlyphButton(icon: "stop.fill", side: ControlHeight.xs, action: stop)
                    .appTooltip("Stop")
                    .accessibilityLabel("Stop \(name)")
            case .finished(let outcome):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.dotOn)
                Text(reviewer.agent.title).font(Typography.label).fixedSize()
                Text(outcome + " · " + Self.clock(from: started, to: ended ?? Date()))
                    .foregroundStyle(.secondary).lineLimit(1)
                if fillsWidth { Spacer(minLength: 0) }
                if let dismiss { GlyphButton(icon: "xmark", side: ControlHeight.xs, action: dismiss).accessibilityLabel("Hide") }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warningText)
                Text("\(reviewer.agent.title) could not finish").font(Typography.label)
                    .foregroundStyle(Theme.warningText).lineLimit(1)
                Text(message).foregroundStyle(Theme.warningText.opacity(0.8)).lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
                    .appTooltip(message)
                InlineLink(title: "Try again", tint: Theme.warningText, action: retry)
                if let dismiss { GlyphButton(icon: "xmark", side: ControlHeight.xs, action: dismiss).accessibilityLabel("Hide") }
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("\(reviewer.agent.title) could not finish").font(Typography.label)
                Spacer(minLength: 0)
                if let dismiss { GlyphButton(icon: "xmark", side: ControlHeight.xs, action: dismiss).accessibilityLabel("Hide") }
            }
            Text(message).foregroundStyle(Theme.warningText.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            InlineLink(title: "Try again", tint: Theme.warningText, action: retry)
        }
        .foregroundStyle(Theme.warningText)
        .padding(.leading, Space.md).padding(.trailing, Space.xs).padding(.vertical, Space.sm)
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
        HStack(spacing: Space.xs) {
            content
            MenuChevron(size: 7)
        }
        .font(Typography.label)
        .lineLimit(1)
        .padding(.horizontal, Space.md).frame(height: 24)
        .background(Capsule().fill(hovering ? Theme.border : Theme.field))
        .contentShape(Capsule())
        .fixedSize()
        .hoverLift(hovering)
        .motion(Motion.hover, value: hovering)
        .onPointerHover { hovering = $0 }
    }
}

// The way into a second opinion on a plan. It leads with the usual
// reviewers' tiles, so the lineup the dialog will start from is the button's mark.
struct SecondOpinionButton: View {
    let usual: [AgentKind]
    let action: () -> Void

    @State private var hovering = false
    @State private var deals = 0

    var body: some View {
        Button {
            deals += 1
            action()
        } label: {
            HStack(spacing: Space.sm) {
                if !usual.isEmpty {
                    LineupTiles(agents: usual, fanned: hovering, deals: deals)
                        .motion(Motion.hover, value: hovering)
                }
                Text("Second opinion").font(Typography.label)
            }
            .padding(.horizontal, Space.md).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(hovering ? Theme.field : .clear))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .accessibilityLabel("Ask for a second opinion")
    }
}

// Three steps for how far a reviewer stands from the author, always beside words that
// say the same. A seat whose model is chosen for it shows dashed steps.
struct IndependenceMeter: View {
    let independence: SecondOpinion.Independence

    var body: some View {
        HStack(spacing: Space.xxs) {
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
        VStack(alignment: .leading, spacing: Space.lg) {
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
            HStack(spacing: Space.xs) {
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
                        .font(Typography.data)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.lg)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
                } else {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        ForEach(groups, id: \.file) { group in
                            VStack(alignment: .leading, spacing: Space.sm) {
                                HStack(spacing: Space.sm) {
                                    Text(fileName(group.comments[0])).font(Typography.label)
                                    Text(counted(group.comments.count, "comment"))
                                        .font(Typography.caption).foregroundStyle(.tertiary)
                                }
                                ForEach(group.comments) { comment in row(comment) }
                            }
                        }
                    }
                    .padding(Space.lg)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
                }
            }
            .frame(height: min(300, listHeight))
            .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.border))
            if questionsLeftOut > 0 {
                Label(questionsLeftOut == 1 ? "Your question and its answer are left out. They stay in Changes."
                      : "Your \(questionsLeftOut) questions and their answers are left out. They stay in Changes.",
                      systemImage: "eye.slash")
                    .font(Typography.detail).foregroundStyle(Theme.plan)
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Anything else for this round?").font(Typography.label)
                TextField("For example: run the tests when you are done", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                    .appTextField()
            }
            HStack(spacing: Space.lg) {
                Spacer(minLength: 0)
                Button { dialogs.dismiss() } label: {
                    Text("Cancel").font(Typography.label).foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .hoverLift()
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                ActionButton(title: "\(busy ? "Queue" : "Send") \(counted(chosen.count, "comment"))",
                             tone: .green, height: ControlHeight.lg, size: Typography.Size.body, icon: "paperplane.fill",
                             keyboardShortcut: .defaultAction) {
                    let list = chosen
                    let words = note
                    dialogs.dismiss()
                    send(list, words)
                }
                .disabled(chosen.isEmpty)
            }
            .padding(.top, Space.xs)
        }
    }

    private func row(_ comment: ReviewComment) -> some View {
        Toggle(isOn: Binding(get: { picked.contains(comment.id) },
                             set: { on in if on { picked.insert(comment.id) } else { picked.remove(comment.id) } })) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.sm) {
                    ReviewAvatars(comment: comment, size: 16)
                    Text(comment.authorName).font(Typography.label)
                    Text(comment.linesLabel).font(Typography.data).foregroundStyle(.secondary)
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
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: icon).foregroundStyle(tint)
            (Text(bold).fontWeight(.semibold) + Text(" " + text))
                .font(Typography.detail)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            action()
        }
        .foregroundStyle(tint)
        .padding(Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(fill))
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
        HStack(spacing: Space.lg) {
            Text(toast.text).font(Typography.body).foregroundStyle(.primary).lineLimit(2)
            if let title = toast.actionTitle, let action = toast.action {
                InlineLink(title: title) {
                    dismiss()
                    action()
                }
            }
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
        .floatingCard(cornerRadius: Radius.card)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Threads

// Where a sent comment stands, in a word and an icon so it never rests on colour.
struct ReviewStatusChip: View {
    let status: ReviewRound.Status
    var label: String?

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(label ?? status.label).lineLimit(1).fixedSize()
        }
        .font(Typography.caption.weight(.semibold))
        .foregroundStyle(ink)
        .padding(.horizontal, status == .resolved ? 0 : 8).padding(.vertical, Space.xxs)
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
                if showsQuote, !comment.excerpt.isBlank { quote.padding(.horizontal, Space.xl).padding(.top, Space.md) }
                VStack(alignment: .leading, spacing: Space.lg) {
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
                            LoopSpinner(size: 14).padding(.vertical, Space.xxs)
                        }
                    }
                }
                .padding(.horizontal, Space.xl).padding(.top, Space.md).padding(.bottom, Space.lg)
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
        HStack(spacing: Space.md) {
            (Text(fileName).foregroundStyle(.primary).fontWeight(.medium) + Text(lines.isEmpty ? "" : " " + lines))
                .font(Typography.data).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if status == .resolved {
                ReviewText(text: comment.body, size: 12, lineLimit: 1)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420, alignment: .leading)
            }
            Spacer(minLength: 0)
            ReviewStatusChip(status: status)
            if status == .resolved {
                InlineLink(title: "Reopen", size: Typography.Size.detail, tint: Color.secondary, action: reopen)
            }
        }
        .padding(.horizontal, Space.xl).padding(.top, Space.lg).padding(.bottom, status == .resolved ? 12 : 0)
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
                        .font(Typography.caption).foregroundStyle(.tertiary)
                        .padding(.leading, 52).padding(.vertical, Space.xxs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverFill(cornerRadius: 0)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            }
        }
        .smoothlyResizes(when: showsAllLines)
        .codeBox()
    }

    private func codeLine(number: Int, text: String, ink: Color, numberInk: Color, fill: Color) -> some View {
        HStack(spacing: Space.lg) {
            Text("\(number)").foregroundStyle(numberInk).frame(width: 28, alignment: .trailing)
            Text(text).foregroundStyle(ink).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(Typography.data)
        .padding(.vertical, 1.5)
        .padding(.trailing, Space.lg)
        .background(fill)
    }

    // The agent's first word on the comment, or where it will go while the turn runs.
    @ViewBuilder private var firstAnswer: some View {
        if !round.isSettled {
            message(agent: agent, when: Text("working on it")) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    RoundedRectangle(cornerRadius: Radius.inset).fill(Theme.field).frame(width: 280, height: 9)
                    RoundedRectangle(cornerRadius: Radius.inset).fill(Theme.field).frame(width: 190, height: 9)
                }
                .padding(.top, Space.xs)
                .accessibilityLabel("\(agent.title) is working on it")
            }
        } else {
            message(agent: agent, when: Text(firstWhen(changedFile: round.outcomes?[comment.id] == .changed))) {
                Text("No answer of its own. What \(agent.title) said is in the conversation.")
                    .font(Typography.body).foregroundStyle(.secondary)
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
            VStack(alignment: .leading, spacing: Space.md) {
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
            HStack(spacing: Space.md) {
                Text((comment.path as NSString).lastPathComponent)
                Text("+\(lines.count { $0.kind == .addition })").font(Typography.data).foregroundStyle(Theme.addition)
                Text("−\(lines.count { $0.kind == .deletion })").font(Typography.data).foregroundStyle(Theme.deletion)
            }
            .font(Typography.caption).foregroundStyle(.secondary)
            .padding(.horizontal, Space.lg).padding(.vertical, Space.xs)
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
        return HStack(alignment: .top, spacing: Space.md) {
            ReviewAvatar(agent: agent, size: 22)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.sm) {
                    Text(isYou ? "You" : agent?.title ?? "").font(Typography.label)
                    if isYou, when == nil {
                        if comment.kind == .question {
                            QuestionTag()
                        } else {
                            Text("Change")
                                .font(Typography.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                                .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs)
                                .background(Capsule().fill(Theme.accent.opacity(0.09)))
                                .fixedSize()
                        }
                    }
                    if let when { when.font(Typography.caption).foregroundStyle(.tertiary) }
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
        HStack(spacing: Space.md) {
            if let suggestion, !replying {
                Button { reply(suggestion) } label: {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "checkmark").font(Typography.micro)
                        Text(suggestion).lineLimit(1)
                    }
                    .font(Typography.label)
                    .foregroundStyle(Theme.plan)
                    .padding(.horizontal, Space.lg).frame(height: 26)
                    .background(Capsule().fill(Theme.card))
                    .overlay(Capsule().strokeBorder(Theme.plan.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(Capsule())
                    .hoverLift()
                }
                .buttonStyle(.plain)
                .appTooltip("Send this reply")
                .accessibilityLabel("Suggested reply: \(suggestion)")
            }
            if !replying {
                ActionButton(title: "Reply", tone: .outlined, height: ControlHeight.sm, size: Typography.Size.detail) {
                    replying = true
                    fieldFocused = true
                }
            }
            if let showInDiff {
                InlineLink(title: "Show in diff", size: Typography.Size.detail, tint: Color.secondary, action: showInDiff)
            }
            Spacer(minLength: 0)
            InlineLink(title: "Resolve", size: Typography.Size.detail, tint: Color.secondary, action: resolve)
        }
        .padding(.leading, 48).padding(.trailing, Space.xl).padding(.bottom, Space.lg)
    }

    private var replyBox: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            TextField("Reply to \(agent.title) about these lines", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .lineLimit(2...8)
                .focused($fieldFocused)
                .onSubmit(send)
                .onExitCommand(perform: cancel)
                .accessibilityLabel("Reply to \(agent.title)")
            HStack(spacing: Space.md) {
                HStack(spacing: Space.xs) {
                    KeyCap(key: "↩"); Text("send")
                    KeyCap(key: "esc"); Text("cancel")
                }
                .font(Typography.caption).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                InlineLink(title: "Cancel", size: Typography.Size.detail, tint: Color.secondary, action: cancel)
                ActionButton(title: "Send reply", tone: .green, height: ControlHeight.sm, size: Typography.Size.detail, action: send)
                    .disabled(draft.isBlank)
            }
        }
        .padding(.horizontal, Space.md).padding(.vertical, Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(Theme.accent.opacity(0.5)))
        .padding(.leading, 48).padding(.trailing, Space.xl).padding(.bottom, Space.lg)
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
        clipShape(RoundedRectangle(cornerRadius: Radius.control))
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.sunken))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.hairline))
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
