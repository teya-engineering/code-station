import AppKit
import SwiftUI

// What a session is besides its name: the branch it is on, the pull request it opened,
// what it runs on and how full its window is. Spread along the status strip they crowd
// out the two readings that are actually watched - what the session is doing and what it
// has changed - so they are collapsed into one chip that opens when it is asked a
// question. The chip keeps the window reading, which is the only one of them that moves
// on its own; the rest are looked up when something needs doing about them.
struct SessionFacts: Equatable {
    var branch: String?
    var pullRequest: PullRequest?
    var model: String?
    // Left out when the agent reports no cost. Codex reports none, and a $0.00 there reads
    // as free rather than as unknown.
    var cost: Double?
    var context: Double?
    var agent: AgentKind = .claudeCode

    // What the chip says while it is shut. How full the window is, since that is the one
    // fact behind the chip that moves every turn and the only one worth a glance rather
    // than a lookup - the branch, the pull request and the rest are asked for once and
    // then known. Before the first turn there is no window to read, so the chip says what
    // it is instead of what it holds.
    var summary: String? {
        if let context { return Self.percent(context) }
        return isEmpty ? nil : "Details"
    }

    // Nothing to open the card for.
    var isEmpty: Bool {
        (branch ?? "").isEmpty && pullRequest == nil && model == nil && cost == nil
            && context == nil
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
            Button {
                if pinned {
                    closeCard()
                } else {
                    pinned = true
                }
            } label: { chip(summary) }
                .buttonStyle(.plain)
                .onHover { pointerOnChip = $0; pointerMoved() }
                .accessibilityLabel(facts.context == nil
                    ? "Session details"
                    : "Session details, \(facts.agent == .codex ? "window" : "context") \(summary) full")
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

    // A window that is filling is the one thing on this strip worth being pulled towards,
    // so on the chip it wears the colour it has on the card. Below that it stays as quiet
    // as everything else on the line.
    private var summaryTint: Color {
        guard let context = facts.context else { return .secondary }
        let colour = SessionFacts.contextColour(context, agent: facts.agent)
        return colour == Theme.dotOn ? .secondary : colour
    }

    private func chip(_ summary: String) -> some View {
        HStack(spacing: 6) {
            Text(summary)
                .font(.mono(10.5, .semibold))
                .foregroundStyle(summaryTint)
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
            closeCard()
        }
    }

    private func closeCard() {
        closing?.cancel()
        pinned = false
        // An explicit close wins over hover until AppKit reports a fresh pointer entry.
        pointerOnCard = false
        pointerOnChip = false
        hovering = false
    }
}

// MARK: - The hairline

// How full the window is, read along the bottom edge of the status strip rather than as
// words on it. The line always runs from green to red, so its length remains the reading
// and its colour is decoration rather than a second warning scale. Near the end, its tip
// burns like a fuse to make a window that needs attention hard to miss.
struct ContextHairline: View {
    static let fuseThreshold = 0.8

    let fraction: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func showsFuse(at fraction: Double) -> Bool {
        fraction > fuseThreshold
    }

    var body: some View {
        GeometryReader { geometry in
            let clamped = min(1, max(0, fraction))
            let width = max(2, geometry.size.width * clamped)
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                        colors: [Theme.dotOn, Theme.attention, Theme.deletion],
                        startPoint: .leading,
                        endPoint: .trailing)
                    .frame(width: geometry.size.width, height: 2)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: width, height: 2)
                    }

                if Self.showsFuse(at: fraction) {
                    if reduceMotion {
                        FuseSpark(progressWidth: width, phase: 0.35, intensity: clamped)
                    } else {
                        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                            FuseSpark(
                                progressWidth: width,
                                phase: timeline.date.timeIntervalSinceReferenceDate,
                                intensity: clamped)
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height,
                   alignment: .bottomLeading)
        }
        .frame(height: 10)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct FuseSpark: View {
    let progressWidth: CGFloat
    let phase: TimeInterval
    let intensity: Double

    private static let embers = [
        Ember(angle: -2.55, distance: 5.2, size: 1.2, speed: 1.31, offset: 0.08),
        Ember(angle: -2.02, distance: 7.2, size: 1.0, speed: 1.73, offset: 0.43),
        Ember(angle: -1.57, distance: 6.2, size: 1.4, speed: 1.49, offset: 0.71),
        Ember(angle: -1.12, distance: 7.7, size: 0.9, speed: 1.91, offset: 0.24),
        Ember(angle: -0.66, distance: 5.5, size: 1.1, speed: 1.57, offset: 0.59),
    ]

    var body: some View {
        Canvas { context, size in
            let tip = CGPoint(x: min(size.width - 1, progressWidth), y: size.height - 1)
            let heat = min(1, max(0, (intensity - ContextHairline.fuseThreshold)
                / (1 - ContextHairline.fuseThreshold)))

            context.drawLayer { glow in
                glow.addFilter(.blur(radius: 2.4))
                glow.opacity = 0.55 + heat * 0.25
                glow.fill(
                    Path(ellipseIn: CGRect(x: tip.x - 3.5, y: tip.y - 3.5,
                                          width: 7, height: 7)),
                    with: .color(Theme.attention))
            }

            context.fill(
                Path(ellipseIn: CGRect(x: tip.x - 1.6, y: tip.y - 1.6,
                                      width: 3.2, height: 3.2)),
                with: .color(Theme.deletion))

            for ember in Self.embers {
                let life = (phase * ember.speed * (1 + heat * 0.65) + ember.offset)
                    .truncatingRemainder(dividingBy: 1)
                let fade = pow(1 - life, 1.7)
                let distance = ember.distance * life
                let point = CGPoint(
                    x: tip.x + cos(ember.angle) * distance,
                    y: tip.y + sin(ember.angle) * distance - life * life * 1.5)
                let diameter = ember.size * (0.55 + fade * 0.7)
                context.opacity = fade
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - diameter / 2,
                                          y: point.y - diameter / 2,
                                          width: diameter, height: diameter)),
                    with: .color(life < 0.45 ? Theme.attention : Theme.deletion))
            }
        }
    }

    private struct Ember {
        let angle: Double
        let distance: Double
        let size: Double
        let speed: Double
        let offset: Double
    }
}
