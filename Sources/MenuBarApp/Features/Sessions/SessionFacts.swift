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
    var pullRequestStatuses: [String: PullRequestStatus] = [:]
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

    var pullRequestCount: Int {
        pullRequests.count { pullRequestStatuses[$0.url]?.state == .open }
    }

    var pullRequestCountKnown: Bool {
        pullRequests.allSatisfy { pullRequestStatuses[$0.url] != nil }
    }

    var pullRequestCountLabel: String {
        return pullRequestCountKnown ? "\(pullRequestCount) open" : "\(pullRequests.count) linked"
    }

    func pullRequestTone(_ pullRequest: PullRequest) -> PullRequestTone {
        PullRequestTone(pullRequestStatuses[pullRequest.url])
    }

    // The pull request the chip names: the one that most needs the person, and of two that
    // need them as much, the one the card lists first.
    var leadPullRequest: PullRequest? {
        orderedPullRequests.map { ($0, pullRequestTone($0).urgency) }.min { $0.1 < $1.1 }?.0
    }

    // How many more the chip counts beside its lead. It counts what the card's heading
    // counts, so the two never disagree: the open ones once every state is known, and
    // every linked one until then. A merged or closed lead means none are open.
    var pullRequestsBesideLead: Int {
        max((pullRequestCountKnown ? pullRequestCount : pullRequests.count) - 1, 0)
    }

    // "1 changes requested, 2 in review", most pressing first, so VoiceOver hears the mix
    // the card holds without opening it.
    var spokenPullRequestStates: String {
        Dictionary(grouping: pullRequests.map(pullRequestTone), by: { $0 })
            .sorted { $0.key.urgency < $1.key.urgency }
            .map { "\($0.value.count) \($0.key.word.lowercased())" }
            .joined(separator: ", ")
    }

    // The pull requests that may still need the person come first, right under the count
    // that counts them, and the merged and closed ones follow. Each group runs newest
    // first. One whose state is not known yet might still need them, so it waits with the
    // open ones rather than being filed away. The badge on every row is what the order
    // follows, so the order explains itself.
    //
    // Newest means when GitHub says it was opened. The stored list is not in that order:
    // one found for the checkout's branch is kept behind the ones read from the
    // transcript, however old it is. One with no date has not been read from GitHub yet,
    // which mostly means it was only just linked, so it counts as the newest.
    var orderedPullRequests: [PullRequest] {
        let newestFirst = Array(pullRequests.reversed()).enumerated().sorted { a, b in
            switch (pullRequestStatuses[a.element.url]?.createdAt, pullRequestStatuses[b.element.url]?.createdAt) {
            case let (first?, second?) where first != second: first > second
            case (nil, _?): true
            case (_?, nil): false
            default: a.offset < b.offset
            }
        }.map(\.element)
        return newestFirst.filter { !isSettled($0) } + newestFirst.filter(isSettled)
    }

    // The order a card opened with, kept while it stays open, so a state that arrives
    // meanwhile does not move a row out from under the pointer. A pull request linked
    // since joins the rows that have not moved where its group belongs: on top if it may
    // still need the person, at the bottom if it is already merged or closed. One that
    // has gone is simply left out.
    func pullRequests(holding held: [String]) -> [PullRequest] {
        let place = Dictionary(held.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let current = orderedPullRequests
        let arrived = current.filter { place[$0.url] == nil }
        let kept = current.compactMap { pullRequest in place[pullRequest.url].map { ($0, pullRequest) } }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
        return arrived.filter { !isSettled($0) } + kept + arrived.filter(isSettled)
    }

    private func isSettled(_ pullRequest: PullRequest) -> Bool {
        switch pullRequestStatuses[pullRequest.url]?.state {
        case .merged?, .closed?: true
        case .open?, nil: false
        }
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
    var completionActivity: SessionCompletionActivity?
    var isNew = false

    var word: String {
        if isNew && tone == .idle { return "NEW SESSION" }
        if diagnosing && tone == .running && completionActivity == nil { return "DIAGNOSING" }
        return tone.word(completionActivity: completionActivity)
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

extension SessionFacts {
    // Read from the session and from what git last said about each of its folders:
    // `snapshots` has one entry for each folder, lead checkout first, and nil where git
    // has not answered yet.
    //
    // The lead checkout is the one the branch speaks for. A worktree session knows its
    // branch from creation, so the branch can draw on the first frame instead of waiting
    // for git and shifting the chip.
    init(session: ChatSession, snapshots: [GitSnapshot?], reviews: [PullRequestReviewStore.Loaded],
         modelTitle: (String) -> String, showsCost: Bool) {
        let answered = snapshots.compactMap { $0 }
        let hasSnapshots = !snapshots.isEmpty && answered.count == snapshots.count
        self.init(
            branch: (snapshots.first ?? nil)?.branch
                ?? session.worktreeBranch
                ?? session.sessionProjects?.compactMap(\.worktreeBranch).first,
            changes: Changes(snapshots: answered, summary: session.summary)
                ?? (hasSnapshots ? .init(files: 0, added: 0, removed: 0) : nil),
            pullRequests: session.pullRequests,
            pullRequestStatuses: Dictionary(reviews.map { ($0.pullRequest.url, $0.status) },
                                            uniquingKeysWith: { first, _ in first }),
            model: session.usage?.model(for: session.agent).map(modelTitle),
            cost: showsCost ? session.usage?.costUSD : nil,
            context: session.usage?.contextFraction(for: session.agent),
            agent: session.agent)
    }
}

extension SessionFacts.Changes {
    // How far the working tree has moved, for the Changes tab and for the card behind the
    // branch. Until git has answered for this tree, the transcript's own running total
    // stands in - the same numbers the session's sidebar row shows - so the counts arrive
    // with the deck instead of a few seconds later. That total has no file count and can
    // disagree with the tree (it keeps counting across commits and repeat edits), so it
    // is only a stand-in until the first snapshot lands and corrects it.
    init?(snapshots: [GitSnapshot], summary: SessionSummary) {
        guard !snapshots.isEmpty else {
            guard summary.added > 0 || summary.removed > 0 else { return nil }
            self.init(files: 0, added: summary.added, removed: summary.removed)
            return
        }
        let files = snapshots.reduce(0) { $0 + $1.files.count }
        guard files > 0 else { return nil }
        self.init(files: files,
                  added: snapshots.reduce(0) { $0 + $1.totalAdded },
                  removed: snapshots.reduce(0) { $0 + $1.totalRemoved })
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
    let sessionID: UUID
    let repositoryCount: Int
    // How wide the branch is allowed to grow before it truncates. A narrow pane hands it
    // less, and a name too long for either cuts from the tail: the end of a branch name
    // is the part that repeats across a project.
    var maxWidth: CGFloat = 210
    var showsBranch = true
    let openChanges: () -> Void
    let contextActions: () -> [MenuEntry]
    let usageTooltip: () -> Tooltip
    var attachProject: (() -> Void)? = nil
    var attachDisabled = false
    // The PR row opens the browser, which leaves nothing in the window to show the click
    // worked, so the header shows a note instead.
    var showNote: (String) -> Void = { _ in }

    // The card hangs off the pill rather than being placed by a presenter: it belongs to
    // this corner of the band, and nothing above the band can clip it.
    private static let pillHeight = ControlHeight.xl
    private static let pillRadius = Radius.card
    private static let cardGap = Space.md
    private static let labelWidth: CGFloat = 62
    // Context and every usage window share one column, so the meters read down the card
    // as one scale rather than as bars that happen to be near each other.
    private static let meterWidth: CGFloat = 240
    private static let radius = Radius.floating
    // The least room the pull requests keep when a short window squeezes them, a few rows
    // and part of the next, so the list still reads as one that goes on.
    private static let pullRequestFloor = ControlHeight.lg * 3
    // Strong enough to read on the cream card, still a step under the values.
    private static let labelInk = Color.primary.opacity(0.42)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AccountUsageMonitor.self) private var usageMonitor: AccountUsageMonitor?
    @Environment(MenuPresenter.self) private var menus
    @FocusedValue(\.sessionFactsPreview) private var focusedPreview
    @FocusState private var chipFocused: Bool
    private enum PreviewControl: Hashable { case attach, pin, close }
    @FocusState private var previewControl: PreviewControl?
    @State private var focusDismissed = false
    @State private var layout = SessionFactsLayout()
    @State private var cardAnchor = FrameAnchor()

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
    @State private var copies = 0
    @State private var showsCopied = false
    @State private var copiedReset: Task<Void, Never>?
    // How much of the window a compact or a clear just gave back, said beside the meter
    // for a moment so the drop reads as the action working rather than as a glitch.
    @State private var freed: Int?
    @State private var freedReset: Task<Void, Never>?

    private var focusInside: Bool {
        !focusDismissed && (chipFocused || focusedPreview == sessionID)
    }

    private var isOpen: Bool { pinned || hovering || focusInside }

    var body: some View {
        Button {
            if pinned {
                closeCard()
            } else {
                pinned = true
            }
        } label: {
            pill
                .offset(y: pointerOnChip && !reduceMotion ? -1 : 0)
                .motion(Motion.hover, value: pointerOnChip)
        }
            .buttonStyle(.plain)
            .focused($chipFocused)
            .focusEffectDisabled()
            .overlay(FocusRingStroke(focused: chipFocused))
            .onChange(of: chipFocused || focusedPreview == sessionID) { _, focused in
                if !focused { focusDismissed = false }
                pointerMoved()
            }
            .background(SessionFactsBoundary(cardAnchor: cardAnchor, isOpen: isOpen,
                dismiss: {
                    if !menus.isOpen { closeCard() }
                }, resized: { layout = $0 }))
            .onPointerHover { pointerOnChip = $0; pointerMoved() }
            .accessibilityLabel(Self.accessibilityLabel(
                state: state, facts: facts, showsBranch: showsBranch))
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .background(WindowAnchor(monitor: escape))
            .overlay(alignment: .topTrailing) {
                ZStack {
                    if isOpen { hoverCard }
                }
                .offset(y: Self.pillHeight)
            }
            .motion(isOpen ? Motion.reveal : Motion.leave, value: isOpen)
            .onChange(of: facts.context) { old, new in
                guard let old, let new else { return }
                let given = Int(((old - new) * 100).rounded())
                guard given >= 1 else { return }
                freed = given
                freedReset?.cancel()
                freedReset = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    freed = nil
                }
            }
            .onChange(of: isOpen) { _, open in
                if open {
                    escape.start {
                        if menus.isOpen { return false }
                        closeCard()
                        chipFocused = true
                        return true
                    }
                } else {
                    escape.stop()
                }
            }
            .onChange(of: sessionID) { _, _ in closeCard() }
            .onDisappear {
                closing?.cancel()
                copiedReset?.cancel()
                freedReset?.cancel()
                escape.stop()
            }
    }

    // The chip and the card are two hover areas that meet along one edge, and AppKit
    // reports leaving the first before entering the second. Taken at face value that
    // pair of events closes the card on the way into it, so leaving is given a moment
    // to be contradicted.
    private func pointerMoved() {
        closing?.cancel()
        guard !pointerOnChip, !pointerOnCard, !focusInside else {
            hovering = true
            return
        }
        closing = Task {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, !pointerOnChip, !pointerOnCard, !focusInside else { return }
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
        if !facts.pullRequests.isEmpty {
            parts.append("pull requests: \(facts.spokenPullRequestStates)")
        }
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
        return HStack(spacing: Space.md) {
            StateRail(tone: state.tone)
            CappedWidth(limit: maxWidth) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Space.xs) {
                        StatusCaps(text: state.word, tint: state.tone.wordColour, size: Typography.Size.micro)
                            .contentTransition(.opacity)
                            .motion(Motion.control, value: state.word)
                        if let since = state.since {
                            StatusDot(size: Typography.Size.micro)
                            if state.ticks {
                                TickingReading(since: since, reading: RelativeTime.duration(since:now:)) {
                                    elapsedLabel($0)
                                }
                            } else {
                                elapsedLabel(state.shortElapsed ?? "")
                            }
                        }
                    }
                    if let subject {
                        HStack(spacing: Space.xs) {
                            if subject.isBranch {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(subject.text)
                                .font(Typography.data)
                                .foregroundStyle(subject.isBranch ? .primary : .secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
            if let lead = facts.leadPullRequest {
                pullRequestLight(lead)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
        .padding(.leading, Space.md)
        .padding(.trailing, Space.md)
        .frame(height: Self.pillHeight)
        // At rest the block is only its words and its rail, which is what lets it sit at
        // the end of the deck without a second shape. The surface arrives with the card.
        .background(shape.fill(isOpen ? Theme.sunken : .clear))
        .overlay(shape.strokeBorder(isOpen ? Theme.border : .clear))
        .contentShape(shape)
    }

    // The pull request that most needs the person, as one light in its colour, and how many
    // more the card's heading counts. The pull glyph comes first, so the light is never
    // read as the session's own. A new state arrives from a background read, which the
    // person did not cause, so it takes its place without motion.
    private func pullRequestLight(_ lead: PullRequest) -> some View {
        let tone = facts.pullRequestTone(lead)
        let more = facts.pullRequestsBesideLead
        return HStack(spacing: Space.xs) {
            PullRequestMark(symbol: .pull, size: Typography.Size.micro)
                .foregroundStyle(.tertiary)
            PullRequestLight(colour: tone.dot, isRing: tone.dotIsRing)
            if more > 0 {
                Text(verbatim: "+\(more)")
                    .font(Typography.micro)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    private func elapsedLabel(_ text: String) -> some View {
        StatusValue(text: text, size: Typography.Size.micro)
            .monospacedDigit()
            .fixedSize()
    }

    private var hoverCard: some View {
        VStack(spacing: 0) {
            // The gap belongs to the hover area rather than sitting between two of them,
            // so moving down into the card does not cross a strip of nothing and take
            // the card away on the way.
            Color.clear.frame(width: layout.width, height: Self.cardGap)
            card
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(FrameAnchorView(anchor: cardAnchor, identifier: "Session details"))
        .focusedValue(\.sessionFactsPreview, sessionID)
        .contentShape(Rectangle())
        .onPointerHover { pointerOnCard = $0; pointerMoved() }
        .transition(.popover(reduceMotion: reduceMotion))
    }

    private var card: some View {
        VStack(spacing: 0) {
            previewHeading.frame(height: Theme.headerHeight)
            // The pull requests scroll inside their own section, so the rest of the card
            // stays put however many there are. The body keeps a scroll of its own only
            // for a window too short to hold even that.
            MenuContentScrollView(maxHeight: bodyHeight) {
                LeftoverHeightStack(available: bodyHeight, floor: Self.pullRequestFloor) {
                    VStack(spacing: 0) {
                        head
                        if let changes = facts.changes { changesRow(changes) }
                        pullRequestsHeading
                    }
                    pullRequestList
                    usageSection
                }
            }
        }
        .frame(width: layout.width, alignment: .leading)
        .floatingCard(cornerRadius: Self.radius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session details")
    }

    private var previewHeading: some View {
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Session details").font(Typography.body.weight(.semibold))
                Text([facts.model.map { "\(facts.agent.title) / \($0)" } ?? facts.agent.title,
                      repositoryCount > 0 ? counted(repositoryCount, "repository", plural: "repositories") : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(Font.system(size: Typography.Size.micro))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.xs)
            if let attachProject {
                GlyphButton(icon: "plus.rectangle.on.folder", side: ControlHeight.sm) {
                    closeCard()
                    chipFocused = true
                    attachProject()
                }
                .disabled(attachDisabled)
                .focused($previewControl, equals: .attach)
                .focusEffectDisabled()
                .overlay(FocusRingStroke(focused: previewControl == .attach))
                .appTooltip("Attach project")
                .accessibilityLabel("Attach a project to this session")
            }
            GlyphButton(icon: pinned ? "pin.fill" : "pin", side: ControlHeight.sm, active: pinned) {
                if pinned { closeCard() } else { pinned = true }
            }
            .focused($previewControl, equals: .pin)
            .focusEffectDisabled()
            .overlay(FocusRingStroke(focused: previewControl == .pin))
            .accessibilityLabel(pinned ? "Unpin session details" : "Pin session details")
            GlyphButton(icon: "xmark", side: ControlHeight.sm) {
                closeCard()
                chipFocused = true
            }
            .focused($previewControl, equals: .close)
            .focusEffectDisabled()
            .overlay(FocusRingStroke(focused: previewControl == .close))
            .accessibilityLabel("Close session details")
        }
        .padding(Space.lg)
        .motion(Motion.control, value: pinned)
    }

    private var bodyHeight: CGFloat {
        max(0, layout.height - Theme.headerHeight - Self.cardGap)
    }

    // The heading stays over the list while a long one scrolls under it, so the count
    // is still in view when the rows it counts are not.
    private var pullRequestsHeading: some View {
        HStack {
            Text("Pull requests").fontWeight(.semibold)
            Spacer()
            Text(facts.pullRequestCountLabel).foregroundStyle(.secondary)
        }
        .font(Typography.caption)
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.md)
        .overlay(alignment: .top) { rule }
    }

    @ViewBuilder private var pullRequestList: some View {
        if facts.pullRequests.isEmpty {
            Text("No pull requests yet")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.md + Space.xxs)
                .padding(.bottom, Space.md + Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HeldPullRequestRows(facts: facts) { pullRequestRow($0) }
                }
                .padding(.top, Space.xxs)
                .padding(.bottom, Space.sm)
            }
            .scrollIndicators(.visible)
        }
    }

    // What the account has left, sunken like the head, since it belongs to the account
    // rather than to the session.
    private var usageSection: some View {
        VStack(spacing: 0) {
            if let usageMonitor, usageMonitor.supports(facts.agent) {
                usageRow(usageMonitor)
            }
            if let context = facts.context { contextRow(context) }
            if let usageMonitor, usageMonitor.supports(facts.agent) {
                Text("\(facts.agent.title) account usage")
                    .font(Font.system(size: Typography.Size.micro))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.lg)
                if !usageMonitor.refreshing.contains(facts.agent),
                   usageMonitor.problems[facts.agent] != nil || usageMonitor.usage[facts.agent] == nil {
                    usageNote(usageMonitor)
                }
                ForEach(usageMonitor.usage[facts.agent]?.windows ?? []) { window in
                    usageWindowRow(window, checking: usageMonitor.refreshing.contains(facts.agent))
                }
            }
            if let cost = facts.cost { costRow(cost) }
        }
        .background(Theme.sunken)
    }

    // The card's head answers both halves of the pill at a size that can be read: the
    // state with its precise time and the clock time it began, then the name the pill
    // truncated, with the one action that takes it out of the app beside it.
    private var head: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                if state.tone == .running {
                    PulsingDot(size: 7)
                } else {
                    StateLight(tone: state.tone, size: 7)
                }
                StatusCaps(text: state.word, tint: state.tone.wordColour)
                    .contentTransition(.opacity)
                    .motion(Motion.control, value: state.word)
                if let since = state.since {
                    if state.ticks {
                        TickingReading(since: since, reading: { since, now in
                            SessionStateReading.preciseElapsed(now.timeIntervalSince(since))
                        }) { preciseElapsed($0) }
                    } else {
                        preciseElapsed(SessionStateReading.preciseElapsed(Date().timeIntervalSince(since)))
                    }
                    Spacer(minLength: 6)
                    Text(SessionStateReading.sinceLine(since, tone: state.tone))
                        .font(Typography.data)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if let branch = facts.namedBranch {
                HStack(spacing: Space.sm) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(Typography.micro)
                        .foregroundStyle(.tertiary)
                    Text(branch)
                        .font(Typography.code.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .background { if !reduceMotion { BrandSweep(trigger: copies) } }
                    Spacer(minLength: 6)
                    CopyButton(size: Typography.Size.micro, onCopy: branchCopied) { branch }
                        .appTooltip("Copy the branch name.")
                        .overlay { if !reduceMotion { CopyBurst(trigger: copies) } }
                        .overlay(alignment: .trailing) {
                            if showsCopied {
                                Text("Copied")
                                    .font(Typography.micro)
                                    .foregroundStyle(Theme.dotOnText)
                                    .padding(.horizontal, Space.sm)
                                    .padding(.vertical, Space.xxs)
                                    .background(RoundedRectangle(cornerRadius: Radius.inset).fill(Theme.card))
                                    .overlay(RoundedRectangle(cornerRadius: Radius.inset).strokeBorder(Theme.border))
                                    .fixedSize()
                                    .offset(x: -24)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                                    .transition(.opacity.combined(with: .offset(x: 6)))
                            }
                        }
                        .motion(Motion.reveal, value: showsCopied)
                }
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.md)
        .padding(.bottom, Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sunken)
        .overlay(alignment: .bottom) { rule }
    }

    private func branchCopied() {
        copies += 1
        showsCopied = true
        AccessibilityNotification.Announcement("Copied").post()
        copiedReset?.cancel()
        copiedReset = Task {
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            showsCopied = false
        }
    }

    private func preciseElapsed(_ text: String) -> some View {
        StatusValue(text: text)
            .monospacedDigit()
            .fixedSize()
    }

    private var rule: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    // MARK: - Rows

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Font.system(size: Typography.Size.micro, weight: .medium))
            .foregroundStyle(Self.labelInk)
            .frame(width: Self.labelWidth, alignment: .leading)
    }

    private func row<Content: View>(_ label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: Space.lg) {
            self.label(label)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.lg)
        .frame(height: 34)
    }

    private func changesRow(_ changes: SessionFacts.Changes) -> some View {
        row("Changes") {
            CardLink(action: acting(openChanges)) { _ in
                HStack(spacing: Space.sm) {
                    if changes.files == 0 && changes.added == 0 && changes.removed == 0 {
                        Text("No changes").font(Typography.detail)
                    } else if changes.files > 0 {
                        Text(counted(changes.files, "changed file"))
                            .font(Typography.detail.weight(.medium))
                    }
                    if changes.added != 0 || changes.removed != 0 {
                        DiffPair(added: changes.added, removed: changes.removed, size: Typography.Size.caption)
                    }
                }
                .lineLimit(1)
            }
            .disabled(changes.files == 0 && changes.added == 0 && changes.removed == 0)
            .appTooltip("Opens Changes.")
        }
    }

    // Pull requests are stacked one to a row and share the label, which is what keeps a
    // list of them reading as one fact about the session. The mark and the badge take the
    // state's colour, and the badge spells the state out.
    private func pullRequestRow(_ pullRequest: PullRequest) -> some View {
        let tone = facts.pullRequestTone(pullRequest)
        let repository = pullRequest.repository ?? "Repository unavailable"
        return CardLink(action: acting {
            guard let url = URL(string: pullRequest.url) else { return }
            NSWorkspace.shared.open(url)
            showNote("Opened \(pullRequest.repository.map { "\($0) " } ?? "")#\(pullRequest.number) in the browser")
        }) { _ in
            HStack(spacing: Space.sm) {
                PullRequestMark(symbol: tone.symbol, size: Typography.Size.detail)
                    .foregroundStyle(tone.ink)
                Text(repository)
                    .font(Typography.detail)
                    .lineLimit(1)
                Spacer(minLength: Space.xs)
                Text(verbatim: "#\(pullRequest.number)").font(Typography.data)
                Text(tone.word)
                    .font(Font.system(size: Typography.Size.micro, weight: .medium))
                    .foregroundStyle(tone.ink)
                    .padding(.horizontal, Space.xs)
                    .padding(.vertical, Space.xxs)
                    .background(RoundedRectangle(cornerRadius: Radius.tag).fill(tone.wash))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(repository) pull request \(pullRequest.number), \(tone.word.lowercased()). Opens in the browser.")
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.xs)
    }

    private func costRow(_ cost: Double) -> some View {
        row("Cost") {
            HStack(spacing: Space.md) {
                Text(Money.short(cost))
                    .font(Typography.code)
                Text("spent this session")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // The account's limits are only read when asked for here, so the band says how old
    // the reading is and carries the button that reads it again. It is sunken like the
    // head, since what sits under it belongs to the account rather than to the session.
    private func usageRow(_ monitor: AccountUsageMonitor) -> some View {
        let agent = facts.agent
        let checking = monitor.refreshing.contains(agent)
        let problem = monitor.problems[agent]
        let status = Self.usageStatus(checkedAt: monitor.usage[agent]?.checkedAt,
                                      checking: checking, hasProblem: problem != nil)
        return HStack(spacing: Space.lg) {
            label("Usage")
            Spacer(minLength: 0)
            Text(status)
                .font(Typography.data)
                .foregroundStyle(problem == nil || checking
                                 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.attentionText))
                .lineLimit(1)
                .motion(Motion.hover, value: status)
            UsageRefreshButton(checking: checking) { checkUsage(monitor) }
            .appTooltip("Check \(agent.title)'s account limits now.")
            .accessibilityLabel("Check \(agent.title) usage")
        }
        .padding(.horizontal, Space.lg)
        .frame(height: 34)
        .background(Theme.sunken)
    }

    // "checked 4m ago", or why there is nothing to show yet.
    static func usageStatus(checkedAt: Date?, checking: Bool, hasProblem: Bool) -> String {
        if checking { return "checking…" }
        if hasProblem { return "couldn't check" }
        if let checkedAt {
            let age = RelativeTime.short(checkedAt)
            return age == "now" ? "checked just now" : "checked \(age) ago"
        }
        return "not checked yet"
    }

    // What stands in for the windows when there are none to trust: an offer to read them
    // the first time, or why the last read failed with a way to try again.
    @ViewBuilder private func usageNote(_ monitor: AccountUsageMonitor) -> some View {
        let agent = facts.agent
        let refresh = { checkUsage(monitor) }
        if let problem = monitor.problems[agent] {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(Self.problemLine(problem, lastReading: monitor.usage[agent]?.checkedAt))
                    .fixedSize(horizontal: false, vertical: true)
                InlineLink(title: "Try again", size: Typography.Size.detail) { refresh() }
            }
            .font(Typography.detail)
            .foregroundStyle(Theme.warningText)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.warningBackground))
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.md)
            .padding(.bottom, Space.lg)
        } else {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Your plan's limits load only when you ask.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                ActionButton(title: "Check usage", tone: .outlined, height: ControlHeight.sm, size: Typography.Size.caption,
                             icon: "arrow.clockwise") { refresh() }
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.md)
            .padding(.bottom, Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // A check swaps the note for the windows, so the card changes size under the pointer
    // and AppKit reports the pointer as gone. Held by hover alone, the card would close
    // just as the reading it was opened for arrives.
    private func checkUsage(_ monitor: AccountUsageMonitor) {
        pinned = true
        let agent = facts.agent
        Task { await monitor.refresh(agent) }
    }

    static func problemLine(_ problem: String, lastReading: Date?) -> String {
        guard let lastReading else { return problem }
        let age = RelativeTime.short(lastReading)
        let when = age == "now" ? "just now" : "\(age) ago"
        return "\(problem) The last good reading was \(when)."
    }

    // One window of the account's limits: its name in the label column, the meter in the
    // same column as the context one, and when it resets underneath, so nothing needs a
    // hover to be read. The mark on the meter is where an even pace would be by now.
    private func usageWindowRow(_ window: AccountUsageWindow, checking: Bool) -> some View {
        let now = Date()
        let pace = window.pace(now: now)
        let resets = window.resetsLine(now: now)
        return HStack(alignment: .top, spacing: Space.lg) {
            Text(window.shortTitle ?? window.title)
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.labelWidth, height: 15, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.md) {
                    LedgerMeter(fraction: window.usedFraction, colour: window.colour,
                                pace: window.elapsedFraction(now: now), shimmering: checking)
                        .frame(maxWidth: Self.meterWidth)
                    percent(window.usedPercent, colour: window.colour)
                }
                .frame(height: 15)
                if let caption = Self.windowCaption(pace: pace, resets: resets) {
                    caption
                        .font(Font.mono(Typography.Size.micro))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.md)
        .padding(.bottom, Space.sm)
        .contentShape(Rectangle())
        .appTooltip { Tooltip(title: window.title) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.windowSpoken(window, pace: pace, resets: resets))
        .accessibilityValue("\(window.usedPercent) of 100 percent used")
    }

    private static func windowCaption(pace: AccountUsageWindow.Pace, resets: String?) -> Text? {
        let verdict: Text? = switch pace {
        case .usedUp: Text("Used up.").fontWeight(.semibold).foregroundStyle(Theme.deletion)
        case .ahead: Text("Ahead of pace.").fontWeight(.semibold).foregroundStyle(Theme.attentionText)
        case .steady: nil
        }
        switch (verdict, resets) {
        case (let verdict?, let resets?): return Text("\(verdict) \(resets)")
        case (let verdict?, nil): return verdict
        case (nil, let resets?): return Text(resets)
        case (nil, nil): return nil
        }
    }

    // "Current session, 71% used, ahead of pace, resets in 2h 24m".
    static func windowSpoken(_ window: AccountUsageWindow, pace: AccountUsageWindow.Pace,
                             resets: String?) -> String {
        var parts = ["\(window.title)", "\(window.usedPercent)% used"]
        switch pace {
        case .usedUp: parts.append("used up")
        case .ahead: parts.append("ahead of pace")
        case .steady: break
        }
        if let resets { parts.append(resets) }
        return parts.joined(separator: ", ")
    }

    // A percentage that rolls to its new value, so a fresh reading or a compact is seen
    // moving rather than swapped.
    private func percent(_ value: Int, colour: Color) -> some View {
        Text("\(value)%")
            .font(Typography.data.weight(.semibold))
            .foregroundStyle(colour)
            .contentTransition(reduceMotion ? .identity : .numericText(value: Double(value)))
            .motion(LedgerMeter.fill, value: value)
            .fixedSize()
    }

    // The window is the one reading here that says a session is getting heavy, so it is
    // also where the window is dealt with. It only opens a menu while there is a
    // conversation to work on and nothing running that still holds it.
    @ViewBuilder private func contextRow(_ fraction: Double) -> some View {
        let actions = contextActions()
        row(facts.agent.asksPermissions ? "Context" : "Window") {
            HStack(spacing: Space.md) {
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
                if let freed {
                    Text("freed \(freed)%")
                        .font(Font.system(size: Typography.Size.micro))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .transition(.opacity.combined(with: .offset(y: 3)))
                }
            }
            .motion(Motion.reveal, value: freed)
        }
    }

    private func contextReading(_ fraction: Double, clearable: Bool) -> some View {
        let colour = SessionFacts.contextColour(fraction, agent: facts.agent)
        return HStack(spacing: Space.md) {
            LedgerMeter(fraction: fraction, colour: colour)
                .frame(maxWidth: Self.meterWidth)
            HStack(spacing: Space.xs) {
                percent(Int((fraction * 100).rounded()), colour: colour)
                if clearable {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(colour)
                }
            }
            .fixedSize()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(facts.agent.asksPermissions ? "Session context" : "Session window")
        .accessibilityValue("\(Int((fraction * 100).rounded())) of 100 percent used")
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
        focusDismissed = true
        // An explicit close wins over hover until AppKit reports a fresh pointer entry.
        pointerOnCard = false
        pointerOnChip = false
        hovering = false
    }
}

// MARK: - The card's layout

// The card's body as three parts stacked: the sections above the pull requests, the
// pull requests, and the usage under them. The pull requests are the one part with no
// end to them, so they take the room the other two leave and scroll inside it, down to
// a floor that keeps a few rows in view. Everything is measured in the same pass that
// places it, so the card opens at its final size rather than settling a frame later.
//
// The body sits in a scroll view that hands down no height of its own, so the room
// there is to share is passed in.
private struct LeftoverHeightStack: Layout {
    let available: CGFloat
    let floor: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width
        let heights = self.heights(width: width, subviews: subviews)
        return CGSize(width: width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0,
                      height: heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (subview, height) in zip(subviews, heights(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }

    // Rounded down, so the parts never add up to a hair more than the room and wake the
    // body's own scroll for nothing.
    private func heights(width: CGFloat?, subviews: Subviews) -> [CGFloat] {
        guard subviews.count == 3 else {
            return subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        }
        let natural = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let leftover = (available - natural[0] - natural[2]).rounded(.down)
        let list = min(natural[1], max(floor, leftover))
        return [natural[0], list, natural[2]]
    }
}

// The pull request rows in the order the card opened with. The order lives in the rows'
// own state, which is made when the card arrives and goes when the card has finished
// leaving, so a state that lands while it is open, or while it fades out, does not move
// a row. The next opening sorts afresh.
private struct HeldPullRequestRows<Row: View>: View {
    let facts: SessionFacts
    @ViewBuilder let row: (PullRequest) -> Row

    @State private var held: [String]

    init(facts: SessionFacts, @ViewBuilder row: @escaping (PullRequest) -> Row) {
        self.facts = facts
        self.row = row
        _held = State(initialValue: facts.orderedPullRequests.map(\.url))
    }

    var body: some View {
        ForEach(facts.pullRequests(holding: held), id: \.url, content: row)
    }
}

// MARK: - The card's motion

// A button that dips under the press. Only the label moves, so whatever is attached to
// the button itself, a tooltip or a card hanging off it, is never scaled.
private struct PressDip: ButtonStyle {
    let scale: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .motion(Motion.hover, value: configuration.isPressed)
    }
}

// A value in the card that leads somewhere. It lifts a point and warms under the
// pointer, the way a link on a page does, and hands its content the hover so an arrow
// inside can lean the way it goes.
private struct CardLink<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: (_ hovering: Bool) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        let moving = hovering && !reduceMotion
        Button(action: action) {
            content(moving)
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.xxs)
                .background(RoundedRectangle(cornerRadius: Radius.inset).fill(hovering ? Theme.field : .clear))
                .offset(y: moving ? -1 : 0)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDip(scale: 0.97))
        .focused($focused)
        .overlay(FocusRingStroke(focused: focused))
        .padding(.horizontal, -4)
        .padding(.vertical, -2)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
    }
}

// The card's meter: it fills from empty as the card opens and slides between readings
// after that, so a fresh check or a compact is seen as a change. It can carry the mark
// where an even pace would be by now, and shimmers while a new reading is on its way.
private struct LedgerMeter: View {
    static let fill = Motion.draw
    static let height: CGFloat = 5

    let fraction: Double
    let colour: Color
    var pace: Double? = nil
    var shimmering = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filled = false

    var body: some View {
        Meter(fraction: filled || reduceMotion ? fraction : 0, colour: colour, height: Self.height)
            .motion(Self.fill, value: fraction)
            .overlay {
                if shimmering && !reduceMotion { Shimmer().clipShape(Capsule()) }
            }
            .overlay(alignment: .leading) {
                if let pace {
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.primary.opacity(0.38))
                            .frame(width: 1.5, height: Self.height + 6)
                            .offset(x: geometry.size.width * pace - 0.75, y: -3)
                    }
                    .accessibilityHidden(true)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Self.fill) { filled = true }
            }
    }
}

private struct Shimmer: NSViewRepresentable {
    func makeNSView(context: Context) -> ShimmerView { ShimmerView() }

    func updateNSView(_ view: ShimmerView, context: Context) {}
}

// A band of light half the meter's width that starts just off its left end and runs
// just past its right one, then starts over.
final class ShimmerView: LoopLayerView {
    static let period: CFTimeInterval = 0.9
    static let bandShare: CGFloat = 0.5

    private let band = CAGradientLayer()
    private var sweptWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = true
        band.colors = [NSColor.white.withAlphaComponent(0).cgColor,
                       NSColor.white.withAlphaComponent(0.6).cgColor,
                       NSColor.white.withAlphaComponent(0).cgColor]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(band)
    }

    var loops: [String] { band.animationKeys() ?? [] }

    // How far the band travels depends on the width, so a new width needs a new sweep.
    override func layoutLayers() {
        let width = bounds.width * Self.bandShare
        band.frame = CGRect(x: -width, y: 0, width: width, height: bounds.height)
        guard bounds.width != sweptWidth else { return }
        sweptWidth = bounds.width
        restartLoops()
    }

    override func restartLoops() {
        band.removeAnimation(forKey: "sweep")
        guard sweptWidth > 0 else { return }
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = 0
        sweep.toValue = sweptWidth * (1 + Self.bandShare)
        sweep.duration = Self.period
        band.add(LayerLoop.repeating(sweep, period: Self.period), forKey: "sweep")
    }
}

// The usage band's refresh. While a check is out the glyph gives way to a turning arc and
// the button will not take a second one. The arc is drawn by Core Animation, so it costs
// nothing between frames, and it never turns the button itself, which carries a tooltip.
private struct UsageRefreshButton: View {
    let checking: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hovering = false

    private static let side: CGFloat = 22

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.inset)
        Button(action: action) {
            Group {
                if checking && !reduceMotion {
                    LoopSpinner(colour: Theme.accent, size: 10)
                } else {
                    glyph
                }
            }
            .frame(width: Self.side, height: Self.side)
            .background(shape.fill(hovering && !checking ? Theme.field : Theme.card))
            .overlay(shape.strokeBorder(Theme.border))
            .contentShape(shape)
        }
        .buttonStyle(PressDip(scale: 0.88))
        .disabled(checking)
        .opacity(checking ? 0.55 : 1)
        .focused($focused)
        .overlay(FocusRingStroke(focused: focused))
        .hoverLift(hovering, amount: Motion.smallLift)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
    }

    private var glyph: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Theme.accent)
    }
}

