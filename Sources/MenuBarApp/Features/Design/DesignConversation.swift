import AppKit
import SwiftUI
import CodeStationCore

enum DesignConversationLayout {
    static let minimizedSize = CGSize(width: 210, height: 56)
    static let minimizedMaxWidth: CGFloat = 320
    // The expand button sits in the top-right corner, this far in from both edges.
    static let cornerButtonSize: CGFloat = 28
    static let cornerButtonInset: CGFloat = 10

    static func inset(in workspace: CGSize) -> CGFloat {
        min(workspace.width < 720 ? 12 : 22, max(0, min(workspace.width, workspace.height) / 2))
    }

    // The folded panel follows the measured heights of the transcript and the composer, so a
    // short transcript does not leave a gap above it. A long transcript stops at the folded cap.
    // The small tab hugs its line of text, between its minimum and maximum widths.
    static func size(in workspace: CGSize, expanded: Bool, minimized: Bool = false,
                     composerHeight: CGFloat = 167, transcriptHeight: CGFloat = .infinity,
                     minimizedWidth: CGFloat = 0) -> CGSize {
        let margin = inset(in: workspace) * 2
        let available = CGSize(width: max(0, workspace.width - margin),
                               height: max(0, workspace.height - margin))
        if minimized {
            let width = min(max(minimizedSize.width, minimizedWidth), minimizedMaxWidth)
            return CGSize(width: min(width, available.width),
                          height: min(minimizedSize.height, available.height))
        }
        guard expanded else {
            let height = min(326, transcriptHeight + composerHeight)
            return CGSize(width: min(880, available.width), height: min(height, available.height))
        }
        return available
    }

    // The one line on the small tab. It names the state in words, so the state never rests
    // on the colour of the ring alone. A running turn shows the bot's current working word.
    static func minimizedLine(_ tone: SessionTone, word: String, waited: String?) -> String {
        switch tone {
        case .running: "\(word)…"
        case .waiting: waited.map { "Waiting… \($0)" } ?? "Waiting…"
        case .needsYou: "Needs you"
        case .idle: "Done. Hover to expand"
        }
    }

    // The corner button takes its own presses, so a press there must not also open the panel.
    static func isOnCornerButton(_ point: CGPoint, fromTop: CGFloat, width: CGFloat) -> Bool {
        let reach = cornerButtonInset * 2 + cornerButtonSize
        return fromTop < reach && point.x > width - reach
    }

    static func minimizedAccessibilityValue(_ tone: SessionTone) -> String {
        switch tone {
        case .running: "Minimized, working"
        case .waiting: "Minimized, waiting"
        case .needsYou: "Minimized, needs you"
        case .idle: "Minimized"
        }
    }
}

// Observe presses without taking them away from the canvas or composer: a press on the
// folded transcript opens it, and a press outside the panel shrinks it to a small tab.
struct DesignConversationDismissal: NSViewRepresentable {
    let expanded: Bool
    let minimized: Bool
    let footerHeight: CGFloat
    let enabled: Bool
    let collapse: (Bool) -> Void
    let expand: () -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.expanded = expanded
        view.minimized = minimized
        view.footerHeight = footerHeight
        view.enabled = enabled
        view.collapse = collapse
        view.expand = expand
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stop() }

    final class ObserverView: NSView {
        var expanded = false
        var minimized = false
        var footerHeight: CGFloat = 0
        var enabled = true
        var collapse: ((Bool) -> Void)?
        var expand: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return stop() }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(event, frontmost: NSApp.keyWindow) == nil
                }
                return consumed ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            collapse = nil
            expand = nil
        }

        func handle(_ event: NSEvent, frontmost: NSWindow?) -> NSEvent? {
            guard enabled, !minimized, !isHiddenOrHasHiddenAncestor, let window,
                  event.window === window, window.attachedSheet == nil else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard expanded else {
                // The corner has its own expand button, and a press in the composer is someone
                // about to type, so only a press on the rest of the transcript opens the panel.
                let fromTop = isFlipped ? point.y : bounds.maxY - point.y
                let transcript = fromTop < bounds.height - footerHeight
                    && !DesignConversationLayout.isOnCornerButton(point, fromTop: fromTop, width: bounds.width)
                if event.type == .leftMouseDown, bounds.contains(point), transcript {
                    expand?()
                } else if event.type != .keyDown, !bounds.contains(point) {
                    collapse?(false)
                }
                return event
            }
            if event.type == .keyDown {
                guard event.keyCode == 53,
                      WindowKeyMonitor.routes(to: window, frontmost: frontmost)
                else { return event }
                collapse?(true)
                return nil
            }
            if !bounds.contains(point) {
                collapse?(false)
            }
            return event
        }
    }
}

