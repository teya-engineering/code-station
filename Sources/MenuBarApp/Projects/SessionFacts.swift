import AppKit
import SwiftUI

// What a session is besides its name: the branch it is on, what it has changed, the pull
// requests it opened, what it runs on and how full its window is. The branch is the fact
// reached for before a diff is read, so it is the one the chip says out loud; the rest
// stay behind it, in the card it opens.
struct SessionFacts: Equatable {
    var branch: String?
    var changes: Changes?
    var pullRequests: [PullRequest] = []
    var model: String?
    // Left out when the agent reports no cost. Codex reports none, and a $0.00 there reads
    // as free rather than as unknown.
    var cost: Double?
    var context: Double?
    var agent: AgentKind = .claudeCode

    // What the working tree has done. The file count is missing until git has answered
    // for the tree, so it is the one part of this that can be zero and still mean
    // something changed.
    struct Changes: Equatable {
        var files: Int
        var added: Int
        var removed: Int
    }

    // What the chip reads as on the bar. A chip that names the branch is a chip whose
    // summary is the fact you were reaching for, which the word `Details` never was; with
    // no repository behind the session there is no branch to name, and the chip stands
    // for the card instead.
    var summary: String? {
        if isEmpty { return nil }
        return namedBranch ?? "Details"
    }

    // The branch when there is one to draw, which is also what tells the chip whether to
    // wear the fork glyph and the card whether to head itself with a name.
    var namedBranch: String? {
        guard let branch, !branch.isEmpty else { return nil }
        return branch
    }

