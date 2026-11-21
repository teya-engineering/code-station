import AppKit
import SwiftUI

// Only what changed is read, so the transcript is not searched on every redraw.
struct LinkedApp: Equatable {
    private(set) var address: URL?
    private var lastSeen: UUID?

    mutating func read(_ messages: [ChatMessage]) {
        if let lastSeen, let end = messages.lastIndex(where: { $0.id == lastSeen }) {
            // Of the messages already read, only the reply being written can still link
            // anything, and it can grow in the same update that adds messages after it.
            let start = messages[...end].lastIndex(where: { $0.role == .assistant }) ?? end + 1
            address = TranscriptLink.latestLocalServer(in: Array(messages[start...])) ?? address
        } else {
            // After a rewind the message last read is gone, so everything is read again.
            address = TranscriptLink.latestLocalServer(in: messages)
        }
        lastSeen = messages.last?.id
    }
}

// The detail pane for one Claude Code conversation: the transcript or the working tree
// diff, with a real shell docked underneath. The terminal shares the screen rather
// than replacing it, so a build and what the agent did are one glance apart.

struct SessionView: View {
    @Environment(ProjectStore.self) var store
    @Environment(SessionRunner.self) var runner
    @Environment(TerminalStore.self) var terminals
    @Environment(DialogPresenter.self) var dialogs
    @Environment(MenuPresenter.self) private var menus
    @Environment(AppSettings.self) var appSettings
    @Environment(\.keyBindings) var keyBindings
    @Environment(GitStatsCache.self) var gitStats
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(GlobalCommandPaletteController.self) private var commandPalette
    @Environment(PullRequestReviewStore.self) var pullRequestReviews
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let sessionID: UUID

    enum Tab: Hashable {
        case conversation, design, troubleshoot, evidence, changes, explorer, reviews

        init(opening: SessionDestination) {
            self = switch opening {
            case .conversation: .conversation
            case .design: .design
            case .troubleshoot: .troubleshoot
            case .evidence: .evidence
            case .changes, .change: .changes
            case .explorer: .explorer
            case .reviews: .reviews
            }
        }
    }

    @State var tab: Tab = .conversation
    @State private var terminalFocused = false
    @State var composerFocused = false
    @State var selectedProjectID: UUID?
    @State private var collapsedExplorerProjects: Set<String> = []
    @State var changesNavigation = ChangesNavigationMemory()
    @State var secondOpinion = SessionSecondOpinion()
    // Where the header's second opinion control sits and how big the ask card drew, so
    // the card can be hung under whatever opened it.
    @State var headerOpinionFrame = CGRect.zero
    @State var opinionCardSize = CGSize.zero
    @State private var explorerShowsDesignFiles = false
    @State var shortcutEditor: ShortcutEditorRequest?
    @State var composerBarWidth: CGFloat = 340
    @State var exportingDesignMaterials = false
    @State var transcriptWindow = TranscriptWindow()
    @State var transcriptPinnedToBottom = true
    // Held by the pane rather than by any one message, since the whole point of it is
    // to carry a selection from a paragraph in one message into a paragraph in another.
    @State var transcriptSelection = TranscriptSelection()
    @State var transcriptFind: TranscriptFind
    // Both strokes a person tries for find, caught with monitors for the same reason as
    // the file view's find: a SwiftUI shortcut only gets the stroke after the sidebar's
    // filter has taken it.
    @State private var findMonitor = WindowKeyMonitor(.control, "f")
    @State private var commandFindMonitor = WindowKeyMonitor(AppCommand.findInConversation.info.keys)
    @FocusState var findFocused: Bool
    @State var transcriptScrollRequest = 0
    // When a prompt last left this composer, so the bubble it becomes can lift into place.
    @State var promptSentAt: Date?
    @State var handoffArrival = TurnHandoffArrival()
    @State var arrivingEnding: Date?
    @State var reviewingEnding: Date?
    @State var reviewedEnding: Date?
    @State var focusHandoffReview = false
    @State var agentFocus: AgentTranscriptFocus?
    @State var recapState = RecapCard()
    // The title being typed while the header's title is open for renaming.
    @State var titleDraft: SessionTitleDraft?
    @State private var requestedChange: RequestedChange?
    @State private var explorerReveal: ExplorerReveal?
    @State var explorerCommand: ExplorerCommand?
    @State var explorerShowsHidden = true
    @State var explorerOpenFolders = 0
    @State var previews = LocalServerPreviewTabs()
    @State var previewFocused = false
    @State var previewAddressFocused = false
    @State var linkedApp = LinkedApp()
    // False until this session's transcript has been scrolled to its end. The pane is
    // rebuilt per session, so it starts false on every switch without being reset.
    @State var opened = false
    // Set by choosing to keep waiting, and cleared when the wait ends, so the next turn
    // that parks itself asks again rather than inheriting an answer about another task.
    @State var waitNoticeDismissed = false
    // Which of this session's folders are gone, and which of those can be built again.
    // Sampled at the moments listed on `sampleMissingFolders` and held here rather than
    // asked while drawing: the file system is what the warning strip is about and SwiftUI
    // has no way to observe it, so asking during a redraw leaves the strip only as current
    // as the last unrelated reason to draw - still reporting a folder that had come back,
    // and silent about one that had just gone.
    @State var missingDirectories: [String] = []
    @State private var rebuildableCheckouts: [LostCheckout] = []

