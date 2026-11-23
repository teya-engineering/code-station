import SwiftUI

// What the person settled on in the ask, for the subject they picked.
struct SecondOpinionAskChoice {
    var stop: SecondOpinionStop
    var lineup: [SecondOpinion.Reviewer]
    var chatFocus: [ChatSecondOpinion.Focus]
    var chatReading: ChatSecondOpinion.Reading
    var changesFocus: Set<SecondOpinion.Focus>
    var designFocus: [DesignSecondOpinion.Focus]
    var designReading: DesignSecondOpinion.Reading
    var note: String
    // The reviewers may use the session's MCP servers.
    var usesServers = false
    var scope: SecondOpinionRequest.Scope? = nil
}

struct SecondOpinionAnchorAction {
    let perform: (CGRect) -> Void

    func callAsFunction(_ frame: CGRect) { perform(frame) }
}

struct AskSecondOpinionOnFileAction {
    let perform: (_ root: String, _ path: String) -> Void

    func callAsFunction(_ root: String, _ path: String) { perform(root, path) }
}

extension EnvironmentValues {
    // Where in the session the control that opens an ask sits, recorded as it is pressed
    // so the card can hang off it. A button under an answer only shows while the pointer
    // is on the answer, so its place is taken at the click, not looked up afterwards.
    @Entry var secondOpinionAnchor = SecondOpinionAnchorAction { _ in }
    // Opens the ask on one changed file, from that file's header in Changes. Nil where
    // the Changes screen is not inside a session that can ask.
    @Entry var askSecondOpinionOnFile: AskSecondOpinionOnFileAction? = nil
}

// The anchored ask: one column of choices, each made once, over a receipt of what the
// reviewers will get, with one clear action in the footer.
struct SecondOpinionAskCard: View {
    // The coordinate space the session draws the card in.
    nonisolated static let space = "secondOpinionAsk"
    static let width = ReviewMetrics.askWidth
    static let previewTurns = 5

    let facts: SecondOpinionAskFacts
    @Binding var stop: SecondOpinionStop
    let author: SecondOpinion.Reviewer
    let installed: [AgentKind]
    // Seats already reading the changes, which cannot be asked again until they finish.
    var running: Set<SecondOpinion.Reviewer> = []
    // What Settings says an ask starts from. Tune changes only this ask.
    let defaults: SecondOpinionDefaults
    let ask: (SecondOpinionAskChoice) -> Void
    let close: () -> Void
    let maxHeight: CGFloat

    @State private var context: SecondOpinionContext
    @State private var keptFocus = false
    @State private var retry = 0
    @State private var footerHeight = ControlHeight.lg + Space.pane * 2
    @State private var lineup: [SecondOpinion.Reviewer]
    @State private var usual: [SecondOpinion.Reviewer]
    @State private var chatFocus: Set<ChatSecondOpinion.Focus>
    @State private var chatReading: ChatSecondOpinion.Reading
    @State private var changesFocus: Set<SecondOpinion.Focus>
    @State private var designFocus: Set<DesignSecondOpinion.Focus>
    @State private var designReading: DesignSecondOpinion.Reading
    @State private var usesServers: Bool
    @State private var note = ""
    @State private var receiptFilter = ""
    @State private var noteOpen = false
    @State private var tuning = false
    @Namespace private var subjectTrack
    @FocusState private var tuneFocused: Bool
    @FocusState private var noteFocused: Bool
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(MenuPresenter.self) private var menus
    @Environment(SessionRunner.self) private var runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(facts: SecondOpinionAskFacts, stop: Binding<SecondOpinionStop>, author: SecondOpinion.Reviewer,
         installed: [AgentKind], running: Set<SecondOpinion.Reviewer> = [],
         lineup: [SecondOpinion.Reviewer],
         defaults: SecondOpinionDefaults, startsTuning: Bool = false,
         maxHeight: CGFloat = ReviewMetrics.askHeight,
         ask: @escaping (SecondOpinionAskChoice) -> Void, close: @escaping () -> Void) {
        self.facts = facts
        self._stop = stop
        self.author = author
        self.installed = installed
        self.running = running
        self.ask = ask
        self.close = close
        self.defaults = defaults
        self.maxHeight = maxHeight
        _context = State(initialValue: SecondOpinionContext(facts: facts, comparison: facts.origin == .file ? .changesTab : defaults.comparison))
        _lineup = State(initialValue: lineup)
        _usual = State(initialValue: defaults.lineup)
        _chatFocus = State(initialValue: defaults.chatFocus)
        _chatReading = State(initialValue: defaults.chatReading)
        _changesFocus = State(initialValue: defaults.changesFocus)
        _designFocus = State(initialValue: defaults.designFocus)
        _designReading = State(initialValue: defaults.designReading)
        _usesServers = State(initialValue: defaults.usesServers)
        _tuning = State(initialValue: startsTuning)
    }