// A band of the brand yellow that runs once across the branch as it is copied, so the
// copy is seen landing on the name and not only on the button.
private struct BrandSweep: View {
    let trigger: Int

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            LinearGradient(colors: [.clear, Theme.brand.opacity(0.55), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: width * 0.4)
                .keyframeAnimator(initialValue: 1.0, trigger: trigger) { band, phase in
                    band
                        .offset(x: width * (phase * 1.4 - 0.4))
                        .opacity(phase >= 1 ? 0 : 1)
                } keyframes: { _ in
                    MoveKeyframe(0)
                    CubicKeyframe(1, duration: 0.6)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.tag))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// A ring that bursts out of the copy button as the tick lands. It is drawn over the
// button rather than inside it, so the button itself is never scaled.
private struct CopyBurst: View {
    let trigger: Int

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.control)
            .strokeBorder(Theme.dotOn, lineWidth: 1.5)
            .padding(-4)
            .keyframeAnimator(initialValue: 1.0, trigger: trigger) { ring, phase in
                ring
                    .scaleEffect(1 + phase * 0.35)
                    .opacity(phase >= 1 ? 0 : 1 - phase)
            } keyframes: { _ in
                MoveKeyframe(0)
                CubicKeyframe(1, duration: 0.5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
    nonisolated static let fuseThreshold = 0.8

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
                        FuseSpark(progressWidth: width, phase: nil, intensity: clamped)
                            .overlay { FuseEmbers(progressWidth: width, intensity: clamped) }
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

// The burning tip of the fuse. It always draws the glow and the tip. Given a phase it
// also draws the embers where they are at that moment, which is how a fuse that is not
// burning holds still; a burning one leaves them to `FuseEmbers`.
private struct FuseSpark: View {
    let progressWidth: CGFloat
    let phase: TimeInterval?
    let intensity: Double

    var body: some View {
        Canvas { context, size in
            let tip = FuseEmber.tip(progressWidth: progressWidth, in: size)
            let heat = FuseEmber.heat(at: intensity)

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

            guard let phase else { return }
            for ember in FuseEmber.all {
                let life = ember.life(at: phase, heat: heat)
                let point = ember.point(at: life, from: tip)
                let diameter = ember.diameter(at: life)
                context.opacity = FuseEmber.fade(at: life)
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - diameter / 2,
                                          y: point.y - diameter / 2,
                                          width: diameter, height: diameter)),
                    with: .color(FuseEmber.isYoung(life) ? Theme.attention : Theme.deletion))
            }
        }
    }
}

