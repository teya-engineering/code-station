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

// MARK: - The pill

// What the session is up to: its state over the branch it is on, with every other fact
// it is looked up by in the card behind it. The two readings answer one question, so they
// are one target. It keeps one shape and one place on the deck while the values inside
// it change, so it is a target that can be learned rather than a label that moves.
struct SessionFactsChip: View {
    let facts: SessionFacts
    let state: SessionStateReading
    let session: ChatSession
    let repositoryCount: Int
    let openWorkingSet: () -> Void
    let reviewRequest: () -> Void
    // How wide the branch is allowed to grow before it truncates. A narrow pane hands it
    // less, and a name too long for either cuts from the tail: the end of a branch name
    // is the part that repeats across a project.
    var maxWidth: CGFloat = 210
    var showsBranch = true
    let openChanges: () -> Void
    let contextActions: () -> [MenuEntry]
    let usageTooltip: () -> Tooltip
    // The PR row opens the browser, which leaves nothing in the window to show the click
    // worked, so the header shows a note instead.
    var showNote: (String) -> Void = { _ in }

    // The card hangs off the pill rather than being placed by a presenter: it belongs to
    // this corner of the band, and nothing above the band can clip it.
    private static let pillHeight: CGFloat = 36
    private static let pillRadius: CGFloat = 9
    private static let cardGap: CGFloat = 7
    private static let labelWidth: CGFloat = 62
    // Context and every usage window share one column, so the meters read down the card
    // as one scale rather than as bars that happen to be near each other.
    private static let meterWidth: CGFloat = 240
    private static let radius: CGFloat = 12
    // Strong enough to read on the cream card, still a step under the values.
    private static let labelInk = Color.primary.opacity(0.42)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AccountUsageMonitor.self) private var usageMonitor: AccountUsageMonitor?
    @Environment(MenuPresenter.self) private var menus
    @Environment(ToolCallDetailPresenter.self) private var toolDetails
    @FocusedValue(\.sessionFactsPreview) private var focusedPreview
    @FocusState private var chipFocused: Bool
    private enum PreviewControl: Hashable { case pin, close, status, workingSet }
    @FocusState private var previewControl: PreviewControl?
    @State private var focusDismissed = false
    @State private var showsDetails = false
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
        !focusDismissed && (chipFocused || focusedPreview == session.id)
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
            .onChange(of: chipFocused || focusedPreview == session.id) { _, focused in
                if !focused { focusDismissed = false }
                pointerMoved()
            }
            .background(SessionFactsBoundary(cardAnchor: cardAnchor, isOpen: isOpen,
                dismiss: {
                    if !menus.isOpen && toolDetails.current == nil { closeCard() }
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
                        if menus.isOpen || toolDetails.current != nil { return false }
                        closeCard()
                        chipFocused = true
                        return true
                    }
                } else {
                    escape.stop()
                }
            }
            .onChange(of: session.id) { _, _ in closeCard() }
            .onChange(of: toolDetails.current != nil) { _, showing in
                if showing && isOpen { pinned = true }
            }
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

    // "Running for 5m, branch main, working set preview". The state leads, since it is the
    // half that changes while the session is looked at.
    static func accessibilityLabel(state: SessionStateReading, facts: SessionFacts,
                                   showsBranch: Bool) -> String {
        var parts = [state.shortElapsed.map { "\(state.spokenWord) for \($0)" }
                         ?? state.spokenWord]
        if showsBranch, let branch = facts.namedBranch { parts.append("branch \(branch)") }
        parts.append("working set preview")
        if !facts.pullRequests.isEmpty {
            parts.append("\(facts.pullRequestCountLabel) pull requests")
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
        return HStack(spacing: 8) {
            StateRail(tone: state.tone)
            CappedWidth(limit: maxWidth) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        StatusCaps(text: state.word, tint: state.tone.wordColour, size: 9.5)
                            .contentTransition(.opacity)
                            .motion(Motion.control, value: state.word)
                        if let since = state.since {
                            StatusDot(size: 9.5)
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
            if !facts.pullRequests.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.pull")
                    Text("\(facts.pullRequestCountKnown ? facts.pullRequestCount : facts.pullRequests.count)")
                        .contentTransition(.numericText())
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
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

    private func elapsedLabel(_ text: String) -> some View {
        StatusValue(text: text, size: 9.5)
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
        .background(FrameAnchorView(anchor: cardAnchor, identifier: "Working set preview"))
        .focusedValue(\.sessionFactsPreview, session.id)
        .contentShape(Rectangle())
        .onPointerHover { pointerOnCard = $0; pointerMoved() }
        .transition(.popover(reduceMotion: reduceMotion))
    }

    private var card: some View {
        VStack(spacing: 0) {
            previewHeading.frame(height: 60)
            MenuContentScrollView(maxHeight: max(0, layout.height - 113)) {
                VStack(spacing: 0) {
                    Button { showsDetails.toggle() } label: {
                        HStack {
                            Text(state.spokenWord + (facts.namedBranch.map { " · \($0)" } ?? ""))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showsDetails ? 90 : 0))
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(state.tone.wordColour)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($previewControl, equals: .status)
                    .focusEffectDisabled()
                    .overlay(FocusRingStroke(focused: previewControl == .status))
                    .hoverFill()
                    .accessibilityLabel("Session status and branch")
                    .accessibilityValue(showsDetails ? "Expanded" : "Collapsed")
                    if showsDetails {
                        head(hasRows: false)
                            .transition(reduceMotion ? .opacity : .fold)
                    }
                    SessionWorkingSetPreview(session: session, state: state,
                                             reviewRequest: acting(reviewRequest))
                    rule
                    if let changes = facts.changes { changesRow(changes) }
                    pullRequestsSection
                    VStack(spacing: 0) {
                        if let usageMonitor, usageMonitor.supports(facts.agent) {
                            usageRow(usageMonitor)
                        }
                        if let context = facts.context { contextRow(context) }
                        if let usageMonitor, usageMonitor.supports(facts.agent) {
                            Text("\(facts.agent.title) account usage")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 13)
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
            }
            .motion(showsDetails ? Motion.reveal : Motion.leave, value: showsDetails)
            rule
            HStack {
                Text(pinned ? "Pinned. Esc to dismiss" : "Hover to preview")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                Spacer(minLength: 4)
                ActionButton(title: "Open working set", tone: .green, height: 28, size: 11,
                             icon: "sidebar.right", action: acting(openWorkingSet))
                    .focused($previewControl, equals: .workingSet)
                    .focusEffectDisabled()
                    .overlay(FocusRingStroke(focused: previewControl == .workingSet))
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
        }
        .frame(width: layout.width, alignment: .leading)
        .floatingCard(cornerRadius: Self.radius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Working set preview")
    }

    private var previewHeading: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Working set").font(.system(size: 14, weight: .semibold))
                Text([facts.model.map { "\(facts.agent.title) / \($0)" } ?? facts.agent.title,
                      repositoryCount > 0 ? counted(repositoryCount, "repository", plural: "repositories") : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            GlyphButton(icon: pinned ? "pin.fill" : "pin", side: 24, active: pinned) {
                if pinned { closeCard() } else { pinned = true }
            }
            .focused($previewControl, equals: .pin)
            .focusEffectDisabled()
            .overlay(FocusRingStroke(focused: previewControl == .pin))
            .accessibilityLabel(pinned ? "Unpin working set preview" : "Pin working set preview")
            GlyphButton(icon: "xmark", side: 24) {
                closeCard()
                chipFocused = true
            }
            .focused($previewControl, equals: .close)
            .focusEffectDisabled()
            .overlay(FocusRingStroke(focused: previewControl == .close))
            .accessibilityLabel("Close working set preview")
        }
        .padding(13)
        .motion(Motion.control, value: pinned)
    }

    private var pullRequestsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Pull requests").fontWeight(.semibold)
                Spacer()
                Text(facts.pullRequestCountLabel).foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 13)
            .padding(.top, 9)
            if facts.pullRequests.isEmpty {
                Text("No pull requests yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
            } else {
                ForEach(facts.pullRequests, id: \.url) { pullRequest in
                    pullRequestRow(pullRequest)
                }
            }
        }
        .padding(.bottom, 6)
        .overlay(alignment: .top) { rule }
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
                        .background { if !reduceMotion { BrandSweep(trigger: copies) } }
                    Spacer(minLength: 6)
                    CopyButton(size: 10, onCopy: branchCopied) { branch }
                        .appTooltip("Copy the branch name.")
                        .overlay { if !reduceMotion { CopyBurst(trigger: copies) } }
                        .overlay(alignment: .trailing) {
                            if showsCopied {
                                Text("Copied")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.dotOnText)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.card))
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
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
        .padding(.horizontal, 13)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sunken)
        .overlay(alignment: .bottom) { if hasRows { rule } }
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
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Self.labelInk)
            .frame(width: Self.labelWidth, alignment: .leading)
    }

    private func row<Content: View>(_ label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            self.label(label)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .frame(height: 34)
    }

    private func changesRow(_ changes: SessionFacts.Changes) -> some View {
        row("Changes") {
            CardLink(action: acting(openChanges)) { _ in
                HStack(spacing: 7) {
                    if changes.files == 0 && changes.added == 0 && changes.removed == 0 {
                        Text("No changes").font(.system(size: 12))
                    } else if changes.files > 0 {
                        Text(counted(changes.files, "changed file"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    if changes.added != 0 || changes.removed != 0 {
                        DiffPair(added: changes.added, removed: changes.removed, size: 10.5)
                    }
                }
                .lineLimit(1)
            }
            .disabled(changes.files == 0 && changes.added == 0 && changes.removed == 0)
            .appTooltip("Opens Changes.")
        }
    }

    // Pull requests are stacked one to a row and share the label, which is what keeps a
    // list of them reading as one fact about the session.
    private func pullRequestRow(_ pullRequest: PullRequest) -> some View {
        let status = facts.pullRequestStatuses[pullRequest.url]
        return CardLink(action: acting {
            guard let url = URL(string: pullRequest.url) else { return }
            NSWorkspace.shared.open(url)
            showNote("Opened \(pullRequest.repository.map { "\($0) " } ?? "")#\(pullRequest.number) in the browser")
        }) { _ in
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.pull").foregroundStyle(Theme.accent)
                Text(pullRequest.repository ?? "Repository unavailable")
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: "#\(pullRequest.number)").font(.mono(11))
                Text(status?.readinessLabel ?? "Linked")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.field))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 5)
    }

    private func costRow(_ cost: Double) -> some View {
        row("Cost") {
            HStack(spacing: 10) {
                Text(Money.short(cost))
                    .font(.mono(11.5))
                Text("spent this session")
                    .font(.system(size: 11))
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
        return HStack(spacing: 12) {
            label("Usage")
            Spacer(minLength: 0)
            Text(status)
                .font(.mono(10.5))
                .foregroundStyle(problem == nil || checking
                                 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.attentionText))
                .lineLimit(1)
                .motion(Motion.hover, value: status)
            UsageRefreshButton(checking: checking) { checkUsage(monitor) }
            .appTooltip("Check \(agent.title)'s account limits now.")
            .accessibilityLabel("Check \(agent.title) usage")
        }
        .padding(.horizontal, 13)
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
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.problemLine(problem, lastReading: monitor.usage[agent]?.checkedAt))
                    .fixedSize(horizontal: false, vertical: true)
                InlineLink(title: "Try again", size: 11.5) { refresh() }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.warningText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warningBackground))
            .padding(.horizontal, 13)
            .padding(.top, 9)
            .padding(.bottom, 11)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your plan's limits load only when you ask.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                ActionButton(title: "Check usage", tone: .outlined, height: 24, size: 11,
                             icon: "arrow.clockwise") { refresh() }
            }
            .padding(.horizontal, 13)
            .padding(.top, 10)
            .padding(.bottom, 12)
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
        return HStack(alignment: .top, spacing: 12) {
            Text(window.shortTitle ?? window.title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.labelWidth, height: 15, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    LedgerMeter(fraction: window.usedFraction, colour: window.colour,
                                pace: window.elapsedFraction(now: now), shimmering: checking)
                        .frame(maxWidth: Self.meterWidth)
                    percent(window.usedPercent, colour: window.colour)
                }
                .frame(height: 15)
                if let caption = Self.windowCaption(pace: pace, resets: resets) {
                    caption
                        .font(.mono(9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.top, 8)
        .padding(.bottom, 7)
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
            .font(.mono(11, .semibold))
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
            HStack(spacing: 8) {
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
                        .font(.system(size: 10))
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
        return HStack(spacing: 10) {
            LedgerMeter(fraction: fraction, colour: colour)
                .frame(maxWidth: Self.meterWidth)
            HStack(spacing: 4) {
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
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Theme.field : .clear))
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
        let shape = RoundedRectangle(cornerRadius: 6)
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
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// A ring that bursts out of the copy button as the tick lands. It is drawn over the
// button rather than inside it, so the button itself is never scaled.
private struct CopyBurst: View {
    let trigger: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
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