    private var stops: [SecondOpinionStop] { SecondOpinionAsk.stops(facts) }

    // A click that reshapes the card runs in one animated transaction, so the rows, the
    // receipt and the card's own height all move together. A modifier on one part would
    // leave the rest, and the scroll view's measured height, to snap.
    private func choose(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : Motion.reveal, change)
    }

    private var asked: [SecondOpinion.Reviewer] {
        SecondOpinionAsk.seated(lineup).filter { stop.kind != .changes || !running.contains($0) }
    }

    private var hasFocus: Bool {
        guard note.isBlank else { return true }
        return switch stop.kind {
        case .chat: !chatFocus.isEmpty
        case .changes: !changesFocus.isEmpty
        case .design: !designFocus.isEmpty
        }
    }

    // Something differs from what a plain click would ask, which the dot on Tune says.
    private var tuned: Bool {
        lineup != usual || !note.isBlank || usesServers != defaults.usesServers
            || chatFocus != defaults.chatFocus || chatReading != defaults.chatReading
            || changesFocus != defaults.changesFocus
            || designFocus != defaults.designFocus || designReading != defaults.designReading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.md) {
                SheetTitle("Second opinion", icon: "eye")
                Spacer(minLength: 0)
                GlyphButton(icon: "xmark", action: close)
                    .appTooltip("Close second opinion")
                    .accessibilityLabel("Close second opinion")
            }
            .padding(.horizontal, Space.pane)
            .headerBand()
            MenuContentScrollView(maxHeight: max(0, maxHeight - Theme.headerHeight - footerHeight)) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    form
                    if tuning { tray.transition(reduceMotion ? .opacity : .fold) }
                    receipt
                }
                .padding(Space.pane)
            }
            footer.padding(.horizontal, Space.pane).padding(.vertical, Space.lg)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
                .background(Theme.card)
                .overlay(alignment: .top) { Divider().overlay(Theme.hairline) }
        }
        .frame(minWidth: 0, idealWidth: Self.width, maxWidth: Self.width, alignment: .leading)
        // The header band and footer are square fills, so the card is clipped to its own
        // corners the way a dialog is.
        .clipShape(RoundedRectangle(cornerRadius: Radius.floating))
        .floatingCard(cornerRadius: Radius.floating)
        .motion(Motion.reveal, value: tuning)
        .background {
            // Escape clears the receipt's filter before it closes the card.
            Button { if receiptFilter.isEmpty { close() } else { receiptFilter = "" } } label: { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask for a second opinion")
        .accessibilityAddTraits(.isModal)
        .focusBoundary(active: dialogs.current == nil && menus.entries.isEmpty)
        .onAppear {
            if lineup.isEmpty, let agent = installed.first(where: { $0 != author.agent }) ?? installed.first {
                seat(agent)
            }
        }
        .task { for agent in installed { await runner.catalog.discoverModels(for: agent) } }
        .task(id: context.refs) { await context.read() }
        .task(id: retry) { if retry > 0 { await context.read() } }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            FormRow {
                rowLabel("Review")
                subjectChoices
            }
            if stop.kind == .changes {
                FormRow {
                    rowLabel("Scope")
                    comparison
                }
                .transition(reduceMotion ? .opacity : .fadeIn)
            }
            FormRow {
                rowLabel("Reviewer")
                seats
            }
            FormRow {
                rowLabel("Look for")
                lookFor
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowLabel(_ title: String) -> some View {
        Text(title).font(Typography.detail).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Space.xs)
    }

    // One track, one pick: the fill slides to the subject chosen.
    private var subjectChoices: some View {
        HStack(spacing: Space.xxs) {
            if stops.contains(where: { $0.kind == .changes }) {
                subjectPill("Changes", icon: "plus.forwardslash.minus", selected: stop.kind == .changes) {
                    stop = facts.file != nil && facts.origin == .file ? .file : .uncommitted
                }
            }
            if facts.answer != nil {
                subjectPill(SecondOpinionAsk.stopTitle(.answer, facts: facts), icon: "text.bubble",
                            selected: stop == .answer) { stop = .answer }
            }
            if stops.contains(.conversation) {
                subjectPill("Whole chat", icon: "bubble.left.and.bubble.right",
                            selected: stop == .conversation) { stop = .conversation }
            }
            if stops.contains(.design) {
                subjectPill("Design", icon: "rectangle.on.rectangle", selected: stop == .design) { stop = .design }
            }
        }
        .padding(Space.xxs)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.control + Space.xxs))
        .motion(Motion.control, value: stop.kind)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What they review")
    }

    private func subjectPill(_ title: String, icon: String, selected: Bool,
                             _ pick: @escaping () -> Void) -> some View {
        ChoicePill(title: title, selected: selected, thumb: subjectTrack, icon: icon) {
            guard !selected else { return }
            choose(pick)
        }
    }

    // MARK: Comparison

    // The comparison reads as one sentence: what, against which branch.
    private var comparison: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            FlowRow(spacing: Space.sm) {
                scopeMenu
                if stop != .sinceReview {
                    Text("against").font(Typography.detail).foregroundStyle(.secondary)
                        .frame(height: ControlHeight.sm)
                    if facts.repositories.count > 1 {
                        ForEach(facts.repositories, id: \.root) { branchMenu($0) }
                    } else {
                        branchMenu(facts.repositories.first)
                    }
                }
            }
            Text(comparisonCaption)
                .font(Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .motion(Motion.control, value: context.comparison)
    }

    private var comparisonCaption: String {
        if stop == .sinceReview { return "What changed after your last review." }
        if stop == .file { return context.usesBranch ? "This file's committed and uncommitted work since you branched."
                                                     : "This file's edits you have not committed yet." }
        return context.usesBranch ? "Committed and uncommitted work since you branched." : "Edits you have not committed yet."
    }

    private var scopeTitle: String {
        switch stop {
        case .file: "Only " + (facts.file?.name ?? "this file")
        case .sinceReview: "Since my last review"
        default: "All changes"
        }
    }

    private var scopeMenu: some View {
        SeatPill { Text(scopeTitle).contentTransition(.opacity) }
            .appMenu(showsFocusRing: true) {
                var entries = [MenuEntry.item("All changes", checked: stop == .uncommitted || stop == .branch,
                                              subtitle: "Every file in the comparison") {
                    choose { stop = .uncommitted }
                }]
                if let file = facts.file {
                    entries.append(.item("Only " + file.name, checked: stop == .file,
                                         subtitle: "The file you opened this from") { choose { stop = .file } })
                }
                if facts.canReadSince {
                    entries.append(.item("Since my last review", checked: stop == .sinceReview,
                                         subtitle: "What changed after your last review") { choose { stop = .sinceReview } })
                }
                return entries
            }
            .accessibilityLabel("Files to review: \(scopeTitle)")
    }

    private func branchTitle(_ root: String?) -> String {
        guard context.usesBranch else { return "HEAD" }
        return root.flatMap { context.currentRef($0) } ?? context.baseTitle
    }

    private func branchMenu(_ repository: ReviewRepository?) -> some View {
        let title = branchTitle(repository?.root)
        let shown = facts.repositories.count > 1 ? "\(repository?.name ?? ""): \(title)" : title
        return SeatPill {
            Image(systemName: "arrow.triangle.branch").font(Typography.micro).foregroundStyle(.secondary)
            Text(shown).font(Typography.data.weight(.medium)).truncationMode(.middle)
                .contentTransition(.opacity)
        }
        .appMenu(showsFocusRing: true) { branchEntries(repository?.root) }
        .accessibilityLabel("Compare against \(title)" + (facts.repositories.count > 1 ? " in \(repository?.name ?? "")" : ""))
    }

    // HEAD leads, since it is the narrowest comparison, then the branches to compare with.
    private func branchEntries(_ root: String?) -> [MenuEntry] {
        var entries = [MenuEntry.item("HEAD", checked: !context.usesBranch,
                                      subtitle: "Only edits you have not committed") {
            choose { context.comparison = .head }
        }]
        let current = context.usesBranch ? root.flatMap { context.currentRef($0) } : nil
        let usual = root.flatMap { context.snapshots[$0]?.remoteBase?.ref } ?? facts.branch?.base
        if let root, let refs = context.branches[root], !refs.isEmpty {
            entries.append(.separator)
            entries += refs.map { ref in
                MenuEntry.item(ref, checked: current == ref,
                               subtitle: ref == usual ? "Everything since you branched" : nil) {
                    choose {
                        context.refs[root] = ref
                        context.comparison = .branch
                    }
                }
            }
        } else if facts.branch != nil || usual != nil {
            entries.append(.separator)
            entries.append(.item(context.baseTitle, checked: context.usesBranch,
                                 subtitle: "Everything since you branched") {
                choose { context.comparison = .branch }
            })
        }
        return entries
    }

    // MARK: Seats

    private var seats: some View {
        FlowRow(spacing: Space.sm) {
            if installed.isEmpty {
                Text(SecondOpinionLineup.installHint(author: author.agent))
                    .font(Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(installed, id: \.self) { agent in
                SeatToggle(agent: agent, author: author,
                           seats: lineup.filter { $0.agent == agent },
                           busy: stop.kind == .changes && running.contains { $0.agent == agent }) {
                    choose {
                        if lineup.contains(where: { $0.agent == agent }) {
                            lineup.removeAll { $0.agent == agent }
                        } else {
                            seat(agent)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Who reviews")
    }

    // A new seat starts on the agent's own model and effort.
    private func seat(_ agent: AgentKind) {
        let defaults = runner.catalog.defaults(for: agent)
        let model = runner.catalog.validModel(defaults.model, for: agent)
        lineup.append(SecondOpinion.Reviewer(agent: agent, model: model,
                                             effort: runner.catalog.validEffort(defaults.effort, for: agent, model: model)))
    }

    // MARK: Look for

    private var lookFor: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            FlowRow(spacing: Space.sm) {
                focusChips
                ToggleChip("Note", isOn: Binding(get: { noteOpen }, set: { open in
                    choose {
                        noteOpen = open
                        if !open { note = "" }
                    }
                    noteFocused = open
                }))
                .appTooltip(noteOpen ? "Remove the note" : "Add a note for your reviewers")
            }
            if noteOpen {
                TextField("Anything else, for example: check the rollback steps", text: $note)
                    .appTextField(size: Typography.Size.detail)
                    .focused($noteFocused)
                    .accessibilityLabel("Anything else to look for")
                    .transition(reduceMotion ? .opacity : .fadeIn)
            }
            if keptFocus {
                Label("Keep one thing to look for, or add a note.", systemImage: "exclamationmark.circle")
                    .font(Typography.caption).foregroundStyle(Theme.attentionText)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .motion(Motion.reveal, value: keptFocus)
    }

    @ViewBuilder private var focusChips: some View {
        switch stop.kind {
        case .chat:
            ForEach(ChatSecondOpinion.Focus.allCases, id: \.self) { item in
                ToggleChip(item.title, isOn: member(item, of: $chatFocus))
            }
        case .changes:
            ForEach(SecondOpinion.Focus.allCases, id: \.self) { item in
                ToggleChip(item.title, isOn: member(item, of: $changesFocus))
            }
        case .design:
            ForEach(DesignSecondOpinion.Focus.allCases, id: \.self) { item in
                ToggleChip(item.title, isOn: member(item, of: $designFocus))
            }
        }
    }

    private func member<Item: Hashable>(_ item: Item, of set: Binding<Set<Item>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(item) },
                set: { on in
                    guard on || set.wrappedValue.count > 1 || !note.isBlank else {
                        keptFocus = true
                        return
                    }
                    keptFocus = false
                    if on { set.wrappedValue.insert(item) } else { set.wrappedValue.remove(item) }
                })
    }

    // MARK: Receipt

    // What the reviewers get, shown as it will be read: the subject first, then one line
    // for anything that comes with it.
    private var receipt: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch stop {
                case .file, .sinceReview, .uncommitted, .branch: changesReceipt
                case .answer: answerReceipt
                case .conversation: conversationReceipt
                case .design: designReceipt
                }
            }
            // The code scopes share one receipt whose rows move as the scope does; each
            // other subject is a different picture and cross-fades.
            .id(stop.kind == .changes ? "changes" : "\(stop)")
            .transition(.opacity)
            .padding(Space.card)
            if let also = alsoIncluded {
                Label {
                    Text(also).contentTransition(.opacity)
                } icon: {
                    Image(systemName: "folder").foregroundStyle(Theme.accent)
                }
                .font(Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.card).padding(.vertical, Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Theme.hairline))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .motion(Motion.reveal, value: stop)
        .motion(Motion.control, value: context.comparison)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What they will receive")
    }

    // Shown only while the subject reads cleanly, so an error or an empty receipt says
    // one thing.
    private var alsoIncluded: String? {
        if stop.kind == .changes && (context.loading || context.blockedReason(for: stop) != nil) { return nil }
        return SecondOpinionAsk.alsoIncluded(stop, chatReading: chatReading, designReading: designReading,
                                             usesServers: usesServers)
    }

    private func receiptHeader(_ title: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(title).font(Typography.label).lineLimit(1).contentTransition(.opacity)
            Spacer(minLength: 0)
            if let detail {
                Text(detail).font(Typography.caption).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
    }

    private var changesReceipt: some View {
        let files = context.files(for: stop)
        let reason = context.loading ? nil : context.blockedReason(for: stop)
        let receipt = ChangeReceipt(files: files, repositoryNames: Dictionary(
            facts.repositories.map { ($0.root, $0.name) }, uniquingKeysWith: { first, _ in first }))
        let base = stop == .sinceReview ? "Last review" : branchTitle(facts.repositories.count == 1 ? facts.repositories.first?.root : nil)
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .center, spacing: Space.sm) {
                if context.loading {
                    ChangesProgressLabel(title: "Reading the comparison…").font(Typography.label)
                } else if reason == nil {
                    Text("\(Text(counted(files.count, "file") + " in this review").font(Typography.label))"
                         + "\(Text(receipt.isFlat ? "" : ", in " + counted(receipt.folders.count, "folder")).foregroundStyle(.secondary))")
                        .font(Typography.detail)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                } else {
                    Text(context.failure != nil ? "Nothing to show yet" : "Nothing to review")
                        .font(Typography.label)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 0)
                if !context.loading && reason == nil {
                    DiffPair(added: files.reduce(0) { $0 + $1.added }, removed: files.reduce(0) { $0 + $1.removed })
                        .contentTransition(.numericText())
                        .transition(.opacity)
                }
            }
            ComparisonRange(base: base, includesCommits: context.usesBranch && stop != .sinceReview,
                            snapshot: stop == .sinceReview, compact: true)
            if context.loading {
                ReceiptSkeleton()
                    .transition(.opacity)
            } else if let reason {
                receiptMessage(reason)
                    .transition(reduceMotion ? .opacity : .fadeIn)
            } else {
                SecondOpinionChangeList(receipt: receipt, filter: $receiptFilter, open: showFile)
                    .transition(reduceMotion ? .opacity : .fadeIn)
            }
        }
        .contentTransition(.opacity)
        .motion(Motion.reveal, value: context.loading)
    }

    // An empty or failed receipt says what happened and offers the one way out.
    @ViewBuilder private func receiptMessage(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(reason)
                .font(Typography.detail)
                .foregroundStyle(context.failure != nil ? AnyShapeStyle(Theme.attentionText) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            if context.failure != nil {
                InlineLink(title: "Try again") { retry += 1 }
            } else if stop == .sinceReview {
                InlineLink(title: "Review all changes instead") { choose { stop = .uncommitted } }
            } else if context.usesBranch && context.bases.isEmpty {
                InlineLink(title: "Compare to HEAD") { choose { context.comparison = .head } }
            } else if !context.usesBranch && (facts.branch != nil || !context.snapshots.isEmpty) {
                InlineLink(title: "Compare to \(context.baseTitle)") { choose { context.comparison = .branch } }
            }
        }
        .padding(.vertical, Space.xs)
    }

    private func showFile(_ file: SecondOpinionAskFacts.File) {
        dialogs.show(Dialog(title: file.name,
                            content: AnyView(SecondOpinionFilePreview(file: file, scope: context.fileScope(file, for: stop))),
                            actions: [], width: FormMetrics.sheetWidth, framesItself: true, fitsWindow: true))
    }

    private var answerReceipt: some View {
        let text = Self.plain(facts.answer?.subject.text ?? "")
        let words = text.split(whereSeparator: \.isWhitespace).count
        return VStack(alignment: .leading, spacing: Space.md) {
            receiptHeader(SecondOpinionAsk.title(.answer, facts: facts), detail: counted(words, "word"))
            if let request = facts.answer?.subject.request, !request.isBlank {
                Text("\(Text("You asked:").fontWeight(.semibold).foregroundStyle(Color.primary)) \(Self.plain(request))")
                    .font(Typography.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(text)
                .font(Typography.detail)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var conversationReceipt: some View {
        let shown = facts.turns.suffix(Self.previewTurns)
        let earlier = facts.turns.count - shown.count
        return VStack(alignment: .leading, spacing: Space.sm) {
            receiptHeader(SecondOpinionAsk.title(.conversation, facts: facts),
                          detail: counted(facts.turns.count, "message"))
            if earlier > 0 {
                Text(counted(earlier, "earlier message")).font(Typography.caption).foregroundStyle(.tertiary)
                    .padding(.leading, FormMetrics.rowLabelWidth)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, turn in
                HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                    Text(turn.fromPerson ? "You" : author.agent.title)
                        .font(Typography.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: FormMetrics.rowLabelWidth - Space.md, alignment: .leading)
                    Text(Self.plain(turn.text).components(separatedBy: .newlines).first ?? "")
                        .font(Typography.detail)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var designReceipt: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            receiptHeader("The design", detail: counted(facts.designScreens?.count ?? 0, "screen") + ", light and dark")
            FlowRow(spacing: Space.sm) {
                ForEach(facts.designScreens ?? [], id: \.self) { screen in
                    Label(screen, systemImage: "rectangle.on.rectangle")
                        .font(Typography.caption)
                        .lineLimit(1)
                        .padding(.horizontal, Space.sm).frame(height: ControlHeight.sm)
                        .background(RoundedRectangle(cornerRadius: Radius.inset).fill(Theme.card))
                }
            }
        }
    }

    // An answer's opening words without the marks Markdown writes around them.
    static func plain(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let text = (try? AttributedString(markdown: markdown, options: options)).map { String($0.characters) } ?? markdown
        return text.trimmed
    }

    // MARK: Tune

    private var tray: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if stop.kind != .changes {
                FormRow {
                    trayLabel("They read")
                    FlowRow(spacing: Space.sm) { readingChips }
                }
            }
            FormRow {
                trayLabel("Tools")
                VStack(alignment: .leading, spacing: Space.xs) {
                    ToggleChip("Read-only MCP tools", isOn: $usesServers, warns: true)
                        .appTooltip("The MCP servers this session uses. Only tools a server marks read-only run.")
                    Text(usesServers == defaults.usesServers ? (usesServers ? "On, as in Settings." : "Your servers stay out of this review.")
                         : usesServers ? "On for this ask only. Settings keeps them off."
                         : "Off for this ask only. Settings has them on.")
                        .font(Typography.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                .motion(Motion.reveal, value: usesServers)
            }
            ForEach(Array(lineup.enumerated()), id: \.offset) { index, seat in
                FormRow {
                    trayLabel(seat.agent.title)
                    VStack(alignment: .leading, spacing: Space.sm) {
                        HStack(alignment: .top, spacing: Space.sm) {
                            modelMenu(seat, at: index)
                            effortMenu(seat, at: index)
                        }
                        HStack(alignment: .top, spacing: Space.sm) {
                            IndependenceMeter(independence: SecondOpinion.independence(of: seat, from: author))
                                .fixedSize()
                                .padding(.top, Space.xs)
                            Text(SecondOpinion.independence(of: seat, from: author).line)
                                .font(Typography.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentTransition(.opacity)
                        }
                        .motion(Motion.control, value: seat)
                    }
                }
                .transition(reduceMotion ? .opacity : .fold)
            }
            FormRow {
                VStack(alignment: .leading, spacing: Space.sm) {
                    if !lineup.isEmpty && lineup == usual {
                        Label("Your usual reviewers", systemImage: "checkmark")
                            .font(Typography.caption).foregroundStyle(.secondary)
                    } else if !lineup.isEmpty {
                        InlineLink(title: "Make these my usual reviewers", size: Typography.Size.caption) {
                            Preferences.setSecondOpinionLineup(lineup)
                            usual = lineup
                        }
                        .appTooltip("Open with these reviewers, models and effort next time")
                    }
                    Text(safety).font(Typography.caption)
                        .foregroundStyle(usesServers ? AnyShapeStyle(Theme.attentionText) : AnyShapeStyle(.tertiary))
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .motion(Motion.control, value: usesServers)
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Theme.hairline))
        .motion(Motion.reveal, value: lineup)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tune the review")
    }

    private func trayLabel(_ title: String) -> some View {
        Text(title).font(Typography.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Space.xs)
    }

    @ViewBuilder private var readingChips: some View {
        switch stop {
        case .answer:
            ToggleChip("Project files", isOn: $chatReading.files)
            ToggleChip("Earlier conversation", isOn: $chatReading.conversation, warns: true)
                .appTooltip("Makes them think like \(author.agent.title)")
        case .conversation:
            ToggleChip("Project files", isOn: $chatReading.files)
        case .design:
            ToggleChip("HTML, handoff and theme", isOn: $designReading.source)
            ToggleChip("The design conversation", isOn: $designReading.conversation, warns: true)
                .appTooltip("Makes them think like the author")
        case .file, .sinceReview, .uncommitted, .branch:
            EmptyView()
        }
    }

    private var safety: String {
        SecondOpinionAsk.safety(stop.kind, usesServers: usesServers, author: author.agent)
    }

    private func modelMenu(_ seat: SecondOpinion.Reviewer, at index: Int) -> some View {
        let title = seat.model.map { runner.catalog.modelTitle($0) } ?? "Default"
        return SeatPill(form: true) { Text(title).contentTransition(.opacity) }
            .appMenu(showsFocusRing: true) {
                runner.catalog.modelOptions(for: seat.agent).map { option in
                    var changed = seat
                    changed.model = option.id
                    let words = SecondOpinion.independence(of: changed, from: author)
                    return MenuEntry.item(option.title, checked: seat.model == option.id,
                                          subtitle: option.detail,
                                          detail: words == .sameModel ? "Author's model" : nil,
                                          detailColour: Theme.attentionText) {
                        changed.effort = runner.catalog.validEffort(seat.effort, for: seat.agent, model: option.id)
                        lineup[index] = changed
                    }
                }
            }
            .appTooltip("The model \(seat.agent.title) reviews on")
            .accessibilityLabel("\(seat.agent.title) model: \(title)")
    }

    private func effortMenu(_ seat: SecondOpinion.Reviewer, at index: Int) -> some View {
        let levels = runner.catalog.effortOptions(for: seat.agent, model: seat.model).compactMap(\.id)
        let title = seat.effort.map { runner.catalog.effortTitle($0, for: seat.agent, model: seat.model) } ?? "Default"
        return SeatPill(form: true) {
            EffortMeter(lit: EffortMeter.lit(for: seat.effort, among: levels), height: Typography.Size.caption)
                .fixedSize()
            Text(title).contentTransition(.opacity)
        }
        .appMenu(showsFocusRing: true) {
            [MenuEntry.item("Default", meter: 0, checked: seat.effort == nil,
                            subtitle: "Whatever \(seat.agent.title) is set to use",
                            detail: "about \(SecondOpinion.minutes(for: nil)) min") {
                lineup[index].effort = nil
            }, .separator] + levels.map { level in
                MenuEntry.item(runner.catalog.effortTitle(level, for: seat.agent, model: seat.model),
                               meter: EffortMeter.lit(for: level, among: levels),
                               checked: seat.effort == level,
                               detail: "about \(SecondOpinion.minutes(for: level)) min") {
                    lineup[index].effort = level
                }
            }
        }
        .appTooltip("How long it thinks. More effort uses more of your plan.")
        .accessibilityLabel("\(seat.agent.title) effort: \(title)")
    }

    // MARK: Footer

    // Tune on the left, then what holds the ask back or what the reviewers may do, and
    // the one action on the right, named for who is asked.
    private var footer: some View {
        let title = SecondOpinionAsk.askTitle(lineup: asked)
        let reason = SecondOpinionAsk.blockedReason(lineup: asked, hasFocus: hasFocus) ?? context.footerReason(for: stop)
        let blocked = reason != nil || context.blockedReason(for: stop) != nil
        return HStack(spacing: Space.md) {
            TuneButton(open: tuning, changed: tuned) { choose { tuning.toggle() } }
                .focused($tuneFocused)
                .focusEffectDisabled()
                .overlay { FocusRingStroke(focused: tuneFocused, cornerRadius: ControlHeight.lg / 2) }
            Group {
                if let reason {
                    Text(reason)
                        .foregroundStyle(Theme.attentionText)
                        .id(reason)
                } else {
                    Label("Read only. Findings come to you first.", systemImage: "lock.shield")
                        .foregroundStyle(Theme.plan)
                        .appTooltip(safety)
                }
            }
            .font(Typography.caption)
            .lineLimit(1)
            .truncationMode(.tail)
            .transition(.opacity)
            Spacer(minLength: 0)
            ActionButton(title: title, tone: .green, shortcut: "↩", keyboardShortcut: .defaultAction) {
                ask(SecondOpinionAskChoice(
                    stop: stop, lineup: asked,
                    chatFocus: ChatSecondOpinion.Focus.allCases.filter(chatFocus.contains),
                    chatReading: stop == .conversation ? .init(files: chatReading.files, conversation: false) : chatReading,
                    changesFocus: changesFocus,
                    designFocus: DesignSecondOpinion.Focus.allCases.filter(designFocus.contains),
                    designReading: designReading, note: note.trimmed, usesServers: usesServers,
                    scope: stop.kind == .changes ? context.scope(for: stop) : nil))
            }
            .disabled(blocked)
            .accessibilityHint(reason ?? "")
            .contentTransition(.opacity)
        }
        .motion(Motion.control, value: title)
        .motion(Motion.reveal, value: reason)
    }
}

// Stand-in rows while the comparison is read, shaped like the file rows that replace
// them, so the receipt keeps its place instead of jumping when they arrive.
private struct ReceiptSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<5, id: \.self) { index in
                HStack(spacing: Space.md) {
                    RoundedRectangle(cornerRadius: Radius.tag / 2).fill(Theme.border)
                        .frame(width: Space.lg, height: Space.md)
                    RoundedRectangle(cornerRadius: Radius.tag / 2).fill(Theme.border)
                        .frame(width: ReviewMetrics.fileNameWidth - CGFloat(index % 3) * Space.xxxl * 2, height: Space.md)
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: Radius.tag / 2).fill(Theme.field)
                        .frame(width: ReviewMetrics.receiptBarWidth / 2, height: Space.xs)
                    RoundedRectangle(cornerRadius: Radius.tag / 2).fill(Theme.field)
                        .frame(width: ReviewMetrics.receiptFiguresWidth / 2, height: Space.md)
                }
                .frame(height: ControlHeight.md)
            }
        }
        .accessibilityHidden(true)
    }
}

// One installed agent as a pill to ask or leave out. A tick on the avatar says it is in.
// How far it stands from the author is in the hover hint, so the pill stays short; only
// the author's own agent says "fresh", since it starts without this chat.
private struct SeatToggle: View {
    let agent: AgentKind
    let author: SecondOpinion.Reviewer
    let seats: [SecondOpinion.Reviewer]
    let busy: Bool
    let toggle: () -> Void

    @State private var hovering = false

    private var on: Bool { !seats.isEmpty }

    private var independence: SecondOpinion.Independence {
        SecondOpinion.independence(of: seats.first ?? SecondOpinion.Reviewer(agent: agent), from: author)
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Space.sm) {
                ReviewAvatar(agent: agent, size: ControlHeight.xs)
                    .opacity(on ? 1 : 0.55)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "checkmark").font(Typography.micro).imageScale(.small)
                            .foregroundStyle(Theme.onFill)
                            .padding(Space.xxs)
                            .background(Circle().fill(Theme.dotOn))
                            .overlay(Circle().stroke(Theme.card, lineWidth: 1.5))
                            .offset(x: Space.xs, y: Space.xs)
                            .opacity(on ? 1 : 0)
                            .motion(Motion.pop, value: on)
                    }
                Text(agent.title).font(Typography.label).lineLimit(1)
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                if busy {
                    MonoChip(text: "reading", tint: Theme.plan, mono: false)
                } else if agent == author.agent {
                    MonoChip(text: "fresh", mono: false)
                }
            }
            .padding(.leading, Space.xs + Space.xxs)
            .padding(.trailing, Space.md)
            .frame(height: ControlHeight.lg)
            .background(Capsule().fill(on ? Theme.accent.opacity(0.08) : hovering ? Theme.field : .clear))
            .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.4) : Theme.border))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.control, value: on)
        .motion(Motion.hover, value: hovering)
        .appTooltip { Tooltip(title: agent == author.agent ? "\(agent.title), fresh start" : agent.title,
                              subtitle: independence.line) }
        .accessibilityLabel(agent == author.agent ? "\(agent.title), fresh start" : agent.title)
        .accessibilityValue((on ? "Asked. " : "Not asked. ") + (busy ? "Reading. " : "") + independence.line)
        .accessibilityAddTraits(on ? [.isToggle, .isSelected] : [.isToggle])
    }
}

// Opens the rest of the choices inside the card. A dot says something differs from a
// plain ask, so a tuned ask is never hidden behind a closed button.
private struct TuneButton: View {
    let open: Bool
    let changed: Bool
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Space.xs) {
                Image(systemName: "slider.horizontal.3").font(Typography.label)
                Text("Tune").font(Typography.label)
                Circle().fill(Theme.attention).frame(width: Space.sm, height: Space.sm)
                    .opacity(changed ? 1 : 0)
                    .motion(Motion.pop, value: changed)
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(Typography.micro)
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, Space.md)
            .frame(height: ControlHeight.lg)
            .background(Capsule().fill(open || hovering ? Theme.field : Theme.card))
            .overlay(Capsule().strokeBorder(Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .appTooltip { Tooltip(title: "Tune the review", subtitle: "What they read and use, models and effort") }
        .accessibilityLabel("Tune the review")
        .accessibilityValue((open ? "Expanded" : "Collapsed") + (changed ? ", changed from your usual" : ""))
    }
}
