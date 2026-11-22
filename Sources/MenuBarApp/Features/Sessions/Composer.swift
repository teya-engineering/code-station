import AppKit
import QuartzCore
import SwiftUI

// The prompt box under a transcript: what has been dropped or pasted onto it, the field
// itself, and the button that sends or stops. The Chat and Design panes both
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
    // Whether the arrows have walked the menu for the word at the caret. Further into a
    // prompt return only picks a command once they have, since a slash word there is as
    // likely a path like `/tmp` that ends the sentence.
    @State private var commandWalked = false
    // Moves on each time a fresh slash is typed, which is when the command files are read
    // again, since they can change between prompts.
    @State private var commandReload = 0
    // The slash word the menu was waved away from, so it stays away until the word
    // changes rather than coming back on the next keystroke.
    @State private var dismissedWord: SlashWord?
    // Where the caret sits in the field. The menu is about the slash word the caret is in,
    // wherever that is in the prompt.
    @State private var caret: ComposerCaret?
    @State private var fieldLink = ComposerFieldLink()
    @State private var dictateShortcut = WindowKeyMonitor(AppCommand.dictate.info.keys)
    @State private var dictationKeys = DictationKeys()
    // The composer's and the field's frames in the window, so a prompt chip flying in
    // from the shortcut list can be drawn from where it starts to where it lands.
    @State private var frame: CGRect = .zero
    @State private var fieldFrame: CGRect = .zero

    private var attachments: [Attachment] { runner.composer.draft(sessionID).attachments }

    // The slash word the caret is in, if any. Nothing until the field has placed its caret
    // in the draft as it now is.
    private var word: SlashWord? {
        let text = runner.composer.draft(sessionID).text
        guard let caret, caret.text == text else { return nil }
        return SlashQuery.word(in: text, caret: caret.location)
    }

    private func slashOffer(for word: SlashWord?) -> SlashOffer {
        guard let word, word != dismissedWord else { return SlashOffer() }
        return SlashQuery.offer(for: word, in: commands, agent: agent)
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

        let word = self.word
        let offer = slashOffer(for: word)
        let menuShown = !offer.isEmpty && isFocused && !blocked
        let menuNews: String? = menuShown ? word.flatMap { offerNews(offer, for: $0) } : nil
        let noticeShown = dictationHere?.notice(for: sessionID) != nil

        let composer = VStack(alignment: .leading, spacing: Space.md) {
            if let dictation = dictationHere, let notice = dictation.notice(for: sessionID) {
                DictationFeedback(dictation: dictation, sessionID: sessionID,
                                  draft: runner.composer.draftBinding(sessionID), notice: notice)
            }
            above
            attachmentStrip

            if menuShown {
                SlashCommandMenu(agent: agent,
                                 commands: offer.usable,
                                 startOnly: offer.startOnly,
                                 selected: min(commandSelection, max(offer.usable.count - 1, 0)),
                                 choose: take,
                                 highlight: { commandSelection = $0 })
                    .transition(.fadeIn)
            }

            HStack(alignment: buttonAlignment, spacing: Space.md) {
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
                              commandNames: SlashCommandNames(commands, agent: agent),
                              onCaretChange: { caret = $0 },
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
                    HStack(spacing: Space.sm) {
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
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { fieldFrame = $0 }
                .landingRings(runner.composer.landing(sessionID), colour: Theme.accent,
                              cornerRadius: Radius.card, reach: 1.08)

                // Send and Stop share one place, so a turn starting reads as the button
                // turning into the other, and the field never changes width over it.
                primaryButton(state: state, canSend: canSend)
            }
            .motion(Motion.reveal, value: canSend)
            .motion(Motion.control, value: busy)
            .motion(Motion.control, value: state == .stopping)

            if let insertion = runner.composer.insertion(sessionID) {
                HStack(spacing: Space.md) {
                    Label("\(insertion.name) inserted", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .motion(Motion.reveal, value: insertion.name)
                    Spacer(minLength: 0)
                    Button {
                        runner.composer.undoInsertion(sessionID)
                        announce("Insertion undone")
                    } label: {
                        Text("Undo insertion")
                            .foregroundStyle(Theme.accent)
                            .padding(.vertical, Space.xs)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverLift()
                }
                .font(Typography.caption)
                .transition(.fadeIn)
            }

            if busy && state != .stopping {
                returnHint
                    .transition(.fadeIn)
            }
        }
        .motion(Motion.reveal, value: menuShown)
        .motion(Motion.reveal, value: noticeShown)
        .motion(Motion.reveal, value: runner.composer.insertion(sessionID) != nil)
        .smoothlyResizes(when: attachments.count)
        .padding(.horizontal, inset)
        // The top matches the stack spacing, so a row above the field sits evenly
        // between the edge of the bar and the field.
        .padding(.top, Space.md)
        .padding(.bottom, Space.lg)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: Radius.card)
            .stroke(Theme.accent, lineWidth: dropTargeted ? 2 : 0)
            .padding(Space.sm))
        .motion(Motion.hover, value: dropTargeted)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .overlay(alignment: .topLeading) { promptFlight }
        .onChange(of: runner.composer.flight(sessionID)?.id) { _, id in
            // A box that has not been laid out yet has nowhere to fly to.
            if id != nil, fieldFrame == .zero, let flight = runner.composer.flight(sessionID) {
                runner.composer.land(flight, in: sessionID)
            }
        }
        // A chip still in the air when the composer goes away lands at once, so its text
        // is never lost.
        .onDisappear {
            if let flight = runner.composer.flight(sessionID) { runner.composer.land(flight, in: sessionID) }
        }

        watchingCommands(composer, roots: roots, word: word, menuNews: menuNews)
        .background {
            if dictationHere != nil {
                WindowAnchor(monitor: dictateShortcut).keyMonitor(dictateShortcut, follows: .dictate)
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

    // What keeps the command menu in step with the field: the commands on offer, the word
    // the caret is in, and what is read out about them.
    private func watchingCommands(_ content: some View, roots: [String], word: SlashWord?,
                                  menuNews: String?) -> some View {
        content
            // Saved drafts need the command names too, so they are read on arrival as well.
            .task(id: [agent.rawValue, String(commandReload)] + roots) {
                let agent = agent
                let loaded = await Task.detached {
                    AgentCommands.all(for: agent, workingDirectories: roots)
                }.value
                guard !Task.isCancelled else { return }
                commands = loaded
            }
            .onChange(of: word) { _, typed in
                commandSelection = 0
                commandWalked = false
                if typed?.query.isEmpty == true { commandReload += 1 }
                // Waving the menu away is about the word that was on screen, so the next one
                // typed gets its own answer.
                if typed != dismissedWord { dismissedWord = nil }
            }
            // Read out each time what the menu holds changes, since the caret stays in the
            // field and nothing else would say so.
            .onChange(of: menuNews) { _, news in
                if let news { announce(news) }
            }
            .onChange(of: runner.composer.focusRequest(sessionID)) { _, request in
                guard request != nil else { return }
                let text = runner.composer.draft(sessionID).text
                let end = (text as NSString).length
                caret = ComposerCaret(text: text, location: end)
                dismissedWord = SlashQuery.word(in: text, caret: end)
                isFocused = true
                fieldLink.placeCaret(end)
                fieldLink.focus()
                if let insertion = runner.composer.insertion(sessionID) {
                    announce("\(insertion.name) inserted into your message. Nothing sent.")
                }
            }
    }

    // A prompt chosen from the shortcut list flies to the top of the message box, across
    // easing out and down easing in, and its text is inserted where it lands. Under
    // Reduce Motion the flight lands at once.
    @ViewBuilder private var promptFlight: some View {
        if let flight = runner.composer.flight(sessionID), fieldFrame != .zero {
            let size = PromptFlightChip.size
            let from = CGRect(x: flight.from.minX + Space.md - frame.minX,
                              y: flight.from.midY - size.height / 2 - frame.minY,
                              width: size.width, height: size.height)
            let to = CGRect(x: fieldFrame.minX + Space.md - frame.minX,
                            y: fieldFrame.minY + Space.sm - frame.minY,
                            width: size.width, height: size.height)
            FlightView(flight: Flight(from: from, to: to),
                       onLanded: { runner.composer.land(flight, in: sessionID) }) {
                PromptFlightChip(shortcut: flight.shortcut)
            }
            .id(flight.id)
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    // While a turn runs, Return can steer it or queue for later, and nothing else on
    // screen says which. One line under the field does.
    private var returnHint: some View {
        let steerable = runner.canSteer(sessionID)
        let message: Text = if steerable && appSettings.midTurnPromptDelivery == .now {
            Text("steers the running turn. The agent reads it at its next step.")
        } else if appSettings.midTurnPromptDelivery == .now {
            Text(agent.canSteer
                 ? "queues it, since this turn cannot take a prompt right now."
                 : "queues it for when the turn ends. \(agent.title) cannot take a prompt mid-turn.")
        } else if agent.canSteer {
            Text("queues it for when the turn ends. Use \(Text("Steer now").fontWeight(.semibold).foregroundStyle(Theme.accent)) on a queued prompt to send it into this turn.")
        } else {
            Text("queues it for when the turn ends.")
        }
        return HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text("return")
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.75))
                .padding(.horizontal, Space.xs)
                .background(RoundedRectangle(cornerRadius: Radius.tag).fill(Theme.field))
            message
                .font(Typography.detail)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .padding(.leading, Space.xxs)
        .accessibilityElement(children: .combine)
        .motion(Motion.control, value: steerable)
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
                        .font(Typography.label)
                        .foregroundStyle(.secondary)
                        .transition(.buttonSwap(reduceMotion: reduceMotion))
                } else if busy {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Theme.onFill)
                        .frame(width: 10, height: 10)
                        .transition(.buttonSwap(reduceMotion: reduceMotion))
                } else {
                    Image(systemName: "arrow.up")
                        .font(Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.onFill)
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
                HStack(spacing: Space.sm) {
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

    // What the menu says to someone who cannot see it, each time what it holds changes.
    private func offerNews(_ offer: SlashOffer, for word: SlashWord) -> String? {
        if offer.usable.isEmpty, offer.startOnly.count == 1, let only = offer.startOnly.first {
            return "\(only.typed) \(SlashCommandMenu.startOnlyNote.lowercased())"
        }
        if offer.usable.isEmpty {
            return "\(offer.startOnly.count) commands matching /\(word.query) only work at the start of a prompt"
        }
        let count = offer.usable.count
        return "\(count) \(count == 1 ? "command matches" : "commands match") /\(word.query)"
    }

    // The keys the menu answers, taken only while it is on screen. Tab picks the
    // highlighted command. Return does too for the first word of a prompt, so a half-typed
    // name is never sent as a prompt by the key that finishes it; the next return sends
    // what it left behind. Further in, return sends unless the arrows have walked the menu.
    // The rows that only work at the start of a prompt are passed over: with nothing else
    // on offer the arrows and return keep their usual meaning.
    private func commandKey(_ key: CommandKey) -> Bool {
        let word = self.word
        let offer = slashOffer(for: word)
        guard !blocked, let word, !offer.isEmpty else { return false }
        if key == .cancel {
            dismissedWord = word
            return true
        }
        let usable = offer.usable
        guard !usable.isEmpty else { return false }
        let selected = min(commandSelection, usable.count - 1)
        switch key {
        case .up:
            commandSelection = (selected - 1 + usable.count) % usable.count
            commandWalked = true
            announceRow(usable[commandSelection])
        case .down:
            commandSelection = (selected + 1) % usable.count
            commandWalked = true
            announceRow(usable[commandSelection])
        case .complete:
            take(usable[selected])
        case .submit:
            guard word.atStart || commandWalked else { return false }
            take(usable[selected])
        case .cancel:
            break
        }
        return true
    }

    // The caret stays in the field while the arrows walk the menu, so the row they land
    // on is read out.
    private func announceRow(_ command: AgentCommand) {
        announce("\(command.typed). \(command.summary)")
    }

    // Only the word at the caret is replaced, so the rest of the prompt stays as written.
    private func take(_ command: AgentCommand) {
        guard let word, let location = caret?.location else { return }
        let done = SlashQuery.completing(word, with: command, caret: location,
                                         in: runner.composer.draft(sessionID).text)
        runner.composer.editDraft(sessionID) { $0.text = done.text }
        caret = ComposerCaret(text: done.text, location: done.caret)
        // The word just put in is settled, so the menu does not offer it again while the
        // caret is still at its end.
        dismissedWord = SlashQuery.word(in: done.text, caret: done.caret)
        commandSelection = 0
        isFocused = true
        fieldLink.placeCaret(done.caret)
        if !reduceMotion {
            fieldLink.wash(NSRange(location: word.range.location, length: (command.typed as NSString).length),
                           holding: command.typed)
        }
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
                    sessionID: sessionID)
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

// The small chip a prompt rides in on its way to the message box. Plain SwiftUI, since
// a flight may scale what it carries.
struct PromptFlightChip: View {
    let shortcut: Shortcut

    static let size = CGSize(width: 220, height: ControlHeight.xl)

    var body: some View {
        HStack(spacing: Space.sm) {
            KindTile(kind: .prompt, icon: shortcut.icon ?? ShortcutKind.prompt.icon, side: ControlHeight.sm)
            Text(shortcut.name)
                .font(Typography.detail.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.sm)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Theme.accent, lineWidth: 1))
        .elevation(.floating)
    }
}
