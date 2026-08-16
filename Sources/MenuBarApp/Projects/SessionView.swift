import AppKit
import SwiftUI

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

    private enum Tab: Hashable { case chat, changes, explorer }

    @State private var tab: Tab = .chat
    @State private var dropTargeted = false
    @State private var terminalFocused = false
    @State private var composerFocused = false
    @State private var selectedProjectID: UUID?
    @State private var openShortcutRun: ShortcutRun?
    @State private var shortcutEditor: ShortcutEditorRequest?
    @State private var transcriptWindow = TranscriptWindow()
    @State private var transcriptPinnedToBottom = true
    // False until this session's transcript has been scrolled to its end. The pane is
    // rebuilt per session, so it starts false on every switch without being reset.
    @State private var opened = false
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

    var body: some View {
        // The sidebar can delete a session or its project while it is on screen.
        if let session = store.session(sessionID), let project = store.project(session.projectID) {
            let workingDirectories = store.workingDirectories(for: session)
            let workingDirectory = workingDirectories.first ?? project.path
            let visibleDirectory = directory(for: selectedProjectID ?? session.projectID,
                                             in: session) ?? workingDirectory
            VStack(spacing: 0) {
                header(session: session, project: project)
                statusStrip(session, project: project)
                warningStrip(session: session, project: project)
                if store.checkoutProjects(for: session).count > 1, tab != .chat {
                    workspaceProjectBar(session)
                }

                switch tab {
                case .chat:
                    transcript(session)
                    Divider().overlay(Theme.hairline)
                    composer(session: session, project: project)
                case .changes:
                    ChangesView(root: visibleDirectory)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .explorer:
                    ExplorerView(root: visibleDirectory)
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
            .onAppear { composerFocused = true }
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
            .background(stopShortcut)
            .onChange(of: terminalFocused) { _, focused in
                if focused { composerFocused = false }
            }
            .task(id: sessionID) {
                selectedProjectID = session.projectID
                openShortcutRun = nil
                sampleMissingFolders()
                refreshStats(workingDirectories, reusingRecent: true)
                runner.refreshContext(sessionID, store: store)
                store.findPullRequest(in: sessionID)
            }
            // These folders only go missing while another program has the keyboard, so
            // coming back to this one is when the answer can have changed.
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                sampleMissingFolders()
            }
            .onChange(of: completedToolCount) {
                refreshStats(workingDirectories, after: .milliseconds(350))
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
            VStack(spacing: 14) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("This session is gone").font(.serif(22))
            }
        }
    }

    // MARK: - Header

    // Where you are and what you are looking at, and nothing else: colour dot, container,
    // title, then the view switcher right-aligned. Everything that describes the state of
    // the session - what it is doing, what it has changed, its branch, its pull request,
    // its window - reads on the strip under this one.
    private func header(session: ChatSession, project: Project) -> some View {
        let workspace = session.workspaceID.flatMap(store.workspace)
        let container = workspace?.name ?? project.name
        return HStack(spacing: 14) {
            HStack(spacing: 7) {
                ProjectDot(tint: workspace == nil ? Theme.projectTint(for: container)
                                                  : Theme.workspaceTint)
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
                HeaderTabToggle(selection: $tab,
                                options: [("Chat", .chat),
                                          ("Changes", .changes),
                                          ("Explorer", .explorer)])
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

    // MARK: - Status strip

    // Everything that describes the session rather than names it, on one thin line and
    // always in the same order: what it is doing, what it has changed, the commands it
    // has to hand, then the branch, the pull request and how full the window is. Reading
    // it is a glance along a line instead of a hunt across a header and a footer.
    //
    // The shortcuts belong on this line rather than on one of their own. They are the
    // same kind of thing as the rest of it - what this session is and what it can do -
    // and a band of their own would cost every session a second rule to read past.
    private func statusStrip(_ session: ChatSession, project: Project) -> some View {
        // The lead checkout is the one this line speaks for, the same root the stats
        // refresh puts first. The cache only ever holds snapshots of a readable
        // repository, so having one is the same as the repository being ready.
        let repository = store.workingDirectories(for: session).first
            .flatMap { gitStats.snapshot(at: $0) }
        // A worktree session knows its branch from creation, so the branch can draw on
        // the first frame instead of waiting for git and shifting the row.
        let branch = repository?.branch
            ?? session.worktreeBranch
            ?? session.sessionProjects?.compactMap(\.worktreeBranch).first
        return HStack(spacing: 14) {
            state(session)
            diffStats(session)

            // Ad-hoc tasks run in a private folder the app made for one prompt, so there
            // is nothing there worth saving a command against.
            if project.kind == .project {
                StatusRule()
                // The chips take the middle of the row rather than a spacer, so a long
                // list of them scrolls in place instead of pushing the readings apart.
                SessionShortcutChips(session: session,
                                     openRun: $openShortcutRun,
                                     edit: { shortcutEditor = $0 })
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 12)
            }

            // The trailing group is laid out before anything flexible gets a say. An
            // HStack splits what is left evenly between its children, so without this
            // the meter is offered a share of the free room, decides it does not fit,
            // and drops its bar while the chips sit on space the bar would have used.
            HStack(spacing: 12) {
                if let branch, !branch.isEmpty {
                    branchTag(branch: branch, repository: repository)
                }
                if let pullRequest = session.pullRequest { pullRequestTag(pullRequest) }
                if appSettings.showsCost(for: session.agent),
                   let cost = session.usage?.costUSD, cost > 0 {
                    spentTag(cost)
                }
                if let usage = session.usage,
                   let fraction = usage.contextFraction(for: session.agent) {
                    contextMeter(fraction: fraction, usage: usage, agent: session.agent)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .statusBand(padding: 20)
    }

    // "RUNNING", "NEEDS YOU · 3m", "IDLE · 2h": the state and how long it has been in it.
    private func state(_ session: ChatSession) -> some View {
        let tone = SessionTone(sessionID, store: store, runner: runner)
        return HStack(spacing: 7) {
            StateLight(tone: tone, size: 6)
            StatusCaps(text: tone.word,
                       tint: tone == .idle ? Color.secondary : tone.colour)
            if tone != .running {
                StatusDot()
                StatusValue(text: RelativeTime.short(session.lastActivity))
            }
        }
        .fixedSize()
    }

    private func workspaceProjectBar(_ session: ChatSession) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(store.checkoutProjects(for: session)) { checkout in
                    if let project = store.project(checkout.projectID) {
                        let root = checkout.worktreePath ?? project.path
                        let snapshot = gitStats.snapshot(at: root)
                        let selected = selectedProjectID == project.id
                        Button { selectedProjectID = project.id } label: {
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(project.id == session.projectID
                                          ? Theme.accent : Theme.secret)
                                    .frame(width: 9, height: 9)
                                Text(project.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                                if let snapshot, !snapshot.files.isEmpty {
                                    Text("+\(snapshot.totalAdded)")
                                        .foregroundStyle(Theme.addition)
                                    Text("-\(snapshot.totalRemoved)")
                                        .foregroundStyle(Theme.deletion)
                                }
                            }
                            .font(.mono(10.5, .semibold))
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
                    StatusValue(text: "\(files) file\(files == 1 ? "" : "s")")
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
        let state = runner.state(sessionID)
        if state.isBusy, state != .stopping, dialogs.current == nil, !menus.isOpen,
           !terminalFocused {
            Button("") { runner.stop(sessionID, store: store) }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
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
            strip("Folder not found at \(project.collapsedPath). Move it back or remove the project.")
        } else if let missing = missingDirectories.first {
            // Which of the two this is comes from the session rather than from the path:
            // a workspace folder and a worktree both turn up in `workingDirectories`, and
            // only the session says whether it has members.
            let name = session.sessionProjects == nil ? "Worktree" : "Workspace folder"
            // The folder named is one the button can actually put back, so the sentence and
            // the action cannot point at different folders - a workspace can be missing one
            // of each.
            if let rebuildable = rebuildableCheckouts.first {
                strip("\(name) not found at \(rebuildable.path.abbreviatedPath). It was removed outside the app.",
                      action: "Rebuild") { confirmRebuild() }
            } else {
                strip("\(name) not found at \(missing.abbreviatedPath). Move it back, or delete this session.")
            }
        } else if !runner.isAvailable(session.agent) {
            strip("\(session.agent.title) CLI not found on PATH. Sessions cannot run until it is installed.")
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
                dialogs.show(Dialog(
                    title: "Nothing here can be rebuilt",
                    message: "Git could not be asked which branch these folders were on.",
                    actions: [.init(label: "OK", kind: .cancel)]))
                return
            }
            dialogs.show(Dialog(
                title: plan.count == 1 ? "Rebuild the missing folder?"
                                       : "Rebuild the missing folders?",
                message: SessionLifecycle.rebuildMessage(for: plan),
                actions: [
                    .init(label: "Rebuild", kind: .primary) { rebuild(plan) },
                    .init(label: "Cancel", kind: .cancel)
                ]))
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
                dialogs.show(Dialog(title: failure.title, message: failure.message,
                                    actions: [.init(label: "OK", kind: .cancel)]))
            }
        }
    }

    private func directory(for projectID: UUID, in session: ChatSession) -> String? {
        guard let checkout = store.checkoutProjects(for: session)
            .first(where: { $0.projectID == projectID }) else { return nil }
        return checkout.worktreePath ?? store.project(projectID)?.path
    }

    // The button sits after the spacer, at the end of the sentence that asks for it, so the
    // strip reads as a statement and then the way out of it. A banner with nothing to offer
    // leaves it off and draws as it always did.
    private func strip(_ message: String, action: String? = nil,
                       run: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let action, let run {
                ActionButton(title: action, tone: .outlined, height: 26, size: 11.5, action: run)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ChatColor.warningText)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(ChatColor.warningBackground)
    }

    // MARK: - Transcript

    private func transcript(_ session: ChatSession) -> some View {
        let state = runner.state(sessionID)
        let projectPath = store.workingDirectory(for: session) ?? ""
        let textShape = streamingTextShape(session)

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
                    // The soft landing for anything new: a fresh row fades in and the
                    // rows above it glide up rather than jumping. Keyed on the shape of
                    // the transcript, not its text, so it plays once per whole arrival
                    // and never while a line is still being typed into.
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2),
                               value: transcriptShape(session, state: state, textShape: textShape))
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
            // Rows measure again after the first layout - an attachment, an image, text
            // that wraps differently once it has its real width - and the end of the
            // transcript moves with them. One nudge once that settles lands on it.
            .task(id: sessionID) {
                transcriptWindow.reset()
                transcriptPinnedToBottom = true
                await Task.yield()
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { opened = true }
            }
            .onChange(of: session.messages.count) { scrollToBottom(proxy, animated: true) }
            // A finished line is worth a glide. A long line is followed in coarse chunks
            // so streaming tokens do not each perform another scroll operation.
            .onChange(of: textShape) { old, new in
                scrollToBottom(proxy, animated: old.lines != new.lines)
            }
            .onChange(of: session.messages.last?.tools.count ?? 0) { scrollToBottom(proxy, animated: true) }
            .onChange(of: session.messages.last?.thinking?.count ?? 0) { scrollToBottom(proxy, animated: true) }
            .onChange(of: state) { scrollToBottom(proxy, animated: true) }
            .onChange(of: runner.question(sessionID)?.id) { scrollToBottom(proxy, animated: true) }
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
            if session.messages.isEmpty {
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
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Load earlier messages, \(hiddenCount) hidden")
            }

            ForEach(messages) { message in
                let isLastMessage = message.id == session.messages.last?.id
                let isTurnActive: Bool = state.isBusy
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
                    .transition(.fadeIn)
            }

            handoff(state: state)

            pendingQuestion
                .transition(.fadeIn)

            if showsThinking(state: state) {
                WorkingRow(since: runner.lastActivity(sessionID) ?? Date(),
                           avatarSequence: runner.avatarSequence(sessionID) ?? 0,
                           avatarName: session.agentAvatarName,
                           waitingOnTasks: state == .waiting)
                    .transition(.fadeIn)
            }

            // A failed run belongs in the flow of the conversation, not in a dialog.
            if case .failed(let message) = state {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ChatColor.warningText)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(ChatColor.warningBackground))
                .transition(.fadeIn)
            }

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
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
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
        // A parked turn is waiting on the person, not working.
        state.isBusy && runner.question(sessionID) == nil
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

    // What the transcript is made of, coarsely: how many rows there are and how many
    // lines the streaming message has settled. Tokens landing inside a line change the
    // text but not this, which is what keeps the animation to one beat per addition.
    private struct TranscriptShape: Equatable {
        let messages: Int
        let tools: Int
        let thoughts: Int
        let lines: Int
        let state: SessionState
        let question: String?
    }

    private struct StreamingTextShape: Equatable {
        let lines: Int
        let chunks: Int
    }

    private func transcriptShape(_ session: ChatSession, state: SessionState,
                                 textShape: StreamingTextShape) -> TranscriptShape {
        TranscriptShape(messages: session.messages.count,
                        tools: session.messages.last?.tools.count ?? 0,
                        thoughts: session.messages.last?.thinking?.count ?? 0,
                        lines: textShape.lines,
                        state: state,
                        question: runner.question(sessionID)?.id)
    }

    private func streamingTextShape(_ session: ChatSession) -> StreamingTextShape {
        let text = session.messages.last?.text ?? ""
        return StreamingTextShape(lines: newlineCount(text), chunks: text.utf8.count / 120)
    }

    private func newlineCount(_ text: String) -> Int {
        var count = 0
        for byte in text.utf8 where byte == UInt8(ascii: "\n") { count += 1 }
        return count
    }

    // MARK: - Composer

    // The half-written prompt is the runner's, not this view's: switching sessions builds
    // the pane again from nothing, and anything held here would go with it.
    private var attachments: [Attachment] { runner.draft(sessionID).attachments }

    private var draft: Binding<String> {
        Binding(get: { runner.draft(sessionID).text },
                set: { text in runner.editDraft(sessionID) { $0.text = text } })
    }

    private func composer(session: ChatSession, project: Project) -> some View {
        let workingDirectory = session.worktreePath ?? project.path
        let blocked = !FileManager.default.fileExists(atPath: workingDirectory)
            || !runner.isAvailable(session.agent)
        let state = runner.state(sessionID)
        let busy = state.isBusy
        let canSend = !blocked && !runner.draft(sessionID).isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            runChoices(session)
            contextNudge(session)
            queueStrip(busy: busy, blocked: blocked)
            attachmentStrip

            HStack(alignment: .bottom, spacing: 10) {
                // Typing during a turn is allowed: what is written goes to the back of the
                // queue instead of waiting for the agent to be free.
                ComposerField(text: draft,
                              isFocused: $composerFocused,
                              placeholder: busy ? "Queue what comes next…" : "Ask for a change",
                              isEnabled: !blocked,
                              onSubmit: send,
                              onOversizedPaste: offerTextFile,
                              onRecallUp: {
                                  guard let last = runner.queued(sessionID).last else { return false }
                                  runner.recall(last.id, sessionID: sessionID)
                                  return true
                              },
                              trailingAccessory: {
                                  SessionBotPicker(avatars: appSettings.agentAvatars,
                                                   selectedName: botSelection(for: session),
                                                   size: 22)
                              })

                if canSend {
                    Button(action: send) {
                        Image(systemName: busy ? "arrow.up.to.line" : "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(busy ? Theme.accentFill : Color.black.opacity(0.88)))
                    }
                    .buttonStyle(.plain)
                    .appTooltip(busy ? "Queue this for when the turn ends"
                                     : "Send (shift-return for a new line)")
                    .transition(.opacity)
                }

                if state == .stopping {
                    Image(systemName: "hourglass")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.field))
                        .appTooltip("Stopping this turn")
                } else if busy {
                    Button {
                        runner.stop(sessionID, store: store)
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Theme.deletion))
                    }
                    .buttonStyle(.plain)
                    .appTooltip("Stop this turn (esc)")
                } else if !canSend {
                    // The button keeps its place so the field does not change width as
                    // soon as there is something to send.
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.black.opacity(0.22)))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: canSend)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Theme.accent, lineWidth: dropTargeted ? 2 : 0)
            .padding(6))
        .pasteAttachments(enabled: composerFocused && !blocked) { attach($0) }
        .dropDestination(for: URL.self) { urls, _ in
            guard !blocked else { return false }
            attach(Attachments.fromDrop(urls))
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    // The choices the next turn will run on, on the line the eye is already on when
    // hitting send: the session's fixed agent, its model, and the rest of the run
    // controls. What the session has done and where belongs on the status strip, not
    // here - this line is only ever about what happens next.
    @ViewBuilder private func runChoices(_ session: ChatSession) -> some View {
        let agent = session.agent
        HStack(spacing: 10) {
            if session.settings?.mcpServersEnabled == false {
                Text("MCP off")
                    .font(.mono(10.5, .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
            }
            pinnedSetting(agent.title, help: "This session always runs on \(agent.title).")
            modelControl(session, lastRan: session.usage?.model(for: agent))
            effortMenu(agent: agent)
            if agent == .claudeCode {
                permissionsMenu(agent: agent)
            } else {
                codexAccessMenu(agent: agent)
            }
            Spacer(minLength: 8)
        }
    }

    private func botSelection(for session: ChatSession) -> Binding<String> {
        Binding(
            get: {
                if let name = store.session(sessionID)?.agentAvatarName,
                   name == AgentAvatarSelection.nonBotName
                    || appSettings.agentAvatars.contains(where: {
                        $0.url.lastPathComponent == name
                    }) {
                    return name
                }
                return AgentAvatarSelection.avatar(
                    named: session.agentAvatarName,
                    forTurn: runner.avatarSequence(sessionID) ?? 0,
                    from: appSettings.agentAvatars)?.url.lastPathComponent
                    ?? AgentAvatarSelection.nonBotName
            },
            set: { store.setAgentAvatarName($0, for: sessionID) })
    }

    // MARK: - Run choices

    // The session's model and its overrides for controls that may still follow app
    // defaults. These are the choices the CLIs hide behind their interactive commands,
    // which cannot be typed at an agent driven over a pipe.
    private var sessionSettings: SessionSettings {
        store.session(sessionID)?.settings ?? SessionSettings()
    }

    private func changeSettings(_ edit: (inout SessionSettings) -> Void) {
        var updated = sessionSettings
        edit(&updated)
        store.setSettings(updated, for: sessionID)
    }

    @ViewBuilder private func modelControl(_ session: ChatSession, lastRan: String?) -> some View {
        let settings = sessionSettings
        let agent = session.agent
        let model = ModelChoice.valid(settings.model, for: agent)
        let label = model.map { ModelChoice.title(of: $0) }
            ?? lastRan.map { ModelChoice.shortName(of: $0) }
            ?? "Default model"
        settingMenu(label,
                    overridden: model != nil,
                    help: "The model this session will use for its next turn.",
                    defaultTitle: "Use \(agent.title) default",
                    options: ModelChoice.options(for: agent).compactMap { choice in
                        choice.id.map { (id: $0, title: choice.title) }
                    },
                    selection: Binding(get: { model },
                                       set: { id in changeSettings { $0.model = id } }))
    }

    private func effortMenu(agent: AgentKind) -> some View {
        let settings = sessionSettings
        let override = EffortChoice.valid(settings.effort, for: agent)
        let appDefault = EffortChoice.valid(runner.defaults(for: agent).effort, for: agent)
        let chosen = override ?? appDefault
        return settingMenu(chosen.map { "\(EffortChoice.summary(of: $0, agent: agent)) effort" } ?? "Default effort",
                           overridden: override != nil,
                           help: "How long the model thinks before it answers.",
                           defaultTitle: defaultTitle(appDefault.map { EffortChoice.summary(of: $0, agent: agent) }),
                           options: EffortChoice.all(for: agent).compactMap { choice in
                               choice.id.map { (id: $0, title: choice.title) }
                           },
                           selection: Binding(get: { override },
                                              set: { id in changeSettings { $0.effort = id } }))
    }

    private func permissionsMenu(agent: AgentKind) -> some View {
        let settings = sessionSettings
        let defaults = runner.defaults(for: agent)
        return settingMenu(PermissionMode.shortTitle(of: settings.permissionMode ?? defaults.permissionMode),
                           overridden: settings.permissionMode != nil,
                           help: "How much the agent asks before it acts.",
                           defaultTitle: defaultTitle(PermissionMode.shortTitle(of: defaults.permissionMode)),
                           options: PermissionMode.all.map { (id: $0.mode, title: $0.title) },
                           selection: Binding(get: { settings.permissionMode },
                                              set: { mode in changeSettings { $0.permissionMode = mode } }))
    }

    private func codexAccessMenu(agent: AgentKind) -> some View {
        let settings = sessionSettings
        let override = CodexSandboxMode.valid(settings.codexSandboxMode)
        let appDefault = CodexSandboxMode.resolved(runner.defaults(for: agent).codexSandboxMode)
        let selected = override ?? appDefault
        return settingMenu(selected.summary,
                           overridden: override != nil,
                           help: selected.detail,
                           defaultTitle: defaultTitle(appDefault.title),
                           options: CodexSandboxMode.allCases.map { (id: $0.rawValue, title: $0.title) },
                           warning: selected == .fullAccess,
                           warningOption: CodexSandboxMode.fullAccess.rawValue,
                           selection: Binding(get: { override?.rawValue },
                                              set: { value in
                                                  changeSettings { $0.codexSandboxMode = value }
                                              }))
    }

    private func pinnedSetting(_ label: String, help: String,
                               accent: Bool = false) -> some View {
        Text(label)
            .font(.system(size: 11, weight: accent ? .semibold : .regular))
            .foregroundStyle(accent ? Theme.accent : Color.secondary)
            .fixedSize()
            .appTooltip(help)
    }

    // The first row of every menu, naming what following the default currently means.
    private func defaultTitle(_ resolved: String?) -> String {
        resolved.map { "Use the default (\($0))" } ?? "Use the default"
    }

    private func settingMenu(_ label: String, overridden: Bool, help: String,
                             defaultTitle: String,
                             options: [(id: String, title: String)],
                             warning: Bool = false,
                             warningOption: String? = nil,
                             selection: Binding<String?>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: overridden ? .semibold : .regular))
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
        }
        .foregroundStyle(warning ? Theme.deletion
                                 : overridden ? Theme.accent : Color.secondary)
        .fixedSize()
        .appMenu {
            var entries: [MenuEntry] = [
                .item(defaultTitle, checked: selection.wrappedValue == nil) {
                    selection.wrappedValue = nil
                },
                .separator,
            ]
            entries += options.map { option in
                MenuEntry.item(option.title,
                               kind: option.id == warningOption ? .destructive : .plain,
                               checked: selection.wrappedValue == option.id,
                               subtitle: option.id == warningOption
                                   ? "No file, service, or network restrictions."
                                   : nil) {
                    selection.wrappedValue = option.id
                }
            }
            return entries
        }
        .appTooltip(overridden ? "\(help) Overridden for this session." : help)
    }

    // Where the work went. It appears the moment the agent opens one, and it is the only
    // thing on this line that leads out of the app, so it opens in the browser.
    private func pullRequestTag(_ pullRequest: PullRequest) -> some View {
        Button {
            guard let url = URL(string: pullRequest.url) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            // Verbatim, or the interpolated number is read as a localised one and comes
            // out grouped: PR #2,395.
            Text(verbatim: "PR #\(pullRequest.number)")
                .font(.mono(11, .semibold))
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appTooltip {
            Tooltip(title: "Pull request #\(pullRequest.number)",
                    subtitle: pullRequest.url,
                    note: "Opens in the browser.")
        }
    }

    // The branch the working tree is on, which for a session without a worktree is the
    // branch the agent is committing to. The snapshot is nil until git has answered;
    // only the hint depends on it.
    private func branchTag(branch: String, repository: GitSnapshot?) -> some View {
        Button { tab = .changes } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(branch)
                    .font(.mono(10.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appTooltip {
            guard let repository else { return Tooltip(title: "Opens Changes.") }
            return Tooltip(title: repository.files.isEmpty
                           ? "The working tree is clean. Opens Changes."
                           : "Uncommitted work on this branch. Opens Changes.")
        }
    }

    // What the session has cost so far. Codex reports no cost, so the figure only
    // appears once there is one, rather than showing a $0.00 that reads as free.
    private func spentTag(_ cost: Double) -> some View {
        Text(Money.short(cost))
            .font(.mono(10.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .appTooltip("What this session has spent.")
    }

    // The meter is the one thing on this row that says the session is getting heavy, so
    // it is also where the window is dealt with. It only opens a menu while there is a
    // conversation to work on and nothing running that still holds it; the rest of the
    // time it stays the read-only reading it has always been.
    @ViewBuilder private func contextMeter(fraction: Double, usage: SessionUsage,
                                           agent: AgentKind) -> some View {
        let actions = contextActions()
        if actions.isEmpty {
            contextReading(fraction, clearable: false, agent: agent)
                .appTooltip { usageTooltip(usage, agent: agent, clearable: false) }
        } else {
            contextReading(fraction, clearable: true, agent: agent)
                .contentShape(Rectangle())
                .appMenu { actions }
                .appTooltip { usageTooltip(usage, agent: agent, clearable: true) }
        }
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
        dialogs.show(Dialog(
            title: "Compact this session's context?",
            message: "The agent reads the conversation so far, replaces it with a summary, and carries on from that. It takes a turn of its own - up to a minute - and counts towards what this session has spent.",
            actions: [
                .init(label: "Compact", kind: .primary) {
                    runner.compact(sessionID, store: store)
                },
                .init(label: "Cancel", kind: .cancel),
            ]))
    }

    // The bar is the first thing to give up when the row runs out of room: it restates
    // the number beside it, which is the part actually being read.
    private func contextReading(_ fraction: Double, clearable: Bool,
                                agent: AgentKind) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                contextLabel(agent)
                Meter(fraction: fraction,
                      colour: contextColour(fraction, agent: agent), height: 5)
                    .frame(width: 110)
                contextPercent(fraction, clearable: clearable, agent: agent)
            }
            HStack(spacing: 10) {
                contextLabel(agent)
                contextPercent(fraction, clearable: clearable, agent: agent)
            }
        }
    }

    private func contextLabel(_ agent: AgentKind) -> some View {
        Text(agent == .codex ? "WINDOW" : "CONTEXT")
            .font(.mono(10.5))
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private func contextPercent(_ fraction: Double, clearable: Bool,
                                agent: AgentKind) -> some View {
        HStack(spacing: 4) {
            Text("\(Int((fraction * 100).rounded()))% USED")
                .font(.mono(11, .semibold))
            if clearable {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
        }
        .foregroundStyle(contextColour(fraction, agent: agent))
        .lineLimit(1)
        .fixedSize()
    }

    private func contextColour(_ fraction: Double, agent: AgentKind) -> Color {
        switch Int((fraction * 100).rounded()) {
        case 85...: agent == .codex ? Theme.attention : Theme.deletion
        case 70...: Theme.attention
        default: Theme.dotOn
        }
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
        let turns = usage.turns == 1 ? "1 turn" : "\(usage.turns) turns"
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
                    Button(action: confirmCompact) {
                        Text("Compact")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .appTooltip("Summarises the conversation so far and carries on from it.")
                }
                Button {
                    runner.clearContext(sessionID, store: store)
                } label: {
                    Text("Clear")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.attention.opacity(0.4)))
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
                        Button("Send now") { runner.runQueue(sessionID, store: store) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
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
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                }
            }
        }
    }

    // What is waiting to go out with the next prompt. Long file names are common, so the
    // strip scrolls rather than squeezing the chips.
    @ViewBuilder private var attachmentStrip: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(attachments) { attachment in
                        AttachmentChip(url: attachment.url) {
                            runner.editDraft(sessionID) { $0.attachments.removeAll { $0.id == attachment.id } }
                        }
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    // The same file twice in one prompt says nothing new.
    private func attach(_ found: [Attachment]) {
        runner.editDraft(sessionID) { draft in
            for item in found where !draft.attachments.contains(where: { $0.url == item.url }) {
                draft.attachments.append(item)
            }
        }
        composerFocused = true
    }

    private func offerTextFile(_ text: String) {
        let count = text.count.formatted()
        let limit = ComposerPaste.characterLimit.formatted()
        let message = "This paste has \(count) characters. Pastes are limited to \(limit) characters "
            + "to keep the composer responsive. Would you like to upload it as a text file instead?"
        dialogs.show(Dialog(
            title: "Text is too long to paste",
            message: message,
            actions: [
                .init(label: "Upload as file", kind: .primary) {
                    guard let attachment = Attachments.fromPastedText(text) else {
                        dialogs.show(Dialog(
                            title: "Could not attach the text",
                            message: "The temporary text file could not be created.",
                            actions: [.init(label: "OK", kind: .cancel)]))
                        return
                    }
                    attach([attachment])
                },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    private func send() {
        let draft = runner.draft(sessionID)
        let prompt = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        runner.send(prompt,
                    attachments: draft.attachments,
                    customInstructions: draft.customInstructions,
                    sessionID: sessionID,
                    store: store)
        runner.clearDraft(sessionID)
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
    let avatarSequence: Int
    let avatarName: String?
    // The agent has answered and is being held open for a background task it started.
    // Silence is the expected thing here, not a worry.
    var waitingOnTasks = false

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
            let personality = avatar?.personality ?? .standard
            let word = waitingOnTasks ? "Waiting" : words.word(after: context.date.timeIntervalSince(started))
            HStack(spacing: 8) {
                if let avatar {
                    AgentAvatarView(image: avatar.image, size: 20)
                        .id(avatar.id)
                        .transition(.opacity)
                } else {
                    WorkingGlyph(animated: !reduceMotion)
                }
                Text("\(word)…")
                    .font(.mono(12, .medium))
                    .foregroundStyle(.primary)
                    // The word is swapped inside one view rather than by giving each word
                    // its own identity. A new identity makes the old word a separate view
                    // that has to be animated away, and the row moves down the transcript
                    // while that happens, so the leaving word is left sitting on top of
                    // whatever has since taken its place.
                    .contentTransition(.opacity)
                if waitingOnTasks {
                    Text("for a background task to finish")
                        .font(.mono(12))
                        .foregroundStyle(.secondary)
                }
                if quiet >= Self.showQuietAfter, !waitingOnTasks {
                    Text("silent for \(elapsed(quiet))")
                        .font(.system(size: 11))
                        .foregroundStyle(quiet >= Self.concerningAfter
                                         ? ChatColor.warningText : .secondary)
                }
                Spacer(minLength: 0)
            }
            // The row keeps sliding down as the turn writes more above it. Without this the
            // avatar fading in on a new turn animates against the transcript rather than
            // against the row, and lands somewhere the row no longer is.
            .geometryGroup()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: word)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: avatar?.id)
            // Only worth a hint once the silence is long enough to worry about; the
            // empty one shows nothing.
            .appTooltip {
                guard quiet >= Self.concerningAfter, !waitingOnTasks else { return Tooltip(title: "") }
                return Tooltip(title: "Claude Code has sent nothing for a while.",
                               note: "The log in Settings says what it last did.")
            }
            .onAppear { words = WorkingWords(personality: personality) }
            .onChange(of: personality) { _, personality in
                words = WorkingWords(personality: personality)
                started = .now
            }
        }
    }

    private var currentAvatar: AgentAvatar? {
        AgentAvatarSelection.avatar(named: avatarName, forTurn: avatarSequence,
                                    from: appSettings.agentAvatars)
    }

    private func elapsed(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        guard whole >= 60 else { return "\(whole)s" }
        return "\(whole / 60)m \(whole % 60)s"
    }
}
