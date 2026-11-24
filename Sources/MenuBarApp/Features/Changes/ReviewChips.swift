import SwiftUI

// The pieces a review is drawn with, shared by both diff layouts, the review list, the
// send dialog and the cards in Chat, so a comment looks the same wherever it turns up.

// Who left a comment: you on a quiet tile, or the reviewer's mark on its own colour.
struct ReviewAvatar: View {
    // Nil for you.
    let agent: AgentKind?
    var size: CGFloat = 20
    // Amber while the reviewer has findings waiting to be looked at.
    var hasFindings = false
    // Counts up each time the reviewer's symbol should play its own move.
    var move = 0
    // Grey and outlined, for a lineup resting on the header rail, where nothing takes a
    // colour until it is pointed at.
    var muted = false
    // Counts up each time the mark should give one small hop, after `hopDelay`.
    var hop = 0
    var hopDelay: TimeInterval = 0

    var body: some View {
        Image(systemName: agent?.symbol ?? "person.fill")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(ink)
            .modifier(SymbolMove(agent: agent, size: size, trigger: move))
            .railHop(trigger: hop, delay: hopDelay)
            .frame(width: size, height: size)
            // A symbol that flies out of its tile leaves through the edge, not over its neighbour.
            .clipped()
            .background(RoundedRectangle(cornerRadius: size * 0.3).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3).strokeBorder(edge, lineWidth: muted ? 1.3 : 1))
            .accessibilityHidden(true)
    }

    private var ink: Color {
        if hasFindings { return Theme.attentionText }
        guard agent != nil else { return Theme.accent }
        return muted ? Color.secondary : Theme.onFill
    }

    private var fill: Color {
        if hasFindings { return Theme.attention.opacity(0.16) }
        guard let agent else { return Theme.userMessage }
        return muted ? Theme.statusBand : agent.tint
    }

    private var edge: Color {
        if hasFindings { return Theme.attention }
        guard agent != nil else { return Theme.border }
        return muted ? Color.secondary : .clear
    }
}

extension AgentKind {
    // The agent's own colour, behind its symbol wherever it speaks.
    var tint: Color {
        switch self {
        case .claudeCode: Theme.agentClaudeCode
        case .codex: Theme.agentCodex
        case .copilot: Theme.agentCopilot
        }
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