// One spark thrown off the fuse's tip. Over its life it flies out along its angle, drops
// a little, shrinks, fades and cools from amber to red, then starts again from the tip.
struct FuseEmber {
    let angle: Double
    let distance: Double
    let size: Double
    let speed: Double
    let offset: Double

    static let all = [
        FuseEmber(angle: -2.55, distance: 5.2, size: 1.2, speed: 1.31, offset: 0.08),
        FuseEmber(angle: -2.02, distance: 7.2, size: 1.0, speed: 1.73, offset: 0.43),
        FuseEmber(angle: -1.57, distance: 6.2, size: 1.4, speed: 1.49, offset: 0.71),
        FuseEmber(angle: -1.12, distance: 7.7, size: 0.9, speed: 1.91, offset: 0.24),
        FuseEmber(angle: -0.66, distance: 5.5, size: 1.1, speed: 1.57, offset: 0.59),
    ]

    static func tip(progressWidth: CGFloat, in size: CGSize) -> CGPoint {
        CGPoint(x: min(size.width - 1, progressWidth), y: size.height - 1)
    }

    // How far past the threshold the window is, from 0 to 1. A hotter fuse throws its
    // sparks faster.
    static func heat(at intensity: Double) -> Double {
        min(1, max(0, (intensity - ContextHairline.fuseThreshold) / (1 - ContextHairline.fuseThreshold)))
    }

