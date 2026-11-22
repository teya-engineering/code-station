import AppKit
import SwiftUI

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
