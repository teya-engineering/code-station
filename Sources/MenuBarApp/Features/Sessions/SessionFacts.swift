import AppKit
import SwiftUI
import CodeStationCore

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
    // and Copilot make their own room as the window fills, so a full one there is worth
    // noticing rather than a failure waiting to happen.
    static func contextColour(_ fraction: Double, agent: AgentKind) -> Color {
        switch Int((fraction * 100).rounded()) {
        case 85...: agent.asksPermissions ? Theme.deletion : Theme.attention
        case 70...: Theme.attention
        default: Theme.dotOn
        }
    }
}

// What the session is doing and for how long. "RUNNING · 4m", "WAITING · 12m",
// "IDLE · 2h": a running turn counts up from its own start rather than from the session's
// last activity, which makes it the age of the work in flight. A waiting one counts from
// where the work stopped, so the number is the length of the wait rather than of the turn
// that is still holding it.
struct SessionStateReading: Equatable {
    var tone: SessionTone
    var since: Date?
    // A running turn or a live wait has to keep counting when nothing arrives to redraw
    // it, which is most of a long turn and all of a wait. Anything else is a fixed time.
    var ticks = false
    // A diagnosis runs like any other turn, but naming it is what tells the reader the
    // brief landed and the agent is working through it.
    var diagnosing = false

    var word: String {
        diagnosing && tone == .running ? "DIAGNOSING" : tone.word
    }

    // The word as a sentence would say it, for VoiceOver: "Needs you" rather than
    // "NEEDS YOU".
    var spokenWord: String {
        word.prefix(1) + word.dropFirst().lowercased()
    }

    // The short reading on the pill. It drops to whole minutes, hours and days, so the
    // pill keeps its width while the card carries the precise count.
    var shortElapsed: String? {
        guard let since else { return nil }
        return ticks ? RelativeTime.duration(since: since) : RelativeTime.short(since)
    }

    // "5m 12s" while it is under the hour, then "2h 14m", then "3d 4h".
    static func preciseElapsed(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds))
        let hours = whole / 3_600
        let minutes = whole / 60 % 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m " + String(format: "%02ds", whole % 60)
    }

    // "since 14:02" for something still going, "last active 14:02" for a session at rest.
    // A day other than today is named, or the clock alone would point at the wrong one.
    static func sinceLine(_ date: Date, tone: SessionTone) -> String {
        let when = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : RelativeTime.stamp(date)
        return tone == .idle ? "last active \(when)" : "since \(when)"
    }
}

// MARK: - The pill

// What the session is up to: its state over the branch it is on, with every other fact
// it is looked up by in the card behind it. The two readings answer one question, so they
// are one target. It keeps one shape and one place on the deck while the values inside
// it change, so it is a target that can be learned rather than a label that moves.
struct SessionFactsChip: View {
    let facts: SessionFacts
    let state: SessionStateReading
    // How wide the branch is allowed to grow before it truncates. A narrow pane hands it
    // less, and a name too long for either cuts from the tail: the end of a branch name
    // is the part that repeats across a project.
    var maxWidth: CGFloat = 210
    var showsBranch = true
    let openChanges: () -> Void
    let contextActions: () -> [MenuEntry]
    let usageTooltip: () -> Tooltip

    // The card hangs off the pill rather than being placed by a presenter: it belongs to
    // this corner of the band, and nothing above the band can clip it.
    private static let pillHeight: CGFloat = 36
    private static let pillRadius: CGFloat = 9
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
    // means leaving the pill. Clicking the pill holds it open until it is clicked again.
    @State private var pinned = false
    // The pill is a plain button, which rarely holds the keyboard, so Escape is heard
    // across the window for as long as the card is open.
    @State private var escape = WindowKeyMonitor([], "\u{1b}")

    private var isOpen: Bool { pinned || hovering }

