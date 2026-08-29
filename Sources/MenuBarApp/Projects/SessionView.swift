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
        onPositionChange?(distance <= 1)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sessionID: UUID

    private enum Tab: Hashable { case conversation, design, changes, explorer }

    @State private var tab: Tab = .conversation
    @State private var terminalFocused = false
    @State private var composerFocused = false
    @State private var selectedProjectID: UUID?
    @State private var explorerShowsDesignFiles = false
    @State private var openShortcutRun: ShortcutRun?
    @State private var shortcutEditor: ShortcutEditorRequest?
    @State private var exportingDesignMaterials = false
    @State private var transcriptWindow = TranscriptWindow()
    @State private var transcriptPinnedToBottom = true
    @State private var recapOpen = false
    @State private var recapNeedsAttention = false
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

    init(sessionID: UUID, opening: SessionDestination = .conversation) {
        self.sessionID = sessionID
        _tab = State(initialValue: opening == .changes ? .changes : .conversation)
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
                header(session: session, project: project)
                // Cards anchored to the strip hang over whatever is under it. A VStack
                // draws its children in order, so without this the transcript would cover
                // them.
                statusStrip(session, project: project, recap: recap)
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
                    // A Build session keeps its Design behind the Design tab.
                    if !session.isImplementingDesign,
                       let design = store.designConversation(for: session.id) {
                        DesignView(sessionID: design.id)
                    } else {
                        transcript(session)
                        Divider().overlay(Theme.hairline)
                        composer(session: session, project: project)
                    }
                case .design:
                    if let design = store.designSession(for: session.id) {
                        DesignView(sessionID: design.id) { tab = .conversation }
                    } else {
                        DesignReferenceView(sessionID: session.id)
                    }
                case .changes:
                    ChangesView(root: projectDirectory)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .explorer:
                    ExplorerView(root: explorerDirectory)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let openShortcutRun {
                    ShortcutOutputDrawer(run: openShortcutRun) { self.openShortcutRun = nil }
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
            }
            .sheet(item: $shortcutEditor) { request in
                ShortcutEditorView(request: request) { shortcut in
                    if request.shortcut == nil {
                        shortcuts.add(name: shortcut.name, command: shortcut.command,
                                      projectID: shortcut.projectID,
                                      availableInAllProjects: shortcut.availableInAllProjects)
                    } else {
                        shortcuts.update(shortcut)
                    }
                }
                .appOverlays()
            }
            .background(terminalShortcut(directory: workingDirectory))
            .background(recapShortcut)
            .background(stopShortcut)
            .onChange(of: terminalFocused) { _, focused in
                if focused { composerFocused = false }
            }
            .task(id: sessionID) {
                selectedProjectID = session.projectID
                explorerShowsDesignFiles = designFilesURL != nil
                openShortcutRun = nil
                sampleMissingFolders()
                refreshStats(workingDirectories, reusingRecent: true)
                runner.refreshContext(sessionID, store: store)
                // Scanning a conversation means having it, and it is still being read in.
                await store.transcriptReady(sessionID)
                store.clearFinished(sessionID)
                store.findPullRequest(in: sessionID)
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

    // MARK: - Header

    // Where you are and what you are looking at, and nothing else: container icon and name,
    // title, then the view switcher right-aligned. Everything that describes the state of
    // the session - what it is doing, what it has changed, and the facts behind the chip -
    // reads on the strip under this one.
    private func header(session: ChatSession, project: Project) -> some View {
        let workspace = session.workspaceID.flatMap(store.workspace)
        let container = workspace?.name ?? project.name
        return HStack(spacing: 14) {
            HStack(spacing: 7) {
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
                // The place the session lives is never cut short: when the row runs out
                // of room, the session title is what gives way.
                Text(container)
                    .font(.mono(11))
                    .kerning(0.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Text("/")
                    .font(.mono(11))
                    .foregroundStyle(.tertiary)
                if session.isTroubleshooting {
                    MonoChip(text: "TROUBLESHOOT", size: 9, tint: Theme.secret)
                }
                Text(session.title)
                    .font(.serif(17, .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .changingName(session.title)
            }

            Spacer(minLength: 12)

            // A row splits its width between the children rather than handing each one what
            // it asks for, so the controls can be offered less than their labels need and the
            // words wrap. Holding them at their natural width makes the title give way first.
            HStack(spacing: 8) {
                if appSettings.mobileAccessEnabled {
                    MobileAccessButton(scope: .session(sessionID))
                }
                HeaderTabToggle(selection: $tab, options: headerTabs(for: session))
                TerminalToggle(isOpen: terminals.isOpen(terminalScope),
                               directory: session.worktreePath ?? project.path) {
                    toggleTerminal(directory: session.worktreePath ?? project.path)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    private func headerTabs(for session: ChatSession) -> [(label: String, value: Tab)] {
        var tabs: [(label: String, value: Tab)] = session.isImplementingDesign
            ? [("Build", .conversation)]
            : [(store.designConversation(for: session.id) == nil ? "Chat" : "Design",
                .conversation)]
        if session.isImplementingDesign {
            tabs.append(("Design", .design))
        }
        tabs.append((store.isDesignMode(session) ? "Project Changes" : "Changes", .changes))
        tabs.append(("Explorer", .explorer))
        return tabs
    }

    private func isDesignTabSelected(for session: ChatSession) -> Bool {
        switch tab {
        case .design:
            true
        case .conversation:
            !session.isImplementingDesign && store.designConversation(for: session.id) != nil
        case .changes, .explorer:
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
        return ActionButton(title: "Export", tone: .outlined, height: 24, size: 10.5,
                            icon: exportingDesignMaterials ? "hourglass" : "doc.zipper") {
            exportDesignMaterials(session: session, project: project)
        }
        .disabled(exportingDesignMaterials)
        .appTooltip(label)
        .accessibilityLabel(label)
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

    // MARK: - Status strip

    // Everything that describes the session rather than names it, on one thin line: what
    // it is doing, actions about that state, what it has changed, where that work went,
    // and one chip for the facts it is looked up by. Reading it is a glance along a line
    // rather than a hunt across a header and a footer.
    //
    // How full the window is runs along the bottom edge as a hairline. It is the reading
    // that moves every turn, so it stays in sight, but it is a line rather than words: a
    // window filling up needs nothing done about it until it is nearly full, and then the
    // composer says so in words.
    private func statusStrip(_ session: ChatSession, project: Project,
                             recap: SessionRecap?) -> some View {
        // The lead checkout is the one this line speaks for, the same root the stats
        // refresh puts first. The cache only ever holds snapshots of a readable
        // repository, so having one is the same as the repository being ready.
        let repository = store.workingDirectories(for: session).first
            .flatMap { gitStats.snapshot(at: $0) }
        let facts = facts(session, repository: repository)
        let tone = SessionTone(sessionID, store: store, runner: runner)
        let recapTarget = visibleConversationID
        return HStack(spacing: 14) {
            state(session, tone: tone)
            diffStats(session)
            Spacer(minLength: 12)
            if isDesignTabSelected(for: session), store.hasDesignArtifacts(for: session) {
                designMaterialExportButton(session: session, project: project)
            }
            if store.session(recapTarget)?.hasAgentConversation == true {
                let recapping = runner.isRecapping(recapTarget)
                SessionRecapControl(
                    recap: recap,
                    regenerating: recapping,
                    canRegenerate: runner.canRecap(recapTarget, store: store),
                    isOpen: recapOpen,
                    needsAttention: recapNeedsAttention,
                    toggle: toggleRecap,
                    regenerate: generateRecap,
                    close: closeRecap)
            }
            if let pullRequest = session.pullRequest {
                pullRequestLink(pullRequest)
            }
            SessionFactsChip(facts: facts,
                             openChanges: openChanges,
                             contextActions: contextActions,
                             usageTooltip: {
                                 guard let usage = session.usage else { return Tooltip(title: "") }
                                 return usageTooltip(usage, agent: session.agent,
                                                     clearable: !contextActions().isEmpty)
                             })
        }
        .statusBand(padding: 20)
        .overlay(alignment: .bottom) {
            if let fraction = facts.context {
                ContextHairline(fraction: fraction, animated: tone == .running)
            }
        }
    }

    // A worktree session knows its branch from creation, so the branch can draw on the
    // first frame instead of waiting for git and shifting the chip.
    private func facts(_ session: ChatSession, repository: GitSnapshot?) -> SessionFacts {
        let cost = session.usage?.costUSD ?? 0
        return SessionFacts(
            branch: repository?.branch
                ?? session.worktreeBranch
                ?? session.sessionProjects?.compactMap(\.worktreeBranch).first,
            pullRequest: session.pullRequest,
            model: session.usage?.model(for: session.agent).map { ModelChoice.shortName(of: $0) },
            cost: appSettings.showsCost(for: session.agent) && cost > 0 ? cost : nil,
            context: session.usage?.contextFraction(for: session.agent),
            agent: session.agent)
    }

    // The destination of the work stays visible after the command finishes instead of
    // being hidden in Details. It is the only item on this line that leaves the app.
    private func pullRequestLink(_ pullRequest: PullRequest) -> some View {
        Button {
            guard let url = URL(string: pullRequest.url) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 5) {
                // Verbatim keeps large PR numbers free of locale grouping separators.
                Text(verbatim: "PR #\(pullRequest.number)")
                    .font(.mono(10.5, .semibold))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appTooltip {
            Tooltip(title: "Pull request #\(pullRequest.number)",
                    subtitle: pullRequest.url,
                    note: "Opens in the browser.")
        }
        .accessibilityLabel("Open pull request #\(pullRequest.number)")
    }

    // "RUNNING · 4m", "WAITING · 12m", "IDLE · 2h": the state and how long it has been
    // in it. A running turn counts up from its own start rather than from the session's
    // last activity, which is what makes it the age of the work in flight. A waiting one
    // counts from where the work stopped, so the number is the length of the wait rather
    // than of the turn that is still holding it.
    private func state(_ session: ChatSession, tone: SessionTone) -> some View {
        let since: Date? = switch tone {
        case .running: runner.turnStarted(sessionID)
        case .waiting: runner.waitingSince(sessionID) ?? session.lastActivity
        default: session.lastActivity
        }
        return HStack(spacing: 7) {
            StateLight(tone: tone, size: 6)
            StatusCaps(text: tone.word, tint: tone.colour)
            if let since {
                StatusDot()
                // A live turn has to keep counting when nothing arrives to redraw it,
                // which is most of a long one and all of a wait.
                if tone == .running || tone == .waiting {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        StatusValue(text: RelativeTime.duration(since: since))
                    }
                } else {
                    StatusValue(text: RelativeTime.short(since))
                }
            }
        }
        .fixedSize()
    }

    private func showsDirectoryBar(for session: ChatSession, designFilesURL: URL?) -> Bool {
        switch tab {
        case .conversation, .design: false
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

    // What the working tree looks like right now: the answer to "what has this session
    // actually done". Clicking it opens the full diff.
    //
    // Until git has answered for this tree, the line wears the transcript's own running
    // total - the same numbers the session's sidebar row shows - so the strip arrives
    // whole instead of growing an item a few seconds in. That total has no file count and
    // can disagree with the tree (it keeps counting across commits and repeat edits),
    // so it is only a stand-in until the first snapshot lands and corrects it.
    @ViewBuilder private func diffStats(_ session: ChatSession) -> some View {
        let snapshots = store.workingDirectories(for: session).compactMap { gitStats.snapshot(at: $0) }
        if snapshots.isEmpty {
            if session.summary.added > 0 || session.summary.removed > 0 {
                statsButton {
                    DiffPair(added: session.summary.added, removed: session.summary.removed,
                             size: 11)
                }
            }
        } else {
            let files = snapshots.reduce(0) { $0 + $1.files.count }
            if files > 0 {
                statsButton {
                    DiffPair(added: snapshots.reduce(0) { $0 + $1.totalAdded },
                             removed: snapshots.reduce(0) { $0 + $1.totalRemoved },
                             size: 11)
                    StatusDot()
                    StatusValue(text: counted(files, "file"))
                }
            }
        }
    }

    private func statsButton(@ViewBuilder content: () -> some View) -> some View {
        Button { tab = .changes } label: {
            HStack(spacing: 6, content: content)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appTooltip("Open Changes")
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
           !terminalFocused, !recapOpen {
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
        guard let session = store.session(sessionID) else { return sessionID }
        switch tab {
        case .conversation where !session.isImplementingDesign:
            return store.designConversation(for: sessionID)?.id ?? sessionID
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
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    // Capped so prose keeps a readable line length, and centered so a
                    // wide window pads both sides instead of piling space on the right.
                    // Wider than a chat app's usual measure: diffs and tool output make
                    // better use of the room than paragraphs do.
                    .frame(maxWidth: 960, alignment: .leading)
                    .frame(maxWidth: .infinity)
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
                            guard !opened || transcriptPinnedToBottom else { return }
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
                transcriptWindow.reset()
                transcriptPinnedToBottom = true
                // The conversation is read off the main actor, so the pane is on screen
                // before the messages are. Waiting here is what keeps that off screen:
                // it fades in once, already full and already at its end, rather than
                // arriving empty and filling in.
                await store.transcriptReady(sessionID)
                await Task.yield()
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { opened = true }
            }
            // Anything new sends a pinned transcript to its end. A whole arrival - a row,
            // a finished line, a change of state - is worth a glide. A long line still
            // being typed into is followed in coarse chunks, each without one, so streaming
            // tokens do not each perform another scroll operation.
            .onChange(of: shape) { old, new in
                if new.state != old.state, new.state != .waiting { waitNoticeDismissed = false }
                scrollToBottom(proxy, animated: old.settled != new.settled)
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
                let isLastMessage = message.id == session.messages.last?.id
                let isTurnActive = state.isBusy
                    && !runner.isRecapping(sessionID)
                    && message.role == .assistant
                    && isLastMessage
                MessageView(message: message,
                            projectPath: projectPath,
                            isTurnActive: isTurnActive,
                            textScale: appSettings.textSize.scale,
                            openChanges: { openChanges() },
                            promptMenu: promptMenu(for: message))
                    // Every message is on screen now, and a streaming turn rewrites
                    // the last one many times a second. Without this, each of those
                    // redraws every message in the transcript, parsing its markdown
                    // again on the way.
                    .equatable()
                    .environment(\.runningAgents, runner.runningAgents(sessionID))
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

            Color.clear.frame(height: 1).id(bottomAnchor)
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
        tab = .changes
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
            PermissionCard(request: request) { answer in
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
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
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
                        blocked: blocked,
                        isFocused: $composerFocused,
                        placeholder: placeholder(state: state),
                        onOversizedPaste: offerTextFile,
                        onRecallUp: {
                            guard let last = runner.queued(sessionID).last else { return false }
                            runner.recall(last.id, sessionID: sessionID)
                            return true
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

            Spacer(minLength: 12)

            // Ad-hoc tasks run in a private folder the app made for one prompt, so there
            // is nothing there worth saving a command against.
            if project.kind == .project {
                SessionShortcutChips(session: session,
                                     openRun: $openShortcutRun,
                                     edit: { shortcutEditor = $0 })
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
                label: agent == .codex ? "Window" : "Context",
                value: "\(formattedTokens(usage.contextTokens)) of \(formattedTokens(usage.contextWindow))"))
        }
        // Codex reports no cost, so a zero here means "unknown" rather than free.
        if appSettings.showsCost(for: agent), usage.costUSD > 0 {
            rows.append(Tooltip.Row(label: "Spent", value: Money.short(usage.costUSD)))
        }
        let turns = counted(usage.turns, "turn")
        let note = if agent == .codex {
            clearable
                ? "Current model window after the latest model call. Codex compacts it automatically as it fills. Click for options."
                : "Current model window after the latest model call. Codex compacts it automatically as it fills."
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
    // than waiting to be looked for. Codex handles this condition through automatic
    // compaction, so only Claude Code needs the interruption.
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