// History and the composer share one floating surface over a design or a running app.
struct DesignConversation: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(MenuPresenter.self) private var menus
    @Environment(Dictation.self) private var dictation: Dictation?
    @Environment(\.textScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: ChatSession
    let size: CGSize
    @Binding var conversationExpanded: Bool
    @Binding var conversationMinimized: Bool
    @Binding var composerFocused: Bool
    // When a prompt last left this composer, so the bubble it becomes can lift into place.
    @Binding var promptSentAt: Date?
    let designEmpty: Bool
    let selectionEnabled: Bool
    let placeholder: String
    let showsDesignAmbition: Bool
    var openPreview: ((URL) -> Bool)? = nil
    // Nil for a design, as openPreview is: SwiftUI cannot compare closures, so it would
    // draw a design's panel again on every update.
    var openChange: ((String) -> Void)? = nil
    var runInShell: ((String) -> Void)? = nil
    var showInExplorer: ((URL) -> Bool)? = nil
    // Every row here is built at once, so a long chat is paged as the chat itself is.
    var pagesTranscript = false

    @FocusState private var conversationToggleFocused: Bool
    @State private var conversationHovered = false
    @State private var cornerHovered = false
    @State private var minimizedWidth: CGFloat = 0
    @State private var hasOpenedConversation = false
    @State private var transcriptAtBottom = true
    @State private var transcriptPosition = ScrollPosition(edge: .bottom)
    @State private var transcriptWindow = TranscriptWindow()
    @State private var transcriptOffset: CGFloat = 0
    @State private var expandedTranscriptOffset: CGFloat?
    @State private var composerHeight: CGFloat = 167
    @State private var transcriptHeight: CGFloat = .infinity
    @State private var waitNoticeDismissed = false

    private var sessionID: UUID { session.id }

    var body: some View {
        floatingConversation(session, size: size)
    }

    private var latestPromptID: UUID? {
        store.session(sessionID)?.messages.last(where: { $0.role == .user })?.id
    }

    // MARK: - Conversation

    private func floatingConversation(_ session: ChatSession, size: CGSize) -> some View {
        let panelSize = DesignConversationLayout.size(in: size, expanded: conversationExpanded,
                                                      minimized: conversationMinimized, composerHeight: composerHeight,
                                                      transcriptHeight: transcriptHeight,
                                                      minimizedWidth: minimizedWidth)
        let footerHeight = min(composerHeight, panelSize.height)
        let needsYou = runner.question(sessionID) != nil || runner.waitIsStale(sessionID)
            || hasTurnEndAction(runner.state(sessionID))
        return VStack(spacing: 0) {
            transcript(session, width: panelSize.width)
                .frame(width: panelSize.width, height: max(0, panelSize.height - footerHeight))
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if !designEmpty {
                        conversationToggle
                    }
                }
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(spacing: 0) {
                    turnNotices(session)
                    designComposer(session)
                    SessionRunSettingsControls(sessionID: sessionID, wraps: true,
                                               showsDesignAmbition: showsDesignAmbition)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        }
        .onHover { conversationHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation")
        // The panel stays built while it is small, so the transcript keeps its scroll
        // position and the composer keeps its text.
        .opacity(conversationMinimized ? 0 : 1)
        .allowsHitTesting(!conversationMinimized)
        .accessibilityHidden(conversationMinimized)
        .overlay {
            if conversationMinimized {
                minimizedConversation(session, needsYou: needsYou)
            }
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 17))
        .overlay {
            RoundedRectangle(cornerRadius: 17).stroke(Theme.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.14), radius: 18, x: 0, y: 8)
        .background(DesignConversationDismissal(
            expanded: conversationExpanded,
            minimized: conversationMinimized,
            footerHeight: footerHeight,
            enabled: dialogs.current == nil && !menus.isOpen && !designEmpty
                && dictation?.isListening(sessionID) != true,
            collapse: { keyboard in
                conversationExpanded = false
                // A press outside shrinks the panel to a small tab, so the canvas gets back
                // as much room as it can. Escape only steps back one level. While picking
                // elements, a press on the canvas is a pick headed for the composer, so the
                // panel stays open.
                if keyboard {
                    composerFocused = false
                    conversationToggleFocused = true
                } else if !selectionEnabled {
                    composerFocused = false
                    conversationMinimized = true
                }
            },
            expand: {
                conversationExpanded = true
            }))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: conversationExpanded)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: conversationMinimized)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: minimizedWidth)
    }

    // Expand and collapse live in the corner, out of the transcript's way. The button only
    // shows while the pointer is over the panel, but it stays up while it has focus or the
    // panel is expanded, since that is when it is the way back.
    private var conversationToggle: some View {
        let visible = conversationHovered || conversationExpanded || conversationToggleFocused
        return Button {
            conversationExpanded.toggle()
        } label: {
            Image(systemName: conversationExpanded ? "chevron.down" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(cornerHovered ? .primary : .secondary)
                .frame(width: DesignConversationLayout.cornerButtonSize,
                       height: DesignConversationLayout.cornerButtonSize)
                .background(Circle().fill(cornerHovered ? Theme.field : Theme.card))
                .overlay(Circle().stroke(conversationToggleFocused ? Theme.accent : Theme.border,
                                         lineWidth: conversationToggleFocused ? 2 : 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($conversationToggleFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.space, .return]) { _ in
            conversationExpanded.toggle()
            return .handled
        }
        .onHover { cornerHovered = $0 }
        .appTooltip(conversationExpanded ? "Collapse" : "Expand")
        .padding(DesignConversationLayout.cornerButtonInset)
        .opacity(visible ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: visible)
        .accessibilityLabel(conversationExpanded ? "Collapse the conversation" : "Expand the conversation")
    }

    private func conversationTone(needsYou: Bool) -> SessionTone {
        needsYou ? .needsYou
            : runner.waitingSince(sessionID) != nil ? .waiting
            : runner.state(sessionID).isBusy ? .running : .idle
    }

    // The panel always shows the session's bot, open or minimized, so it is clear who is
    // in the conversation. While the session is alive the bot is ringed in the state
    // colour, and it breathes while a turn is being worked on, the way its avatar does in
    // the sidebar.
    private func conversationBot(_ session: ChatSession, needsYou: Bool, size: CGFloat) -> some View {
        let tone = conversationTone(needsYou: needsYou)
        let bot = AgentAvatarSelection.avatar(named: session.agentAvatarName, from: appSettings.agentAvatars)
        return Breathing(active: tone == .running) {
            AgentAvatarView(image: bot.displayImage(for: sessionID), size: size)
        }
        .overlay(Circle().stroke(tone == .idle ? Color.clear : tone.colour, lineWidth: 1.5)
            .padding(-3))
        .accessibilityHidden(true)
    }

    // A button as well as a hover target, so the panel can be brought back by keyboard
    // and by assistive tools too.
    private func minimizedConversation(_ session: ChatSession, needsYou: Bool) -> some View {
        let tone = conversationTone(needsYou: needsYou)
        let personality = AgentAvatarSelection.avatar(named: session.agentAvatarName,
                                                      from: appSettings.agentAvatars).personality
        return Button {
            conversationMinimized = false
        } label: {
            HStack(spacing: 11) {
                conversationBot(session, needsYou: needsYou, size: 30)
                MinimizedConversationLine(tone: tone, personality: personality,
                                          waitingSince: runner.waitingSince(sessionID)) { lineWidth in
                    // The tab hugs its line: the bot, the gap and the padding around them.
                    minimizedWidth = 14 + 30 + 11 + lineWidth + 18
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { conversationMinimized = false }
        }
        .accessibilityLabel("Conversation")
        .accessibilityValue(DesignConversationLayout.minimizedAccessibilityValue(tone))
        .accessibilityHint("Show the conversation")
    }

    private func transcript(_ session: ChatSession, width: CGFloat) -> some View {
        let projectPath = store.workingDirectory(for: session) ?? ""
        let bubble = appSettings.userMessageStyle(for: session, in: store)
        let messages = pagesTranscript
            ? transcriptWindow.visibleMessages(in: session.messages) : session.messages[...]
        let hiddenCount = session.messages.count - messages.count
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if session.messages.isEmpty, showsDesignAmbition {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("What would you like to design?")
                                .font(.system(size: 13, weight: .medium))
                            Text("Describe a screen, or drag a reference into the prompt to get started.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if hiddenCount > 0 {
                        LoadEarlierMessages(hiddenCount: hiddenCount) {
                            transcriptWindow.loadEarlier(totalCount: session.messages.count)
                            guard let earliestID = transcriptWindow
                                .visibleMessages(in: session.messages).first?.id else { return }
                            Task {
                                await Task.yield()
                                proxy.scrollTo(earliestID, anchor: .top)
                            }
                        }
                    }
                    ForEach(messages) { message in
                        MessageView(message: message,
                                    projectPath: projectPath,
                                    textScale: textScale,
                                    openChange: openChange ?? { _ in },
                                    runInShell: runInShell ?? { _ in },
                                    showInExplorer: showInExplorer ?? { _ in false },
                                    openPreview: openPreview ?? { _ in false },
                                    availableWidth: width - 28,
                                    arriving: message.isArriving(sentAt: promptSentAt),
                                    bubble: bubble)
                            .equatable()
                            .environment(\.runningAgents, runner.runningAgents(sessionID))
                            .environment(\.previewsLocalServers, openPreview != nil)
                            .environment(\.activeTranscriptTools, runner.runningTools(sessionID))
                    }

                    if !runner.state(sessionID).isBusy,
                       let ending = runner.lastTurnEnding(sessionID),
                       let receipt = TurnReceipt(lastTurnIn: session.messages,
                                                 projectPath: projectPath) {
                        TurnSeal(ending: ending, receipt: receipt, arriving: ending.isFresh())
                            .id(ending.ended)
                            .transition(.fadeIn)
                    }

                    if runner.state(sessionID).isBusy, runner.question(sessionID) == nil {
                        designStatus(session)
                    }

                    Color.clear.frame(height: 1).id("design-transcript-bottom")
                }
                .padding(14)
                .background {
                    TranscriptScrollObserver(pinnedToBottom: transcriptAtBottom) { isAtBottom in
                        transcriptAtBottom = isAtBottom
                    }
                }
                .modifier(SentPromptCommands(agent: session.agent,
                                             workingDirectories: store.workingDirectories(for: session),
                                             latestPromptID: latestPromptID))
            }
            .defaultScrollAnchor(.bottom)
            .scrollPosition($transcriptPosition)
            .onChange(of: conversationExpanded) { _, expanded in
                if expanded {
                    if !hasOpenedConversation {
                        proxy.scrollTo("design-transcript-bottom", anchor: .bottom)
                    }
                    hasOpenedConversation = true
                } else {
                    expandedTranscriptOffset = transcriptOffset
                }
            }
            .task(id: conversationExpanded) {
                guard conversationExpanded, let offset = expandedTranscriptOffset else { return }
                // Restore after the width transition has finished reflowing message text.
                if !reduceMotion { try? await Task.sleep(for: .milliseconds(280)) }
                guard !Task.isCancelled else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { transcriptPosition.scrollTo(y: offset) }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                transcriptOffset = offset
            }
            // Only a person scrolling unpins the transcript. Growth alone also leaves the
            // end out of view for a moment, and reading that as "scrolled up" stopped the
            // transcript following the reply to a prompt just sent.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
                transcriptHeight = height
                if transcriptAtBottom {
                    Task { proxy.scrollTo("design-transcript-bottom", anchor: .bottom) }
                }
            }
            // The panel grows with its content and the composer shrinks once a prompt is
            // sent, so the viewport changes height under a transcript that keeps its offset.
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, _ in
                if transcriptAtBottom {
                    Task { proxy.scrollTo("design-transcript-bottom", anchor: .bottom) }
                }
            }
            .onChange(of: transcriptShape(session)) {
                if transcriptAtBottom {
                    Task { proxy.scrollTo("design-transcript-bottom", anchor: .bottom) }
                }
            }
            // A new prompt always goes to the end, even when the user had scrolled back
            // or the composer growing while they typed pushed the end out of view. The
            // scroll waits a turn so the new message is laid out before it runs.
            .onChange(of: latestPromptID) {
                transcriptAtBottom = true
                Task { proxy.scrollTo("design-transcript-bottom", anchor: .bottom) }
            }
        }
    }

    // The same row the chat shows while a turn runs, so the bot speaks here with its own
    // working words. A held-open turn names the task keeping it open instead.
    private func designStatus(_ session: ChatSession) -> some View {
        WorkingRow(since: runner.lastActivity(sessionID) ?? Date(),
                   sessionID: sessionID,
                   avatarName: session.agentAvatarName,
                   agentTitle: session.agent.title,
                   tasks: runner.backgroundTasks(sessionID),
                   waitingSince: runner.waitingSince(sessionID))
            .transition(.fadeIn)
    }

    private struct TranscriptShape: Equatable {
        var messages: Int
        var characters: Int
        var tools: Int
        var question: String?
        var state: SessionState
    }

    private func transcriptShape(_ session: ChatSession) -> TranscriptShape {
        TranscriptShape(messages: session.messages.count,
                        characters: session.messages.last?.text.count ?? 0,
                        tools: session.messages.last?.tools.count ?? 0,
                        question: runner.question(sessionID)?.id,
                        state: runner.state(sessionID))
    }

    // MARK: - Composer

    private func designComposer(_ session: ChatSession) -> some View {
        let blocked = !FileManager.default.fileExists(atPath: store.workingDirectory(for: session) ?? "")
            || !runner.isAvailable(session.agent)
        return Composer(sessionID: sessionID,
                        agent: session.agent,
                        blocked: blocked,
                        isFocused: $composerFocused,
                        placeholder: placeholder,
                        inset: 14,
                        minimumLines: 3,
                        onOversizedPaste: attachPastedText,
                        onRecallUp: { runner.recallEarlier(sessionID, store: store) },
                        onRecallDown: { runner.recallLater(sessionID, store: store) },
                        onSend: { promptSentAt = .now },
                        dictates: !conversationMinimized,
                        above: {
                            let queued = runner.queued(sessionID).count
                            if queued > 0 {
                                Text(counted(queued, "prompt") + " queued")
                                    .font(.mono(9.5, .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        },
                        accessory: {
                            SessionBotPicker(avatars: appSettings.agentAvatars,
                                             selectedName: botSelection,
                                             sessionID: sessionID,
                                             size: 22)
                        })
    }

    private var botSelection: Binding<String> {
        Binding(
            get: {
                AgentAvatarSelection.resolvedName(
                    store.session(sessionID)?.agentAvatarName,
                    availableNames: appSettings.agentAvatars.map { $0.url.lastPathComponent })
            },
            set: { store.setAgentAvatarName($0, for: sessionID) })
    }

    private func attachPastedText(_ text: String) {
        guard let attachment = Attachments.fromPastedText(text) else { return }
        runner.composer.attach([attachment], to: sessionID)
        composerFocused = true
    }

    // Questions from the agent, a held-open turn and a failed one all sit right above
    // the composer, where the answer gets typed.
    @ViewBuilder
    private func turnNotices(_ session: ChatSession) -> some View {
        let state = runner.state(sessionID)
        let projectPath = store.workingDirectory(for: session) ?? ""
        let question = runner.question(sessionID)
        let waiting = state == .waiting && !waitNoticeDismissed
            ? runner.waitingSince(sessionID) : nil
        VStack(alignment: .leading, spacing: 10) {
            if let request = question {
                PermissionCard(request: request,
                               workingDirectories: store.workingDirectories(for: session),
                               projectPath: projectPath) { answer in
                    runner.answer(request, with: answer,
                                  sessionID: sessionID, store: store)
                }
                .id(request.id)
            }

            if let waitingSince = waiting {
                WaitingNotice(since: waitingSince,
                              tasks: runner.backgroundTasks(sessionID),
                              agentTitle: session.agent.title,
                              command: { session.shellCommand(for: $0) },
                              onKeepWaiting: { waitNoticeDismissed = true },
                              onEnd: { runner.endWait(sessionID) })
            }

            TurnEndActions(sessionID: sessionID, agent: session.agent, state: state)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, question != nil || waiting != nil || hasTurnEndAction(state) ? 10 : 0)
        // A dismissed notice is dismissed for that wait only: the next one is a new turn
        // parked on new tasks, and it has its own case to make.
        .onChange(of: state) { _, state in
            if state != .waiting { waitNoticeDismissed = false }
        }
    }

    private func hasTurnEndAction(_ state: SessionState) -> Bool {
        if case .failed = state { return true }
        return runner.canContinueAfterStop(sessionID, store: store)
    }
}

// The one line on the minimized tab. A running turn walks the bot's working words, the way
// the row in the transcript does, and a wait counts itself up, so the tab keeps moving
// while nothing arrives to redraw it.
private struct MinimizedConversationLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let tone: SessionTone
    let personality: AgentPersonality
    let waitingSince: Date?
    let measured: (CGFloat) -> Void

    @State private var words = WorkingWords()
    @State private var started = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let word = words.word(after: context.date.timeIntervalSince(started))
            let line = DesignConversationLayout.minimizedLine(
                tone, word: word, waited: waitingSince.map { RelativeTime.duration(since: $0) })
            let font: Font = tone == .running || tone == .waiting ? .mono(12, .medium)
                : .system(size: 12, weight: tone == .needsYou ? .semibold : .regular)
            Text(line)
                .font(font)
                .foregroundStyle(tone == .needsYou ? Theme.attentionText
                                 : tone == .idle ? Color.secondary : Color.primary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .id(tone == .running ? word : "")
                .transition(.fadeIn)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: word)
                .background {
                    Text(line).font(font).monospacedDigit().fixedSize().hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured($0) }
                }
        }
        .onAppear { words = WorkingWords(personality: personality) }
        .onChange(of: personality) { _, personality in
            words = WorkingWords(personality: personality)
            started = .now
        }
    }
}