    // Nothing to open the card for.
    var isEmpty: Bool {
        namedBranch == nil && changes == nil && pullRequests.isEmpty && model == nil
            && cost == nil && context == nil
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    // The tint the window reading wears, and with it the hairline under the deck. Codex
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

// The branch, and behind it every other fact the session is looked up by. It keeps one
// shape and one place on the deck while the values inside it change, so it is a target
// that can be learned rather than a label that moves.
struct SessionFactsChip: View {
    let facts: SessionFacts
    // How wide the chip is allowed to grow before the branch truncates. A narrow pane
    // hands it less, and a name too long for either cuts from the tail: the end of a
    // branch name is the part that repeats across a project.
    var maxWidth: CGFloat = 210
    let openChanges: () -> Void
    let contextActions: () -> [MenuEntry]
    let usageTooltip: () -> Tooltip

    // The card hangs off the chip rather than being placed by a presenter: it belongs to
    // this corner of the band, and nothing above the band can clip it.
    private static let chipHeight: CGFloat = 24
    private static let cardGap: CGFloat = 7
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
                .accessibilityLabel(accessibilityLabel)
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

    private var accessibilityLabel: String {
        let opens = facts.namedBranch.map { "Branch \($0), session details" }
            ?? "Session details"
        guard let context = facts.context else { return opens }
        let window = facts.agent == .codex ? "window" : "context"
        return "\(opens), \(window) \(SessionFacts.percent(context)) full"
    }

    private func chip(_ summary: String) -> some View {
        HStack(spacing: 6) {
            if facts.namedBranch != nil {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Text(summary)
                .font(.mono(10.5))
                .foregroundStyle(isOpen ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
        .padding(.horizontal, 9)
        .frame(height: Self.chipHeight)
        .frame(maxWidth: maxWidth)
        .surface(isOpen ? Theme.field : Theme.sunken, cornerRadius: 11)
        .contentShape(Rectangle())
    }

    private var hoverCard: some View {
        VStack(spacing: 0) {
            // The gap belongs to the hover area rather than sitting between two of them,
            // so moving down into the card does not cross a strip of nothing and take
            // the card away on the way.
            Color.clear.frame(width: Self.cardWidth, height: Self.cardGap)
            card
        }
        .fixedSize()
        .offset(y: Self.chipHeight)
        .onHover { pointerOnCard = $0; pointerMoved() }
        .transition(.fadeIn)
    }

    private var card: some View {
        VStack(spacing: 0) {
            if let branch = facts.namedBranch { head(branch) }
            let rows = self.rows
            ForEach(Array(rows.enumerated()), id: \.element) { position, fact in
                row(fact)
                    .overlay(alignment: .bottom) {
                        if position < rows.count - 1 { rule }
                    }
            }
        }
        .frame(width: Self.cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Self.radius).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Self.radius).stroke(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Self.radius))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
    }

    // The card's head repeats the name the chip truncated, at a size that can be read,
    // with the one action that takes it out of the app beside it.
    private func head(_ branch: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(branch)
                .font(.mono(11.5, .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            CopyButton(size: 10) { branch }
                .appTooltip("Copy the branch name.")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Theme.sunken)
        .overlay(alignment: .bottom) { rule }
    }

    private var rule: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    // MARK: - Rows

    // Everything that came off the bar, in the order it is asked about: what changed,
    // where the change went, what did it, and what the work is costing in room and money.
    // A session opens as many pull requests as it has checkouts to open them in, so that
    // fact is a row each rather than one row, and carries which of them it stands for.
    private enum Fact: Hashable { case changes, pullRequest(Int), model, context, cost }

    private var rows: [Fact] {
        var rows: [Fact] = []
        if facts.changes != nil { rows.append(.changes) }
        rows.append(contentsOf: facts.pullRequests.indices.map(Fact.pullRequest))
        if facts.model != nil { rows.append(.model) }
        if facts.context != nil { rows.append(.context) }
        if facts.cost != nil { rows.append(.cost) }
        return rows
    }

    @ViewBuilder private func row(_ fact: Fact) -> some View {
        switch fact {
        case .changes:
            if let changes = facts.changes { changesRow(changes) }
        case .pullRequest(let position):
            if facts.pullRequests.indices.contains(position) {
                pullRequestRow(facts.pullRequests[position], first: position == 0)
            }
        case .model:
            if let model = facts.model { modelRow(model) }
        case .context:
            if let context = facts.context { contextRow(context) }
        case .cost:
            if let cost = facts.cost { costRow(cost) }
        }
    }

    private func row<Content: View>(_ label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.mono(9.5, .semibold))
                .kerning(1.2)
                .foregroundStyle(.tertiary)
                .frame(width: Self.labelWidth, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .frame(height: 34)
    }

    private func changesRow(_ changes: SessionFacts.Changes) -> some View {
        row("CHANGES") {
            Button(action: acting(openChanges)) {
                HStack(spacing: 7) {
                    if changes.files > 0 {
                        Text(counted(changes.files, "file"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    DiffPair(added: changes.added, removed: changes.removed, size: 10.5)
                }
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appTooltip("Opens Changes.")
        }
    }

    // Pull requests are stacked one to a row and share the label, which is what keeps a
    // list of them reading as one fact about the session.
    private func pullRequestRow(_ pullRequest: PullRequest, first: Bool) -> some View {
        row(first ? "PULL REQ" : "") {
            Button(action: acting {
                guard let url = URL(string: pullRequest.url) else { return }
                NSWorkspace.shared.open(url)
            }) {
                HStack(spacing: 6) {
                    if namesRepositories, let repository = pullRequest.repository {
                        Text(repository)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
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

    // Numbers count up per repository, so two of them in one session can both be #3. The
    // repository is named only when it is what tells them apart.
    private var namesRepositories: Bool {
        Set(facts.pullRequests.compactMap(\.repository)).count > 1
    }

    private func modelRow(_ model: String) -> some View {
        row("MODEL") {
            Text(model)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
    }

    private func costRow(_ cost: Double) -> some View {
        row("COST") {
            Text(Money.short(cost))
                .font(.mono(11.5))
                .appTooltip("What this session has spent.")
        }
    }

    // The window is the one reading here that says a session is getting heavy, so it is
    // also where the window is dealt with. It only opens a menu while there is a
    // conversation to work on and nothing running that still holds it.
    @ViewBuilder private func contextRow(_ fraction: Double) -> some View {
        let actions = contextActions()
        row(facts.agent == .codex ? "WINDOW" : "CONTEXT") {
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
                .frame(width: 110)
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

// How full the window is, read above the destination deck rather than as
// words on it. The line always runs from green to red, so its length remains the reading
// and its colour is decoration rather than a second warning scale. Near the end, its tip
// burns like a fuse to make a window that needs attention hard to miss.
struct ContextHairline: View {
    static let fuseThreshold = 0.8

    let fraction: Double
    let animated: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func showsFuse(at fraction: Double) -> Bool {
        fraction > fuseThreshold
    }

    static func animatesFuse(at fraction: Double, whileActive active: Bool) -> Bool {
        active && showsFuse(at: fraction)
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
                    if Self.animatesFuse(at: fraction, whileActive: animated), !reduceMotion {
                        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                            FuseSpark(
                                progressWidth: width,
                                phase: timeline.date.timeIntervalSinceReferenceDate,
                                intensity: clamped)
                        }
                    } else {
                        FuseSpark(progressWidth: width, phase: 0.35, intensity: clamped)
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