    static func fade(at life: Double) -> Double { pow(1 - life, 1.7) }

    static func isYoung(_ life: Double) -> Bool { life < 0.45 }

    // Lives each second, so one life lasts the inverse of this.
    func rate(heat: Double) -> Double { speed * (1 + heat * 0.65) }

    func life(at time: TimeInterval, heat: Double) -> Double {
        (time * rate(heat: heat) + offset).truncatingRemainder(dividingBy: 1)
    }

    func point(at life: Double, from tip: CGPoint) -> CGPoint {
        let travelled = distance * life
        return CGPoint(x: tip.x + cos(angle) * travelled,
                       y: tip.y + sin(angle) * travelled - life * life * 1.5)
    }

    func diameter(at life: Double) -> Double {
        size * (0.55 + Self.fade(at: life) * 0.7)
    }
}

// The sparks of a burning fuse, played by Core Animation. Each spark's whole life is laid
// out as keyframes once, then repeats on its own, so the window is not drawn again for
// every frame while a long turn runs near the end of its window.
private struct FuseEmbers: NSViewRepresentable {
    let progressWidth: CGFloat
    let intensity: Double

    func makeNSView(context: Context) -> FuseEmbersView { FuseEmbersView() }

    func updateNSView(_ view: FuseEmbersView, context: Context) {
        view.update(look: .init(progressWidth: progressWidth, heat: FuseEmber.heat(at: intensity),
                                young: Theme.attention.resolve(in: context.environment).cgColor,
                                old: Theme.deletion.resolve(in: context.environment).cgColor))
    }
}

