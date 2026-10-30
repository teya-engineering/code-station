import AppKit
import QuartzCore
import SwiftUI

// The prompt box under a transcript: what has been dropped or pasted onto it, the field
// itself, and the button that sends, queues or stops. The Chat and Design panes both
// draw it, and differ only in the words in the field, what sits at its end, and what
// they put on the rows above it.
//
// The half-written prompt is the runner's, not this view's: switching sessions builds
// the pane again from nothing, and anything held here would go with it.
struct Composer<Above: View, Accessory: View>: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var appSettings
    // Optional so a pane hosted without them simply has no microphone.
    @Environment(Dictation.self) private var dictation: Dictation?
    @Environment(MenuPresenter.self) private var menus: MenuPresenter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let sessionID: UUID
    // Which CLI the prompt is bound for: only Claude's reads a thinking keyword out of it.
    let agent: AgentKind
    // Whether the session can run at all: its folder is there and its CLI is installed.
    let blocked: Bool
    @Binding var isFocused: Bool
    let placeholder: String
    // The side margin, which the narrow Design pane keeps smaller.
    var inset: CGFloat = 20
    var minimumLines: Int = 1
    // Where the send button sits against a field taller than one line. The tall Design
    // field centres it, level with the microphone and avatar inside the field.
    var buttonAlignment: VerticalAlignment = .bottom
    let onOversizedPaste: (String) -> Void
    var onRecallUp: (() -> Bool)? = nil
    var onRecallDown: (() -> Bool)? = nil
    var onSend: (() -> Void)? = nil
    // Passed to the field so the keys the suggestion above answers are only taken while
    // the cursor is in the box.
    var onSuggestionKey: ((SuggestionKey) -> Bool)? = nil
    // Whether the box has a microphone.
    var dictates = false
    @ViewBuilder let above: Above
    @ViewBuilder let accessory: Accessory

    @State private var dropTargeted = false
    @State private var commands: [AgentCommand] = []
    @State private var commandSelection = 0
    // The command being typed when the menu was waved away, so it stays away until the
    // word changes rather than coming back on the next keystroke.
    @State private var dismissedQuery: String?
    @State private var fieldLink = ComposerFieldLink()
    @State private var dictateShortcut = WindowKeyMonitor([.command, .shift], "d")
    @State private var dictationKeys = DictationKeys()

    private var attachments: [Attachment] { runner.composer.draft(sessionID).attachments }

    // The slash command being typed, if the whole of the prompt is one.
    private var query: String? { SlashQuery.typed(in: runner.composer.draft(sessionID).text) }

    private var matches: [AgentCommand] {
        guard let query, query != dismissedQuery else { return [] }
        return SlashQuery.matches(query, in: commands)
    }

    private var draft: Binding<String> {
        Binding(get: { runner.composer.draft(sessionID).text },
                set: { text in
                    runner.composer.editDraft(sessionID) { $0.text = text }
                    dictationHere?.draftEdited(sessionID, text: text)
                })
    }

    private var dictationHere: Dictation? { dictates ? dictation : nil }

    var body: some View {
        let state = runner.state(sessionID)
        let busy = state.isBusy
        let listening = dictationHere?.isListening(sessionID) == true
        // Speaking never sends: while the app listens the words are still arriving, and
        // only a deliberate send once they have settled takes them to the agent.
        let canSend = !blocked && !listening && dictationHere?.isPreparing(sessionID) != true
            && !runner.composer.draft(sessionID).isEmpty
        let roots = store.session(sessionID).map(store.workingDirectories(for:)) ?? []

        let matches = matches
        let menuShown = !matches.isEmpty && isFocused && !blocked
        let noticeShown = dictationHere?.notice(for: sessionID) != nil

        VStack(alignment: .leading, spacing: 8) {
            if let dictation = dictationHere, let notice = dictation.notice(for: sessionID) {
                DictationFeedback(dictation: dictation, sessionID: sessionID,
                                  draft: runner.composer.draftBinding(sessionID), notice: notice)
            }
            above
            attachmentStrip

            if menuShown {
                SlashCommandMenu(agent: agent,
                                 commands: matches,
                                 selected: min(commandSelection, matches.count - 1),
                                 choose: take,
                                 highlight: { commandSelection = $0 })
                    .transition(.fadeIn)
            }

            HStack(alignment: buttonAlignment, spacing: 10) {
                // Typing during a turn is allowed. An agent that can take a prompt
                // mid-turn gets it at its next step when settings say to steer; otherwise
                // what is written goes to the back of the queue. A turn parked on a
                // background task always takes it straight away, since its pipe is open.
                ComposerField(text: draft,
                              isFocused: $isFocused,
                              placeholder: placeholder,
                              isEnabled: !blocked,
                              onSubmit: { send(delivery: appSettings.midTurnPromptDelivery) },
                              onOversizedPaste: onOversizedPaste,
                              onRecallUp: onRecallUp,
                              onRecallDown: onRecallDown,
                              highlightsKeyword: agent == .claudeCode,
                              commandNames: Set(commands.map { $0.name.lowercased() }),
                              onSuggestionKey: onSuggestionKey,
                              onCommandKey: commandKey,
                              onDropFiles: blocked ? nil : { attach(Attachments.fromDrop($0)) },
                              onFileDragTargeted: { dropTargeted = $0 },
                              minimumLines: minimumLines,
                              listening: listening,
                              marks: dictationMarks,
                              onMarkClick: dictationHere == nil ? nil : { showWordMenu($0, at: $1) },
                              link: fieldLink,
                              trailingInset: dictationHere == nil ? 48 : listening ? 134 : 82) {
                    HStack(spacing: 6) {
                        if let dictation = dictationHere {
                            DictationMicButton(live: listening,
                                               preparing: dictation.isPreparing(sessionID),
                                               blocked: dictation.notice(for: sessionID).isMicrophoneBlocked,
                                               level: dictation.level,
                                               startedAt: dictation.startedAt,
                                               download: dictation.notice(for: sessionID).downloadFraction,
                                               action: toggleDictation)
                                .disabled(blocked)
                        }
                        accessory
                    }
                }

                // While a turn runs the prompt can go now or wait for the turn to end.
                // Return does the one chosen in settings, and the other stays one click
                // away. An agent that cannot take a prompt mid-turn only has the queue.
                if busy, canSend {
                    sideButtons
                }

                // Send and Stop share one place, so a turn starting reads as the button
                // turning into the other, and the field never changes width over it.
                primaryButton(state: state, canSend: canSend)
            }
            .motion(Motion.reveal, value: canSend)
            .motion(Motion.control, value: busy)
            .motion(Motion.control, value: state == .stopping)
        }
        .motion(Motion.reveal, value: menuShown)
        .motion(Motion.reveal, value: noticeShown)
        .smoothlyResizes(when: attachments.count)
        .padding(.horizontal, inset)
        // The top matches the stack spacing, so a row above the field sits evenly
        // between the edge of the bar and the field.
        .padding(.top, 8)
        .padding(.bottom, 14)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Theme.accent, lineWidth: dropTargeted ? 2 : 0)
            .padding(6))
        .motion(Motion.hover, value: dropTargeted)
        // Saved drafts need the command names too. Refresh as the menu opens or closes,
        // since command files can change between prompts.
        .task(id: [agent.rawValue, String(query == nil)] + roots) {
            let agent = agent
            let loaded = await Task.detached {
                AgentCommands.all(for: agent, workingDirectories: roots)
            }.value
            guard !Task.isCancelled else { return }
            commands = loaded
        }
        .onChange(of: query) { _, typed in
            commandSelection = 0
            // Waving the menu away is about the word that was on screen, so the next one
            // typed gets its own answer.
            if typed != dismissedQuery { dismissedQuery = nil }
        }
        .background {
            if dictationHere != nil {
                WindowAnchor(monitor: dictateShortcut)
                DictationKeysAnchor(keys: dictationKeys)
            }
        }
        // Registered again when the session's state changes, since the handler holds on
        // to this copy of the view.
        .onChange(of: [blocked, dictates], initial: true) {
            dictateShortcut.stop()
            guard dictationHere != nil else {
                dictation?.leave(sessionID)
                return
            }
            dictateShortcut.start {
                guard !blocked else { return false }
                toggleDictation()
                return true
            }
        }
        .onDisappear {
            dictateShortcut.stop()
            dictationKeys.stop()
            dictationHere?.leave(sessionID)
        }
        .onChange(of: listening, initial: true) { _, live in
            guard let dictation = dictationHere, live else {
                dictationKeys.stop()
                return
            }
            dictationKeys.start(stop: { dictation.stop() }, throwAway: { dictation.throwAway() })
        }
        .pasteAttachments(enabled: isFocused && !blocked) { attach($0) }
        .dropDestination(for: URL.self) { urls, _ in
            guard !blocked else { return false }
            attach(Attachments.fromDrop(urls))
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    @ViewBuilder private var sideButtons: some View {
        let steers = runner.canSteer(sessionID)
        let returnSteers = appSettings.midTurnPromptDelivery == .now
        sideButton(icon: "arrow.up.to.line", filled: !steers || !returnSteers,
                   label: "Queue prompt", tooltip: "Queue this for when the turn ends") {
            send(delivery: .afterTurn)
        }
        if steers {
            sideButton(icon: "arrow.up", filled: returnSteers, label: "Send now",
                       tooltip: "Send now - the agent takes it at its next step") {
                send(delivery: .now)
            }
        }
    }

    // A circle beside the main button for what a prompt does while a turn runs. Filled
    // for the one Return does, drawn as a card for the other.
    private func sideButton(icon: String, filled: Bool, label: String, tooltip: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(filled ? Color.white : Theme.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(filled ? Theme.accentFill : Theme.card))
                .overlay(Circle().stroke(filled ? Color.clear : Theme.border))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverLift(amount: Motion.smallLift)
        .accessibilityLabel(label)
        .appTooltip(tooltip)
        .transition(.fadeIn)
    }

    // One button that sends, stops, or waits for a stop to land. It stays put while its
    // glyph turns into the next one: the button carries views AppKit lays out itself,
    // and those cannot be spun or shrunk. With nothing to send it keeps its place, so the
    // field does not change width as soon as there is something.
    //
    // Idle it is the green send arrow. While a turn works it is red with a square and a
    // faint ring turning around it, and amber while the agent is asking a question, so
    // the way to stop is never in doubt.
    private func primaryButton(state: SessionState, canSend: Bool) -> some View {
        let stopping = state == .stopping
        let busy = state.isBusy
        let asking = runner.question(sessionID) != nil
        let fill: Color = stopping ? Theme.field
            : busy ? (asking ? Theme.attention : Theme.deletion)
            : Theme.accentFill.opacity(canSend ? 1 : 0.45)
        return Button {
            if busy { runner.stop(sessionID) } else { send(delivery: appSettings.midTurnPromptDelivery) }
        } label: {
            ZStack {
                Circle().fill(fill)
                if stopping {
                    Image(systemName: "hourglass")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .transition(.buttonSwap(reduceMotion: reduceMotion))
                } else if busy {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(.white)
                        .frame(width: 10, height: 10)
                        .transition(.buttonSwap(reduceMotion: reduceMotion))
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.buttonSwap(reduceMotion: reduceMotion))
                }
            }
            .frame(width: 32, height: 32)
            // Lifted below the ring, which is an AppKit layer view that cannot be laid
            // out under a scale.
            .hoverLift(amount: Motion.smallLift)
            .overlay {
                if busy && !stopping {
                    TurnRing(colour: asking ? Theme.attention : Theme.deletion)
                        .transition(.opacity)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(stopping || (!busy && !canSend))
        .motion(Motion.control, value: busy)
        .motion(Motion.control, value: asking)
        .motion(Motion.hover, value: canSend)
        .accessibilityLabel(stopping ? "Stopping this turn" : busy ? "Stop this turn" : "Send prompt")
        .appTooltip(stopping ? "Stopping this turn"
                    : busy ? "Stop this turn (esc)"
                    : canSend ? "Send (shift-return for a new line)" : "")
    }

    // What is waiting to go out with the next prompt. Long file names are common, so the
    // strip scrolls rather than squeezing the chips.
    @ViewBuilder private var attachmentStrip: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(attachments) { attachment in
                        AttachmentChip(url: attachment.url) {
                            runner.composer.editDraft(sessionID) { $0.attachments.removeAll { $0.id == attachment.id } }
                        }
                        .transition(.asymmetric(insertion: .fadeIn, removal: .fold))
                    }
                }
                .padding(.vertical, 1)
            }
            .transition(.fold)
        }
    }

    // The keys the menu answers, taken only while it is on screen. Return picks the
    // highlighted command rather than sending, so a half-typed name can never be sent as
    // a prompt by the key that finishes it; the next return sends what it left behind.
    private func commandKey(_ key: CommandKey) -> Bool {
        let matches = matches
        guard !blocked, !matches.isEmpty else { return false }
        let selected = min(commandSelection, matches.count - 1)
        switch key {
        case .up:
            commandSelection = (selected - 1 + matches.count) % matches.count
        case .down:
            commandSelection = (selected + 1) % matches.count
        case .complete:
            take(matches[selected])
        case .cancel:
            dismissedQuery = query
        }
        return true
    }

    // The name goes in whole, with a space after it, so anything the command takes can be
    // typed straight on the end. The space also closes the menu, since the word is settled.
    private func take(_ command: AgentCommand) {
        runner.composer.editDraft(sessionID) { $0.text = command.typed + " " }
        commandSelection = 0
        isFocused = true
    }

    private func attach(_ found: [Attachment]) {
        runner.composer.attach(found, to: sessionID)
        isFocused = true
    }

    private func send(delivery: SessionRunner.PromptDelivery) {
        let draft = runner.composer.draft(sessionID)
        guard !blocked, !draft.isEmpty else { return }
        guard dictationHere?.isListening(sessionID) != true,
              dictationHere?.isPreparing(sessionID) != true else { return }
        onSend?()
        runner.send(draft.text.trimmed,
                    attachments: draft.attachments,
                    customInstructions: draft.customInstructions,
                    dictated: draft.dictated,
                    delivery: delivery,
                    sessionID: sessionID,
                    store: store)
        runner.composer.clearDraft(sessionID)
        dictationHere?.sent(sessionID)
    }

    // MARK: - Dictation

    private var dictationMarks: ComposerMarks {
        guard let dictation = dictationHere else { return ComposerMarks() }
        if dictation.isListening(sessionID) {
            return ComposerMarks(tentative: dictation.tentative)
        }
        return ComposerMarks(unsure: dictation.review(sessionID)?.unsure.map(\.range) ?? [])
    }

    private func toggleDictation() {
        guard let dictation = dictationHere, !blocked else { return }
        let session = store.session(sessionID)
        let project = session.flatMap { store.project($0.projectID) }
        // Names the engine is likely to hear in a prompt about this project.
        let vocabulary = [project?.name, session?.worktreeBranch].compactMap { $0 }
            + store.sessions.filter { $0.projectID == session?.projectID }.map(\.title)
        let link = fieldLink
        dictation.toggle(DictationRequest(
            sessionID: sessionID,
            draft: runner.composer.draftBinding(sessionID),
            caret: link.caret ?? (runner.composer.draft(sessionID).text as NSString).length,
            roots: session.map(store.workingDirectories(for:)) ?? [],
            vocabulary: vocabulary,
            placeCaret: { location in
                isFocused = true
                link.placeCaret(location)
            }))
    }

    private func showWordMenu(_ index: Int, at frame: CGRect) {
        guard let words = dictationHere?.review(sessionID)?.unsure, words.indices.contains(index) else { return }
        guard let dictation = dictationHere else { return }
        let feedback = DictationFeedback(dictation: dictation, sessionID: sessionID,
                                         draft: runner.composer.draftBinding(sessionID),
                                         notice: dictation.notice(for: sessionID))
        menus?.show(feedback.wordMenu(words[index]),
                   at: CGPoint(x: frame.minX, y: frame.minY - 4),
                   verticalAttachment: .control(edge: .top, oppositeY: frame.maxY + 4))
    }
}

