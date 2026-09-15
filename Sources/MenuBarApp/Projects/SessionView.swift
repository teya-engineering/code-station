import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Long conversations stay fully available to the runner and persistence layer, but the
// view only builds a bounded tail. Earlier pages are added on demand without changing
// the transcript format or making old sessions migrate their data.
struct TranscriptWindow: Equatable {
    // What a session opens with. Every row is built eagerly, so this is what opening one
    // costs, and it is kept small because it is paid before anything is on screen.
    let openingPage: Int
    // What each request for earlier messages adds. Larger than the opening page: someone
    // reading back through a conversation asked for the wait, and should not have to keep
    // asking a page at a time.
    let step: Int
    private(set) var visibleCount: Int

    init(openingPage: Int = 20, step: Int = 80) {
        self.openingPage = max(1, openingPage)
        self.step = max(1, step)
        visibleCount = self.openingPage
    }

    func hiddenCount(totalCount: Int) -> Int {
        max(0, totalCount - visibleCount)
    }

    func visibleMessages(in messages: [ChatMessage]) -> ArraySlice<ChatMessage> {
        messages.suffix(visibleCount)
    }

    mutating func loadEarlier(totalCount: Int) {
        guard hiddenCount(totalCount: totalCount) > 0 else { return }
        visibleCount = min(totalCount, visibleCount + step)
    }

    mutating func reveal(_ messageID: UUID, in messages: [ChatMessage]) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        visibleCount = max(visibleCount, messages.count - index)
    }

    mutating func reset() {
        visibleCount = openingPage
    }
}

// Content growth and a person scrolling up both move the transcript's bottom marker.
// AppKit's live-scroll notifications separate those cases, so streaming can keep its
// place without taking the scroll position back from someone reading an earlier line.
private struct TranscriptScrollObserver: NSViewRepresentable {
    let onPositionChange: (Bool) -> Void

    func makeNSView(context: Context) -> TranscriptScrollObserverView {
        let view = TranscriptScrollObserverView()
        view.onPositionChange = onPositionChange
        return view
    }

    func updateNSView(_ view: TranscriptScrollObserverView, context: Context) {
        view.onPositionChange = onPositionChange
        view.observeEnclosingScrollView()
    }

    static func dismantleNSView(_ view: TranscriptScrollObserverView, coordinator: ()) {
        view.stopObserving()
    }
}