    // Working tree totals for the header live in the shared cache and are refreshed
    // as tools finish, so the numbers track the run rather than only its end and are
    // already there the next time this session opens.
    @State private var statsTask: Task<Void, Never>?
    @State private var designHasContent: Bool?
    // Focus goes back to the button that opened the questions card once it is put away.
    @AccessibilityFocusState var askButtonFocused: Bool
    @State var railNote = TransientNote(duration: .seconds(1.9))

    let bottomAnchor = "transcript-bottom"
    var terminalScope: TerminalScope { .session(sessionID) }
    private var shortcutScope: ShortcutScope { .session(sessionID) }

    private struct RequestedChange: Hashable {
        let root: String
        let path: String
    }

    init(sessionID: UUID, opening: SessionDestination = .conversation,
         transcriptFind: TranscriptFind = TranscriptFind()) {
        self.sessionID = sessionID
        _transcriptFind = State(initialValue: transcriptFind)
        _tab = State(initialValue: Tab(opening: opening))
        if case .change(let root, let path) = opening {
            _requestedChange = State(initialValue: RequestedChange(root: root, path: path))
        }
    }

    var body: some View {
        // The sidebar can delete a session or its project while it is on screen.
        if let session = store.session(sessionID), let project = store.project(session.projectID) {
            let workingDirectories = store.workingDirectories(for: session)
            let workingDirectory = workingDirectories.first ?? project.path
            let projectDirectory = directory(for: selectedProjectID ?? session.projectID,
                                             in: session) ?? workingDirectory
            let designFilesURL = store.designFilesURL(for: session)
            let recap = store.recap(for: sessionID)
            // A Design gets its folder only once the agent writes into it, so until then
            // the Explorer has nothing to list there and leaves it out.
            let explorerDesignFilesURL = hasDesignFiles(session, of: session) ? designFilesURL : nil
            let explorerDirectory = explorerShowsDesignFiles
                ? explorerDesignFilesURL?.path ?? projectDirectory
                : projectDirectory
            // Built once for the pass: the deck lays the row out at several widths, and the
            // Evidence tab reads the whole transcript to know whether it has anything.
            let tabs = headerTabs(for: session)
            VStack(spacing: 0) {
                // Cards anchored to a band hang over whatever is under it. A VStack draws
                // its children in order, so without these the transcript would cover them,
                // and the facts card opening off the first deck would go under the second.
                identityDeck(session: session, project: project)
                    .zIndex(2)
                destinationDeck(session: session, project: project, recap: recap, tabs: tabs)
                    .zIndex(1)
                warningStrip(session: session, project: project)
                if store.designHasUpdated(for: session) {
                    designUpdateStrip(session)
                }
                if session.isTroubleshooting && tab == .conversation && !session.isActivelyDesigning {
                    diagnosisStrip(session)
                }
                // The group hands the transition to each page, so whichever one is chosen
                // lifts in under the tab that chose it.
                Group {
                    switch tab {
                    case .conversation:
                        if session.isActivelyDesigning {
                            DesignView(sessionID: session.id)
                        } else {
                            conversation(session: session, project: project)
                        }
                    case .design:
                        if let design = store.designSession(for: session.id) {
                            DesignView(sessionID: design.id) { tab = .conversation }
                        } else if session.sourceDesignSessionID != nil {
                            DesignReferenceView(sessionID: session.id)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .task { openDesign(for: session) }
                        }
                    case .troubleshoot:
                        TroubleshootTabView(sessionID: session.id) { tab = .conversation }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .evidence:
                        TroubleshootEvidenceView(session: session) { messageID, toolID in
                            showInConversation(messageID, toolID: toolID, in: session)
                        }
                        .environment(\.askAgent, askAgent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .reviews:
                        PullRequestReviewsView(sessionID: session.id, openChanges: { tab = .changes })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .changes:
                        VStack(spacing: 0) {
                            WorkspaceChangesView(session: session, initialRoot: requestedChange?.root ?? projectDirectory,
                                                 initialPath: requestedChange?.path,
                                                 selectedRoot: Binding(get: { projectDirectory }, set: { root in
                                                     selectWorkspaceRoot(root, in: session)
                                                 }), navigation: changesNavigation,
                                                 reviewSent: {
                                                     tab = .conversation
                                                     previews.hide()
                                                 })
                            if let reviewingEnding,
                               reviewingEnding == runner.lastTurnEnding(sessionID)?.ended,
                               !runner.state(sessionID).isBusy {
                                TurnReviewFooter(back: returnToHandoff, viewed: changesNavigation.viewedTally) {
                                    reviewedEnding = reviewingEnding
                                    returnToHandoff()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onExitCommand {
                            if reviewingEnding != nil { returnToHandoff() }
                        }
                    case .explorer:
                        ExplorerView(root: explorerDirectory, reveal: $explorerReveal,
                                     command: $explorerCommand,
                                     showHidden: $explorerShowsHidden,
                                     openFolders: $explorerOpenFolders,
                                     refreshed: { showRailNote("Refreshed \(counted($0, "item"))", icon: "checkmark") },
                                     repositories: workspaceRepositories(session) + (explorerDesignFilesURL.map {
                                         [ChangesRepository(root: $0.path, name: "Design files")]
                                     } ?? []),
                                     designFilesRoot: explorerDesignFilesURL?.path,
                                     collapsedProjects: $collapsedExplorerProjects,
                                     selectRoot: { root in
                                         explorerShowsDesignFiles = root == explorerDesignFilesURL?.path
                                         if !explorerShowsDesignFiles { selectWorkspaceRoot(root, in: session) }
                                     })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .transition(.headerPage(reduceMotion: reduceMotion))

                if let openRun = shortcuts.output(for: shortcutScope) {
                    ShortcutOutputDrawer(run: openRun) {
                        shortcuts.showOutput(nil, for: shortcutScope)
                    }
                    .transition(.drawer(from: .bottom, reduceMotion: reduceMotion))
                }

                if terminals.isOpen(terminalScope) {
                    TerminalDrawer(scope: terminalScope,
                                   directory: workingDirectory,
                                   focusTerminal: $terminalFocused,
                                   onBack: { composerFocused = true })
                        .transition(.drawer(from: .bottom, reduceMotion: reduceMotion))
                }
            }
            .background(Theme.background)
            .overlay(alignment: .topLeading) { opinionLayer(session) }
            .coordinateSpace(.named(SecondOpinionAskCard.space))
            .environment(\.secondOpinionAnchor, SecondOpinionAnchorAction { secondOpinion.anchor = $0 })
            .environment(\.askSecondOpinionOnFile, AskSecondOpinionOnFileAction { root, path in
                askForSecondOpinion(session, origin: .file, file: (root, path))
            })
            .environment(\.secondOpinionLineup, SecondOpinionLineup.reviewers(
                installed: runner.catalog.availableAgents, author: session.agent))
            .onChange(of: tab) { secondOpinion.close() }
            .task(id: secondOpinion.ask?.id) {
                await secondOpinion.readSinceReviewFiles(reviews: runner.reviews, sessionID: sessionID)
            }
            // Clicks deep in the transcript that act outside the window, such as revealing
            // a file or opening a link, leave their note on the rail like the header's own.
            .environment(\.showExternalNote, ExternalNote { text, icon in showRailNote(text, icon: icon) })
            .onAppear {
                composerFocused = true
                recapState.appeared(with: recap)
            }
            .sheet(item: $shortcutEditor) { request in
                ShortcutEditorView(request: request) { shortcut in
                    shortcuts.saveShortcut(shortcut)
                }
                .appOverlays()
            }
            .background(TerminalShortcut(scope: terminalScope, directory: workingDirectory,
                                         focusTerminal: $terminalFocused))
            .background(tabShortcuts(tabs))
            // A sent diagnosis has no brief form left to show; its findings are in the
            // conversation, which the Troubleshoot tab stands for from then on.
            .onChange(of: session.isTroubleshooting, initial: true) { _, troubleshooting in
                if troubleshooting && tab == .troubleshoot { tab = .conversation }
            }
            .task(id: designFilesURL) {
                // Agents and external editors write artifacts without changing the store.
                while !Task.isCancelled {
                    if let current = store.session(sessionID) {
                        let presence = store.hasDesignArtifacts(for: current)
                        if presence != designHasContent { designHasContent = presence }
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(400))
                    } catch {
                        return
                    }
                }
            }
            .background(recapShortcut)
            .background(stopShortcut)
            .background(WindowAnchor(monitor: findMonitor))
            .background(WindowAnchor(monitor: commandFindMonitor)
                .keyMonitor(commandFindMonitor, follows: .findInConversation))
            .preference(key: PaneFindShortcutKey.self,
                        value: canFindInChat(session) && keyBindings.takes(.filterSidebar, from: .findInConversation))
            .onChange(of: canFindInChat(session), initial: true) { _, canFind in
                for monitor in findMonitors {
                    guard canFind else { monitor.stop(); continue }
                    monitor.start {
                        findShortcut()
                        return true
                    }
                }
            }
            .onDisappear {
                findMonitors.forEach { $0.stop() }
                // A closed page stops following its loads, so it cannot be shown again.
                previews.closeAll()
            }
            .onChange(of: transcriptFind.isPresented ? session.messages : []) {
                transcriptFind.refresh(in: session.messages)
            }
            .onChange(of: terminalFocused) { _, focused in
                if focused { composerFocused = false }
            }
            // The reply is found by role, as a note the app adds can land below it.
            .onChange(of: session.messages.last?.id, initial: true) {
                linkedApp.read(session.messages)
            }
            .onChange(of: session.messages.last(where: { $0.role == .assistant })?.text) {
                linkedApp.read(session.messages)
            }
            .onChange(of: tab, initial: true) {
                store.noteSessionTab(openedDestination, for: sessionID)
                if tab != .changes { requestedChange = nil }
                if tab != .conversation {
                    arrivingEnding = nil
                    focusHandoffReview = false
                }
            }
            .task(id: sessionID) {
                selectedProjectID = requestedChange.flatMap { change in
                    store.checkoutProjects(for: session).first { checkout in
                        store.root(of: checkout) == change.root
                    }?.projectID
                } ?? session.projectID
                explorerShowsDesignFiles = store.hasDesignArtifacts(for: session)
                collapsedExplorerProjects = Set(workingDirectories.dropFirst())
                sampleMissingFolders()
                refreshStats(workingDirectories, reusingRecent: true)
                runner.refreshContext(sessionID)
                // Scanning a conversation means having it, and it is still being read in.
                await store.transcriptReady(sessionID)
                store.clearFinished(sessionID)
                store.findPullRequests(in: sessionID)
            }
            // Read now rather than on the next beat of the loop, so the tab's count is
            // right as the session opens.
            .task(id: sessionID) { await pullRequestReviews.load(sessionID, store: store) }
            // These folders only go missing while another program has the keyboard, so
            // coming back to this one is when the answer can have changed.
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                sampleMissingFolders()
                store.clearFinished(sessionID)
            }
            .onChange(of: completedToolCount) {
                refreshStats(workingDirectories, after: .milliseconds(350))
            }
            .onChange(of: recap) { previous, current in
                let lifts = current != nil && recapState.arrivalLifts
                withAnimation(lifts && !reduceMotion ? Motion.reveal : nil) {
                    recapState.recapChanged(old: previous, new: current,
                                           finished: store.hasFinished(sessionID))
                }
            }
            .onChange(of: runner.state(sessionID)) { _, state in
                if state.isBusy {
                    reviewingEnding = nil
                    focusHandoffReview = false
                    arrivingEnding = nil
                }
                if !state.isBusy {
                    // The runner checks the same folders before it launches and refuses the
                    // turn if one is gone, so the end of a turn is where that failure turns
                    // into a strip with a way out of it.
                    sampleMissingFolders()
                    refreshStats(workingDirectories, after: .milliseconds(350))
                }
            }
        } else {
            PaneMessage(icon: "bubble.left.and.bubble.right",
                        title: "This session is gone",
                        detail: "Choose another session from the sidebar.")
        }
    }

    // MARK: - Pages

    private var openedDestination: SessionDestination {
        switch tab {
        case .conversation: .conversation
        case .design: .design
        case .troubleshoot: .troubleshoot
        case .evidence: .evidence
        case .changes: requestedChange.map { .change(root: $0.root, path: $0.path) } ?? .changes
        case .explorer: .explorer
        case .reviews: .reviews
        }
    }

    func isDesignTabSelected(for session: ChatSession) -> Bool {
        switch tab {
        case .design:
            true
        case .conversation:
            session.isActivelyDesigning
        case .troubleshoot, .evidence, .changes, .explorer, .reviews:
            false
        }
    }

    // The turn Escape stops. A Design conversation runs in a session of its own, so what
    // is on screen is not always this session's own turn.
    var visibleConversationID: UUID {
        switch tab {
        case .design:
            return store.designSession(for: sessionID)?.id ?? sessionID
        default:
            return sessionID
        }
    }

    func openDesign(for session: ChatSession) {
        guard store.designSession(for: session.id) == nil,
              session.sourceDesignSessionID == nil else {
            tab = .design
            return
        }

        switch store.startDesign(for: session.id) {
        case .success:
            tab = .design
        case .failure(let failure):
            tab = .conversation
            dialogs.show(.notice("Could not start the Design", message: failure.message))
        }
    }

    // Evidence is read off the transcript, so each card can send the reader back to the
    // reply or call it came from.
    private func showInConversation(_ messageID: UUID, toolID: String?, in session: ChatSession) {
        tab = .conversation
        previews.hide()
        transcriptWindow.reveal(messageID, in: session.messages)
        transcriptPinnedToBottom = false
        agentFocus = AgentTranscriptFocus(messageID: messageID, toolID: toolID ?? "")
    }

    private func returnToHandoff() {
        focusHandoffReview = true
        tab = .conversation
    }

    func openChanges() {
        requestedChange = nil
        tab = .changes
    }

    func openChange(_ path: String, root: String) {
        var target = RequestedChange(root: root, path: path)
        if path.hasPrefix("/"), let session = store.session(sessionID) {
            let containingDirectory = store.workingDirectories(for: session)
                .compactMap { directory -> RequestedChange? in
                    guard let relative = path.pathRelative(to: directory) else { return nil }
                    return RequestedChange(root: directory, path: relative)
                }
                .max { $0.root.count < $1.root.count }
            if let containingDirectory { target = containingDirectory }
        }
        if let session = store.session(sessionID) { selectWorkspaceRoot(target.root, in: session) }
        requestedChange = target
        tab = .changes
    }

    func directory(for projectID: UUID, in session: ChatSession) -> String? {
        guard let checkout = store.checkoutProjects(for: session)
            .first(where: { $0.projectID == projectID }) else { return nil }
        return store.root(of: checkout)
    }

    private func workspaceRepositories(_ session: ChatSession) -> [ChangesRepository] {
        store.checkoutProjects(for: session).compactMap { checkout in
            guard let project = store.project(checkout.projectID) else { return nil }
            return ChangesRepository(root: checkout.worktreePath ?? project.path, name: project.name)
        }
    }

    func selectWorkspaceRoot(_ root: String, in session: ChatSession) {
        if let checkout = store.checkoutProjects(for: session).first(where: {
            store.root(of: $0) == root
        }) {
            selectedProjectID = checkout.projectID
            explorerShowsDesignFiles = false
            requestedChange = nil
        }
    }

    func explorerRoots(for session: ChatSession) -> [String] {
        store.workingDirectories(for: session) + [store.designFilesURL(for: session)?.path].compactMap { $0 }
    }

    func showInExplorer(_ url: URL) -> Bool {
        guard let session = store.session(sessionID),
              let target = TranscriptLink.explorerTarget(for: url,
                                                         roots: explorerRoots(for: session))
        else { return false }

        explorerShowsDesignFiles = target.root == store.designFilesURL(for: session)?.path
        if let checkout = store.checkoutProjects(for: session).first(where: { checkout in
            store.root(of: checkout) == target.root
        }) {
            selectedProjectID = checkout.projectID
        }
        explorerReveal = ExplorerReveal(path: target.path, line: target.line)
        tab = .explorer
        return true
    }

    func openPreview(_ url: URL) -> Bool {
        previews.open(url, inNewPage: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        return true
    }

    func closePreview() {
        previews.hide()
        composerFocused = true
    }

    // The button both opens and shuts it; opening puts the cursor straight in the shell
    // so it can be used without reaching for the mouse again.
    func toggleTerminal(directory: String) {
        terminalFocused = terminals.toggle(terminalScope, directory: directory)
        if !terminalFocused { composerFocused = true }
    }

    // The shell a command ran in belongs to the agent and is gone by the time its output
    // is being read, so there is none to reopen. What is worth having instead is the
    // command itself, in a shell of your own: it arrives at the prompt unrun, ready to be
    // edited or fired off. A tab with something running in it is left to it and a new one
    // is opened, since whatever holds that terminal would read the command as its input.
    func runInShell(_ command: String, directory: String) {
        terminals.setOpen(true, for: terminalScope, directory: directory)
        let idle = terminals.selection(for: terminalScope).flatMap { $0.isBusy ? nil : $0 }
        let shell = idle ?? terminals.add(to: terminalScope, directory: directory)
        shell.paste(command)
        terminalFocused = true
    }

    // A result asking for more sends the agent a follow-up, the same as typing it would.
    var askAgent: AgentAsk {
        AgentAsk(sessionID: sessionID) { [runner, store, sessionID] text in
            runner.send(text, sessionID: sessionID)
        }
    }

    // The app a folder opens in comes up over the window, and a copy shows nothing at
    // all, so the note is all the window itself shows of the click.
    func showRailNote(_ text: String, icon: String = "arrow.up.forward.app") {
        railNote.show(text, icon: icon)
    }

    // A strip the user puts away fades while the space it held closes. Under Reduce
    // Motion the space closes at once and only the fade is left.
    var dismissal: AnyTransition {
        .asymmetric(insertion: .fadeIn,
                    removal: reduceMotion ? AnyTransition.opacity.animation(Motion.leave) : .fold)
    }

    // MARK: - Keys

    // Command-1 onwards in bar order. They are numbered by position rather than by
    // destination, so a session without the Design tab still has its tabs in a row with
    // no gap in the middle.
    private func tabShortcuts(_ tabs: [HeaderTab]) -> some View {
        let numbered = Array(tabs.prefix(9).enumerated())
        return ZStack {
            ForEach(numbered, id: \.offset) { position, tab in
                Button("") { tab.activate() }
                    .keyboardShortcut(KeyEquivalent(Character("\(position + 1)")),
                                      modifiers: .command)
            }
        }
        .opacity(0)
    }

    // Nothing else on screen has a better claim on Escape: a dialog and a menu both close
    // on it, and the shell in the drawer, the running app and a focused field need the key
    // for themselves.
    private var escapeIsUnclaimed: Bool {
        dialogs.current == nil && !menus.isOpen && !terminalFocused && !previewFocused
            && !findFocused && !previewAddressFocused
    }

    // Escape calls off the running turn, so a run can be stopped without reaching for
    // the button in the composer. It only takes the key while there is a turn to stop
    // and nothing else has a better claim on it.
    @ViewBuilder private var stopShortcut: some View {
        let target = visibleConversationID
        let state = runner.state(target)
        if state.isBusy, state != .stopping, escapeIsUnclaimed,
           !recapState.isOpen, !commandPalette.isPresented,
           !(tab == .changes && changesNavigation.askingWholeChange) {
            Button("") { runner.stop(target) }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
        }
    }

    // The visible card has the first claim on Escape. In particular, closing a recap that
    // is being refreshed must not also stop the agent turn doing the refresh.
    @ViewBuilder private var recapShortcut: some View {
        if recapState.isOpen, escapeIsUnclaimed {
            Button("") { closeRecap() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
        }
    }

    // MARK: - Find in chat

    var currentMessages: [ChatMessage] {
        store.session(sessionID)?.messages ?? []
    }

    // Only the conversation is searched: the other tabs are either a file view with a
    // find of its own or a pane with no transcript in it.
    private func canFindInChat(_ session: ChatSession) -> Bool {
        tab == .conversation && !session.isActivelyDesigning && !previews.isOpen
            && dialogs.current == nil
    }

    private var findMonitors: [WindowKeyMonitor] { [findMonitor, commandFindMonitor] }

    // A selection in the chat becomes the search. Without one, find opens on the last
    // search, or goes back to the search field when it is already open.
    private func findShortcut() {
        if let query = transcriptSelection.selectedText.flatMap(TranscriptSearch.query(fromSelection:)) {
            transcriptFind.open(query: query, in: currentMessages)
        } else if !transcriptFind.isPresented {
            transcriptFind.open(in: currentMessages)
        }
        $findFocused.request()
    }

    func closeFind() {
        transcriptFind.close()
        findFocused = false
        composerFocused = true
    }

    // MARK: - Strips under the decks

    // A banner that names a problem and stops there leaves the reader hunting for the way
    // out of it. A checkout the app made is one it can make again, so that is offered here
    // rather than left to a session deleted and started over, which costs the conversation.
    @ViewBuilder private func warningStrip(session: ChatSession, project: Project) -> some View {
        if store.isMissing(project) {
            WarningStrip("Folder not found at \(project.collapsedPath). Move it back or remove the project.")
        } else if let missing = missingDirectories.first {
            // Which of the two this is comes from the session rather than from the path:
            // a workspace folder and a worktree both turn up in `workingDirectories`, and
            // only the session says whether it has members.
            let name = session.sessionProjects == nil ? "Worktree" : "Workspace folder"
            // The folder named is one the button can actually put back, so the sentence and
            // the action cannot point at different folders - a workspace can be missing one
            // of each.
            if let rebuildable = rebuildableCheckouts.first {
                WarningStrip("\(name) not found at \(rebuildable.path.abbreviatedPath). It was removed outside the app.") {
                    ActionButton(title: "Rebuild", tone: .outlined, height: ControlHeight.sm, size: Typography.Size.detail) {
                        confirmRebuild()
                    }
                }
            } else {
                WarningStrip("\(name) not found at \(missing.abbreviatedPath). Move it back, or delete this session.")
            }
        } else if !runner.catalog.isAvailable(session.agent) {
            WarningStrip("\(session.agent.title) CLI not found on PATH. Sessions cannot run until it is installed.")
        }
    }

    // A handful of stat calls on the folders whose disappearing is the whole subject of the
    // strip. Cheap, but asked only at the moments the answer can have changed or is about to
    // be needed: opening the session, returning to the app, the end of a turn, and a rebuild.
    // A folder that goes while the session sits open and untouched therefore goes unreported
    // until one of those, which costs nothing: the runner refuses the turn on its own check.
    private func sampleMissingFolders() {
        guard let session = store.session(sessionID) else { return }
        let missing = SessionLifecycle.missingDirectories(of: session, in: store)
        if missing != missingDirectories { missingDirectories = missing }
        let rebuildable = SessionLifecycle.rebuildableCheckouts(of: session, in: store)
        if rebuildable != rebuildableCheckouts { rebuildableCheckouts = rebuildable }
    }

    // What the rebuild would do is worked out before it is offered, so the confirmation names
    // where the commits come from instead of guessing. Promising work that is not there would
    // be worse than offering nothing.
    private func confirmRebuild() {
        let checkouts = rebuildableCheckouts
        Task {
            let plan = await SessionLifecycle.planRebuild(checkouts)
            guard !plan.isEmpty else {
                dialogs.show(.notice("Nothing here can be rebuilt",
                                     message: "Git could not be asked which branch these folders were on."))
                return
            }
            dialogs.show(.confirm(plan.count == 1 ? "Rebuild the missing folder?"
                                                  : "Rebuild the missing folders?",
                                  message: SessionLifecycle.rebuildMessage(for: plan),
                                  action: "Rebuild", kind: .primary) { rebuild(plan) })
        }
    }

    private func rebuild(_ plan: [PlannedRebuild]) {
        Task {
            // Sampled straight away rather than left to the next tick, so the banner answers
            // the button instead of clearing a moment later on its own. Done either way: a
            // run that rebuilt some of a workspace's folders before failing has still changed
            // what the banner should say.
            defer { sampleMissingFolders() }
            if case .failure(let failure) = await SessionLifecycle.rebuild(plan) {
                dialogs.show(.notice(failure.title, message: failure.message))
            }
        }
    }

    private func designUpdateStrip(_ session: ChatSession) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: "paintbrush.pointed.fill")
                .font(Typography.caption.weight(.semibold))
            Text("A newer approved Design is available.")
                .font(Typography.detail.weight(.medium))
            Spacer(minLength: 10)
            ActionButton(title: "Send update", tone: .outlined, height: ControlHeight.md, size: Typography.Size.caption) {
                switch DesignHandoffLifecycle.sendLatestDesign(
                    to: session.id, store: store, runner: runner) {
                case .success:
                    tab = .design
                case .failure(let failure):
                    dialogs.show(.notice(failure.title, message: failure.message))
                }
            }
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, Space.xxl)
        .frame(height: 36)
        .background(Theme.accent.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.accent.opacity(0.25)).frame(height: 1)
        }
    }

    // A diagnosis reads its own state, place and findings off this line rather than off
    // the header, which stands for the session as a whole. It shares the header pill's
    // reading, so the two never disagree about what the agent is doing.
    private func diagnosisStrip(_ session: ChatSession) -> some View {
        let tone = SessionTone(sessionID, store: store, runner: runner)
        let model = session.settings?.model
            ?? session.usage?.model(for: session.agent)
            ?? runner.catalog.defaults(for: session.agent).model
        let agentLine = [session.agent.title, model.map { runner.catalog.modelTitle($0) }]
            .compactMap { $0 }.joined(separator: " · ")
        return TroubleshootDiagnosisStrip(
            session: session,
            state: sessionState(tone: tone, conversation: session, isTroubleshooting: true),
            agentLine: agentLine,
            openEvidence: { tab = .evidence })
    }

    func sessionState(tone: SessionTone, conversation: ChatSession,
                              isTroubleshooting: Bool) -> SessionStateReading {
        // Read off the wait rather than the tone: a wait that has gone stale reads as
        // NEEDS YOU, and how long it has been held is exactly what that state is for.
        let waitingSince = runner.waitingSince(conversation.id)
        let since: Date? = switch tone {
        case .running: runner.turnStarted(conversation.id)
        default: waitingSince ?? conversation.lastActivity
        }
        return SessionStateReading(tone: tone,
                            since: conversation.messages.isEmpty && tone != .running ? nil : since,
                            ticks: tone == .running || waitingSince != nil,
                            diagnosing: isTroubleshooting,
                            completionActivity: runner.completionActivity(conversation.id),
                            isNew: conversation.messages.isEmpty)
    }

    // MARK: - Disk and git

    // Whether a Design has files. The disk is not asked while drawing: the loop on `body`
    // keeps the answer for this session's Design folder, and that copy is used whenever
    // the Design asked about lives there. Before the loop's first answer, and for a Design
    // kept in another folder, the disk is asked.
    func hasDesignFiles(_ design: ChatSession, of session: ChatSession) -> Bool {
        guard let designHasContent,
              store.designFilesURL(for: design) == store.designFilesURL(for: session) else {
            return store.hasDesignArtifacts(for: design)
        }
        return designHasContent
    }

    // One snapshot for each of the session's folders, lead checkout first, and nil where
    // git has not answered yet. The cache only ever holds snapshots of a readable
    // repository, so having one is the same as the repository being ready.
    func treeSnapshots(_ session: ChatSession) -> [GitSnapshot?] {
        store.workingDirectories(for: session).map { gitStats.snapshot(at: $0) }
    }

    func workingTreeChanges(_ session: ChatSession) -> SessionFacts.Changes? {
        SessionFacts.Changes(snapshots: treeSnapshots(session).compactMap { $0 }, summary: session.summary)
    }

    // Completed tool calls in the turn that is streaming right now. Each one may have
    // touched the working tree, so each is a moment to refresh the header stats.
    private var completedToolCount: Int {
        guard let last = store.session(sessionID)?.messages.last, last.role == .assistant else { return 0 }
        return last.tools.count { !$0.isRunning }
    }

    // `reusingRecent` is for opening a session, where the trees are usually the ones just
    // looked at and git has nothing new to say. A tree inspected that recently is skipped
    // outright rather than refreshed behind the numbers already on screen, so the window
    // is kept short: nothing else will correct them until a tool finishes or the run ends.
    // Anything that follows a change to the working tree must ask again, so it leaves
    // this off.
    private func refreshStats(_ roots: [String], after delay: Duration? = nil,
                              reusingRecent: Bool = false) {
        let roots = reusingRecent
            ? roots.filter { !gitStats.isFresh(at: $0, within: .seconds(5)) }
            : roots
        guard !roots.isEmpty else { return }
        statsTask?.cancel()
        statsTask = Task {
            if let delay {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            // Each tree's answer lands in the cache as it arrives rather than all at
            // once, so a workspace with one slow repository still updates the rest.
            await withTaskGroup(of: (String, GitSnapshot).self) { group in
                for root in roots {
                    group.addTask { (root, await GitInspector.snapshot(at: root, lane: .interactive)) }
                }
                for await (root, snapshot) in group {
                    if !Task.isCancelled { gitStats.store(snapshot, at: root) }
                }
            }
        }
    }
}