    var body: some View {
        Button {
            if pinned {
                closeCard()
            } else {
                pinned = true
            }
        } label: { pill }
            .buttonStyle(.plain)
            .onHover { pointerOnChip = $0; pointerMoved() }
            .accessibilityLabel(Self.accessibilityLabel(
                state: state, facts: facts, showsBranch: showsBranch))
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .background(WindowAnchor(monitor: escape))
            .overlay(alignment: .topTrailing) {
                if isOpen { hoverCard }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isOpen)
            .onChange(of: isOpen) { _, open in
                if open {
                    escape.start {
                        closeCard()
                        return true
                    }
                } else {
                    escape.stop()
                }
            }
            .onDisappear {
                closing?.cancel()
                escape.stop()
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

    // "Running for 5m, branch main, session details". The state leads, since it is the
    // half that changes while the session is looked at.
    static func accessibilityLabel(state: SessionStateReading, facts: SessionFacts,
                                   showsBranch: Bool) -> String {
        var parts = [state.shortElapsed.map { "\(state.spokenWord) for \($0)" }
                         ?? state.spokenWord]
        if showsBranch, let branch = facts.namedBranch { parts.append("branch \(branch)") }
        parts.append("session details")
        if let context = facts.context {
            let window = facts.agent.asksPermissions ? "context" : "window"
            parts.append("\(window) \(SessionFacts.percent(context)) full")
        }
        return parts.joined(separator: ", ")
    }

    // The second line: the branch when there is one to name, otherwise a word for the
    // card. A session with nothing behind it yet keeps to the state line alone.
    private var subject: (text: String, isBranch: Bool)? {
        if showsBranch, let branch = facts.namedBranch { return (branch, true) }
        return facts.isEmpty ? nil : ("Session details", false)
    }

    private var pill: some View {
        let shape = RoundedRectangle(cornerRadius: Self.pillRadius)
        return HStack(spacing: 8) {
            StateRail(tone: state.tone)
            CappedWidth(limit: maxWidth) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        StatusCaps(text: state.word, tint: state.tone.wordColour, size: 9.5)
                        if state.since != nil {
                            StatusDot(size: 9.5)
                            if state.ticks {
                                TimelineView(.periodic(from: .now, by: 1)) { _ in
                                    elapsed
                                }
                            } else {
                                elapsed
                            }
                        }
                    }
                    if let subject {
                        HStack(spacing: 5) {
                            if subject.isBranch {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(subject.text)
                                .font(.mono(11))
                                .foregroundStyle(subject.isBranch ? .primary : .secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .frame(height: Self.pillHeight)
        // At rest the block is only its words and its rail, which is what lets it sit at
        // the end of the deck without a second shape. The surface arrives with the card.
        .background(shape.fill(isOpen ? Theme.sunken : .clear))
        .overlay(shape.strokeBorder(isOpen ? Theme.border : .clear))
        .contentShape(shape)
    }

    private var elapsed: some View {
        StatusValue(text: state.shortElapsed ?? "", size: 9.5)
            .monospacedDigit()
            .fixedSize()
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
        .offset(y: Self.pillHeight)
        .onHover { pointerOnCard = $0; pointerMoved() }
        .transition(.fadeIn)
    }

    private var card: some View {
        VStack(spacing: 0) {
            let rows = self.rows
            head(hasRows: !rows.isEmpty)
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

    // The card's head answers both halves of the pill at a size that can be read: the
    // state with its precise time and the clock time it began, then the name the pill
    // truncated, with the one action that takes it out of the app beside it.
    private func head(hasRows: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                if state.tone == .running {
                    PulsingDot(size: 7)
                } else {
                    StateLight(tone: state.tone, size: 7)
                }
                StatusCaps(text: state.word, tint: state.tone.wordColour)
                if let since = state.since {
                    if state.ticks {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            preciseElapsed(since, now: context.date)
                        }
                    } else {
                        preciseElapsed(since, now: .now)
                    }
                    Spacer(minLength: 6)
                    Text(SessionStateReading.sinceLine(since, tone: state.tone))
                        .font(.mono(10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if let branch = facts.namedBranch {
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
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sunken)
        .overlay(alignment: .bottom) { if hasRows { rule } }
    }

    private func preciseElapsed(_ since: Date, now: Date) -> some View {
        StatusValue(text: SessionStateReading.preciseElapsed(now.timeIntervalSince(since)))
            .monospacedDigit()
            .fixedSize()
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
            .hoverLift()
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
            .hoverLift()
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
        row(facts.agent.asksPermissions ? "CONTEXT" : "WINDOW") {
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

// Offers its content no more than `limit` points and then takes only what the content
// used. A flexible frame would cap it too, but grows to fill whatever it is offered, so
// a short branch would leave the pill as wide as a long one.
private struct CappedWidth: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(proposal.width ?? limit, limit)
        return content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        subviews.first?.place(at: bounds.origin,
                              proposal: ProposedViewSize(width: bounds.width,
                                                         height: bounds.height))
    }
}

// MARK: - The rail

// The thin mark at the head of the pill, in the state's colour. It flows while the agent
// works and is an outline while it waits, the same difference the light's pulse makes
// elsewhere. The word beside it always says the same thing, so the rail is never the
// only way the state is told.
struct StateRail: View {
    let tone: SessionTone

    static let width: CGFloat = 3
    static let height: CGFloat = 22

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 1.5)
        Group {
            switch tone {
            case .waiting:
                shape.strokeBorder(tone.wordColour, lineWidth: 1)
            case .running where !reduceMotion:
                FlowingRail(colour: tone.wordColour).clipShape(shape)
            default:
                shape.fill(tone.wordColour)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct FlowingRail: NSViewRepresentable {
    let colour: Color

    func makeNSView(context: Context) -> FlowingRailView { FlowingRailView() }

    func updateNSView(_ view: FlowingRailView, context: Context) {
        view.update(colour: colour.resolve(in: context.environment).cgColor)
    }
}

// A gradient twice the rail's height, with the same pattern in each half, slides up by
// one half and starts over, so the loop has no seam.
final class FlowingRailView: LoopLayerView {
    static let period: CFTimeInterval = 2.2

    private let gradient = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = true
        layer?.addSublayer(gradient)
    }

    var loops: [String] { gradient.animationKeys() ?? [] }

    func update(colour: CGColor) {
        let faded = colour.copy(alpha: colour.alpha * 0.35) ?? colour
        LayerLoop.still { gradient.colors = [colour, faded, colour, faded, colour] }
    }

    override func layoutLayers() {
        gradient.frame = CGRect(x: 0, y: 0, width: bounds.width, height: StateRail.height * 2)
    }

    override func restartLoops() {
        let flow = CABasicAnimation(keyPath: "transform.translation.y")
        flow.fromValue = 0
        flow.toValue = -StateRail.height
        flow.duration = Self.period
        gradient.add(LayerLoop.repeating(flow, period: Self.period), forKey: "flow")
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