// A faint arc turning around the stop button once every 1.4 seconds, so a working turn
// reads as alive even with the transcript scrolled away. With motion turned down it holds
// still and the colour and the square still say the turn is running.
private struct TurnRing: View {
    let colour: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TurnRingLayer(colour: colour, moving: !reduceMotion)
            .padding(-4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct TurnRingLayer: NSViewRepresentable {
    let colour: Color
    let moving: Bool

    func makeNSView(context: Context) -> TurnRingView { TurnRingView() }

    func updateNSView(_ view: TurnRingView, context: Context) {
        view.update(colour: colour.resolve(in: context.environment).cgColor, moving: moving)
    }
}

// The arc is a slice of a conic gradient seen through a ring-shaped mask. The gradient
// fades in towards the arc's leading end, which is the end the turn moves towards.
final class TurnRingView: LoopLayerView {
    static let lap: CFTimeInterval = 1.4
    static let arcLength: NSNumber = 0.3

    private let turner = CALayer()
    private let gradient = CAGradientLayer()
    private let ring = CAShapeLayer()
    private var colour: CGColor?
    private(set) var moving = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [0, Self.arcLength, Self.arcLength, 1]
        ring.fillColor = nil
        ring.strokeColor = .black
        ring.lineWidth = 2
        gradient.mask = ring
        turner.addSublayer(gradient)
        layer?.addSublayer(turner)
    }

    var loops: [String] { turner.animationKeys() ?? [] }

    func update(colour: CGColor, moving: Bool) {
        if colour != self.colour {
            self.colour = colour
            let clear = colour.copy(alpha: 0) ?? colour
            let lit = colour.copy(alpha: colour.alpha * 0.55) ?? colour
            LayerLoop.still { gradient.colors = [clear, lit, clear, clear] }
        }
        guard moving != self.moving else { return }
        self.moving = moving
        restartLoops()
    }

    override func layoutLayers() {
        turner.bounds = bounds
        turner.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // The line is centred on the circle, so half of it lies outside the view. The
        // gradient reaches that far too, or the mask would cut the line in half.
        let overhang = ring.lineWidth / 2
        gradient.frame = bounds.insetBy(dx: -overhang, dy: -overhang)
        ring.frame = gradient.bounds
        ring.path = CGPath(ellipseIn: gradient.bounds.insetBy(dx: overhang, dy: overhang),
                           transform: nil)
    }

    override func restartLoops() {
        turner.removeAnimation(forKey: "turn")
        guard moving else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = CGFloat.pi * 2
        turn.duration = Self.lap
        turner.add(LayerLoop.repeating(turn, period: Self.lap), forKey: "turn")
    }
}