@MainActor
private final class TranscriptScrollObserverView: NSView {
    var onPositionChange: ((Bool) -> Void)?
    private weak var observedScrollView: NSScrollView?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeEnclosingScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeEnclosingScrollView()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func observeEnclosingScrollView() {
        guard observedScrollView !== enclosingScrollView else { return }
        stopObserving()
        guard let enclosingScrollView else { return }
        observedScrollView = enclosingScrollView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didLiveScroll),
            name: NSScrollView.didLiveScrollNotification,
            object: enclosingScrollView)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didLiveScroll),
            name: NSScrollView.didEndLiveScrollNotification,
            object: enclosingScrollView)
    }

    func stopObserving() {
        guard let observedScrollView else { return }
        NotificationCenter.default.removeObserver(
            self, name: NSScrollView.didLiveScrollNotification, object: observedScrollView)
        NotificationCenter.default.removeObserver(
            self, name: NSScrollView.didEndLiveScrollNotification, object: observedScrollView)
        self.observedScrollView = nil
    }

    @objc private func didLiveScroll() {
        guard let scrollView = observedScrollView,
              let documentView = scrollView.documentView else { return }
        let visible = scrollView.documentVisibleRect
        let document = scrollView.contentView.documentRect
        guard document.height > visible.height + 1 else {
            onPositionChange?(true)
            return
        }
        let distance = documentView.isFlipped
            ? document.maxY - visible.maxY
            : visible.minY - document.minY
        // A small gap at the end should not stop following the conversation.
        onPositionChange?(distance <= 24)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sessionID: UUID

    private enum Tab: Hashable { case conversation, design, troubleshoot, changes, explorer }

    @State private var tab: Tab = .conversation
    @State private var terminalFocused = false
    @State private var composerFocused = false
    @State private var selectedProjectID: UUID?
    @State private var explorerShowsDesignFiles = false
    @State private var shortcutEditor: ShortcutEditorRequest?
    @State private var exportingDesignMaterials = false
    @State private var transcriptWindow = TranscriptWindow()
    @State private var transcriptPinnedToBottom = true
    @State private var transcriptScrollRequest = 0
    @State private var agentFocus: AgentTranscriptFocus?
    @State private var recapOpen = false
    @State private var recapNeedsAttention = false
    @State private var workingSetVisible: Bool
    @State private var requestedChange: RequestedChange?
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

    private let bottomAnchor = "transcript-bottom"
    private var terminalScope: TerminalScope { .session(sessionID) }
    private var shortcutScope: ShortcutScope { .session(sessionID) }

    private struct RequestedChange: Hashable {
        let root: String
        let path: String
    }

    init(sessionID: UUID, opening: SessionDestination = .conversation) {
        self.sessionID = sessionID
        switch opening {
        case .conversation:
            _tab = State(initialValue: .conversation)
            _requestedChange = State(initialValue: nil)
        case .design:
            _tab = State(initialValue: .design)
            _requestedChange = State(initialValue: nil)
        case .changes:
            _tab = State(initialValue: .changes)
            _requestedChange = State(initialValue: nil)
        case .change(let root, let path):
            _tab = State(initialValue: .changes)
            _requestedChange = State(initialValue: RequestedChange(root: root, path: path))
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
            let explorerDirectory = explorerShowsDesignFiles
                ? designFilesURL?.path ?? projectDirectory
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
                if showsDirectoryBar(for: session, designFilesURL: designFilesURL) {
                    sessionDirectoryBar(session, designFilesURL: designFilesURL)
                }
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
                case .changes:
                    ChangesView(root: requestedChange?.root ?? projectDirectory,
                                initiallySelectedPath: requestedChange?.path)
                        .id(requestedChange)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .explorer:
                    ExplorerView(root: explorerDirectory)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let openRun = shortcuts.output(for: shortcutScope) {
                    ShortcutOutputDrawer(run: openRun) {
                        shortcuts.showOutput(nil, for: shortcutScope)
                    }
                }

                if terminals.isOpen(terminalScope) {
                    TerminalDrawer(scope: terminalScope,
                                   directory: workingDirectory,
                                   focusTerminal: $terminalFocused)
                }
            }
            .background(Theme.background)
            .onAppear {
                composerFocused = true
                recapOpen = recap != nil
                recapNeedsAttention = recap != nil
                openWorkingSetForLiveTurnIfNeeded()
            }
            .sheet(item: $shortcutEditor) { request in
                ShortcutEditorView(request: request) { shortcut in
                    if request.shortcut == nil {
                        shortcuts.add(name: shortcut.name, text: shortcut.text,
                                      kind: shortcut.kind,
                                      icon: shortcut.icon,
                                      projectID: shortcut.projectID,
                                      availableInAllProjects: shortcut.availableInAllProjects)
                    } else {
                        shortcuts.update(shortcut)
                    }
                }
                .appOverlays()
            }
            .background(terminalShortcut(directory: workingDirectory))
            .background(tabShortcuts(headerTabs(for: session)))
            .background(recapShortcut)
            .background(stopShortcut)
            .onChange(of: terminalFocused) { _, focused in
                if focused { composerFocused = false }
            }
            .task(id: sessionID) {
                selectedProjectID = requestedChange.flatMap { change in
                    store.checkoutProjects(for: session).first { checkout in
                        let root = checkout.worktreePath ?? store.project(checkout.projectID)?.path
                        return root == change.root
                    }?.projectID
                } ?? session.projectID
                explorerShowsDesignFiles = designFilesURL != nil
                sampleMissingFolders()
                refreshStats(workingDirectories, reusingRecent: true)
                runner.refreshContext(sessionID, store: store)
                // Scanning a conversation means having it, and it is still being read in.
                await store.transcriptReady(sessionID)
                store.clearFinished(sessionID)
                store.findPullRequests(in: sessionID)
            }
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
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                        recapOpen = true
                    }
                    recapNeedsAttention = store.hasFinished(sessionID)
                }
            }
            .onChange(of: runner.state(sessionID)) { _, state in
                openWorkingSetForLiveTurnIfNeeded()
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

    // What each deck gives up to fit the pane, in the order it is worth giving up.
    // Nothing here drops an action: the rail is where every one of them lives, so it is
    // a rail that is always whole and reachable, however narrow the window is pulled.
    private enum HeaderFit {
        // Every group on the rail, and the branch chip at the width a name deserves.
        case whole
        // The utilities behind one button, and the branch cut back to a stub. They are
        // the parts reached for least often, and the utilities are the only group whose
        // words survive being put in a menu.
        case folded
    }

    // The first deck stands taller than the second: it carries the identity tile and the
    // state seat, and it is the band a reader lands on first.
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
        let context = session.usage?.contextFraction(for: session.agent)
        let tone = SessionTone(sessionID, store: store, runner: runner)
        // The pane draws the first of these that fits. What the readings ask for is
        // measured rather than guessed at a width chosen in advance, so a longer branch
        // or a longer project name gives something up on its own instead of running off
        // the right edge of the pane.
        return ViewThatFits(in: .horizontal) {
            identityRow(session: session, project: project, fit: .whole)
            identityRow(session: session, project: project, fit: .folded)
        }
        .overlay(alignment: .bottom) {
            if let context {
                ContextHairline(fraction: context, animated: tone == .running)
            }
        }
    }

    private func identityRow(session: ChatSession, project: Project,
                             fit: HeaderFit) -> some View {
        let workspace = session.workspaceID.flatMap(store.workspace)
        let container = workspace?.name ?? project.name
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
                // A prompt cut to a line is a label rather than a heading, so it is drawn
                // as one: the same family, a step down in size, and a step back in
                // contrast from the name it qualifies.
                Text(session.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(idealWidth: Self.titleRoom, alignment: .leading)
                    .changingName(session.title)
            }

            Spacer(minLength: 12)

            // A row splits its width between the children rather than handing each one
            // what it asks for, so the readings could be offered less than they need and
            // truncate. Holding them at their natural width makes the title give way.
            readings(session: session, fit: fit)
                .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .headerBand(height: Self.identityDeckHeight)
    }

    // The session's state and branch, with the other details behind the branch chip.
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
            stateSeat(tone: tone, conversation: live,
                      isTroubleshooting: session.isTroubleshooting)
            SessionAgentIndicator(session: session) { target in
                tab = .conversation
                transcriptWindow.reveal(target.messageID, in: session.messages)
                transcriptPinnedToBottom = false
                agentFocus = target
            }
            SessionFactsChip(
                facts: facts,
                maxWidth: fit == .whole ? Self.branchRoom : Self.foldedBranchRoom,
                openChanges: openChanges,
                contextActions: contextActions,
                usageTooltip: {
                    guard let usage = session.usage else { return Tooltip(title: "") }
                    return usageTooltip(usage, agent: session.agent,
                                        clearable: !contextActions().isEmpty)
                })
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // The second deck: where to go on the left, what to open beside where you already are
    // on the right. The gap between the two is the line the tab bar's edge used to carry.
    private func destinationDeck(session: ChatSession, project: Project,
                                 recap: SessionRecap?) -> some View {
        ViewThatFits(in: .horizontal) {
            destinationRow(session: session, project: project, recap: recap, fit: .whole)
            destinationRow(session: session, project: project, recap: recap, fit: .folded)
            // Even the folded rail can leave too little room for every tab label.
            destinationRow(session: session, project: project, recap: recap, fit: .folded,
                           scrollsTabs: true)
        }
        .overlay(alignment: .topTrailing) {
            recapCard(recap)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: recapOpen)
    }

    private func destinationRow(session: ChatSession, project: Project,
                                recap: SessionRecap?, fit: HeaderFit,
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

    // What the pane can open beside where you already are: the panel toggles, the saved
    // prompts, then what the session itself offers. A hairline closes each group, so the
    // rail reads as a few things rather than as a row of icons.
    private func rail(session: ChatSession, project: Project, recap: SessionRecap?,
                      fit: HeaderFit) -> some View {
        HStack(spacing: 9) {
            panelToggles(session: session, project: project)
            // An ad-hoc task runs in a private folder made for one prompt, so there is no
            // project behind it to have saved any.
            if project.kind == .project, !promptsBlocked(session: session, project: project) {
                SessionPromptShortcuts(session: session,
                                       conversationID: visibleConversationID,
                                       folded: fit == .folded,
                                       edit: { shortcutEditor = $0 })
            }
            if hasUtilities(session: session) {
                HeaderRailDivider()
                if fit == .whole {
                    utilities(session: session, project: project, recap: recap)
                } else {
                    utilitiesOverflow(session: session, project: project)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // Neither of these sends you anywhere: they open a panel beside the pane and leave
    // what you were reading where it was. Keeping them off the tab deck is what gives the
    // gap between the two its meaning - inside the deck you choose where to be, outside
    // it you open something next to where you already are. Without a word beside them
    // they carry a tooltip, which the worded tabs do not need.
    private func panelToggles(session: ChatSession, project: Project) -> some View {
        let directory = session.worktreePath ?? project.path
        let inDrawer = appSettings.opensTerminalInDrawer
        let terminalOpen = terminals.isOpen(terminalScope)
        let lit = inDrawer && terminalOpen
        return HStack(spacing: 2) {
            // The terminal setting says where a shell belongs, so the press goes straight
            // there. Opening one the other way is the same wish reached a different way,
            // so it stays on the button's own menu.
            HeaderRailButton(icon: "terminal",
                             state: lit ? .open : .rest,
                             label: inDrawer
                                ? (terminalOpen ? "Hide terminal here" : "Open terminal here")
                                : "Open in \(SystemTerminal.appName)") {
                if inDrawer {
                    toggleTerminal(directory: directory)
                } else {
                    SystemTerminal.open(directory)
                }
            }
            .appContextMenu {
                terminalEntries(isOpen: terminalOpen,
                                toggle: { toggleTerminal(directory: directory) },
                                directory: directory)
            }
            workingSetToggle
        }
    }

    private var workingSetToggle: some View {
        let isOpen = tab == .conversation && workingSetVisible
        return HeaderRailButton(icon: "sidebar.right",
                                state: isOpen ? .open : .rest,
                                label: isOpen ? "Close working set" : "Open working set") {
            if isOpen {
                setWorkingSetVisible(false)
            } else {
                tab = .conversation
                setWorkingSetVisible(true)
            }
        }
        .accessibilityValue(isOpen ? "open" : "closed")
    }

    // Actions for the session as a whole stay together at the end of the rail.
    private func utilities(session: ChatSession, project: Project,
                           recap: SessionRecap?) -> some View {
        HStack(spacing: 2) {
            if let worktreePath = session.worktreePath {
                HeaderRailButton(icon: "folder", label: "Open worktree in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: worktreePath, isDirectory: true))
                }
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
            if appSettings.mobileAccessEnabled {
                MobileAccessButton(scope: .session(sessionID), onRail: true)
            }
        }
    }

    // The same actions behind one button, for a window too narrow to hold the rail. The
    // utilities fold before the toggles and the tab deck do: they are the group you reach
    // for least often, and the only one whose words survive being put in a menu.
    private func utilitiesOverflow(session: ChatSession, project: Project) -> some View {
        HeaderRailButton(icon: "ellipsis",
                         badge: recapNeedsAttention,
                         label: "More session actions")
            .appMenu { utilityEntries(session: session, project: project) }
    }

    private func utilityEntries(session: ChatSession, project: Project) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if let worktreePath = session.worktreePath {
            entries.append(.item("Open worktree in Finder", icon: "folder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: worktreePath, isDirectory: true))
            })
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
        if appSettings.mobileAccessEnabled {
            entries.append(.item(MobilePairing.menuLabel, icon: "qrcode") {
                MobilePairing.open(scope: .session(sessionID), dialogs: dialogs, store: store)
            })
        }
        return entries
    }

    // A session whose folder has gone cannot take a prompt any more than it can take a
    // typed one, and the pane already says so above the composer.
    private func promptsBlocked(session: ChatSession, project: Project) -> Bool {
        !FileManager.default.fileExists(atPath: session.worktreePath ?? project.path)
    }

    private func hasUtilities(session: ChatSession) -> Bool {
        session.worktreePath != nil || showsDesignMaterialExport(session)
            || showsRecap || appSettings.mobileAccessEnabled
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
                .transition(.fadeIn)
        }
    }

    // The deck in the order it is reached by ⌘1 through ⌘5: first what the agent is being
    // set to do, then what it did to the working tree.
    private func headerTabs(for session: ChatSession) -> [HeaderTab] {
        var tabs: [HeaderTab] = [
            destination(session.isActivelyDesigning
                            ? "Design"
                            : (session.isImplementingDesign ? "Build" : "Chat"),
                        icon: "bubble.left.and.bubble.right",
                        value: .conversation)
        ]
        if !session.isActivelyDesigning,
           appSettings.designEnabled || store.isDesignMode(session) {
            tabs.append(HeaderTab(
                label: "Design",
                icon: "paintbrush.pointed",
                selected: tab == .design,
                activate: { openDesign(for: session) }))
        }
        tabs.append(destination("Troubleshoot", icon: "stethoscope", value: .troubleshoot))
        tabs.append(changesTab(session))
        tabs.append(destination("Explorer", icon: "folder", value: .explorer))
        return tabs
    }

    private func destination(_ label: String, icon: String, value: Tab) -> HeaderTab {
        HeaderTab(label: label, icon: icon, selected: tab == value) {
            tab = value
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

    // The counts ride on the tab that opens them. A mark beside the word could only say
    // that the working tree had moved; the numbers say how far, and they say it in the
    // one place someone would click to go and look.
    private func changesTab(_ session: ChatSession) -> HeaderTab {
        let label = store.isDesignMode(session) ? "Project Changes" : "Changes"
        var changes = destination(label, icon: "plusminus", value: .changes)
        changes.diff = workingTreeChanges(session).map {
            HeaderTab.Diff(added: $0.added, removed: $0.removed)
        }
        return changes
    }

    private func isDesignTabSelected(for session: ChatSession) -> Bool {
        switch tab {
        case .design:
            true
        case .conversation:
            session.isActivelyDesigning
        case .troubleshoot, .changes, .explorer:
            false
        }
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

    // "RUNNING · 4m", "WAITING · 12m", "IDLE · 2h": the state and how long it has been
    // in it. A running turn counts up from its own start rather than from the session's
    // last activity, which is what makes it the age of the work in flight. A waiting one
    // counts from where the work stopped, so the number is the length of the wait rather
    // than of the turn that is still holding it.
    //
    // The seat under it is a tint of the state's own colour, which is what lets the
    // reading hold the end of the deck without being drawn any larger. The word is always
    // there beside the light, so nothing here is said in colour alone.
    private func stateSeat(tone: SessionTone, conversation: ChatSession,
                           isTroubleshooting: Bool) -> some View {
        // Read off the wait rather than the tone: a wait that has gone stale reads as
        // NEEDS YOU, and how long it has been held is exactly what that row is for.
        let waitingSince = runner.waitingSince(conversation.id)
        let since: Date? = switch tone {
        case .running: runner.turnStarted(conversation.id)
        default: waitingSince ?? conversation.lastActivity
        }
        return HStack(spacing: 6) {
            if tone == .running {
                PulsingDot(size: 7)
            } else {
                StateLight(tone: tone, size: 7)
            }
            // A diagnosis runs like any other turn, but naming it is what tells the reader
            // the brief landed and the agent is working through it.
            StatusCaps(text: isTroubleshooting && tone == .running
                           ? "DIAGNOSING" : tone.word,
                       tint: tone.colour)
            if let since {
                StatusDot()
                // A live turn has to keep counting when nothing arrives to redraw it,
                // which is most of a long one and all of a wait.
                if tone == .running || waitingSince != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        StatusValue(text: RelativeTime.duration(since: since))
                    }
                } else {
                    StatusValue(text: RelativeTime.short(since))
                }
            }
        }
        .fixedSize()
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7).fill(tone.colour.opacity(0.12)))
    }

    private func showsDirectoryBar(for session: ChatSession, designFilesURL: URL?) -> Bool {
        switch tab {
        case .conversation, .design, .troubleshoot: false
        case .changes: store.checkoutProjects(for: session).count > 1
        case .explorer:
            designFilesURL != nil || store.checkoutProjects(for: session).count > 1
        }
    }

    private func sessionDirectoryBar(_ session: ChatSession, designFilesURL: URL?) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if tab == .explorer, designFilesURL != nil {
                    Button { explorerShowsDesignFiles = true } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "paintbrush.pointed.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 9)
                            Text("Design files")
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(explorerShowsDesignFiles ? Theme.card : Color.clear)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(explorerShowsDesignFiles ? Theme.accent : Color.clear)
                                .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(store.checkoutProjects(for: session)) { checkout in
                    if let project = store.project(checkout.projectID) {
                        let root = checkout.worktreePath ?? project.path
                        let snapshot = gitStats.snapshot(at: root)
                        let selected = selectedProjectID == project.id
                            && (tab == .changes || !explorerShowsDesignFiles)
                        Button {
                            selectedProjectID = project.id
                            requestedChange = nil
                            if tab == .explorer { explorerShowsDesignFiles = false }
                        } label: {
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(project.id == session.projectID
                                          ? Theme.accent : Theme.secret)
                                    .frame(width: 9, height: 9)
                                Text(project.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                                if let snapshot, !snapshot.files.isEmpty {
                                    DiffPair(added: snapshot.totalAdded,
                                             removed: snapshot.totalRemoved, size: 10.5)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(selected ? Theme.card : Color.clear)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(selected ? Theme.accent : Color.clear)
                                    .frame(height: 2)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
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

    // Escape calls off the running turn, so a run can be stopped without reaching for
    // the button in the composer. It only takes the key while there is a turn to stop
    // and nothing else on screen has a better claim on it: a dialog and a menu both
    // close on escape, and the shell in the drawer needs the key for whatever is
    // running in it.
    @ViewBuilder private var stopShortcut: some View {
        let target = visibleConversationID
        let state = runner.state(target)
        if state.isBusy, state != .stopping, dialogs.current == nil, !menus.isOpen,
           !terminalFocused, !recapOpen, !commandPalette.isPresented {
            Button("") { runner.stop(target) }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
        }
    }

    // The visible card has the first claim on Escape. In particular, closing a recap that
    // is being refreshed must not also stop the agent turn doing the refresh.
    @ViewBuilder private var recapShortcut: some View {
        if recapOpen, dialogs.current == nil, !menus.isOpen, !terminalFocused {
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
        _ = runner.recap(visibleConversationID, store: store)
    }

    private func toggleRecap() {
        guard store.recap(for: sessionID) != nil else {
            generateRecap()
            return
        }
        recapNeedsAttention = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
            recapOpen.toggle()
        }
    }

    private func closeRecap() {
        recapNeedsAttention = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
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
            let isDocked = geometry.size.width >= 800
            ZStack(alignment: .trailing) {
                conversationContent(session: session, project: project)
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
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18),
                           value: workingSetVisible)
            }
        }
    }

    private func conversationContent(session: ChatSession, project: Project) -> some View {
        VStack(spacing: 0) {
            transcript(session)
            Divider().overlay(Theme.hairline)
            composer(session: session, project: project)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func workingSet(_ session: ChatSession) -> some View {
        SessionWorkingSet(
            session: session,
            close: { setWorkingSetVisible(false) },
            openChange: { projectID, root, path in
                selectedProjectID = projectID
                requestedChange = RequestedChange(root: root, path: path)
                tab = .changes
            })
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

    private func transcript(_ session: ChatSession) -> some View {
        let state = runner.state(sessionID)
        let projectPath = store.workingDirectory(for: session) ?? ""
        let shape = transcriptShape(session, state: state)

        return ScrollViewReader { proxy in
            ScrollView {
                let visibleMessages = transcriptWindow.visibleMessages(in: session.messages)
                transcriptContent(session, messages: visibleMessages, state: state,
                                  projectPath: projectPath) {
                    let firstVisibleID = visibleMessages.first?.id
                    transcriptWindow.loadEarlier(totalCount: session.messages.count)
                    guard let firstVisibleID else { return }
                    Task {
                        await Task.yield()
                        proxy.scrollTo(firstVisibleID, anchor: .top)
                    }
                }
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
                        TranscriptScrollObserver { isAtBottom in
                            transcriptPinnedToBottom = isAtBottom
                        }
                    }
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
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { opened = true }
            }
            .task(id: agentFocus?.requestID) {
                guard opened, let agentFocus else { return }
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
        VStack(alignment: .leading, spacing: 18) {
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
                Button(action: loadEarlier) {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.up")
                        Text("Load earlier messages")
                        Text("\(hiddenCount) hidden")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .cardSurface(cornerRadius: 8)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Load earlier messages, \(hiddenCount) hidden")
            }

            ForEach(messages) { message in
                MessageView(message: message,
                            projectPath: projectPath,
                            textScale: appSettings.textSize.scale,
                            openChange: { path in
                                openChange(path, root: projectPath)
                            },
                            openTerminal: {
                                openTerminal(directory: projectPath)
                            },
                            promptMenu: promptMenu(for: message))
                    // Every message is on screen now, and a streaming turn rewrites
                    // the last one many times a second. Without this, each of those
                    // redraws every message in the transcript, parsing its markdown
                    // again on the way.
                    .equatable()
                    .environment(\.runningAgents, runner.runningAgents(sessionID))
                    .environment(\.activeTranscriptTools, runner.runningTools(sessionID))
                    .environment(\.agentTranscriptFocus, agentFocus)
                    .transition(.fadeIn)
            }

            handoff(state: state)

            pendingQuestion
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
                              onKeepWaiting: { waitNoticeDismissed = true },
                              onEnd: { runner.endWait(sessionID) })
                    .transition(.fadeIn)
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

            TurnEndActions(sessionID: sessionID, state: state)
        }
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
                ActionButton(title: "Click here to review changes") {
                    openChanges()
                }
                Spacer(minLength: 0)
            }
            .transition(.fadeIn)
        }
    }

    private func openChanges() {
        requestedChange = nil
        tab = .changes
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

            if let checkout = store.checkoutProjects(for: session).first(where: { checkout in
                let directory = checkout.worktreePath ?? store.project(checkout.projectID)?.path
                return directory == target.root
            }) {
                selectedProjectID = checkout.projectID
            }
        }
        requestedChange = target
        tab = .changes
    }

    private func openTerminal(directory: String) {
        if !terminals.isOpen(terminalScope) {
            terminals.setOpen(true, for: terminalScope, directory: directory)
        }
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
                    runner.editDraft(fork.id) { draft in
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
    @ViewBuilder private var pendingQuestion: some View {
        if let request = runner.question(sessionID) {
            PermissionCard(request: request,
                           workingDirectories: store.session(sessionID)
                               .map(store.workingDirectories(for:)) ?? []) { answer in
                runner.answer(request, with: answer, sessionID: sessionID, store: store)
            }
            .id(request.id)
        }
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
        case _ where state.isBusy: "Queue what comes next…"
        default: "Ask for a change"
        }
    }

    private func composer(session: ChatSession, project: Project) -> some View {
        let state = runner.state(sessionID)
        let blocked = !FileManager.default.fileExists(atPath: session.worktreePath ?? project.path)
            || !runner.isAvailable(session.agent)
        return Composer(sessionID: sessionID,
                        agent: session.agent,
                        blocked: blocked,
                        isFocused: $composerFocused,
                        placeholder: placeholder(state: state),
                        onOversizedPaste: offerTextFile,
                        onRecallUp: { runner.recallEarlier(sessionID, store: store) },
                        onRecallDown: { runner.recallLater(sessionID, store: store) },
                        onSend: {
                            transcriptPinnedToBottom = true
                            transcriptScrollRequest += 1
                        },
                        above: {
                            runChoices(session, project: project)
                            contextNudge(session)
                            queueStrip(busy: state.isBusy, blocked: blocked)
                        },
                        accessory: {
                            SessionBotPicker(avatars: appSettings.agentAvatars,
                                             selectedName: botSelection(for: session),
                                             sessionID: sessionID,
                                             size: 22)
                        })
    }

    // The choices the next turn will run on, on the line the eye is already on when
    // hitting send: the session's fixed agent, its model, and the rest of the run
    // controls. What the session has done and where belongs on the status strip, not
    // here - this line is only ever about what happens next.
    //
    // The saved commands sit at the end of it for the same reason. Running the tests for
    // what was just written is the next thing that happens as much as sending another
    // prompt is, and docking them here keeps them off a status strip that has to stay one
    // glance wide however many commands a project collects.
    @ViewBuilder private func runChoices(_ session: ChatSession, project: Project) -> some View {
        let agent = session.agent
        HStack(spacing: 10) {
            if session.settings?.mcpServersEnabled == false {
                MonoChip(text: "MCP off", size: 10.5, bordered: true)
            }
            pinnedSetting(agent.title, help: "This session always runs on \(agent.title).")
            SessionRunSettingsControls(sessionID: sessionID)

            // Ad-hoc tasks run in a private folder the app made for one prompt, so there
            // is nothing there worth saving a command against.
            if project.kind == .project {
                // The commands take the rest of the row, so they end at its right edge
                // and fit themselves to whatever is left of it once there are more of
                // them than it can hold.
                SessionShortcutChips(session: session,
                                     edit: { shortcutEditor = $0 })
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Spacer(minLength: 12)
            }
        }
    }

    private func botSelection(for session: ChatSession) -> Binding<String> {
        Binding(
            get: {
                if let name = store.session(sessionID)?.agentAvatarName,
                   name == AgentAvatarSelection.defaultName
                    || appSettings.agentAvatars.contains(where: {
                        $0.url.lastPathComponent == name
                    }) {
                    return name
                }
                return AgentAvatarSelection.resolvedName(
                    session.agentAvatarName,
                    availableNames: appSettings.agentAvatars.map { $0.url.lastPathComponent })
            },
            set: { store.setAgentAvatarName($0, for: sessionID) })
    }

    private func pinnedSetting(_ label: String, help: String) -> some View {
        Text(label)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize()
            .appTooltip(help)
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
                .appTooltip("Hide this until the window is dealt with")
            }
            .foregroundStyle(Theme.attention)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(Theme.field, cornerRadius: 8, border: Theme.attention.opacity(0.4))
        }
    }

    // Prompts typed ahead, above the composer where what happens next belongs. A queue that
    // is not moving on its own - the last turn failed, or was stopped - gets a button,
    // since nothing else would ever start it.
    @ViewBuilder private func queueStrip(busy: Bool, blocked: Bool) -> some View {
        let waiting = runner.queued(sessionID)
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    // The count sits in the heading because the list can be scrolled past
                    // or capped, and how much is waiting is the part worth knowing.
                    Text(busy ? "QUEUED · \(waiting.count) · RUNS WHEN THIS TURN ENDS"
                              : "QUEUED · \(waiting.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(1.2)
                    Spacer(minLength: 8)
                    if !busy && !blocked {
                        InlineLink(title: "Send now", size: 12) {
                            runner.runQueue(sessionID, store: store)
                        }
                    }
                }
                .foregroundStyle(Theme.accent)

                ForEach(waiting) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(item.text)
                            .font(.system(size: 13))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button {
                            runner.recall(item.id, sessionID: sessionID)
                            composerFocused = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(2)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .appTooltip("Take it back into the composer to rework")
                        Button {
                            runner.unqueue(item.id, sessionID: sessionID)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(2)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .appTooltip("Remove from the queue")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fieldSurface(cornerRadius: 8)
                }
            }
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
            runner.attach([attachment], to: sessionID)
            composerFocused = true
        })
    }
}

// What a turn that did not end on its own leaves at the foot of the transcript. A failed
// run belongs in the flow of the conversation, not in a dialog, so it is a card with the
// ways out of it. A stop went wrong with nothing, so it gets a button under its
// transcript note rather than a card of its own.
struct TurnEndActions: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner

    let sessionID: UUID
    let state: SessionState

    var body: some View {
        if case .failed(let message) = state {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if runner.canContinueAfterFailure(sessionID, store: store) {
                        ActionButton(title: "Continue", height: 28, size: 11.5) {
                            runner.continueAfterFailure(sessionID, store: store)
                        }
                    }
                    ActionButton(title: "Dismiss", tone: .outlined, height: 28, size: 11.5) {
                        runner.dismissFailure(sessionID)
                    }
                }
            }
            .warningCard()
        }

        if runner.canContinueAfterStop(sessionID, store: store) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ActionButton(title: "Continue", tone: .outlined, height: 28, size: 11.5) {
                    runner.continueAfterStop(sessionID, store: store)
                }
            }
            .transition(.fadeIn)
        }
    }
}

