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

// The ask for a second opinion, as a small card hung off the control that opened it. It
// shows the thing to be reviewed rather than describing it: a picture of it, its name,
// a track for how much of the work to take, and who reads it. Every other choice waits
// behind Tune, so the usual ask is one click and Return.
struct SecondOpinionAskCard: View {
    // The coordinate space the session draws the card in.
    nonisolated static let space = "secondOpinionAsk"
    static let width: CGFloat = 480
    // The preview keeps one height whatever it shows, so the card does not jump as the
    // knob moves.
    static let previewHeight: CGFloat = 140
    // Lines of the preview's list, and bubbles of its conversation, that fit that height.
    static let previewRows = 6
    static let previewTurns = 5

    let facts: SecondOpinionAskFacts
    @Binding var stop: SecondOpinionStop
    let author: SecondOpinion.Reviewer
    let installed: [AgentKind]
    // Seats already reading the changes, which cannot be asked again until they finish.
    var running: Set<SecondOpinion.Reviewer> = []
    // The files changed since the last review, once they have been worked out.
    var sinceReviewFiles: Set<String>?
    // What Settings says an ask starts from. Tune changes only this ask.
    let defaults: SecondOpinionDefaults
    let ask: (SecondOpinionAskChoice) -> Void
    let close: () -> Void

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
    @Environment(SessionRunner.self) private var runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(facts: SecondOpinionAskFacts, stop: Binding<SecondOpinionStop>, author: SecondOpinion.Reviewer,
         installed: [AgentKind], running: Set<SecondOpinion.Reviewer> = [],
         sinceReviewFiles: Set<String>? = nil, lineup: [SecondOpinion.Reviewer],
         defaults: SecondOpinionDefaults, startsTuning: Bool = false,
         ask: @escaping (SecondOpinionAskChoice) -> Void, close: @escaping () -> Void) {
        self.facts = facts
        self._stop = stop
        self.author = author
        self.installed = installed
        self.running = running
        self.sinceReviewFiles = sinceReviewFiles
        self.ask = ask
        self.close = close
        self.defaults = defaults
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
        VStack(alignment: .leading, spacing: Space.lg) {
            preview
            caption
            if stops.count > 1 {
                ScopeTrack(label: "How much to review", stops: stops, selection: $stop) {
                    SecondOpinionAsk.stopTitle($0, facts: facts)
                }
            }
            seats
            if tuning {
                tray.transition(reduceMotion ? .opacity : .fold)
            }
            footer
        }
        .padding(Space.card)
        .frame(minWidth: 0, idealWidth: Self.width, maxWidth: Self.width, alignment: .leading)
        .floatingCard(cornerRadius: Radius.floating)
        .motion(Motion.reveal, value: tuning)
        .background {
            Button {
                if tuning {
                    tuning = false
                    tuneFocused = true
                } else {
                    close()
                }
            } label: { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask for a second opinion")
        .accessibilityAddTraits(.isModal)
        .onAppear {
            // Nobody usual is installed, so the most independent agent there is sits
            // first: one from another maker than the author's.
            if lineup.isEmpty, let agent = installed.first(where: { $0 != author.agent }) ?? installed.first {
                seat(agent)
            }
        }
        .task { for agent in installed { await runner.catalog.discoverModels(for: agent) } }
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
        let lit = SecondOpinionAsk.litFiles(stop, facts: facts, sinceReview: sinceReviewFiles) ?? []
        let files = SecondOpinionAsk.files(stop, facts: facts)
        // Files in scope lead, so a narrow scope is never below the fold.
        let ordered = files.filter { lit.contains($0.id) } + files.filter { !lit.contains($0.id) }
        let fits = ordered.count > Self.previewRows ? Self.previewRows - 1 : Self.previewRows
        let scale = files.map { $0.added + $0.removed }.max() ?? 1
        return VStack(alignment: .leading, spacing: Space.sm) {
            if stop == .sinceReview && sinceReviewFiles == nil {
                Text("Working out what changed since the review…")
                    .font(Typography.caption).foregroundStyle(.secondary)
            }
            ForEach(ordered.prefix(fits)) { file in
                FileBarRow(name: file.name, added: file.added, removed: file.removed,
                           lit: lit.contains(file.id), scale: scale)
            }
            if ordered.count > fits {
                Text("and \(counted(ordered.count - fits, "more file"))")
                    .font(Typography.caption).foregroundStyle(.secondary)
            }
        }
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

    // MARK: Caption

    private var caption: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(SecondOpinionAsk.title(stop, facts: facts))
                .font(Typography.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            if let fact = SecondOpinionAsk.fact(stop, facts: facts) {
                Text(fact).font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let lines = codeLines {
                DiffPair(added: lines.added, removed: lines.removed)
            }
            Spacer(minLength: 0)
        }
        .contentTransition(.opacity)
        .motion(Motion.reveal, value: stop)
    }

    private var codeLines: (added: Int, removed: Int)? {
        guard let lit = SecondOpinionAsk.litFiles(stop, facts: facts, sinceReview: sinceReviewFiles),
              stop != .sinceReview else { return nil }
        let files = SecondOpinionAsk.files(stop, facts: facts).filter { lit.contains($0.id) }
        return (files.reduce(0) { $0 + $1.added }, files.reduce(0) { $0 + $1.removed })
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
        TuneButton(open: tuning, changed: tuned) { tuning.toggle() }
            .focused($tuneFocused)
            .focusEffectDisabled()
            .overlay { FocusRingStroke(focused: tuneFocused) }
    }

    // MARK: Tune

    private var tray: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            FormRow {
                trayLabel("Look for")
                VStack(alignment: .leading, spacing: Space.sm) {
                    FlowRow(spacing: Space.sm) { focusChips }
                    TextField("Anything else to look for", text: $note)
                        .appTextField(size: Typography.Size.detail)
                        .accessibilityLabel("Anything else to look for")
                }
            }
            FormRow {
                trayLabel("They read")
                FlowRow(spacing: Space.sm) { readingChips }
            }
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
            ToggleChip("This conversation", isOn: $chatReading.conversation, warns: true)
                .appTooltip("Makes them think like \(author.agent.title)")
        case .conversation:
            ToggleChip(fixed: "The conversation")
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
                set: { on in if on { set.wrappedValue.insert(item) } else { set.wrappedValue.remove(item) } })
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
                    designReading: designReading, note: note.trimmed, usesServers: usesServers))
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
