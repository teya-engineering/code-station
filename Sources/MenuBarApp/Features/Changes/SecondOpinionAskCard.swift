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

// The anchored ask keeps subject, context and comparison visible beside a live preview.
struct SecondOpinionAskCard: View {
    // The coordinate space the session draws the card in.
    nonisolated static let space = "secondOpinionAsk"
    static let width = ReviewMetrics.askWidth
    // Text previews stay bounded even when an answer or conversation is long.
    static let previewHeight = ReviewMetrics.previewHeight
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
    @State private var tuning = false
    @FocusState private var tuneFocused: Bool
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

    // A click that reshapes the card runs in one animated transaction, so the chips,
    // the preview and the card's own height all move together. A modifier on one part
    // would leave the rest, and the scroll view's measured height, to snap.
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
                FormPair(minimumWidth: ReviewMetrics.columnsWidth) {
                    setup
                    contextPreview
                }
                .padding(Space.pane)
            }
            footer.padding(Space.pane)
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
            Button(action: close) { EmptyView() }
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

    private var setup: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text("What should they review?").font(Typography.label)
            subjectChoices
            if stop.kind == .changes {
                comparisonChoices
            } else {
                Text("Supporting context").font(Typography.label)
                FlowRow(spacing: Space.sm) { readingChips }
            }
            SectionRule("WHO REVIEWS")
            seats
            SectionRule("WHAT TO LOOK FOR")
            FlowRow(spacing: Space.sm) { focusChips }
            if keptFocus {
                Text("Keep one focus or add a note for your reviewers.")
                    .font(Typography.caption).foregroundStyle(Theme.attentionText)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            TextField("Anything else to look for", text: $note)
                .appTextField(size: Typography.Size.detail)
                .accessibilityLabel("Anything else to look for")
            if tuning { tray.transition(reduceMotion ? .opacity : .fold) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subjectChoices: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            if facts.answer != nil {
                SubjectChoice(title: SecondOpinionAsk.stopTitle(.answer, facts: facts),
                              detail: "The answer and what you asked", icon: "text.bubble",
                              selected: stop == .answer) { choose { stop = .answer } }
            }
            if stops.contains(.conversation) {
                SubjectChoice(title: "Whole chat", detail: "Every turn in this conversation", icon: "bubble.left.and.bubble.right",
                              selected: stop == .conversation) { choose { stop = .conversation } }
            }
            if stops.contains(where: { $0.kind == .changes }) {
                SubjectChoice(title: "Changes", detail: "The code in your comparison", icon: "plus.forwardslash.minus",
                              selected: stop.kind == .changes) { choose { stop = .uncommitted } }
            }
            if stops.contains(.design) {
                SubjectChoice(title: "Design", detail: "Every screen, light and dark", icon: "rectangle.on.rectangle",
                              selected: stop == .design) { choose { stop = .design } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review subject")
    }

    private var comparisonChoices: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Compare changes to").font(Typography.label)
            Text(stop == .sinceReview ? "From your last review" : context.inheritsComparison
                 ? "From your Changes tab" : "For this review only")
                .font(Typography.caption).foregroundStyle(Theme.accent)
                .contentTransition(.opacity)
            if stop == .sinceReview {
                Label("Last review snapshot", systemImage: "clock")
                    .font(Typography.label).padding(Space.lg).frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
            } else {
                FlowRow(spacing: Space.sm) {
                    ChoicePill(title: "HEAD", selected: !context.usesBranch) { choose { context.comparison = .head } }
                    ChoicePill(title: context.baseTitle, selected: context.usesBranch) { choose { context.comparison = .branch } }
                }
                Text(context.usesBranch ? "Committed and uncommitted work since the branch point."
                     : "Uncommitted edits since the latest commit.")
                    .font(Typography.caption).foregroundStyle(.secondary)
                ForEach(facts.repositories, id: \.root) { repository in
                    if let refs = context.branches[repository.root], !refs.isEmpty {
                        SeatPill {
                            Text(facts.repositories.count > 1 ? repository.name : "Base branch")
                            Text(context.refs[repository.root] ?? context.snapshots[repository.root]?.remoteBase?.ref ?? "Choose")
                                .font(Typography.data).lineLimit(1).truncationMode(.middle)
                        }
                        .appMenu {
                            refs.map { ref in
                                MenuEntry.item(ref, checked: context.refs[repository.root] == ref) {
                                    context.refs[repository.root] = ref
                                    context.comparison = .branch
                                }
                            }
                        }
                        .accessibilityLabel("Comparison branch for \(repository.name)")
                    }
                }
            }
            FlowRow(spacing: Space.sm) {
                ChoicePill(title: "All changes", selected: stop == .uncommitted || stop == .branch) { choose { stop = .uncommitted } }
                if facts.file != nil {
                    ChoicePill(title: "This file", selected: stop == .file) { choose { stop = .file } }
                }
                if facts.canReadSince {
                    ChoicePill(title: "Since last review", selected: stop == .sinceReview) { choose { stop = .sinceReview } }
                }
            }
            .accessibilityLabel("Files to review")
        }
        .motion(Motion.control, value: context.comparison)
        .motion(Motion.reveal, value: stop)
    }

    private var contextPreview: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("What they’ll receive").font(Typography.label)
            Label(previewTitle, systemImage: stop.kind == .changes ? "plus.forwardslash.minus"
                  : stop == .conversation ? "bubble.left.and.bubble.right" : stop == .design ? "rectangle.on.rectangle" : "text.bubble")
                .font(Typography.title)
                .contentTransition(.opacity)
            if stop.kind == .changes {
                ComparisonRange(base: stop == .sinceReview ? "Review snapshot" : context.usesBranch ? context.baseTitle : "HEAD",
                                includesCommits: context.usesBranch, snapshot: stop == .sinceReview)
                    .id(stop == .sinceReview ? "snapshot" : context.usesBranch ? context.baseTitle : "HEAD")
                filesPreview
            } else {
                preview
                if stop == .answer, let request = facts.answer?.subject.request, !request.isBlank {
                    Text("Your request").font(Typography.label)
                    Text(Self.plain(request)).font(Typography.detail).foregroundStyle(.secondary).lineLimit(4)
                }
                if stop == .conversation {
                    Text("Every conversational turn is included (\(facts.turns.count) messages).")
                        .font(Typography.caption).foregroundStyle(.secondary)
                }
            }
            SectionRule("ALSO INCLUDED")
            if stop.kind == .changes {
                contextLine("Project files to check the surrounding code", included: true)
                contextLine("Conversation", included: false)
            } else if stop.kind == .chat {
                contextLine("Project files", included: chatReading.files)
                contextLine("Earlier conversation", included: stop == .conversation || chatReading.conversation)
            } else {
                contextLine("HTML, handoff and theme", included: designReading.source)
                contextLine("Design conversation", included: designReading.conversation)
            }
            contextLine("Read-only MCP tools", included: usesServers)
            Label("Reviewers read and report. Findings come to you first.", systemImage: "lock.shield")
                .font(Typography.caption).foregroundStyle(Theme.plan)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.sunken))
        .motion(Motion.control, value: context.comparison)
        .motion(Motion.reveal, value: stop)
        .motion(Motion.control, value: chatReading)
        .motion(Motion.control, value: designReading)
        .motion(Motion.control, value: usesServers)
    }

    private var previewTitle: String {
        if stop.kind != .changes { return SecondOpinionAsk.title(stop, facts: facts) }
        if stop == .file { return facts.file?.name ?? "This file" }
        if stop == .sinceReview { return "Since your last review" }
        return "Changes from " + (context.usesBranch ? context.baseTitle : "HEAD")
    }

    private func contextLine(_ title: String, included: Bool) -> some View {
        Label(included ? title : title + " not included", systemImage: included ? "checkmark" : "minus")
            .font(Typography.caption).foregroundStyle(included ? Theme.accent : Theme.secondaryText)
            .contentTransition(.opacity)
    }

    // MARK: Preview

    private var preview: some View {
        Group {
            switch stop {
            case .file, .sinceReview, .uncommitted, .branch: filesPreview
            case .answer: answerPreview
            case .conversation: conversationPreview
            case .design: designPreview
            }
        }
        // Code stops share one picture whose bars draw as the scope moves; the others
        // cross-fade, since each is a different picture.
        .id(stop.kind == .changes ? "changes" : "\(stop)")
        .transition(.opacity)
        .padding(Space.card)
        .frame(maxWidth: .infinity, minHeight: Self.previewHeight, maxHeight: Self.previewHeight, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.sunken))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .motion(Motion.reveal, value: stop)
    }

    private var filesPreview: some View {
        let files = context.files(for: stop)
        let scale = files.map { $0.added + $0.removed }.max() ?? 1
        return VStack(alignment: .leading, spacing: Space.md) {
            if context.loading {
                ChangesProgressLabel(title: "Reading the comparison…")
            } else if let reason = context.blockedReason(for: stop) {
                Text(reason).font(Typography.detail).foregroundStyle(.secondary)
                if context.failure != nil {
                    InlineLink(title: "Try again") { retry += 1 }
                } else if !context.usesBranch && stop != .sinceReview {
                    InlineLink(title: "Compare to \(context.baseTitle)") { context.comparison = .branch }
                }
            } else {
                HStack(spacing: Space.sm) {
                    Text(counted(files.count, "file") + " in this review").font(Typography.label)
                    Spacer(minLength: 0)
                    DiffPair(added: files.reduce(0) { $0 + $1.added }, removed: files.reduce(0) { $0 + $1.removed })
                }
                ForEach(files) { file in
                    Button { showFile(file) } label: {
                        FileBarRow(name: file.name, added: file.added, removed: file.removed,
                                   scale: scale, nameWidth: ReviewMetrics.fileNameWidth)
                            .motion(Motion.draw, value: file)
                            .padding(.vertical, Space.sm)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverFill(cornerRadius: Radius.inset)
                    .appTooltip(file.path)
                    .accessibilityLabel("Open \(file.path), \(file.added) added, \(file.removed) removed")
                }
            }
        }
        .contentTransition(.opacity)
    }

    private func showFile(_ file: SecondOpinionAskFacts.File) {
        dialogs.show(Dialog(title: file.name,
                            content: AnyView(SecondOpinionFilePreview(file: file, scope: context.fileScope(file, for: stop))),
                            actions: [], width: FormMetrics.sheetWidth, framesItself: true, fitsWindow: true))
    }

    private var answerPreview: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Capsule().fill(Theme.accent.opacity(0.5)).frame(width: SubjectRail.width)
            Text(Self.plain(facts.answer?.subject.text ?? ""))
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var conversationPreview: some View {
        VStack(spacing: Space.xs) {
            ForEach(Array(facts.turns.suffix(Self.previewTurns).enumerated()), id: \.offset) { _, turn in
                HStack {
                    if turn.fromPerson { Spacer(minLength: Space.xxxl) }
                    Text(Self.plain(turn.text).components(separatedBy: .newlines).first ?? "")
                        .font(Typography.caption)
                        .lineLimit(1)
                        .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs)
                        .background(RoundedRectangle(cornerRadius: Radius.inset)
                            .fill(turn.fromPerson ? Theme.userMessage : Theme.card))
                    if !turn.fromPerson { Spacer(minLength: Space.xxxl) }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var designPreview: some View {
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

    // An answer's opening words without the marks Markdown writes around them.
    static func plain(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let text = (try? AttributedString(markdown: markdown, options: options)).map { String($0.characters) } ?? markdown
        return text.trimmed
    }

    // MARK: Seats

    private var seats: some View {
        ViewThatFits(in: .horizontal) {
            seatRow
            FlowRow(spacing: Space.sm) {
                seatChoices
                tuneButton
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Who reviews")
    }

    private var seatRow: some View {
        HStack(spacing: Space.sm) {
            seatChoices
            Spacer(minLength: 0)
            tuneButton
        }
    }

    @ViewBuilder private var seatChoices: some View {
        if installed.isEmpty {
            Text(SecondOpinionLineup.installHint(author: author.agent))
                .font(Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(installed, id: \.self) { agent in
            seatButton(agent)
        }
    }

    private func seatButton(_ agent: AgentKind) -> some View {
        SeatToggle(agent: agent, author: author,
                   seats: lineup.filter { $0.agent == agent },
                   busy: stop.kind == .changes && running.contains { $0.agent == agent }) {
            if lineup.contains(where: { $0.agent == agent }) {
                lineup.removeAll { $0.agent == agent }
            } else {
                seat(agent)
            }
        }
    }

    // A new seat starts on the agent's own model and effort.
    private func seat(_ agent: AgentKind) {
        let defaults = runner.catalog.defaults(for: agent)
        let model = runner.catalog.validModel(defaults.model, for: agent)
        lineup.append(SecondOpinion.Reviewer(agent: agent, model: model,
                                             effort: runner.catalog.validEffort(defaults.effort, for: agent, model: model)))
    }

    private var tuneButton: some View {
        TuneButton(open: tuning, changed: tuned) { choose { tuning.toggle() } }
            .focused($tuneFocused)
            .focusEffectDisabled()
            .overlay { FocusRingStroke(focused: tuneFocused) }
    }

    // MARK: Tune

    private var tray: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            FormRow {
                trayLabel("They can use")
                VStack(alignment: .leading, spacing: Space.xs) {
                    ToggleChip("Your MCP servers", isOn: $usesServers, warns: true)
                        .appTooltip("The MCP servers this session uses. Only tools a server marks read-only run.")
                    if usesServers != defaults.usesServers {
                        Text(usesServers ? "On for this ask only. Settings keeps them off."
                                         : "Off for this ask only. Settings has them on.")
                            .font(Typography.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(reduceMotion ? .opacity : .fadeIn)
                    }
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
        .padding(.top, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .motion(Motion.reveal, value: lineup)
    }

    private func trayLabel(_ title: String) -> some View {
        Text(title).font(Typography.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Space.xs)
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

    @ViewBuilder private var readingChips: some View {
        switch stop {
        case .answer:
            ToggleChip(fixed: facts.answer?.subject.kind == .plan ? "The plan and your ask" : "The answer and your ask")
            ToggleChip("Project files", isOn: $chatReading.files)
            ToggleChip("Earlier conversation", isOn: $chatReading.conversation, warns: true)
                .appTooltip("Makes them think like \(author.agent.title)")
        case .conversation:
            ToggleChip(fixed: "Earlier conversation included")
            ToggleChip("Project files", isOn: $chatReading.files)
        case .file, .sinceReview, .uncommitted, .branch:
            ToggleChip(fixed: "The changes")
            ToggleChip(fixed: "Project files")
        case .design:
            ToggleChip(fixed: "Every screen, light and dark")
            ToggleChip("HTML, handoff and theme", isOn: $designReading.source)
            ToggleChip("The design conversation", isOn: $designReading.conversation, warns: true)
                .appTooltip("Makes them think like the author")
        }
    }

    private var safety: String {
        SecondOpinionAsk.safety(stop.kind, usesServers: usesServers, author: author.agent)
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

    private var footer: some View {
        let title = SecondOpinionAsk.askTitle(lineup: asked, hasFocus: hasFocus)
        let blockedReason = SecondOpinionAsk.blockedReason(lineup: asked, hasFocus: hasFocus)
            ?? context.blockedReason(for: stop)
        return HStack(spacing: Space.md) {
            if let blockedReason {
                Text(blockedReason)
                    .font(Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
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
            .disabled(blockedReason != nil)
            .accessibilityHint(blockedReason ?? "")
            .contentTransition(.opacity)
        }
        .motion(Motion.control, value: title)
    }
}

// One installed agent as a seat to fill or leave empty. A tick on the tile says it is
// in; the meter under the name says how independent it is of the author.
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
                        if on {
                            Image(systemName: "checkmark").font(Typography.micro)
                                .foregroundStyle(Theme.onFill)
                                .padding(Space.xxs)
                                .background(Circle().fill(Theme.dotOn))
                                .overlay(Circle().stroke(Theme.card, lineWidth: 1.5))
                                .offset(x: Space.xs, y: Space.xs)
                                .transition(.opacity)
                        }
                    }
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(agent.title).font(Typography.label).lineLimit(1)
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                    HStack(spacing: Space.xs) {
                        IndependenceMeter(independence: independence)
                        if busy {
                            Text("reading").font(Typography.micro).foregroundStyle(.secondary)
                        } else if agent == author.agent {
                            Text("fresh").font(Typography.micro).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.md)
            .frame(height: ControlHeight.xl)
            .surface(on ? Theme.accent.opacity(0.08) : hovering ? Theme.field : .clear,
                     cornerRadius: Radius.control,
                     border: on ? Theme.accent.opacity(0.4) : Theme.border)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.control, value: on)
        .motion(Motion.hover, value: hovering)
        .accessibilityLabel(agent == author.agent ? "\(agent.title), fresh start" : agent.title)
        .accessibilityValue((on ? "Asked. " : "Not asked. ") + independence.line)
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
                if changed && !open {
                    Circle().fill(Theme.attention).frame(width: Space.sm, height: Space.sm)
                        .transition(.opacity)
                }
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(Typography.micro)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, Space.md)
            .frame(height: ControlHeight.md)
            .background(RoundedRectangle(cornerRadius: Radius.control)
                .fill(open || hovering ? Theme.field : Theme.sunken))
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .motion(Motion.pop, value: changed)
        .appTooltip { Tooltip(title: "Tune the review", subtitle: "What to look for, what they read and use, models and effort") }
        .accessibilityLabel("Tune the review")
        .accessibilityValue((open ? "Expanded" : "Collapsed") + (changed ? ", changed from your usual" : ""))
    }
}