// That the turn is still alive, and how long since it last said anything. A working turn
// reports something every few seconds, so the silence is the number worth watching: it is
// the only thing that separates a long build from a turn that will never come back. The
// call in flight is named in the block above, so the row does not repeat it.
private struct WorkingRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppSettings.self) private var appSettings

    let since: Date
    let sessionID: UUID
    let avatarName: String?
    let agentTitle: String
    // The tasks holding the turn open, if that is why it is still here. Naming one is the
    // whole point of the row in that state: silence is expected, and what decides whether
    // it will ever end is what is running, not how long it has been quiet.
    var tasks: [BackgroundTask] = []
    // When the wait began, which is what the row counts while it is waiting.
    var waitingSince: Date?

    private var waiting: Bool { waitingSince != nil }

    // Below this a gap is just the model thinking, and a clock ticking on every turn would
    // be noise. Past the second one it is long enough to be worth doubting.
    private static let showQuietAfter: TimeInterval = 20
    private static let concerningAfter: TimeInterval = 120

    // Held as state, not rebuilt with the view: the order is shuffled once, and a fresh
    // shuffle on every redraw would change the word mid-breath.
    @State private var words = WorkingWords()
    // When the row appeared, which is what the words are paced against. `since` moves
    // every time the agent says anything, and pacing off that would restart the cycle on
    // each event and leave the same word up all turn.
    @State private var started = Date()

    var body: some View {
        // The row has to keep counting when nothing arrives to redraw it, which is exactly
        // the case it exists for.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let quiet = context.date.timeIntervalSince(since)
            let avatar = currentAvatar
            let personality = avatar.personality
            let word = waiting ? "Waiting" : words.word(after: context.date.timeIntervalSince(started))
            HStack(spacing: 8) {
                AgentAvatarView(image: avatar.displayImage(for: sessionID), size: 20)
                    .id(avatar.id)
                    .transition(.fadeIn)
                Text("\(word)…")
                    .font(.mono(12, .medium))
                    .foregroundStyle(.primary)
                    // Each word is a replacement: the old one leaves before the new one
                    // fades in, so it cannot linger as the row moves down the transcript.
                    .id(word)
                    .transition(.fadeIn)
                if let waitingSince {
                    Text("for \(BackgroundTaskPhrase.of(tasks))")
                        .font(.mono(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // The same clock the strip runs, so the row and the header agree on
                    // how long this has been going on.
                    Text(RelativeTime.duration(since: waitingSince))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if quiet >= Self.showQuietAfter, !waiting {
                    Text("silent for \(elapsed(quiet))")
                        .font(.system(size: 11))
                        .foregroundStyle(quiet >= Self.concerningAfter
                                         ? Theme.warningText : .secondary)
                }
                Spacer(minLength: 0)
            }
            // The row keeps sliding down as the turn writes more above it. Without this the
            // avatar fading in on a new turn animates against the transcript rather than
            // against the row, and lands somewhere the row no longer is.
            .geometryGroup()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: word)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: avatar.id)
            // Only worth a hint once the silence is long enough to worry about; the
            // empty one shows nothing.
            .appTooltip {
                if waiting {
                    guard !tasks.isEmpty else { return Tooltip(title: "") }
                    return Tooltip(title: "\(agentTitle) has answered and is holding the turn open.",
                                   note: tasks.map(\.label).joined(separator: "\n"))
                }
                guard quiet >= Self.concerningAfter else { return Tooltip(title: "") }
                return Tooltip(title: "\(agentTitle) has sent nothing for a while.",
                               note: "The log in Settings says what it last did.")
            }
            .onAppear { words = WorkingWords(personality: personality) }
            .onChange(of: personality) { _, personality in
                words = WorkingWords(personality: personality)
                started = .now
            }
        }
    }

    private var currentAvatar: AgentAvatar {
        AgentAvatarSelection.avatar(named: avatarName, from: appSettings.agentAvatars)
    }

    private func elapsed(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        guard whole >= 60 else { return "\(whole)s" }
        return "\(whole / 60)m \(whole % 60)s"
    }
}