final class FuseEmbersView: LoopLayerView {
    struct Look: Equatable {
        var progressWidth: CGFloat = 0
        var heat: Double = 0
        var young: CGColor = .clear
        var old: CGColor = .clear
    }

    // Enough points along a life that the curve of the flight and the fade read smooth.
    private static let steps = 16

    private var embers: [CAShapeLayer] = []
    private var look = Look()
    private var laidOut = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        for ember in FuseEmber.all {
            let layer = CAShapeLayer()
            let side = ember.diameter(at: 0)
            layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            layer.path = CGPath(ellipseIn: layer.bounds, transform: nil)
            layer.opacity = 0
            self.layer?.addSublayer(layer)
            embers.append(layer)
        }
    }

    var loops: [String] { embers.flatMap { $0.animationKeys() ?? [] } }

    func update(look: Look) {
        guard look != self.look else { return }
        self.look = look
        restartLoops()
    }

    // The tip moves with the window's size, so a new size needs new flights.
    override func layoutLayers() {
        guard bounds.size != laidOut else { return }
        laidOut = bounds.size
        restartLoops()
    }

    override func restartLoops() {
        let tip = FuseEmber.tip(progressWidth: look.progressWidth, in: bounds.size)
        let now = CACurrentMediaTime()
        for (ember, layer) in zip(FuseEmber.all, embers) {
            layer.removeAnimation(forKey: "life")
            guard bounds.width > 0 else { continue }
            let lives = (0...Self.steps).map { Double($0) / Double(Self.steps) }
            let side = ember.diameter(at: 0)

            let flight = CAKeyframeAnimation(keyPath: "position")
            flight.values = lives.map { NSValue(point: ember.point(at: $0, from: tip)) }
            let shrink = CAKeyframeAnimation(keyPath: "transform.scale")
            shrink.values = lives.map { ember.diameter(at: $0) / side }
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = lives.map { FuseEmber.fade(at: $0) }
            let cool = CAKeyframeAnimation(keyPath: "fillColor")
            cool.calculationMode = .discrete
            cool.values = [look.young, look.old]
            cool.keyTimes = [0, 0.45, 1]

            let period = 1 / ember.rate(heat: look.heat)
            let life = CAAnimationGroup()
            life.animations = [flight, shrink, fade, cool]
            life.duration = period
            life.repeatCount = .infinity
            life.isRemovedOnCompletion = false
            // Picks the spark up where the clock says it is, the same as the still fuse
            // and every other loop, rather than starting each one at the tip.
            life.timeOffset = ember.life(at: now, heat: look.heat) * period
            layer.add(life, forKey: "life")
        }
    }
}
