import SwiftUI

// The count on a file row that folds its comments away or opens them again.
struct FileNotesBadge: View {
    let notes: FileNotes
    let expanded: Bool
    let toggle: () -> Void

    // The count turns over only when the change around it is animated, which is when the
    // person kept or removed a comment. Findings that arrive in the background just appear.
    var body: some View {
        Button(action: toggle) {
            Label {
                Text("\(notes.badgeCount)")
                    .contentTransition(.numericText(value: Double(notes.badgeCount)))
            } icon: {
                Image(systemName: "text.bubble")
            }
            .font(Typography.caption.weight(.semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, Space.sm).frame(height: 18)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
            .hoverLift(amount: Motion.smallLift)
        }
        .buttonStyle(.plain)
        .appTooltip(expanded ? "Hide comments" : "Show comments")
        .accessibilityLabel(counted(notes.badgeCount, "comment"))
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint(expanded ? "Hides the comments under this file" : "Shows the comments under this file")
    }

    private var ink: Color {
        switch notes.tone {
        case .must: Theme.warningText
        case .attention: Theme.attentionText
        case .plain: Color.secondary
        }
    }

    private var fill: Color {
        switch notes.tone {
        case .must: Theme.warningBackground
        case .attention: Theme.attention.opacity(0.14)
        case .plain: Theme.field
        }
    }
}

// A comment under its file, on one line with its state. The whole thread opens in the
// diff, so the row only says what the comment is and where it stands.
struct FileNoteRow: View {
    let note: FileNote
    let agentTitle: String
    // The file, for a note listed away from its file row.
    var fileLabel: String? = nil
    let focused: Bool
    let showsCursor: Bool
    let open: () -> Void
    var stop: (() -> Void)? = nil

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: Space.md) {
                avatar.padding(.top, 1)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(spacing: Space.sm) {
                        if note.unread { Circle().fill(Theme.plan).frame(width: 6, height: 6) }
                        if let fileLabel {
                            Text(fileLabel).font(Typography.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Text(lines).font(Typography.data).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                        Spacer(minLength: 4)
                        FileNoteTag(tag: note.tag)
                        // Room for the stop button, which sits over the row so it is not a
                        // button inside a button.
                        if stop != nil { Color.clear.frame(width: 22, height: 18) }
                    }
                    ReviewText(text: text, size: 12, lineLimit: 1)
                    if let reply {
                        Text(reply).font(Typography.detail).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(focused ? Theme.plan.opacity(0.07) : .clear))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control).stroke(showsCursor ? Theme.accent : .clear, lineWidth: 2)
            }
            .opacity(note.isResolved ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.control)
        .overlay(alignment: .topTrailing) {
            if let stop { StopAnsweringButton(action: stop).padding(.top, Space.xs).padding(.trailing, Space.sm) }
        }
        .accessibilityLabel(spokenName)
        .accessibilityAddTraits(focused ? .isSelected : [])
    }

    @ViewBuilder private var avatar: some View {
        switch note.source {
        case .unsent(let comment), .sent(let comment, _): ReviewAvatars(comment: comment, size: 18)
        case .question: ReviewAvatar(agent: nil, size: 18)
        }
    }

    private var lines: String {
        switch note.source {
        case .unsent(let comment), .sent(let comment, _):
            if comment.onFile { return "file" }
            return "line " + (comment.lastLine.map { "\(comment.line)–\($0)" } ?? "\(comment.line)")
        case .question(let question):
            if question.isWhole { return "whole change" }
            return "line " + (question.lastLine.map { "\(question.line)–\($0)" } ?? "\(question.line)")
        }
    }

    private var text: String {
        switch note.source {
        case .unsent(let comment), .sent(let comment, _): comment.body
        case .question(let question): question.text
        }
    }

    // The last word on it, when someone answered.
    private var reply: String? {
        switch note.source {
        case .unsent: return nil
        case .sent(let comment, let round):
            guard let last = round.replies(comment.id).last, !last.body.isBlank else { return nil }
            return (last.author == .agent ? agentTitle : "You") + ": " + last.body
        case .question(let question):
            guard let answer = question.exchanges.last?.answer, !answer.isBlank else { return nil }
            return question.agent.title + ": " + answer
        }
    }

    private var spokenName: String {
        let state = FileNoteTag.label(note.tag)
        let where_ = fileLabel.map { $0 + ", " } ?? ""
        return "\(where_)\(lines), \(state)\(note.unread ? ", unread reply" : ""): \(text)"
    }
}

// Where a comment stands, in words, in the colours the review uses everywhere else.
struct FileNoteTag: View {
    let tag: FileNote.Tag

    var body: some View {
        switch tag {
        case .severity(let severity): SeverityChip(severity: severity)
        case .status(let status): ReviewStatusChip(status: status)
        case .answering:
            Breathing { chip(Self.label(tag), icon: nil, ink: Theme.plan, fill: Theme.plan.opacity(0.08)) }
        default:
            chip(Self.label(tag), icon: icon, ink: ink, fill: fill)
        }
    }

    static func label(_ tag: FileNote.Tag) -> String {
        switch tag {
        case .notSent: "Not sent yet"
        case .toLookAt: "To look at"
        case .severity(let severity): severity.label
        case .status(let status): status.label
        case .answering: "Answering"
        case .couldNotAnswer: "Couldn't answer"
        case .stopped: "Stopped"
        case .answered: "Answered"
        case .changeWaiting: "Change not sent"
        case .becameChange: "Became a change"
        case .resolved: "Resolved"
        }
    }

    private var icon: String? {
        switch tag {
        case .notSent, .changeWaiting: "clock"
        case .resolved: "checkmark"
        case .becameChange: "pencil"
        default: nil
        }
    }

    private var ink: Color {
        switch tag {
        case .answered: Theme.plan
        case .becameChange: Theme.dotOnText
        case .couldNotAnswer: Theme.warningText
        case .toLookAt: Theme.attentionText
        case .resolved: Color.secondary.opacity(0.7)
        default: Color.secondary
        }
    }

    private var fill: Color {
        switch tag {
        case .answered: Theme.plan.opacity(0.12)
        case .becameChange: Theme.dotOn.opacity(0.14)
        case .couldNotAnswer: Theme.warningBackground
        case .toLookAt: Theme.attention.opacity(0.14)
        case .resolved: .clear
        default: Theme.field
        }
    }

    private func chip(_ title: String, icon: String?, ink: Color, fill: Color) -> some View {
        HStack(spacing: Space.xs) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(title).lineLimit(1).fixedSize()
        }
        .font(Typography.caption.weight(.semibold))
        .foregroundStyle(ink)
        .padding(.horizontal, tag == .resolved ? 0 : 6).padding(.vertical, Space.xxs)
        .background(Capsule().fill(fill))
    }
}
