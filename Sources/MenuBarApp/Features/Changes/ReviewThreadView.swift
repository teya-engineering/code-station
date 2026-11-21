import AppKit
import SwiftUI

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
