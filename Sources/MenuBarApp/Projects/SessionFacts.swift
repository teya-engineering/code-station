import AppKit
import SwiftUI

// The facts a session is looked up by rather than watched: the branch it is on, the pull
// request it opened, what it runs on and how full its window is. Spread along the status
// strip they crowd out the two readings that are actually watched - what the session is
// doing and what it has changed - and none of them move often enough to earn the room, so
// they are collapsed into one chip that opens when it is asked a question.
struct SessionFacts: Equatable {
    var branch: String?
    var pullRequest: PullRequest?
    var model: String?
    // Left out when the agent reports no cost. Codex reports none, and a $0.00 there reads
    // as free rather than as unknown.
    var cost: Double?
    var context: Double?
    var agent: AgentKind = .claudeCode

    // What the chip says while it is shut, in the order the facts are asked for. The
    // branch loses its prefix: a team that starts every branch with the same word would
    // otherwise fill the chip with the part that never differs.
    var summary: String? {
        var parts: [String] = []
        if let branchLeaf { parts.append(branchLeaf) }
        if let pullRequest { parts.append("#\(pullRequest.number)") }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        if let model { return model }
        if let context { return Self.percent(context) }
        if let cost { return Money.short(cost) }
        return nil
    }

    var branchLeaf: String? {
        guard let branch, !branch.isEmpty else { return nil }
        return branch.split(separator: "/").last.map(String.init)
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    // The tint the window reading wears, and with it the hairline under the strip. Codex
    // makes its own room as the window fills, so a full one there is worth noticing
    // rather than a failure waiting to happen.
    static func contextColour(_ fraction: Double, agent: AgentKind) -> Color {
        switch Int((fraction * 100).rounded()) {
        case 85...: agent == .codex ? Theme.attention : Theme.deletion
        case 70...: Theme.attention
        default: Theme.dotOn
        }
    }
}

// MARK: - The chip

struct SessionFactsChip: View {
    let facts: SessionFacts
    let openChanges: () -> Void
    let contextActions: () -> [MenuEntry]
    let usageTooltip: () -> Tooltip

    // The card hangs off the chip rather than being placed by a presenter: it belongs to
    // this corner of the strip, and nothing above the strip can clip it.
    private static let chipHeight: CGFloat = 22
    private static let gap: CGFloat = 7
    private static let cardWidth: CGFloat = 292
    private static let labelWidth: CGFloat = 62
    private static let radius: CGFloat = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pointerOnChip = false
    @State private var pointerOnCard = false
    @State private var hovering = false
    @State private var closing: Task<Void, Never>?
    // Hover alone would make a card that can be read but not used, since reaching a row
    // means leaving the chip. Clicking the chip holds it open until it is clicked again.
    @State private var pinned = false

    private var isOpen: Bool { pinned || hovering }

    var body: some View {
        if let summary = facts.summary {
            Button { pinned.toggle() } label: { chip(summary) }
                .buttonStyle(.plain)
                .onHover { pointerOnChip = $0; pointerMoved() }
                .accessibilityLabel("Session facts: \(summary)")
                .overlay(alignment: .topTrailing) {
                    if isOpen { hoverCard }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isOpen)
                .onDisappear { closing?.cancel() }
        }
    }

    // The chip and the card are two hover areas that meet along one edge, and AppKit
    // reports leaving the first before entering the second. Taken at face value that
    // pair of events closes the card on the way into it, so leaving is given a moment
    // to be contradicted.
    private func pointerMoved() {
        closing?.cancel()
        guard !pointerOnChip, !pointerOnCard else {
            hovering = true
            return
        }
        closing = Task {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, !pointerOnChip, !pointerOnCard else { return }
            hovering = false
        }
    }

    private func chip(_ summary: String) -> some View {
        HStack(spacing: 6) {
            Text(summary)
                .font(.mono(10.5, .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 9)
        .frame(height: Self.chipHeight)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(isOpen ? Theme.accent.opacity(0.5) : Theme.border))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }

    private var hoverCard: some View {
        VStack(spacing: 0) {
            // The gap belongs to the hover area rather than sitting between two of them,
            // so moving down into the card does not cross a strip of nothing and take
            // the card away on the way.
            Color.clear.frame(width: Self.cardWidth, height: Self.gap)
            card
        }
        .fixedSize()
        .offset(y: Self.chipHeight)
        .onHover { pointerOnCard = $0; pointerMoved() }
        .transition(.fadeIn)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let branch = facts.branch, !branch.isEmpty { branchRow(branch) }
            if let pullRequest = facts.pullRequest { pullRequestRow(pullRequest) }
            if facts.model != nil || facts.cost != nil { modelRow }
            if let context = facts.context { contextRow(context) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Self.radius).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Self.radius).stroke(Theme.border))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
    }

