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
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(TerminalStore.self) private var terminals
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(MenuPresenter.self) private var menus
    @Environment(AppSettings.self) private var appSettings
    @Environment(GitStatsCache.self) private var gitStats
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(GlobalCommandPaletteController.self) private var commandPalette
    @Environment(PullRequestReviewStore.self) private var pullRequestReviews
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sessionID: UUID

    private enum Tab: Hashable { case conversation, design, troubleshoot, evidence, changes, explorer, reviews }

    @State private var tab: Tab = .conversation
    @State private var terminalFocused = false
    @State private var composerFocused = false
    @State private var selectedProjectID: UUID?
    @State private var collapsedExplorerProjects: Set<String> = []
    @State private var changesNavigation = ChangesNavigationMemory()
    // The reviewers last asked from this session, whatever they were asked about.
    @State private var opinionLineup: [SecondOpinion.Reviewer]?
    @State private var explorerShowsDesignFiles = false
    @State private var shortcutEditor: ShortcutEditorRequest?
    @State private var exportingDesignMaterials = false
    @State private var transcriptWindow = TranscriptWindow()
    @State private var transcriptPinnedToBottom = true
    // Held by the pane rather than by any one message, since the whole point of it is
    // to carry a selection from a paragraph in one message into a paragraph in another.
    @State private var transcriptSelection = TranscriptSelection()
    @State private var transcriptFind: TranscriptFind
    // Both strokes a person tries for find, caught with monitors for the same reason as
    // the file view's find: a SwiftUI shortcut only gets the stroke after the sidebar's
    // filter has taken it.
    @State private var findMonitor = WindowKeyMonitor(.control, "f")
    @State private var commandFindMonitor = WindowKeyMonitor(.command, "f")
    @FocusState private var findFocused: Bool
    @State private var transcriptScrollRequest = 0
    // When a prompt last left this composer, so the bubble it becomes can lift into place.
    @State private var promptSentAt: Date?
    @State private var handoffArrival = TurnHandoffArrival()
    @State private var arrivingEnding: Date?
    @State private var reviewingEnding: Date?
    @State private var reviewedEnding: Date?
    @State private var focusHandoffReview = false
    @State private var agentFocus: AgentTranscriptFocus?
    @State private var recapOpen = false
    // The title being typed while the header's title is open for renaming.
    @State private var titleDraft: String?
    @State private var recapNeedsAttention = false
    // Whether the person asked for the recap that is on its way. One they asked for lifts
    // into place; one written on its own appears where it hangs without moving, since
    // nobody clicked anything for it.
    @State private var recapRequested = false
    @State private var recapArrivesUnasked = false
    @State private var workingSetVisible: Bool
    @State private var requestedChange: RequestedChange?
    @State private var explorerReveal: ExplorerReveal?
    @State private var explorerCommand: ExplorerCommand?
    @State private var explorerShowsHidden = true
    @State private var explorerOpenFolders = 0
    @State private var previews = LocalServerPreviewTabs()
    @State private var previewFocused = false
    @State private var previewAddressFocused = false
    @State private var linkedApp = LinkedApp()
    // False until this session's transcript has been scrolled to its end. The pane is
    // rebuilt per session, so it starts false on every switch without being reset.
    @State private var opened = false
    // Set by choosing to keep waiting, and cleared when the wait ends, so the next turn
    // that parks itself asks again rather than inheriting an answer about another task.
    @State private var waitNoticeDismissed = false
    // Which of this session's folders are gone, and which of those can be built again.
    // Sampled at the moments listed on `sampleMissingFolders` and held here rather than
    // asked while drawing: the file system is what the warning strip is about and SwiftUI
    // has no way to observe it, so asking during a redraw leaves the strip only as current
    // as the last unrelated reason to draw - still reporting a folder that had come back,
    // and silent about one that had just gone.
    @State private var missingDirectories: [String] = []
    @State private var rebuildableCheckouts: [LostCheckout] = []

    // Working tree totals for the header live in the shared cache and are refreshed
    // as tools finish, so the numbers track the run rather than only its end and are
    // already there the next time this session opens.
    @State private var statsTask: Task<Void, Never>?
    @State private var designHasContent: Bool?
    // Focus goes back to the button that opened the questions card once it is put away.
    @AccessibilityFocusState private var askButtonFocused: Bool
    @State private var railNotes = 0
    @State private var railNote: String?
    @State private var railNoteIcon = "arrow.up.forward.app"

    private let bottomAnchor = "transcript-bottom"
    private var terminalScope: TerminalScope { .session(sessionID) }
    private var shortcutScope: ShortcutScope { .session(sessionID) }

    private struct RequestedChange: Hashable {
        let root: String
        let path: String
    }

    init(sessionID: UUID, opening: SessionDestination = .conversation,
         transcriptFind: TranscriptFind = TranscriptFind()) {
        self.sessionID = sessionID
        _transcriptFind = State(initialValue: transcriptFind)
        switch opening {
        case .conversation:
            _tab = State(initialValue: .conversation)
            _requestedChange = State(initialValue: nil)
        case .design:
            _tab = State(initialValue: .design)
            _requestedChange = State(initialValue: nil)
        case .troubleshoot:
            _tab = State(initialValue: .troubleshoot)
            _requestedChange = State(initialValue: nil)
        case .evidence:
            _tab = State(initialValue: .evidence)
            _requestedChange = State(initialValue: nil)
        case .explorer:
            _tab = State(initialValue: .explorer)
            _requestedChange = State(initialValue: nil)
        case .changes:
            _tab = State(initialValue: .changes)
            _requestedChange = State(initialValue: nil)
        case .change(let root, let path):
            _tab = State(initialValue: .changes)
            _requestedChange = State(initialValue: RequestedChange(root: root, path: path))
        case .reviews:
            _tab = State(initialValue: .reviews)
            _requestedChange = State(initialValue: nil)
        }
        _workingSetVisible = State(
            initialValue: Preferences.workingSetVisibility()[sessionID] ?? false)
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
            let explorerDesignFilesURL = designHasContent ?? store.hasDesignArtifacts(for: session)
                ? designFilesURL : nil
            let explorerDirectory = explorerShowsDesignFiles
                ? explorerDesignFilesURL?.path ?? projectDirectory
                : projectDirectory
            VStack(spacing: 0) {
                // Cards anchored to a band hang over whatever is under it. A VStack draws
                // its children in order, so without these the transcript would cover them,
                // and the facts card opening off the first deck would go under the second.
                identityDeck(session: session, project: project)
                    .zIndex(2)
                destinationDeck(session: session, project: project, recap: recap)
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
                                TurnReviewFooter(back: returnToHandoff) {
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
                                   focusTerminal: $terminalFocused)
                        .transition(.drawer(from: .bottom, reduceMotion: reduceMotion))
                }
            }
            .background(Theme.background)
            // Clicks deep in the transcript that act outside the window, such as revealing
            // a file or opening a link, leave their note on the rail like the header's own.
            .environment(\.showExternalNote, ExternalNote { text, icon in showRailNote(text, icon: icon) })
            .onAppear {
                composerFocused = true
                recapOpen = recap != nil
                recapNeedsAttention = recap != nil
                openWorkingSetForLiveTurnIfNeeded()
            }
            .sheet(item: $shortcutEditor) { request in
                ShortcutEditorView(request: request) { shortcut in
                    shortcuts.saveShortcut(shortcut)
                }
                .appOverlays()
            }
            .background(terminalShortcut(directory: workingDirectory))
            .background(workingSetShortcut)
            .background(tabShortcuts(headerTabs(for: session)))
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
            .background(WindowAnchor(monitor: commandFindMonitor))
            .preference(key: PaneFindShortcutKey.self, value: canFindInChat(session))
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
                        let root = checkout.worktreePath ?? store.project(checkout.projectID)?.path
                        return root == change.root
                    }?.projectID
                } ?? session.projectID
                explorerShowsDesignFiles = store.hasDesignArtifacts(for: session)
                collapsedExplorerProjects = Set(workingDirectories.dropFirst())
                sampleMissingFolders()
                refreshStats(workingDirectories, reusingRecent: true)
                runner.refreshContext(sessionID, store: store)
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
                guard previous != current else { return }
                if current == nil {
                    recapOpen = false
                    recapNeedsAttention = false
                } else {
                    if recapRequested || recapOpen {
                        withAnimation(reduceMotion ? nil : Motion.reveal) {
                            recapOpen = true
                        }
                    } else {
                        recapArrivesUnasked = true
                        recapOpen = true
                    }
                    recapRequested = false
                    recapNeedsAttention = store.hasFinished(sessionID)
                }
            }
            .onChange(of: runner.state(sessionID)) { _, state in
                openWorkingSetForLiveTurnIfNeeded()
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

    // MARK: - The two decks

    // What the identity deck gives up to fit the pane. Nothing here drops an action: the
    // rail on the deck below is where every one of them lives.
    private enum HeaderFit {
        // The branch at the width a name deserves.
        case whole
        // The branch cut back to a stub.
        case folded
    }

    // The first deck stands taller than the second: it carries the identity tile and the
    // state pill, and it is the band a reader lands on first.
    private static let identityDeckHeight: CGFloat = 58
    // A 34pt tab needs more room than the thin strip of state this replaces. The eight
    // points buy destinations that are readable without being pointed at.
    private static let destinationDeckHeight: CGFloat = 40

    // How much of the session title the row is fitted around. The title truncates by
    // design, so its full length says nothing about whether the rest fits; this is the
    // stub worth keeping, and the readings give way rather than cut into it.
    private static let titleRoom: CGFloat = 110

    // How wide the branch is allowed to grow on each fit.
    private static let branchRoom: CGFloat = 210
    private static let foldedBranchRoom: CGFloat = 130

    // The first deck names the session and says what it is doing: the container's icon
    // and name, the title it was given, then the state and the branch it is on.
    // Nothing on it navigates. Where to go is the deck under it, which
    // holds every destination and every panel this pane can open.
    private func identityDeck(session: ChatSession, project: Project) -> some View {
        // The pane draws the first of these that fits. What the readings ask for is
        // measured rather than guessed at a width chosen in advance, so a longer branch
        // or a longer project name gives something up on its own instead of running off
        // the right edge of the pane.
        ViewThatFits(in: .horizontal) {
            identityRow(session: session, project: project, fit: .whole)
            identityRow(session: session, project: project, fit: .folded)
        }
    }

    private func identityRow(session: ChatSession, project: Project,
                             fit: HeaderFit) -> some View {
        let workspace = session.workspaceID.flatMap(store.workspace)
        let container = workspace?.name ?? project.name
        let context = session.usage?.contextFraction(for: session.agent)
        let tone = SessionTone(sessionID, store: store, runner: runner)
        return HStack(spacing: 8) {
            HStack(spacing: 9) {
                if let workspace {
                    SidebarIdentityTile(
                        avatar: workspace.sidebarAvatar,
                        name: workspace.name,
                        tint: Theme.workspaceTint,
                        stacked: true)
                } else {
                    SidebarIdentityTile(
                        avatar: project.sidebarAvatar,
                        name: project.name,
                        tint: Theme.projectTint(for: project.name),
                        dashed: project.kind == .adHoc)
                }
                // The durable name reads as the heading, in the same family as everything
                // else on the deck. It holds its width while there is any title left to
                // give up, and is only cut short once the title is gone.
                Text(container)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text("/")
                    .font(.mono(11))
                    .foregroundStyle(.tertiary)
                if session.isTroubleshooting {
                    MonoChip(text: "TROUBLESHOOT", size: 9, tint: Theme.secret)
                }
                SessionHeaderTitle(title: session.title, idealWidth: Self.titleRoom,
                                   draft: $titleDraft) { name in
                    store.renameSession(session.id, to: name)
                }
            }

            Spacer(minLength: 12)

            // A row splits its width between the children rather than handing each one
            // what it asks for, so the readings could be offered less than they need and
            // truncate. Holding them at their natural width makes the title give way.
            readings(session: session, fit: fit)
                .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        // The window reading closes the band the same way the rule does, so it is drawn
        // with it and stays behind anything the band opens.
        .headerBand(height: Self.identityDeckHeight) {
            if let context {
                ContextHairline(fraction: context, animated: tone == .running)
            }
        }
    }

    // The session's state and branch as one pill, with the other details behind it.
    private func readings(session: ChatSession, fit: HeaderFit) -> some View {
        // The lead checkout is the one the branch speaks for, the same root the stats
        // refresh puts first. The cache only ever holds snapshots of a readable
        // repository, so having one is the same as the repository being ready.
        let repository = store.workingDirectories(for: session).first
            .flatMap { gitStats.snapshot(at: $0) }
        let facts = facts(session, repository: repository)
        let tone = SessionTone(sessionID, store: store, runner: runner)
        // The deck stands for both of a session's conversations, so a Design turn is what
        // it counts while Design is the side running.
        let live = LiveConversation.of(sessionID, store: store, runner: runner) ?? session
        return HStack(spacing: 9) {
            SessionAgentIndicator(session: session) { target in
                tab = .conversation
                previews.hide()
                transcriptWindow.reveal(target.messageID, in: session.messages)
                transcriptPinnedToBottom = false
                agentFocus = target
            }
            SessionFactsChip(
                facts: facts,
                state: sessionState(tone: tone, conversation: live,
                                    isTroubleshooting: session.isTroubleshooting),
                maxWidth: fit == .whole ? Self.branchRoom : Self.foldedBranchRoom,
                showsBranch: tab != .changes,
                openChanges: openChanges,
                contextActions: contextActions,
                usageTooltip: {
                    guard let usage = session.usage else { return Tooltip(title: "") }
                    return usageTooltip(usage, agent: session.agent,
                                        clearable: !contextActions().isEmpty)
                },
                showNote: { showRailNote($0) })
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // What the rail gives up as the pane narrows, in the order it is worth giving up:
    // words first, then the session's actions fold behind one button. The dock never
    // folds, since it holds the panels reached for most.
    private enum RailFit {
        case wide
        case medium
        case narrow
    }

    // The second deck: where to go on the left, what to open beside where you already are
    // on the right. The gap between the two is the line the tab bar's edge used to carry.
    private func destinationDeck(session: ChatSession, project: Project,
                                 recap: SessionRecap?) -> some View {
        ViewThatFits(in: .horizontal) {
            destinationRow(session: session, project: project, recap: recap, fit: .wide)
            destinationRow(session: session, project: project, recap: recap, fit: .medium)
            destinationRow(session: session, project: project, recap: recap, fit: .narrow)
            // Even the folded rail can leave too little room for every tab label.
            destinationRow(session: session, project: project, recap: recap, fit: .narrow,
                           scrollsTabs: true)
        }
        .overlay(alignment: .topTrailing) {
            recapCard(recap)
        }
        .motion(recapOpen ? Motion.reveal : Motion.leave, value: recapOpen)
    }

    private func destinationRow(session: ChatSession, project: Project,
                                recap: SessionRecap?, fit: RailFit,
                                scrollsTabs: Bool = false) -> some View {
        HStack(spacing: 8) {
            HeaderTabDeck(tabs: headerTabs(for: session),
                          height: Self.destinationDeckHeight,
                          scrollable: scrollsTabs)
            Spacer(minLength: 12)
            rail(session: session, project: project, recap: recap, fit: fit)
        }
        // The deck's own tabs carry the inset that lines their words up with the name on
        // the band above; the rail's buttons carry theirs inside the glyph's seat.
        .padding(.leading, 9)
        .padding(.trailing, 14)
        .headerBand(Theme.statusBand, height: Self.destinationDeckHeight)
    }

    // What the pane can open beside where you already are, then what the session itself
    // offers. The dock holds what is reached for most and never folds; the actions use
    // words, so the two groups read as different kinds of thing without a hover.
    private func rail(session: ChatSession, project: Project, recap: SessionRecap?,
                      fit: RailFit) -> some View {
        HStack(spacing: 10) {
            switch tab {
            case .changes where workingTreeChanges(session) != nil:
                askWholeChangeButton
                    .transition(.opacity)
            case .explorer:
                explorerActions
                    .transition(.opacity)
            default:
                EmptyView()
            }
            dock(session: session, project: project, showsWords: fit == .wide)
            if hasUtilities(session) {
                HeaderRailDivider()
                if fit == .narrow {
                    utilitiesOverflow(session: session, project: project)
                } else {
                    utilities(session: session, project: project, recap: recap,
                              showsWords: fit == .wide)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .motion(Motion.reveal, value: tab)
        .overlay(alignment: .topTrailing) {
            if let railNote {
                HeaderNote(icon: railNoteIcon, text: railNote)
                    .offset(y: Self.destinationDeckHeight + 2)
                    .transition(reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .offset(y: -6)))
            }
        }
        .motion(Motion.reveal, value: railNote)
    }

    // None of these sends you anywhere: they open something beside the pane and leave
    // what you were reading where it was. Keeping them off the tab deck is what gives the
    // gap between the two its meaning - inside the deck you choose where to be, outside
    // it you open something next to where you already are. Preview is the exception, as
    // it puts the running app in the conversation's place.
    //
    // The second opinion leads on every tab. It is the one seat that grows while it
    // works, and the rail keeps to the trailing edge, so the seats after it stay still.
    // Most panels open beside the chat, so only the chat has the whole dock. The terminal
    // opens under any tab, so it stays where files are being looked at.
    private func dock(session: ChatSession, project: Project, showsWords: Bool) -> some View {
        HeaderRailDock {
            secondOpinionButton(session)
            switch tab {
            case .conversation:
                previewSeat(session, showsWord: showsWords)
                    .transition(.opacity)
                terminalSeat(session: session, project: project, showsWord: showsWords)
                workingSetSeat(session, showsWord: showsWords)
                    .transition(.opacity)
                findSeat(session, showsWord: showsWords)
                    .transition(.opacity)
            case .design, .troubleshoot, .evidence, .changes, .explorer:
                terminalSeat(session: session, project: project, showsWord: showsWords)
            case .reviews:
                EmptyView()
            }
        }
    }

    // The glyph toggles the drawer; the other ways to reach a shell sit behind the
    // chevron, so the most common one is a single click.
    private func terminalSeat(session: ChatSession, project: Project,
                              showsWord: Bool) -> some View {
        let directory = session.worktreePath ?? project.path
        let terminalOpen = terminals.isOpen(terminalScope)
        return HeaderDockSeat(
            icon: "terminal",
            word: "Terminal",
            isOpen: terminalOpen,
            showsWord: showsWord,
            keys: ["⌃", "`"],
            detail: "A shell under the pane, in this session's folder",
            options: .init(label: "Other ways to open a shell") {
                terminalOptions(isOpen: terminalOpen, directory: directory)
            }) {
                toggleTerminal(directory: directory)
            }
    }

    // A question about the whole change has no file or line to start from, so it is asked
    // from here, and its card hangs under this button over the diff.
    private var askWholeChangeButton: some View {
        let asking = changesNavigation.askingWholeChange
        let unread = !asking && WholeChangeThreads.hasUnreadAnswer(runner.reviews.questions(sessionID),
                                                                   seen: changesNavigation.wholeChangeSeen)
        return HeaderRailButton(icon: "questionmark.bubble",
                                state: asking ? .open : .rest,
                                badge: unread,
                                label: asking ? "Put away the questions" : "Ask about the whole change",
                                hint: asking ? "Esc does the same" : unread ? "An answer is waiting" : "Shift-? opens it here, over the diff") {
            if asking { changesNavigation.citation = nil }
            changesNavigation.setAskingWholeChange(!asking)
        }
        .motion(Motion.pop, value: unread)
        .onCentreChange { changesNavigation.askOrigin = $0 }
        .accessibilityAddTraits(asking ? .isSelected : [])
        .accessibilityValue(unread ? "An answer is waiting" : "")
        .accessibilityFocused($askButtonFocused)
        .onChange(of: asking) { _, open in
            if !open { askButtonFocused = true }
        }
    }

    // Find stays one click away. Everything else done to the tree sits behind the menu,
    // which is the only place those actions live.
    private var explorerActions: some View {
        HStack(spacing: 2) {
            HeaderRailButton(icon: "magnifyingglass", label: "Find files or text",
                             hint: "Shift twice for files, Ctrl+H for text") {
                explorerCommand = .find(nil)
            }
            HeaderRailMenuButton(icon: "ellipsis", label: "File actions",
                                 hint: "New, hidden files, collapse, refresh")
                .appMenu { explorerMenu }
        }
    }

    private var explorerMenu: [MenuEntry] {
        let open = explorerOpenFolders
        return [.item("New file", icon: "doc.badge.plus") { explorerCommand = .newFile },
                .item("New folder", icon: "folder.badge.plus") { explorerCommand = .newFolder },
                .separator,
                .item("Show hidden files", icon: explorerShowsHidden ? "eye" : "eye.slash",
                      checked: explorerShowsHidden) { explorerCommand = .toggleHidden },
                .item("Collapse folders", icon: "rectangle.compress.vertical",
                      detail: open == 0 ? "All closed" : "\(open) open",
                      disabled: open == 0) { explorerCommand = .collapseFolders },
                .item("Refresh files", icon: "arrow.clockwise") { explorerCommand = .refresh }]
    }

    private func terminalOptions(isOpen: Bool, directory: String) -> [MenuEntry] {
        terminalEntries(isOpen: isOpen,
                        toggle: { toggleTerminal(directory: directory) },
                        directory: directory,
                        note: { text, icon in showRailNote(text, icon: icon) })
            + [.separator,
               .item("Copy cd command", icon: "doc.on.doc",
                     subtitle: "cd \(directory.shellQuoted)", monospacedSubtitle: true) {
                   Pasteboard.copy("cd \(directory.shellQuoted)")
                   showRailNote("Copied the cd command")
               }]
    }

    // Find has nothing to search while a Design or a running app is on screen. It stays in
    // the dock, greyed out, so the seats beside it do not shift when either comes or goes.
    private func findSeat(_ session: ChatSession, showsWord: Bool) -> some View {
        let isOpen = tab == .conversation && transcriptFind.isPresented
        return HeaderDockSeat(icon: "magnifyingglass",
                              word: "Find",
                              isOpen: isOpen,
                              showsWord: showsWord,
                              keys: ["⌘", "F"],
                              detail: "Search this conversation") {
            if isOpen {
                closeFind()
            } else {
                tab = .conversation
                transcriptFind.open(in: currentMessages)
                $findFocused.request()
            }
        }
        .disabled(session.isActivelyDesigning || previews.isOpen)
    }

    // Placed first: the rail keeps to the trailing edge, so the other seats do not move.
    // It shows before the agent links an app, so any address can be typed in, but stays
    // faint until there is an app to show.
    @ViewBuilder
    private func previewSeat(_ session: ChatSession, showsWord: Bool) -> some View {
        if !session.isActivelyDesigning && appSettings.shows(.preview) {
            let address = previews.selected.flatMap { $0.isBlank ? nil : $0.address }
                ?? linkedApp.address
            let isOpen = tab == .conversation && previews.isOpen
            let pages = previews.pages.count
            HeaderDockSeat(icon: "globe",
                           word: "Preview",
                           isOpen: isOpen,
                           count: pages > 1 ? pages : nil,
                           showsWord: showsWord,
                           detail: address.map { "The running app at \(LocalServerPreview.label(for: $0))" }
                               ?? "Open a running app by its address",
                           isDimmed: address == nil && previews.pages.isEmpty) {
                if isOpen {
                    closePreview()
                } else {
                    tab = .conversation
                    if !previews.pages.isEmpty {
                        previews.show()
                    } else if let address {
                        previews.open(address)
                    } else {
                        previews.openBlank()
                    }
                }
            }
        }
    }

    private func workingSetSeat(_ session: ChatSession, showsWord: Bool) -> some View {
        let isOpen = tab == .conversation && workingSetVisible
        return HeaderDockSeat(icon: "sidebar.right",
                              word: "Working set",
                              isOpen: isOpen,
                              showsWord: showsWord,
                              keys: ["⌘", "\\"],
                              detail: "What the agent did, prompt by prompt",
                              action: toggleWorkingSet)
    }

    private func toggleWorkingSet() {
        if tab == .conversation && workingSetVisible {
            setWorkingSetVisible(false)
        } else {
            tab = .conversation
            setWorkingSetVisible(true)
        }
    }

    // Actions for the session as a whole stay together at the end of the rail.
    private func utilities(session: ChatSession, project: Project,
                           recap: SessionRecap?, showsWords: Bool) -> some View {
        HStack(spacing: 6) {
            if let worktreePath = session.worktreePath, let app = WorktreeOpener.current {
                openInButton(path: worktreePath, app: app, showsWord: showsWords)
            }
            if showsDesignMaterialExport(session) {
                designMaterialExportButton(session: session, project: project)
            }
            if showsRecap {
                let recapping = runner.isRecapping(visibleConversationID)
                SessionRecapControl(
                    recap: recap,
                    regenerating: recapping,
                    canRegenerate: runner.canRecap(visibleConversationID, store: store),
                    isOpen: recapOpen,
                    needsAttention: recapNeedsAttention,
                    toggle: toggleRecap)
            }
        }
    }

    // Says where the folder goes rather than showing a glyph that only ever meant Finder.
    // The chevron picks another app, and the pick is kept for next time.
    private func openInButton(path: String, app: WorktreeApp, showsWord: Bool) -> some View {
        HeaderSplitButton(
            image: WorktreeOpener.icon(for: app),
            word: "Open in \(app.name)",
            showsWord: showsWord,
            menuLabel: "Choose where to open",
            tooltip: {
                Tooltip(title: "Open worktree in \(app.name)", subtitle: path.abbreviatedPath)
            },
            action: { openWorktree(path, in: app) },
            refresh: { WorktreeOpener.refresh() },
            entries: { openInEntries(path: path, current: app) })
    }

    private func openInEntries(path: String, current: WorktreeApp) -> [MenuEntry] {
        WorktreeOpener.apps.map { app in
            .item(app.name, image: WorktreeOpener.icon(for: app), imageShape: .tile,
                  checked: app == current) {
                WorktreeOpener.choose(app)
                openWorktree(path, in: app)
            }
        } + [
            .separator,
            .item("Copy path", icon: "doc.on.doc") {
                Pasteboard.copy(path)
                showRailNote("Copied the worktree path")
            },
        ]
    }

    private func openWorktree(_ path: String, in app: WorktreeApp) {
        WorktreeOpener.open(path, in: app)
        showRailNote("Opened the worktree in \(app.name)")
    }

    // The same actions behind one button, for a window too narrow to hold the rail. The
    // utilities fold before the dock and the tab deck do: they are the group you reach
    // for least often, and the only one whose words survive being put in a menu.
    private func utilitiesOverflow(session: ChatSession, project: Project) -> some View {
        HeaderRailButton(icon: "ellipsis",
                         badge: recapNeedsAttention,
                         label: "More session actions")
            .appMenu(refreshOnOpen: { WorktreeOpener.refresh() }) {
                utilityEntries(session: session, project: project)
            }
    }

    private func utilityEntries(session: ChatSession, project: Project) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if let worktreePath = session.worktreePath, let current = WorktreeOpener.current {
            // Finder stays one click away whichever app was picked.
            var apps = [current]
            if current.bundleID != WorktreeOpener.finderID,
               let finder = WorktreeOpener.apps.first(where: { $0.bundleID == WorktreeOpener.finderID }) {
                apps.append(finder)
            }
            for app in apps {
                entries.append(.item("Open in \(app.name)", image: WorktreeOpener.icon(for: app),
                                     imageShape: .tile) {
                    openWorktree(worktreePath, in: app)
                })
            }
        }
        if showsDesignMaterialExport(session) {
            entries.append(.item("Export Design materials", icon: "doc.zipper") {
                exportDesignMaterials(session: session, project: project)
            })
        }
        if showsRecap {
            entries.append(.item("Session recap", icon: "lightbulb",
                                 showsUpdate: recapNeedsAttention, action: toggleRecap))
        }
        return entries
    }

    // A session whose folder has gone cannot take a prompt any more than it can take a
    // typed one, and the pane already says so above the composer.
    private func promptsBlocked(session: ChatSession, project: Project) -> Bool {
        !FileManager.default.fileExists(atPath: session.worktreePath ?? project.path)
    }

    private func hasUtilities(_ session: ChatSession) -> Bool {
        (session.worktreePath != nil && WorktreeOpener.current != nil)
            || showsDesignMaterialExport(session) || showsRecap
    }

    // A design session is recapped through the conversation it belongs to, so what the
    // rail offers follows the transcript on screen rather than the session it was opened
    // from.
    private var showsRecap: Bool {
        store.session(visibleConversationID)?.hasAgentConversation == true
    }

    private func showsDesignMaterialExport(_ session: ChatSession) -> Bool {
        isDesignTabSelected(for: session) && store.hasDesignArtifacts(for: session)
    }

    // The card hangs off the rail rather than off the button that opens it: it is wider
    // than any of them, and the button it belongs to may have folded into the overflow.
    @ViewBuilder
    private func recapCard(_ recap: SessionRecap?) -> some View {
        if let recap, recapOpen {
            SessionRecapView(
                recap: recap,
                regenerating: runner.isRecapping(visibleConversationID),
                regenerate: generateRecap,
                close: closeRecap)
                .padding(.trailing, 20)
                .offset(y: Self.destinationDeckHeight + 7)
                .transition(recapArrivesUnasked ? .identity : .popover(reduceMotion: reduceMotion))
                // Once it is in place, closing it fades out like any other.
                .onAppear { recapArrivesUnasked = false }
        }
    }

    // The deck in the order it is reached by ⌘1 through ⌘5: first what the agent is being
    // set to do, then what it did to the working tree.
    //
    // A session settles into one kind of work with its first prompt. A diagnosis takes
    // over the conversation, so its findings are read under its own name and Chat and
    // Design go. A chat or a design leaves no room for a diagnosis brief, so the
    // Troubleshoot form goes. A tab already open stays, so the pane is never left
    // without its tab.
    private func headerTabs(for session: ChatSession) -> [HeaderTab] {
        if session.isTroubleshooting {
            var tabs = [HeaderTab(label: "Troubleshoot", icon: "stethoscope",
                                  selected: tab == .conversation) {
                tab = .conversation
            }]
            if tab == .design { tabs.append(designTab(session)) }
            tabs.append(evidenceTab(session))
            return tabs + trailingTabs(session)
        }
        var tabs: [HeaderTab] = [
            destination(session.isActivelyDesigning
                            ? "Design"
                            : (session.isImplementingDesign ? "Build" : "Chat"),
                        icon: "bubble.left.and.bubble.right",
                        value: .conversation)
        ]
        if session.isActivelyDesigning {
            tabs[0].hasContent = designHasContent ?? store.hasDesignArtifacts(for: session)
        } else {
            tabs.append(designTab(session))
        }
        let started = session.hasStarted || store.designSession(for: session.id)?.hasStarted == true
        if !started || tab == .troubleshoot {
            tabs.append(destination("Troubleshoot", icon: "stethoscope", value: .troubleshoot))
        }
        if tab == .evidence { tabs.append(evidenceTab(session)) }
        return tabs + trailingTabs(session)
    }

    private func evidenceTab(_ session: ChatSession) -> HeaderTab {
        var evidence = destination("Evidence", icon: "point.3.connected.trianglepath.dotted",
                                   value: .evidence)
        evidence.hasContent = TroubleshootEvidence.count(in: session.messages) > 0
        return evidence
    }

    // A result asking for more sends the agent a follow-up, the same as typing it would.
    private var askAgent: AgentAsk {
        AgentAsk(sessionID: sessionID) { [runner, store, sessionID] text in
            runner.send(text, sessionID: sessionID, store: store)
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

    private func designTab(_ session: ChatSession) -> HeaderTab {
        HeaderTab(
            label: "Design",
            icon: "paintbrush.pointed",
            selected: tab == .design,
            hasContent: designHasContent ?? store.hasDesignArtifacts(for: session),
            activate: { openDesign(for: session) })
    }

    private func trailingTabs(_ session: ChatSession) -> [HeaderTab] {
        var tabs = [changesTab(session)]
        tabs.append(destination("Explorer", icon: "folder", value: .explorer))
        // Reviews come from a pull request, so without one there is nothing to go to. A
        // tab already open stays, so the pane is never left without its tab.
        if !session.pullRequests.isEmpty || tab == .reviews {
            var reviewsTab = destination("Reviews", icon: "text.bubble", value: .reviews)
            let waiting = pullRequestReviews.waitingCount(session.id)
            reviewsTab.count = waiting > 0 ? waiting : nil
            tabs.append(reviewsTab)
        }
        return tabs
    }

    private func destination(_ label: String, icon: String, value: Tab) -> HeaderTab {
        HeaderTab(label: label, icon: icon, selected: tab == value) {
            tab = value
        }
    }

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

    private func openDesign(for session: ChatSession) {
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

    private func changesTab(_ session: ChatSession) -> HeaderTab {
        var changes = destination("Changes", icon: "plusminus", value: .changes)
        let tree = workingTreeChanges(session)
        changes.hasContent = tree != nil
        // A file count of zero means git has not answered yet and the transcript's
        // running total is standing in.
        changes.lineCounts = tree.map {
            HeaderTabLineCounts(added: $0.added, removed: $0.removed, provisional: $0.files == 0)
        }
        return changes
    }

    private func isDesignTabSelected(for session: ChatSession) -> Bool {
        switch tab {
        case .design:
            true
        case .conversation:
            session.isActivelyDesigning
        case .troubleshoot, .evidence, .changes, .explorer, .reviews:
            false
        }
    }

    // A diagnosis reads its own state, place and findings off this line rather than off
    // the header, which stands for the session as a whole. It shares the header pill's
    // reading, so the two never disagree about what the agent is doing.
    private func diagnosisStrip(_ session: ChatSession) -> some View {
        let tone = SessionTone(sessionID, store: store, runner: runner)
        let model = session.settings?.model
            ?? session.usage?.model(for: session.agent)
            ?? runner.defaults(for: session.agent).model
        let agentLine = [session.agent.title, model.map { runner.modelTitle($0) }]
            .compactMap { $0 }.joined(separator: " · ")
        return TroubleshootDiagnosisStrip(
            session: session,
            state: sessionState(tone: tone, conversation: session, isTroubleshooting: true),
            agentLine: agentLine,
            openEvidence: { tab = .evidence })
    }

    private func designUpdateStrip(_ session: ChatSession) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "paintbrush.pointed.fill")
                .font(.system(size: 11, weight: .semibold))
            Text("A newer approved Design is available.")
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 10)
            ActionButton(title: "Send update", tone: .outlined, height: 27, size: 11) {
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
        .padding(.horizontal, 20)
        .frame(height: 36)
        .background(Theme.accent.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.accent.opacity(0.25)).frame(height: 1)
        }
    }

    private func designMaterialExportButton(session: ChatSession, project: Project) -> some View {
        let label = exportingDesignMaterials
            ? "Exporting Design materials"
            : "Export Design materials as a ZIP file"
        return HeaderRailButton(
            icon: exportingDesignMaterials ? "hourglass" : "doc.zipper",
            state: exportingDesignMaterials ? .working : .rest,
            label: label,
            action: exportingDesignMaterials
                ? nil
                : { exportDesignMaterials(session: session, project: project) })
    }

    private func exportDesignMaterials(session: ChatSession, project: Project) {
        guard let materialsURL = store.designFilesURL(for: session),
              store.hasDesignArtifacts(for: session) else {
            dialogs.show(.notice("Nothing to export yet",
                                 message: "Create a Design first, then export its HTML and supporting files."))
            return
        }

        guard let destination = FilePicker.saveFile(
            suggestedName: DesignMaterialExporter.suggestedFileName(
                projectName: project.name, sessionTitle: session.title),
            prompt: "Export",
            message: "Export the Design materials as a ZIP file.",
            types: [.zip]) else { return }

        exportingDesignMaterials = true
        Task {
            defer { exportingDesignMaterials = false }
            do {
                try await DesignMaterialExporter.export(
                    materialsAt: materialsURL, to: destination)
            } catch {
                dialogs.show(.notice("Could not export Design materials",
                                     message: error.localizedDescription))
            }
        }
    }

    // MARK: - The readings

    // A worktree session knows its branch from creation, so the branch can draw on the
    // first frame instead of waiting for git and shifting the chip.
    private func facts(_ session: ChatSession, repository: GitSnapshot?) -> SessionFacts {
        let cost = session.usage?.costUSD ?? 0
        return SessionFacts(
            branch: repository?.branch
                ?? session.worktreeBranch
                ?? session.sessionProjects?.compactMap(\.worktreeBranch).first,
            changes: workingTreeChanges(session),
            pullRequests: session.pullRequests,
            model: session.usage?.model(for: session.agent).map { runner.modelTitle($0) },
            cost: appSettings.showsCost(for: session.agent) && cost > 0 ? cost : nil,
            context: session.usage?.contextFraction(for: session.agent),
            agent: session.agent)
    }

    // How far the working tree has moved, for the Changes tab and for the card behind the
    // branch. Until git has answered for this tree, the transcript's own running total
    // stands in - the same numbers the session's sidebar row shows - so the counts arrive
    // with the deck instead of a few seconds later. That total has no file count and can
    // disagree with the tree (it keeps counting across commits and repeat edits), so it
    // is only a stand-in until the first snapshot lands and corrects it.
    private func workingTreeChanges(_ session: ChatSession) -> SessionFacts.Changes? {
        let snapshots = store.workingDirectories(for: session)
            .compactMap { gitStats.snapshot(at: $0) }
        guard !snapshots.isEmpty else {
            guard session.summary.added > 0 || session.summary.removed > 0 else { return nil }
            return SessionFacts.Changes(files: 0,
                                        added: session.summary.added,
                                        removed: session.summary.removed)
        }
        let files = snapshots.reduce(0) { $0 + $1.files.count }
        guard files > 0 else { return nil }
        return SessionFacts.Changes(
            files: files,
            added: snapshots.reduce(0) { $0 + $1.totalAdded },
            removed: snapshots.reduce(0) { $0 + $1.totalRemoved })
    }

    private func sessionState(tone: SessionTone, conversation: ChatSession,
                              isTroubleshooting: Bool) -> SessionStateReading {
        // Read off the wait rather than the tone: a wait that has gone stale reads as
        // NEEDS YOU, and how long it has been held is exactly what that state is for.
        let waitingSince = runner.waitingSince(conversation.id)
        let since: Date? = switch tone {
        case .running: runner.turnStarted(conversation.id)
        default: waitingSince ?? conversation.lastActivity
        }
        return SessionStateReading(tone: tone, since: since,
                            ticks: tone == .running || waitingSince != nil,
                            diagnosing: isTroubleshooting)
    }

    private func workspaceRepositories(_ session: ChatSession) -> [ChangesRepository] {
        store.checkoutProjects(for: session).compactMap { checkout in
            guard let project = store.project(checkout.projectID) else { return nil }
            return ChangesRepository(root: checkout.worktreePath ?? project.path, name: project.name)
        }
    }

    private func selectWorkspaceRoot(_ root: String, in session: ChatSession) {
        if let checkout = store.checkoutProjects(for: session).first(where: {
            ($0.worktreePath ?? store.project($0.projectID)?.path) == root
        }) {
            selectedProjectID = checkout.projectID
            explorerShowsDesignFiles = false
            requestedChange = nil
        }
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

    // Control-backtick reaches the terminal from the keyboard: it opens the drawer if
    // it is shut, and otherwise moves focus between the composer and the shell. A
    // hidden button is how a shortcut gets a home when there is no menu item for it.
    private func terminalShortcut(directory: String) -> some View {
        Button("") {
            if !terminals.isOpen(terminalScope) {
                terminals.setOpen(true, for: terminalScope, directory: directory)
                terminalFocused = true
            } else {
                terminalFocused.toggle()
                if !terminalFocused { composerFocused = true }
            }
        }
        .keyboardShortcut("`", modifiers: .control)
        .opacity(0)
    }

    private var workingSetShortcut: some View {
        Button("", action: toggleWorkingSet)
            .keyboardShortcut("\\", modifiers: .command)
            .opacity(0)
    }

    // MARK: - Find in chat

    private var currentMessages: [ChatMessage] {
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

    private func closeFind() {
        transcriptFind.close()
        findFocused = false
        composerFocused = true
    }

    private func revealFindMatch(in session: ChatSession, proxy: ScrollViewProxy) async {
        guard let match = transcriptFind.currentMatch else { return }
        transcriptPinnedToBottom = false
        transcriptWindow.reveal(match.messageID, in: session.messages)
        await Task.yield()
        guard !Task.isCancelled else { return }
        proxy.scrollTo(match.messageID, anchor: .center)

        // Folded thinking opens on a later pass, and its text only joins the find once it
        // has been drawn, so the match is looked for again until it is there.
        var attempts = 0
        while !transcriptFind.currentIsFullyDrawn, attempts < 10 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
        }
        // Opening folded text animates its height, so the match is still moving.
        if attempts > 0 { try? await Task.sleep(for: .milliseconds(220)) }
        guard !Task.isCancelled, let placed = transcriptFind.placeCurrent() else { return }
        placed.view.revealCentered(placed.range)
    }

    // Escape calls off the running turn, so a run can be stopped without reaching for
    // the button in the composer. It only takes the key while there is a turn to stop
    // and nothing else on screen has a better claim on it: a dialog and a menu both
    // close on escape, and the shell in the drawer needs the key for whatever is
    // running in it.
    @ViewBuilder private var stopShortcut: some View {
        let target = visibleConversationID
        let state = runner.state(target)
        if state.isBusy, state != .stopping, dialogs.current == nil, !menus.isOpen,
           !terminalFocused, !previewFocused, !recapOpen, !commandPalette.isPresented,
           !(tab == .changes && changesNavigation.askingWholeChange),
           !findFocused, !previewAddressFocused {
            Button("") { runner.stop(target) }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
        }
    }

    // The visible card has the first claim on Escape. In particular, closing a recap that
    // is being refreshed must not also stop the agent turn doing the refresh.
    @ViewBuilder private var recapShortcut: some View {
        if recapOpen, dialogs.current == nil, !menus.isOpen, !terminalFocused, !previewFocused,
           !findFocused, !previewAddressFocused {
            Button("") { closeRecap() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
        }
    }

    // The turn Escape stops. A Design conversation runs in a session of its own, so what
    // is on screen is not always this session's own turn.
    private var visibleConversationID: UUID {
        switch tab {
        case .design:
            return store.designSession(for: sessionID)?.id ?? sessionID
        default:
            return sessionID
        }
    }

    // The app a folder opens in comes up over the window, and a copy shows nothing at
    // all, so the note is all the window itself shows of the click. A second click keeps
    // the note up rather than letting the first one's timer take it down early.
    private func showRailNote(_ text: String, icon: String = "arrow.up.forward.app") {
        railNotes += 1
        let note = railNotes
        railNoteIcon = icon
        railNote = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.9))
            if railNotes == note { railNote = nil }
        }
    }

    // The button both opens and shuts it; opening puts the cursor straight in the shell
    // so it can be used without reaching for the mouse again.
    private func toggleTerminal(directory: String) {
        let opening = !terminals.isOpen(terminalScope)
        terminals.setOpen(opening, for: terminalScope, directory: directory)
        terminalFocused = opening
        if !opening { composerFocused = true }
    }

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
                    ActionButton(title: "Rebuild", tone: .outlined, height: 26, size: 11.5) {
                        confirmRebuild()
                    }
                }
            } else {
                WarningStrip("\(name) not found at \(missing.abbreviatedPath). Move it back, or delete this session.")
            }
        } else if !runner.isAvailable(session.agent) {
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

    private func generateRecap() {
        recapRequested = runner.recap(visibleConversationID, store: store)
    }

    private func toggleRecap() {
        guard store.recap(for: sessionID) != nil else {
            generateRecap()
            return
        }
        recapNeedsAttention = false
        withAnimation(reduceMotion ? nil : recapOpen ? Motion.leave : Motion.reveal) {
            recapOpen.toggle()
        }
    }

    private func closeRecap() {
        recapNeedsAttention = false
        withAnimation(reduceMotion ? nil : Motion.leave) {
            recapOpen = false
        }
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

    private func directory(for projectID: UUID, in session: ChatSession) -> String? {
        guard let checkout = store.checkoutProjects(for: session)
            .first(where: { $0.projectID == projectID }) else { return nil }
        return checkout.worktreePath ?? store.project(projectID)?.path
    }

    // MARK: - Transcript

    private func conversation(session: ChatSession, project: Project) -> some View {
        GeometryReader { geometry in
            // A running app has the conversation floating over it, reading every press around
            // it, so the drawer sits beside the app rather than over the two.
            let isDocked = geometry.size.width >= 800 || previews.isOpen
            ZStack(alignment: .trailing) {
                Group {
                    if previews.isOpen, let preview = previews.selected {
                        previewPage(preview, session: session)
                    } else {
                        conversationContent(session: session, project: project)
                    }
                }
                .padding(.trailing,
                         isDocked && workingSetVisible ? SessionWorkingSet.width : 0)
                // The transcript takes its final width in one layout pass. Animating
                // that width makes every line wrap again on every animation frame.
                .animation(nil, value: workingSetVisible)

                ZStack(alignment: .trailing) {
                    if workingSetVisible {
                        workingSet(session)
                            .overlay(alignment: .leading) {
                                if isDocked {
                                    Rectangle().fill(Theme.hairline).frame(width: 1)
                                }
                            }
                            .shadow(color: isDocked ? .clear : .black.opacity(0.16),
                                    radius: isDocked ? 0 : 18,
                                    x: isDocked ? 0 : -5)
                            .transition(.drawer(from: .trailing, reduceMotion: reduceMotion))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
    }

    private func conversationContent(session: ChatSession, project: Project) -> some View {
        let blocked = !FileManager.default.fileExists(atPath: session.worktreePath ?? project.path)
            || !runner.isAvailable(session.agent)
        return VStack(spacing: 0) {
            if transcriptFind.isPresented {
                FindBar(placeholder: "Find in chat",
                        query: Binding(get: { transcriptFind.query },
                                       set: { transcriptFind.search($0, in: session.messages) }),
                        summary: transcriptFind.summary,
                        hasMatches: !transcriptFind.result.matches.isEmpty,
                        focused: $findFocused,
                        move: { transcriptFind.move(by: $0) },
                        close: closeFind)
                    // The field must be fully visible as soon as it takes focus.
                    .transition(.identity)
            }
            transcript(session, replies: !blocked)
            Divider().overlay(Theme.hairline)
            composer(session: session, project: project, blocked: blocked)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func workingSet(_ session: ChatSession) -> some View {
        SessionWorkingSet(session: session, close: { setWorkingSetVisible(false) })
    }

    private func setWorkingSetVisible(_ visible: Bool) {
        workingSetVisible = visible
        Preferences.setWorkingSetVisible(visible, for: sessionID)
    }

    private func openWorkingSetForLiveTurnIfNeeded() {
        guard appSettings.opensWorkingSetByDefault,
              runner.state(sessionID).isBusy,
              Preferences.workingSetVisibility()[sessionID] == nil else { return }
        setWorkingSetVisible(true)
    }

    // Reply is offered only while the composer can take the quote and send it.
    private func transcript(_ session: ChatSession, replies: Bool) -> some View {
        let state = runner.state(sessionID)
        let projectPath = store.workingDirectory(for: session) ?? ""
        let shape = transcriptShape(session, state: state)
        let replyAction = replies ? TranscriptReply(sessionID: sessionID) { reply($0) } : nil

        return ScrollViewReader { proxy in
            ScrollView {
                let visibleMessages = transcriptWindow.visibleMessages(in: session.messages)
                transcriptContent(session, messages: visibleMessages, state: state,
                                  projectPath: projectPath) {
                    transcriptWindow.loadEarlier(totalCount: session.messages.count)
                    // Land on the oldest message the page just added, so the reader
                    // starts at the beginning of what they asked for and reads forward
                    // into what they had already.
                    guard let earliestID = transcriptWindow
                        .visibleMessages(in: session.messages).first?.id else { return }
                    Task {
                        await Task.yield()
                        proxy.scrollTo(earliestID, anchor: .top)
                    }
                }
                    .environment(\.transcriptSelection, transcriptSelection)
                    .environment(\.transcriptFind, transcriptFind)
                    .environment(\.transcriptReply, replyAction)
                    .environment(\.explorerRoots, explorerRoots(for: session))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 22)
                    // Capped so prose keeps a readable line length, and centered so a
                    // wide window pads both sides instead of piling space on the right.
                    // Wider than a chat app's usual measure: diffs and tool output make
                    // better use of the room than paragraphs do.
                    .frame(maxWidth: 960, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    // Include the padding so the scroll target is the actual bottom.
                    .id(bottomAnchor)
                    .background {
                        TranscriptScrollObserver(pinnedToBottom: transcriptPinnedToBottom) { isAtBottom in
                            transcriptPinnedToBottom = isAtBottom
                        }
                    }
                    // Sits outside the padding so the margins count as page too: a press
                    // beside a paragraph puts the selection away just as one below it does.
                    .background(TranscriptSelectionClearing(selection: transcriptSelection))
                    // Message rows can settle after the first scroll when text wraps or
                    // an attachment gets its final size. Keep an opening transcript at
                    // its real end, then respect manual scrolling once it is visible.
                    .background(GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.size.height, initial: true) {
                            guard (!opened && agentFocus == nil) || transcriptPinnedToBottom else { return }
                            Task { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                        }
                    })
                    // The soft landing for anything new: a fresh row fades in and the
                    // rows above it glide up rather than jumping. Keyed on the shape of
                    // the transcript, not its text, so it plays once per whole arrival
                    // and never while a line is still being typed into.
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2),
                               value: shape.settled)
            }
            // Opening a transcript starts at the end, where the conversation is.
            .defaultScrollAnchor(.bottom)
            // The pane changes height under a transcript that is already there: the
            // composer grows a line, the terminal drawer opens, the window is resized.
            // The end of the content moves with it while the scroll view keeps its offset,
            // so a pinned transcript must be sent to the bottom again.
            .background(GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.height, initial: true) {
                    guard transcriptPinnedToBottom else { return }
                    Task { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                }
            })
            // Held back until the scroll has landed, so the conversation arrives already
            // at its end instead of appearing and then jumping there.
            .opacity(opened ? 1 : 0)
            .accessibilityHidden(!opened)
            .onAppear {
                _ = handoffArrival.observe(runner.lastTurnEnding(sessionID), visible: false)
            }
            .onDisappear { arrivingEnding = nil }
            .onChange(of: runner.lastTurnEnding(sessionID)) { _, ending in
                guard handoffArrival.observe(ending, visible: opened && transcriptPinnedToBottom),
                      let ending, !runner.state(sessionID).isBusy,
                      let receipt = TurnReceipt(lastTurnIn: session.messages, projectPath: projectPath)
                else { return }
                arrivingEnding = ending.ended
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                    userInfo: [.announcement: receipt.spokenSummary(ending),
                               .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
            .task(id: sessionID) {
                if agentFocus == nil {
                    transcriptWindow.reset()
                    transcriptPinnedToBottom = true
                }
                // The conversation is read off the main actor, so the pane is on screen
                // before the messages are. Waiting here is what keeps that off screen:
                // it fades in once, already full and already at its end, rather than
                // arriving empty and filling in.
                await store.transcriptReady(sessionID)
                await Task.yield()
                if let agentFocus {
                    transcriptWindow.reveal(agentFocus.messageID, in: session.messages)
                    await Task.yield()
                    proxy.scrollTo(agentFocus.anchor, anchor: .top)
                } else {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
                withAnimation(reduceMotion ? nil : Motion.reveal) { opened = true }
            }
            .task(id: transcriptFind.jumpRequest) {
                await revealFindMatch(in: session, proxy: proxy)
            }
            .task(id: agentFocus?.requestID) {
                guard opened, let agentFocus else { return }
                // A tool anchor does not exist until its lazy message row is on screen.
                proxy.scrollTo(agentFocus.messageID, anchor: .top)
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo(agentFocus.anchor, anchor: .top)
            }
            // Anything new sends a pinned transcript to its end. A whole arrival - a row,
            // a finished line, a change of state - is worth a glide. A long line still
            // being typed into is followed in coarse chunks, each without one, so streaming
            // tokens do not each perform another scroll operation.
            .onChange(of: shape) { old, new in
                if new.state != old.state, new.state != .waiting { waitNoticeDismissed = false }
                scrollToBottom(proxy, animated: old.settled != new.settled)
            }
            .task(id: transcriptScrollRequest) {
                guard transcriptScrollRequest > 0 else { return }
                // The prompt and composer must finish updating before the scroll lands.
                await Task.yield()
                guard !Task.isCancelled else { return }
                scrollToBottom(proxy, animated: true)
            }
        }
    }

    // Not lazy, deliberately. A lazy stack decides what to build from where the scroll
    // view is looking, and when that offset stops being a valid one - the pane resizing
    // under a transcript sitting at the bottom, a message landing as the bottom anchor
    // is re-applied - it builds nothing at all and the transcript goes blank until it
    // is scrolled by hand. A turn is a handful of rows, and the tool rows inside one
    // are built eagerly anyway. Bounding the eager stack keeps large transcripts cheap
    // without bringing back the blank-pane bug, and keeps an opened tool card alive while
    // it remains in the loaded window.
    private func transcriptContent(_ session: ChatSession,
                                   messages: ArraySlice<ChatMessage>,
                                   state: SessionState, projectPath: String,
                                   loadEarlier: @escaping () -> Void) -> some View {
        let bubble = appSettings.userMessageStyle(for: session, in: store)
        let reviewRounds = sentReviews(in: session)
        let lineup = SecondOpinionLineup.reviewers(installed: AgentKind.allCases.filter { runner.executable(for: $0) != nil },
                                                   author: session.agent)
        return VStack(alignment: .leading, spacing: 18) {
            // Only for a session that has nothing to say yet, never for one whose
            // conversation is still being read in.
            if session.messages.isEmpty, !store.isTranscriptLoading(sessionID) {
                Text("Ask for a change. \(session.agent.title) runs in the project folder, so what it edits is your working tree.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }

            let hiddenCount = transcriptWindow.hiddenCount(totalCount: session.messages.count)
            if hiddenCount > 0 {
                LoadEarlierMessages(hiddenCount: hiddenCount, action: loadEarlier)
            }

            ForEach(messages) { message in
                if let round = reviewRounds.cards[message.id] {
                    reviewCard(round, session: session, working: state.isBusy, projectPath: projectPath)
                        .transition(.fadeIn)
                } else if !reviewRounds.hidden.contains(message.id) {
                MessageView(message: reviewRounds.cuts[message.id].map { message.cut(at: $0) } ?? message,
                            projectPath: projectPath,
                            textScale: appSettings.textSize.scale,
                            openChange: { path in
                                openChange(path, root: projectPath)
                            },
                            runInShell: { command in
                                runInShell(command, directory: projectPath)
                            },
                            showInExplorer: showInExplorer,
                            openPreview: openPreview,
                            promptMenu: promptMenu(for: message),
                            arriving: message.isArriving(sentAt: promptSentAt),
                            bubble: bubble,
                            secondOpinion: canJudge(message, in: session, state: state) ? { @MainActor in
                                askForSecondOpinion(session, on: answerSubject(message, in: session),
                                                    anchor: message.id)
                            } : nil)
                    // Every message is on screen now, and a streaming turn rewrites
                    // the last one many times a second. Without this, each of those
                    // redraws every message in the transcript, parsing its markdown
                    // again on the way.
                    .equatable()
                    .environment(\.runningAgents, runner.runningAgents(sessionID))
                    .environment(\.previewsLocalServers, true)
                    .environment(\.activeTranscriptTools, runner.runningTools(sessionID))
                    .environment(\.agentTranscriptFocus, agentFocus)
                    .environment(\.askAgent, askAgent)
                    .transition(.fadeIn)
                }
                ForEach(opinions(after: message.id)) { opinion in
                    opinionCard(opinion, session: session)
                        .transition(.fadeIn)
                }
            }

            if !state.isBusy, let ending = runner.lastTurnEnding(sessionID),
               let receipt = TurnReceipt(lastTurnIn: session.messages, projectPath: projectPath) {
                TurnSeal(ending: ending, receipt: receipt,
                         reviewed: reviewedEnding == ending.ended,
                         arriving: arrivingEnding == ending.ended,
                         focusReview: focusHandoffReview,
                         review: runner.question(sessionID) == nil ? {
                             reviewingEnding = ending.ended
                             focusHandoffReview = false
                             Task { await openTurnChanges(ending, in: session) }
                         } : nil)
                    .id(ending.ended)
                    .transition(.identity)
            } else if runner.lastTurnEnding(sessionID) == nil {
                handoff(state: state)
            }

            pendingQuestion(projectPath: projectPath)
                .transition(.fadeIn)

            if showsThinking(state: state) {
                WorkingRow(since: runner.lastActivity(sessionID) ?? Date(),
                           sessionID: sessionID,
                           avatarName: session.agentAvatarName,
                           agentTitle: session.agent.title,
                           tasks: runner.backgroundTasks(sessionID),
                           waitingSince: runner.waitingSince(sessionID))
                    .transition(.fadeIn)
            }

            if state == .waiting, !waitNoticeDismissed,
               let waitingSince = runner.waitingSince(sessionID) {
                WaitingNotice(since: waitingSince,
                              tasks: runner.backgroundTasks(sessionID),
                              agentTitle: session.agent.title,
                              command: { session.shellCommand(for: $0) },
                              onKeepWaiting: {
                                  withAnimation(reduceMotion ? nil : Motion.leave) {
                                      waitNoticeDismissed = true
                                  }
                              },
                              onEnd: { runner.endWait(sessionID) })
                    .transition(dismissal)
            }

            if case .reconnecting(let message) = state {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Codex is reconnecting")
                            .fontWeight(.semibold)
                        Text(message)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .warningCard()
            }

            if state == .stalled {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Codex has stopped responding")
                                .fontWeight(.semibold)
                            Text("There has been no output for five minutes, with no command, question, or background task in progress. "
                                + "You can keep waiting, stop the turn, or retry it safely.")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        ActionButton(title: "Stop", tone: .outlined,
                                     height: 28, size: 11.5) {
                            runner.stop(sessionID)
                        }
                        if runner.canRetryStalled(sessionID, store: store) {
                            ActionButton(title: "Retry turn", height: 28, size: 11.5) {
                                runner.retryStalled(sessionID, store: store)
                            }
                        }
                    }
                }
                .warningCard()
            }

            TurnEndActions(sessionID: sessionID, agent: session.agent, state: state)
        }
        .environment(\.secondOpinionLineup, lineup)
        .modifier(SentPromptCommands(agent: session.agent,
                                     workingDirectories: store.workingDirectories(for: session),
                                     latestPromptID: session.messages.last(where: { $0.role == .user })?.id))
    }

    // What to do with what the turn left behind. It sits at the end of the conversation
    // because that is where the decision is made, and only once the agent has stopped:
    // reviewing a tree that is still being written to is not a review.
    @ViewBuilder private func handoff(state: SessionState) -> some View {
        let hasChanges = store.session(sessionID).map { session in
            store.workingDirectories(for: session)
                .compactMap { gitStats.snapshot(at: $0) }
                .contains { !$0.files.isEmpty }
        } ?? false
        if hasChanges, !state.isBusy, runner.question(sessionID) == nil {
            HStack(spacing: 8) {
                ActionButton(title: "Review changes") {
                    openChanges()
                }
                Spacer(minLength: 0)
            }
            .transition(.fadeIn)
        }
    }

    // Reviews sent from Changes, matched to the messages that carried them. Each shows as
    // one card where its prompt would be. The answers the agent wrote under each comment's
    // heading live in the card's threads, so they are cut from the turn's text, and a reply
    // sent in a thread is left to the thread instead of showing as a message of its own.
    private func sentReviews(in session: ChatSession) -> (cards: [UUID: ReviewRound], hidden: Set<UUID>,
                                                          cuts: [UUID: Int]) {
        let reviews = runner.reviews
        let rounds = reviews.rounds(sessionID)
        guard !rounds.isEmpty else { return ([:], [], [:]) }
        var cards: [UUID: ReviewRound] = [:]
        var hidden: Set<UUID> = []
        var cuts: [UUID: Int] = [:]
        let messages = session.messages
        for (index, message) in messages.enumerated() where message.role == .user {
            let prompt = message.text.trimmed
            let count: Int
            let settled: Bool
            if let round = rounds.last(where: { $0.prompt == prompt }) {
                cards[message.id] = round
                count = round.comments.count
                settled = round.isSettled
            } else if reviews.isThreadReply(prompt: prompt, in: sessionID) {
                hidden.insert(message.id)
                count = 1
                settled = reviews.awaitingReply(prompt: prompt, in: sessionID) == nil
            } else {
                continue
            }
            guard let reply = messages[(index + 1)...].prefix(while: { $0.role != .user })
                .last(where: { $0.role == .assistant }) else { continue }
            // While the turn runs, only text under a heading is known to be an answer.
            let cut = settled ? ReviewAnswers.read(reply, count: count)?.start : ReviewAnswers.split(reply.text)?.start
            guard let cut else { continue }
            if reply.cut(at: cut).isEmpty { hidden.insert(reply.id) } else { cuts[reply.id] = cut }
        }
        return (cards, hidden, cuts)
    }

    private func reviewCard(_ round: ReviewRound, session: ChatSession, working: Bool,
                            projectPath: String) -> some View {
        let installed = AgentKind.allCases.filter { runner.executable(for: $0) != nil }
        let checker = installed.first { $0 != session.agent } ?? installed.first
        let reviews = runner.reviews
        let directories = store.workingDirectories(for: session)
        let names = Dictionary(directories.map { ($0, ($0 as NSString).lastPathComponent) },
                               uniquingKeysWith: { first, _ in first })
        return ReviewCard(
            round: round, agent: session.agent, working: working, checker: checker,
            projectPath: projectPath, textScale: appSettings.textSize.scale,
            fileName: { ($0.path as NSString).lastPathComponent },
            openInChanges: {
                changesNavigation.showingHistory = false
                openChanges()
            },
            reply: { comment, text in
                Task {
                    guard let prompt = await reviews.reply(text, to: comment.id, round: round.id, in: sessionID,
                                                           projectNames: names) else { return }
                    runner.send(prompt, sessionID: sessionID, store: store)
                }
            },
            resolve: { reviews.resolve($0.id, round: round.id, in: sessionID) },
            reopen: { reviews.reopen($0.id, round: round.id, in: sessionID) },
            showInDiff: { comment in
                reviews.markRead(comment.id, in: sessionID)
                changesNavigation.showingHistory = false
                changesNavigation.focusedComment = comment.id
                openChange(comment.path, root: comment.root)
            },
            reviewWhatChanged: openChanges,
            checkFixes: {
                guard let checker, let executable = runner.executable(for: checker) else { return }
                let repositories = directories.map {
                    ReviewRepository(root: $0, name: ($0 as NSString).lastPathComponent)
                }
                let seat = Preferences.secondOpinionLineup().first { $0.agent == checker }
                    ?? SecondOpinion.Reviewer(agent: checker)
                reviews.startSecondOpinion(sessionID, reviewer: seat, request: SecondOpinionRequest(
                    scope: .sinceReview(trees: round.trees), repositories: repositories, executable: executable))
                changesNavigation.showingHistory = false
                openChanges()
            })
            // Answers read here are read: the thread is open in front of the person.
            .onChange(of: round.unread, initial: true) { _, unread in
                for id in unread { reviews.markRead(id, in: sessionID) }
            }
            // A round whose turn ended while nothing was watching, or before the app was
            // last quit, is settled as soon as it is seen.
            .task(id: "\(round.id)-\(working)") {
                guard !working, !round.isSettled else { return }
                let reply = store.session(sessionID).flatMap { ReviewAnswers.reply(to: round.prompt, in: $0.messages) }
                await reviews.turnEnded(sessionID, prompt: round.prompt, reply: reply)
            }
    }

    private func returnToHandoff() {
        focusHandoffReview = true
        tab = .conversation
    }

    private func openChanges() {
        requestedChange = nil
        tab = .changes
    }

    // A turn that committed its work leaves nothing in the working tree, so its review is
    // the range of commits it made instead. Uncommitted work anywhere keeps the review on
    // the working tree, where it can be commented on and committed.
    private func openTurnChanges(_ ending: TurnEnding, in session: ChatSession) async {
        let committed = await GitInspector.turnCommits(roots: store.workingDirectories(for: session),
                                                       startHeads: ending.startHeads)
        guard reviewingEnding == ending.ended else { return }
        guard let committed else {
            changesNavigation.showingHistory = false
            openChanges()
            return
        }
        let history = changesNavigation.history(for: committed.root)
        history.select(committed.head)
        history.parent = committed.start
        changesNavigation.showingHistory = true
        selectWorkspaceRoot(committed.root, in: session)
        openChanges()
    }

    private func openChange(_ path: String, root: String) {
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

    // The picked-out text goes into the draft as a quote and the caret waits below it,
    // so the answer to it is the next thing typed.
    private func reply(_ text: String) {
        runner.composer.editDraft(sessionID) { $0.text = ReplyQuote.appending(text, to: $0.text) }
        transcriptSelection.clear()
        composerFocused = true
    }

    private func explorerRoots(for session: ChatSession) -> [String] {
        store.workingDirectories(for: session) + [store.designFilesURL(for: session)?.path].compactMap { $0 }
    }

    private func showInExplorer(_ url: URL) -> Bool {
        guard let session = store.session(sessionID),
              let target = TranscriptLink.explorerTarget(for: url,
                                                         roots: explorerRoots(for: session))
        else { return false }

        explorerShowsDesignFiles = target.root == store.designFilesURL(for: session)?.path
        if let checkout = store.checkoutProjects(for: session).first(where: { checkout in
            (checkout.worktreePath ?? store.project(checkout.projectID)?.path) == target.root
        }) {
            selectedProjectID = checkout.projectID
        }
        explorerReveal = ExplorerReveal(path: target.path, line: target.line)
        tab = .explorer
        return true
    }

    private func openPreview(_ url: URL) -> Bool {
        previews.open(url, inNewPage: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        return true
    }

    private func closePreview() {
        previews.hide()
        composerFocused = true
    }

    private func previewPage(_ preview: LocalServerPreview, session: ChatSession) -> some View {
        let projectPath = store.workingDirectory(for: session) ?? ""
        return LocalServerPreviewPage(previews: previews, preview: preview, session: session,
                                      placeholder: placeholder(state: runner.state(sessionID)),
                                      openPreview: openPreview,
                                      openChange: { path in
                                          openChange(path, root: projectPath)
                                      },
                                      runInShell: { command in
                                          runInShell(command, directory: projectPath)
                                      },
                                      showInExplorer: showInExplorer,
                                      pageFocused: $previewFocused,
                                      addressFocused: $previewAddressFocused,
                                      onClose: closePreview)
            .environment(\.explorerRoots, explorerRoots(for: session))
    }

    // The shell a command ran in belongs to the agent and is gone by the time its output
    // is being read, so there is none to reopen. What is worth having instead is the
    // command itself, in a shell of your own: it arrives at the prompt unrun, ready to be
    // edited or fired off. A tab with something running in it is left to it and a new one
    // is opened, since whatever holds that terminal would read the command as its input.
    private func runInShell(_ command: String, directory: String) {
        terminals.setOpen(true, for: terminalScope, directory: directory)
        let idle = terminals.selection(for: terminalScope).flatMap { $0.isBusy ? nil : $0 }
        let shell = idle ?? terminals.add(to: terminalScope, directory: directory)
        shell.paste(command)
        terminalFocused = true
    }

    // The right-click menu on one of the user's own prompts. Only prompts that recorded
    // a checkpoint have one - they are the points the conversation can go back to. The
    // entries are built when the menu opens, so a turn starting or ending in the
    // meantime is reflected.
    private func promptMenu(for message: ChatMessage) -> (() -> [MenuEntry])? {
        guard message.role == .user, message.checkpoint != nil else { return nil }
        let store = store
        let runner = runner
        let sessionID = sessionID
        return {
            var actions: [MenuEntry] = []
            if runner.canRewind(to: message.id, sessionID: sessionID, store: store) {
                actions.append(.item(
                    "Rewind to here",
                    icon: "arrow.uturn.backward",
                    subtitle: "Discards this prompt and everything after it. The prompt returns to the composer.") {
                    runner.rewind(to: message.id, sessionID: sessionID, store: store)
                })
            }
            if store.canForkSession(sessionID, before: message.id) {
                actions.append(.item(
                    "Fork from here",
                    icon: "arrow.triangle.branch",
                    subtitle: "Starts a new session that carries the conversation up to this point.") {
                    guard let fork = store.forkSession(sessionID, before: message.id) else { return }
                    runner.composer.editDraft(fork.id) { draft in
                        draft.text = message.text
                        draft.attachments = (message.attachments ?? []).map {
                            Attachment(url: URL(fileURLWithPath: $0))
                        }
                    }
                })
            }
            let copy = MenuEntry.item("Copy prompt", icon: "doc.on.doc") {
                Pasteboard.copy(message.text)
            }
            guard !actions.isEmpty else { return [copy] }
            return actions + [.separator, copy]
        }
    }

    // Whatever the agent is waiting on sits under the transcript, where the next thing to
    // happen belongs. The turn is parked until it is answered.
    @ViewBuilder private func pendingQuestion(projectPath: String) -> some View {
        if let request = runner.question(sessionID) {
            let session = store.session(sessionID)
            PermissionCard(request: request,
                           workingDirectories: session.map(store.workingDirectories(for:)) ?? [],
                           projectPath: projectPath,
                           secondOpinion: session.map { session in
                               { askForSecondOpinion(session, on: planSubject(request, in: session),
                                                     anchor: session.messages.last(where: { !$0.isEmpty })?.id) }
                           }) { answer in
                runner.answer(request, with: answer, sessionID: sessionID, store: store)
            }
            .id(request.id)
            if let session, let opinion = runner.opinions.opinion(on: Self.planID(request), in: sessionID) {
                opinionCard(opinion, session: session)
                    .transition(.fadeIn)
            }
        }
    }

    // MARK: - Second opinion in Chat

    private static func planID(_ request: PermissionRequest) -> String { "plan:" + request.id }

    // The plan waiting on an answer, judged against the request that led to it.
    private func planSubject(_ request: PermissionRequest, in session: ChatSession) -> ChatSecondOpinion.Subject {
        ChatSecondOpinion.Subject(kind: .plan, id: Self.planID(request), text: request.subject,
                                  request: session.messages.last(where: { $0.role == .user })?.text ?? "")
    }

    private func answerSubject(_ message: ChatMessage, in session: ChatSession) -> ChatSecondOpinion.Subject {
        let index = session.messages.firstIndex { $0.id == message.id } ?? session.messages.endIndex
        let asked = session.messages[..<index].last { $0.role == .user }?.text ?? ""
        return ChatSecondOpinion.Subject(kind: .answer, id: "answer:" + message.id.uuidString,
                                         text: message.text, request: asked)
    }

    // An answer can be judged once it is whole: not while its turn is still writing it.
    private func canJudge(_ message: ChatMessage, in session: ChatSession, state: SessionState) -> Bool {
        guard message.role == .assistant, !message.text.isBlank else { return false }
        return !(state.isBusy && session.messages.last?.id == message.id)
    }

    // Cards joined to a message. The one on a plan still waiting sits under the plan.
    private func opinions(after messageID: UUID) -> [ChatOpinion] {
        let pending = runner.question(sessionID).map(Self.planID)
        return runner.opinions.opinions(sessionID).filter { $0.anchor == messageID && $0.subject.id != pending }
    }

    // The header's one control for a second opinion, on every tab. It shows the review
    // that belongs to the page in view: the design's on the canvas, the changes' anywhere
    // else, since a card under an answer already shows its own.
    @ViewBuilder
    private func secondOpinionButton(_ session: ChatSession) -> some View {
        let installed = AgentKind.allCases.filter { runner.executable(for: $0) != nil }
        if let design = shownDesign(session) {
            let opinion = runner.designOpinions.opinion(design.id)
            SecondOpinionLineupButton(author: design.agent, installed: installed,
                                      canReview: hasOpinionSubject(session),
                                      runs: opinion?.runs ?? [], status: opinion?.status ?? .ask,
                                      ask: { askForSecondOpinion(session) },
                                      // The notes already sit in their panel beside the canvas.
                                      open: {})
        } else {
            SecondOpinionLineupButton(author: session.agent, installed: installed,
                                      canReview: hasOpinionSubject(session),
                                      runs: runner.reviews.runs(session.id),
                                      status: SecondOpinionStatus(reviews: runner.reviews, sessionID: session.id),
                                      ask: { askForSecondOpinion(session) },
                                      open: {
                                          tab = .changes
                                          changesNavigation.secondOpinionRequest = .open
                                      })
        }
    }

    // The design on screen right now, whose notes the canvas shows.
    private func shownDesign(_ session: ChatSession) -> ChatSession? {
        let design = switch tab {
        case .design: store.designSession(for: session.id)
        case .conversation where session.isActivelyDesigning: session
        default: nil as ChatSession?
        }
        guard let design, store.hasDesignArtifacts(for: design) else { return nil }
        return design
    }

    private func reviewableDesign(_ session: ChatSession) -> ChatSession? {
        store.designConversation(for: session.id).flatMap { store.hasDesignArtifacts(for: $0) ? $0 : nil }
    }

    private func latestAnswer(in session: ChatSession) -> ChatMessage? {
        let state = runner.state(session.id)
        return session.messages.last { canJudge($0, in: session, state: state) }
    }

    private func hasOpinionSubject(_ session: ChatSession) -> Bool {
        latestAnswer(in: session) != nil || workingTreeChanges(session) != nil || reviewableDesign(session) != nil
    }

    // One dialog for whatever the session can be judged on. A plan or answer the person
    // pointed at comes in already picked; from the header, the pick follows the page in
    // view. Each kind is then asked where its results land.
    private func askForSecondOpinion(_ session: ChatSession, on picked: ChatSecondOpinion.Subject? = nil,
                                     anchor: UUID? = nil) {
        let installed = AgentKind.allCases.filter { runner.executable(for: $0) != nil }
        let author = runner.author(of: session)
        let latest = picked == nil ? latestAnswer(in: session) : nil
        let chatSubject = picked ?? latest.map { answerSubject($0, in: session) }
        let chatAnchor = picked == nil ? latest?.id : anchor
        let answer = chatSubject.map { SessionOpinionAsk.Answer(subject: $0, author: author, picked: picked != nil) }

        let changes = workingTreeChanges(session).map { facts in
            SessionOpinionAsk.Changes(
                author: author,
                running: Set(runner.reviews.runs(session.id).filter(\.isRunning).map(\.reviewer)),
                fileCount: facts.files,
                fileName: selectedChangeName(session),
                canReadSince: runner.reviews.latestTrees(session.id) != nil)
        }

        let designSession = reviewableDesign(session)
        let designDirectory = designSession.flatMap { store.designArtifactURL(for: $0) }?.deletingLastPathComponent()
        let screens = designDirectory.map { DesignManifest.read(from: $0).screens } ?? []
        let design = designSession.flatMap { design in
            designDirectory.map { _ in SessionOpinionAsk.Design(author: runner.author(of: design), screenCount: screens.count) }
        }

        let initial: SessionOpinionKind = {
            if picked != nil { return .chat }
            let preferred: SessionOpinionKind? = switch tab {
            case .changes: .changes
            case .design: .design
            case .conversation where session.isActivelyDesigning: .design
            default: nil
            }
            let available = [answer != nil ? SessionOpinionKind.chat : nil,
                             changes != nil ? .changes : nil,
                             design != nil ? .design : nil].compactMap { $0 }
            if let preferred, available.contains(preferred) { return preferred }
            return available.first ?? .chat
        }()

        let executables = Dictionary(uniqueKeysWithValues: installed.compactMap { agent in
            runner.executable(for: agent).map { (agent, $0) }
        })
        dialogs.show(Dialog(
            title: "Ask for a second opinion",
            content: AnyView(SessionOpinionAsk(
                answer: answer, changes: changes, design: design, initial: initial, installed: installed,
                lineup: opinionLineup ?? Preferences.secondOpinionLineup().filter { installed.contains($0.agent) },
                changesFocus: changesNavigation.secondOpinionFocus, scope: changesNavigation.secondOpinionScope,
                ask: { choice in
                    switch choice {
                    case .chat(let lineup, let focus, let reading):
                        guard let chatSubject else { return }
                        opinionLineup = lineup
                        dialogs.dismiss()
                        if tab != .conversation { tab = .conversation }
                        runner.opinions.ask(
                            ChatSecondOpinion.Request(subject: chatSubject, focus: focus, reading: reading,
                                                      conversation: reading.conversation
                                                        ? SideQuestion.recentChat(session.messages) : "",
                                                      directories: store.workingDirectories(for: session),
                                                      executable: ""),
                            reviewers: lineup, executables: executables, anchor: chatAnchor, in: sessionID)
                    case .changes(let lineup, let focus, let scope):
                        opinionLineup = lineup
                        changesNavigation.secondOpinionFocus = focus
                        changesNavigation.secondOpinionScope = scope
                        // The Changes screen starts the run and puts its progress up in
                        // place of this dialog.
                        tab = .changes
                        changesNavigation.secondOpinionRequest = .ask(lineup)
                    case .design(let lineup, let focus, let reading):
                        guard let designSession, let designDirectory else { return }
                        opinionLineup = lineup
                        dialogs.dismiss()
                        if shownDesign(session) == nil {
                            tab = session.isActivelyDesigning ? .conversation : .design
                        }
                        let shots = FileManager.default.temporaryDirectory
                            .appendingPathComponent("code-station-design-review-\(UUID().uuidString)", isDirectory: true)
                        let asked = designSession.messages.filter { $0.role == .user }.suffix(3).reversed()
                            .map(\.text).joined(separator: "\n\n")
                        runner.designOpinions.ask(
                            DesignSecondOpinion.Request(focus: focus, reading: reading,
                                                        designDirectory: designDirectory.path, shotsDirectory: shots.path,
                                                        shots: [], asked: asked,
                                                        conversation: reading.conversation
                                                            ? SideQuestion.recentChat(designSession.messages) : "",
                                                        executable: ""),
                            screens: screens, reviewers: lineup, executables: executables, in: designSession.id)
                    }
                })),
            actions: [], width: 620, framesItself: true))
    }

    // The file picked on the Changes screen, which a reviewer can be held to.
    private func selectedChangeName(_ session: ChatSession) -> String? {
        let root = directory(for: selectedProjectID ?? session.projectID, in: session)
            ?? store.workingDirectories(for: session).first
        guard let root, let id = changesNavigation.selections[root]?.activeID,
              let file = gitStats.snapshot(at: root)?.files.first(where: { $0.id == id }) else { return nil }
        return file.fileName
    }

    private func opinionCard(_ opinion: ChatOpinion, session: ChatSession) -> some View {
        let pending = runner.question(sessionID).flatMap { Self.planID($0) == opinion.subject.id ? $0 : nil }
        let opinions = runner.opinions
        return ChatOpinionCard(
            opinion: opinion, authorTitle: session.agent.title, planPending: pending != nil,
            toggle: { opinions.toggle($0, of: opinion.id, in: sessionID) },
            send: {
                let names = Array(NSOrderedSet(array: opinion.lanes.map(\.reviewer.agent.title))) as? [String] ?? []
                let text = ChatSecondOpinion.feedback(opinion.ticked, subject: opinion.subject,
                                                      names: names.joined(separator: " and "))
                // A plan still waiting goes back as its answer, so the agent keeps
                // planning with the points in mind rather than being told no.
                if let pending {
                    runner.answer(pending, with: .revise(text), sessionID: sessionID, store: store)
                } else {
                    runner.send(text, sessionID: sessionID, store: store)
                }
                opinions.markSent(opinion.id, count: opinion.ticked.count, in: sessionID)
            },
            approve: {
                guard let pending else { return }
                runner.answer(pending, with: .allowOnce, sessionID: sessionID, store: store)
            },
            askAgain: {
                askForSecondOpinion(session, on: opinion.subject, anchor: opinion.anchor)
            },
            retry: { seat in
                guard let executable = runner.executable(for: seat.agent) else { return }
                opinions.retry(seat, of: opinion.id, executable: executable, in: sessionID)
            },
            stop: { opinions.stop($0, of: opinion.id, in: sessionID) },
            dismiss: { opinions.dismiss(opinion.id, in: sessionID) })
    }

    // A running turn shows the row for as long as it runs, whatever the transcript looks
    // like. A message holds what the model said and the calls it then made, so anything
    // keyed off its text goes dark the moment the model speaks and stays dark for the rest
    // of the turn - which is also when the silence counter is worth the most.
    private func showsThinking(state: SessionState) -> Bool {
        guard !runner.isRecapping(sessionID) else { return false }
        // A parked turn is waiting on the person, not working.
        return switch state {
        case .reconnecting, .stalled:
            false
        default:
            state.isBusy && runner.question(sessionID) == nil
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard transcriptPinnedToBottom else { return }
        // Animating every streamed token makes the transcript jitter, so only whole
        // arrivals - a message, a tool row, a finished line - are worth animating.
        if animated, !reduceMotion {
            withAnimation(.easeOut(duration: 0.18), completionCriteria: .removed) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            } completion: {
                // The composer and rows can change size while the scroll is moving.
                guard transcriptPinnedToBottom else { return }
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    // What the transcript is made of, coarsely: how many rows there are, how many lines
    // the streaming message has settled, and the state around them. Tokens landing inside
    // a line change the text but not this, which is what keeps the animation to one beat
    // per addition. The chunk count is the one part that moves with the text, in coarse
    // steps, so a long line can be followed without every token asking for a scroll.
    private struct TranscriptShape: Equatable {
        var messages: Int
        var tools: Int
        var thoughts: Int
        var lines: Int
        var state: SessionState
        var question: String?
        var chunks: Int

        // The shape with the chunk count set aside: what has changed when something whole
        // arrives, and what the transcript's animation is keyed on.
        var settled: TranscriptShape {
            var shape = self
            shape.chunks = 0
            return shape
        }
    }

    private func transcriptShape(_ session: ChatSession, state: SessionState) -> TranscriptShape {
        let text = session.messages.last?.text ?? ""
        return TranscriptShape(messages: session.messages.count,
                               tools: session.messages.last?.tools.count ?? 0,
                               thoughts: session.messages.last?.thinking?.count ?? 0,
                               lines: newlineCount(text),
                               state: state,
                               question: runner.question(sessionID)?.id,
                               chunks: text.utf8.count / 120)
    }

    private func newlineCount(_ text: String) -> Int {
        var count = 0
        for byte in text.utf8 where byte == UInt8(ascii: "\n") { count += 1 }
        return count
    }

    // MARK: - Composer

    private func placeholder(state: SessionState) -> String {
        switch state {
        case .waiting: "Say what to do next…"
        case _ where state.isBusy:
            runner.canSteer(sessionID) && appSettings.midTurnPromptDelivery == .now
                ? "Say more while it works…" : "Queue what comes next…"
        default: "Ask for a change"
        }
    }

    private func composer(session: ChatSession, project: Project, blocked: Bool) -> some View {
        let state = runner.state(sessionID)
        return Composer(sessionID: sessionID,
                        agent: session.agent,
                        blocked: blocked,
                        isFocused: $composerFocused,
                        placeholder: placeholder(state: state),
                        onOversizedPaste: offerTextFile,
                        onRecallUp: { runner.recallEarlier(sessionID, store: store) },
                        onRecallDown: { runner.recallLater(sessionID, store: store) },
                        onSend: {
                            promptSentAt = .now
                            transcriptPinnedToBottom = true
                            transcriptScrollRequest += 1
                        },
                        onSuggestionKey: { suggestionKey($0, blocked: blocked) },
                        dictates: true,
                        above: {
                            snoozeStrip(session)
                            runChoices(session, project: project)
                            contextNudge(session)
                            promptSuggestion(busy: state.isBusy, blocked: blocked)
                            SessionQueueStrip(sessionID: sessionID, busy: state.isBusy,
                                              blocked: blocked) { composerFocused = true }
                        },
                        accessory: {
                            SessionBotPicker(avatars: appSettings.agentAvatars,
                                             selectedName: botSelection(for: session),
                                             sessionID: sessionID,
                                             size: 22)
                        })
                        .motion(store.isSnoozed(sessionID) ? Motion.reveal : Motion.leave,
                                value: store.isSnoozed(sessionID))
                        .motion(Motion.reveal, value: runner.queued(sessionID).isEmpty)
                        .motion(Motion.leave, value: runner.isNudgeDismissed(sessionID))
    }

    // The choices the next turn will run on, on the line the eye is already on when
    // hitting send: the session's fixed agent, its model, and the rest of the run
    // controls. What the session has done and where belongs on the status strip, not
    // here - this line is only ever about what happens next.
    //
    // The saved commands sit at the end of it, behind one Run button, for the same
    // reason. Running the tests for what was just written is the next thing that happens
    // as much as sending another prompt is.
    @ViewBuilder private func runChoices(_ session: ChatSession, project: Project) -> some View {
        HStack(spacing: 10) {
            if session.settings?.mcpServersEnabled == false {
                MonoChip(text: "MCP off", size: 10.5, bordered: true)
            }
            SessionRunSettingsControls(sessionID: sessionID)
            Spacer(minLength: 12)

            // Ad-hoc tasks run in a private folder the app made for one prompt, so there
            // is nothing there worth saving a command against.
            if project.kind == .project {
                SessionRunButton(session: session, edit: { shortcutEditor = $0 })
            }
        }
        // The command list rises over the transcript, so the row is drawn above it.
        .zIndex(1)
    }

    private func botSelection(for session: ChatSession) -> Binding<String> {
        Binding(
            get: {
                AgentAvatarSelection.resolvedName(
                    store.session(sessionID)?.agentAvatarName,
                    availableNames: appSettings.agentAvatars.map { $0.url.lastPathComponent })
            },
            set: { store.setAgentAvatarName($0, for: sessionID) })
    }

    // Manual compaction is a Claude Code action. Clearing remains available for either
    // agent as a deliberate fresh start, even though Codex makes room automatically.
    private func contextActions() -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if runner.canCompactContext(sessionID, store: store) {
            entries.append(.item("Compact context",
                                 subtitle: "Summarises the conversation so far and carries on from it.") {
                confirmCompact()
            })
        }
        if runner.canClearContext(sessionID, store: store) {
            entries.append(.item("Clear context",
                                 kind: .destructive,
                                 subtitle: "The next turn starts a fresh conversation in the same folder.") {
                runner.clearContext(sessionID, store: store)
            })
        }
        return entries
    }

    // Compacting spends a turn and takes the best part of a minute, which is not what a
    // menu row usually costs, so it is said plainly before it starts.
    private func confirmCompact() {
        dialogs.show(.confirm(
            "Compact this session's context?",
            message: "The agent reads the conversation so far, replaces it with a summary, and carries on from that. It takes a turn of its own - up to a minute - and counts towards what this session has spent.",
            action: "Compact", kind: .primary) {
                runner.compact(sessionID, store: store)
            })
    }

    // The percentage says how much of the window is in use but not where it went, and the
    // split is rarely what it looks like: cache reads run an order of magnitude ahead.
    private func usageTooltip(_ usage: SessionUsage, agent: AgentKind,
                              clearable: Bool) -> Tooltip {
        var rows: [Tooltip.Row] = []
        for (label, count) in [("Input", usage.inputTokens),
                               ("Output", usage.outputTokens),
                               ("Cache read", usage.cacheReadTokens),
                               ("Cache write", usage.cacheWriteTokens)] where count > 0 {
            rows.append(Tooltip.Row(label: label, value: formattedTokens(count)))
        }
        if usage.contextWindow > 0 {
            rows.append(Tooltip.Row(
                label: agent.asksPermissions ? "Context" : "Window",
                value: "\(formattedTokens(usage.contextTokens)) of \(formattedTokens(usage.contextWindow))"))
        }
        // Codex and Copilot report no cost, so a zero here means "unknown" rather than free.
        if appSettings.showsCost(for: agent), usage.costUSD > 0 {
            rows.append(Tooltip.Row(label: "Spent", value: Money.short(usage.costUSD)))
        }
        let turns = counted(usage.turns, "turn")
        let note = if !agent.asksPermissions {
            clearable
                ? "Current model window after the latest model call. \(agent.title) compacts it automatically as it fills. Click for options."
                : "Current model window after the latest model call. \(agent.title) compacts it automatically as it fills."
        } else {
            clearable
                ? "Context in use after the last turn. Click for options."
                : "Context in use after the last turn."
        }
        return Tooltip(title: "Session usage",
                       subtitle: usage.model(for: agent).map { "\($0) · \(turns)" } ?? turns,
                       note: note,
                       rows: rows)
    }

    // A session runs into the end of its window mid-thought, and the failure is a turn
    // that will not start rather than anything the meter said. So once the window is
    // nearly full the way out is offered here, on the line above the composer, rather
    // than waiting to be looked for. Codex and Copilot handle this condition through
    // automatic compaction, so only Claude Code needs the interruption.
    @ViewBuilder private func contextNudge(_ session: ChatSession) -> some View {
        let fraction = session.usage?.contextFraction(for: session.agent) ?? 0
        let actions = contextActions()
        if session.agent == .claudeCode,
           fraction >= SessionRunner.nearlyFullContext, !actions.isEmpty,
           !runner.isNudgeDismissed(sessionID) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                Text("CONTEXT IS NEARLY FULL · \(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(1.2)
                Spacer(minLength: 8)
                if runner.canCompactContext(sessionID, store: store) {
                    ActionButton(title: "Compact", tone: .green, height: 26, size: 12,
                                 action: confirmCompact)
                        .appTooltip("Summarises the conversation so far and carries on from it.")
                }
                InlineLink(title: "Clear", size: 12) {
                    runner.clearContext(sessionID, store: store)
                }
                .appTooltip("Starts the next turn on a fresh conversation in the same folder.")
                Button { runner.dismissNudge(sessionID) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverLift(amount: Motion.smallLift)
                .appTooltip("Hide this until the window is dealt with")
            }
            .foregroundStyle(Theme.attention)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(Theme.field, cornerRadius: 8, border: Theme.attention.opacity(0.4))
            .transition(dismissal)
        }
    }

    // A strip the user puts away fades while the space it held closes. Under Reduce
    // Motion the space closes at once and only the fade is left.
    private var dismissal: AnyTransition {
        .asymmetric(insertion: .fadeIn,
                    removal: reduceMotion ? AnyTransition.opacity.animation(Motion.leave) : .fold)
    }

    private func dismissSuggestion() {
        withAnimation(reduceMotion ? nil : Motion.leave) {
            runner.dismissSuggestion(sessionID)
        }
    }

    // What the agent expects to be asked next. It sits with the other rows about what
    // happens next, and goes as soon as the session starts working again, since a
    // prediction made about a finished turn says nothing about the one now running.
    @ViewBuilder private func promptSuggestion(busy: Bool, blocked: Bool) -> some View {
        if !busy, !blocked, let suggestion = runner.suggestion(sessionID) {
            PromptSuggestionStrip(
                suggestion: suggestion,
                hasDraft: !runner.composer.draft(sessionID).text.isBlank,
                edit: editSuggestion,
                send: sendSuggestion,
                dismiss: dismissSuggestion)
                .transition(dismissal)
        }
    }

    private func editSuggestion() {
        runner.takeSuggestion(sessionID)
        composerFocused = true
    }

    private func sendSuggestion() {
        transcriptPinnedToBottom = true
        transcriptScrollRequest += 1
        runner.sendSuggestion(sessionID, store: store)
    }

    // The keys the strip answers, taken only while it is on screen and the cursor is in
    // the composer. Return is deliberately not among them: the key pressed hundreds of
    // times a day keeps meaning "send the draft" and can never be taken by a prediction.
    private func suggestionKey(_ key: SuggestionKey, blocked: Bool) -> Bool {
        guard !blocked, !runner.state(sessionID).isBusy,
              runner.suggestion(sessionID) != nil else { return false }
        switch key {
        case .edit:
            editSuggestion()
        case .send:
            // With words already typed the pill reads Append, so the key that would have
            // sent has nothing to answer and falls through to its usual meaning.
            guard runner.composer.draft(sessionID).text.isBlank else { return false }
            sendSuggestion()
        case .cancel:
            dismissSuggestion()
        }
        return true
    }

    // A snoozed session says so where the next prompt is typed, with the way back.
    @ViewBuilder private func snoozeStrip(_ session: ChatSession) -> some View {
        if let snooze = store.snooze(of: session.id) {
            SessionSnoozeStrip(snooze: snooze) {
                SessionSnoozeMenu.wake(session.id, store: store)
                composerFocused = true
            }
            .transition(dismissal)
        }
    }

    private func offerTextFile(_ text: String) {
        let count = text.count.formatted()
        let limit = ComposerPaste.characterLimit.formatted()
        let message = "This paste has \(count) characters. Pastes are limited to \(limit) characters "
            + "to keep the composer responsive. Would you like to upload it as a text file instead?"
        dialogs.show(.confirm("Text is too long to paste", message: message,
                              action: "Upload as file", kind: .primary) {
            guard let attachment = Attachments.fromPastedText(text) else {
                dialogs.show(.notice("Could not attach the text",
                                     message: "The temporary text file could not be created."))
                return
            }
            runner.composer.attach([attachment], to: sessionID)
            composerFocused = true
        })
    }
}