// The way out of a wait that has no end of its own. A held-open turn is correct behaviour
// and usually short, but nothing bounds it: a dev server or a watcher keeps the turn alive
// for as long as it runs, and from the outside that is indistinguishable from a hang. Past
// a few minutes the wait names itself and offers the only two answers there are.
private struct WaitingNotice: View {
    let since: Date
    let tasks: [BackgroundTask]
    let agentTitle: String
    let onKeepWaiting: () -> Void
    let onEnd: () -> Void

    // Short waits are ordinary - a build, a test run - and a card under every one of them
    // would be noise. This is about the ones that are not going to end on their own.
    private static let showAfter: TimeInterval = 3 * 60

    var body: some View {
        // Five seconds is fine for something that appears once after minutes, and it keeps
        // the transcript from redrawing every second for a card that is not counting.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if context.date.timeIntervalSince(since) >= Self.showAfter {
                card
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "clock")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Still waiting for \(BackgroundTaskPhrase.of(tasks))")
                        .fontWeight(.semibold)
                    Text("\(agentTitle) answered \(RelativeTime.duration(since: since)) ago and the turn "
                        + "is being held open so the task can wake it again. Type to carry on in the same "
                        + "turn. Ending it stops the tasks it started.")
                        .fixedSize(horizontal: false, vertical: true)
                    if tasks.count > 1 {
                        ForEach(tasks) { task in
                            Text("· \(task.label)")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ActionButton(title: "Keep waiting", tone: .outlined,
                             height: 28, size: 11.5, action: onKeepWaiting)
                ActionButton(title: "End turn", height: 28, size: 11.5, action: onEnd)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(12)
        .cardSurface(cornerRadius: 10)
    }
}