    // MARK: - Rows

    private func row<Content: View>(_ label: String,
                                    alignment: VerticalAlignment = .firstTextBaseline,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(label)
                .font(.mono(9.5, .semibold))
                .kerning(1.2)
                .foregroundStyle(.tertiary)
                .frame(width: Self.labelWidth, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func branchRow(_ branch: String) -> some View {
        row("BRANCH") {
            Button(action: acting(openChanges)) {
                Text(branch)
                    .font(.mono(11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appTooltip("Opens Changes.")
        }
    }

    // The one thing here that leads out of the app, so it opens in the browser.
    private func pullRequestRow(_ pullRequest: PullRequest) -> some View {
        row("PR") {
            Button(action: acting {
                guard let url = URL(string: pullRequest.url) else { return }
                NSWorkspace.shared.open(url)
            }) {
                HStack(spacing: 5) {
                    // Verbatim, or the interpolated number is read as a localised one
                    // and comes out grouped: PR #2,395.
                    Text(verbatim: "#\(pullRequest.number)")
                        .font(.mono(11.5, .semibold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8.5, weight: .semibold))
                }
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appTooltip {
                Tooltip(title: "Pull request #\(pullRequest.number)",
                        subtitle: pullRequest.url,
                        note: "Opens in the browser.")
            }
        }
    }

    private var modelRow: some View {
        row("MODEL") {
            HStack(spacing: 6) {
                if let model = facts.model {
                    Text(model).font(.system(size: 12, weight: .medium))
                }
                if let cost = facts.cost {
                    if facts.model != nil { StatusDot() }
                    Text(Money.short(cost))
                        .font(.mono(11))
                        .foregroundStyle(.secondary)
                        .appTooltip("What this session has spent.")
                }
            }
            .lineLimit(1)
        }
    }

    // The window is the one reading here that says a session is getting heavy, so it is
    // also where the window is dealt with. It only opens a menu while there is a
    // conversation to work on and nothing running that still holds it.
    @ViewBuilder private func contextRow(_ fraction: Double) -> some View {
        let actions = contextActions()
        row(facts.agent == .codex ? "WINDOW" : "CONTEXT", alignment: .center) {
            if actions.isEmpty {
                contextReading(fraction, clearable: false)
                    .appTooltip(usageTooltip)
            } else {
                contextReading(fraction, clearable: true)
                    .appMenu {
                        // The menu takes the pointer off the card, and a card that went
                        // with it would take the reading being acted on with it.
                        pinned = true
                        return contextActions()
                    }
                    .appTooltip(usageTooltip)
            }
        }
    }

    private func contextReading(_ fraction: Double, clearable: Bool) -> some View {
        let colour = SessionFacts.contextColour(fraction, agent: facts.agent)
        return HStack(spacing: 10) {
            Meter(fraction: fraction, colour: colour, height: 5)
                .frame(width: 128)
            HStack(spacing: 4) {
                Text(SessionFacts.percent(fraction))
                    .font(.mono(11, .semibold))
                if clearable {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                }
            }
            .foregroundStyle(colour)
            .fixedSize()
        }
        .contentShape(Rectangle())
    }

    // A row that leads somewhere has done what the card was opened for, so the card
    // closes behind it rather than being left over whatever it opened.
    private func acting(_ perform: @escaping () -> Void) -> () -> Void {
        {
            perform()
            closing?.cancel()
            pinned = false
            pointerOnCard = false
            pointerOnChip = false
            hovering = false
        }
    }
}

// MARK: - The hairline

// How full the window is, read along the bottom edge of the status strip rather than as
// words on it. It is the one fact behind the chip that moves every turn, so it stays
// visible - but as a line, since nothing has to be done about it until it is nearly full,
// and the composer says that in words when it is.
struct ContextHairline: View {
    let fraction: Double
    let colour: Color

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(colour)
                .frame(width: max(2, geometry.size.width * min(1, max(0, fraction))))
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}
