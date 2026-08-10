import AppKit
import SwiftUI

// Long conversations stay fully available to the runner and persistence layer, but the
// view only builds a bounded tail. Earlier pages are added on demand without changing
// the transcript format or making old sessions migrate their data.
struct TranscriptWindow: Equatable {
    let pageSize: Int
    private(set) var visibleCount: Int

    init(pageSize: Int = 80) {
        self.pageSize = max(1, pageSize)
        visibleCount = max(1, pageSize)
    }

    func hiddenCount(totalCount: Int) -> Int {
        max(0, totalCount - visibleCount)
    }

    func visibleMessages(in messages: [ChatMessage]) -> ArraySlice<ChatMessage> {
        messages.suffix(visibleCount)
    }

    mutating func loadEarlier(totalCount: Int) {
        guard hiddenCount(totalCount: totalCount) > 0 else { return }
        visibleCount = min(totalCount, visibleCount + pageSize)
    }

    mutating func reset() {
        visibleCount = pageSize
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sessionID: UUID

    private enum Tab: Hashable { case chat, changes, explorer }

    @State private var tab: Tab = .chat
    @State private var dropTargeted = false
    @State private var terminalFocused = false
    @State private var composerFocused = false
    @State private var selectedProjectID: UUID?
    @State private var transcriptWindow = TranscriptWindow()
    @State private var transcriptPinnedToBottom = true

    // Working tree totals for the header; refreshed as tools finish so the numbers
    // track the run rather than only its end.
    @State private var stats: GitSnapshot?
    @State private var workspaceStats: [String: GitSnapshot] = [:]
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

                if terminals.isOpen(terminalScope) {
                    TerminalDrawer(scope: terminalScope,
                                   directory: workingDirectory,
                                   focusTerminal: $terminalFocused)
                }
            }
            .background(Theme.background)
            .onAppear { composerFocused = true }
            .background(terminalShortcut(directory: workingDirectory))
            .onChange(of: terminalFocused) { _, focused in
                if focused { composerFocused = false }
            }
            .task(id: sessionID) {
                selectedProjectID = session.projectID
                refreshStats(workingDirectories)
                store.findPullRequest(in: sessionID)
            }
            .onChange(of: completedToolCount) {
                refreshStats(workingDirectories, after: .milliseconds(350))
            }
            .onChange(of: runner.state(sessionID)) { _, state in
                if !state.isBusy {
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

    private func header(session: ChatSession, project: Project) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if session.isTroubleshooting {
                        StatusPill(text: "Troubleshoot", running: false, tint: Theme.secret)
                            .fixedSize()
                    }
                    Text(session.title)
                        .font(.serif(22, .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 8) {
                    Text(session.workspaceID.flatMap(store.workspace)?.name ?? project.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    // A worktree path is long and mostly noise, so it is held short here;
                    // the full path is a hover away. The branch is not repeated either,
                    // since the composer's footer already names it.
                    Text(store.checkoutProjects(for: session).count == 1
                         ? (session.worktreePath ?? project.path).abbreviatedPath
                         : "\(store.checkoutProjects(for: session).count) projects")
                        .font(.mono(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 260, alignment: .leading)
                        .help((session.worktreePath ?? project.path).abbreviatedPath)
                }
            }

            Spacer(minLength: 12)

            // A row splits its width between the children rather than handing each one what
            // it asks for, so the controls can be offered less than their labels need and the
            // words wrap. Holding them at their natural width makes the title give way first.
            HStack(spacing: 16) {
                diffStats
                HeaderTabToggle(selection: $tab,
                                options: [("Chat", .chat),
                                          ("Changes", .changes),
                                          ("Explorer", .explorer)])
                TerminalToggle(isOpen: terminals.isOpen(terminalScope)) {
                    toggleTerminal(directory: session.worktreePath ?? project.path)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    private func workspaceProjectBar(_ session: ChatSession) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(store.checkoutProjects(for: session)) { checkout in
                    if let project = store.project(checkout.projectID) {
                        let root = checkout.worktreePath ?? project.path
                        let snapshot = workspaceStats[root]
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

    // "+38 -6 in 3 files": what the working tree looks like right now. Clicking it
    // opens the full diff.
    @ViewBuilder private var diffStats: some View {
        let snapshots = workspaceStats.values.filter { $0.state == .ready }
        let added = snapshots.reduce(0) { $0 + $1.totalAdded }
        let removed = snapshots.reduce(0) { $0 + $1.totalRemoved }
        let files = snapshots.reduce(0) { $0 + $1.files.count }
        if files > 0 {
            Button { tab = .changes } label: {
                HStack(spacing: 6) {
                    Text("+\(added)").foregroundStyle(Theme.addition)
                    Text("-\(removed)").foregroundStyle(Theme.deletion)
                    Text("in \(files) file\(files == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .font(.mono(12, .semibold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Changes")
        }
    }

    // Completed tool calls in the turn that is streaming right now. Each one may have
    // touched the working tree, so each is a moment to refresh the header stats.
    private var completedToolCount: Int {
        guard let last = store.session(sessionID)?.messages.last, last.role == .assistant else { return 0 }
        return last.tools.filter { !$0.isRunning }.count
    }

    private func refreshStats(_ roots: [String], after delay: Duration? = nil) {
        statsTask?.cancel()
        statsTask = Task {
            if let delay {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            var snapshots: [String: GitSnapshot] = [:]
            await withTaskGroup(of: (String, GitSnapshot).self) { group in
                for root in roots {
                    group.addTask { (root, await GitInspector.snapshot(at: root)) }
                }
                for await (root, snapshot) in group {
                    snapshots[root] = snapshot
                }
            }
            if !Task.isCancelled {
                workspaceStats = snapshots
                stats = roots.first.flatMap { snapshots[$0] }
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

    // The button both opens and shuts it; opening puts the cursor straight in the shell
    // so it can be used without reaching for the mouse again.
    private func toggleTerminal(directory: String) {
        let opening = !terminals.isOpen(terminalScope)
        terminals.setOpen(opening, for: terminalScope, directory: directory)
        terminalFocused = opening
        if !opening { composerFocused = true }
    }

    @ViewBuilder private func warningStrip(session: ChatSession, project: Project) -> some View {
        if store.isMissing(project) {
            strip("Folder not found at \(project.collapsedPath). Move it back or remove the project.")
        } else if let missing = missingCheckout(in: session) {
            strip("Workspace folder not found at \(missing.abbreviatedPath). Move it back or recreate this session.")
        } else if let worktree = session.worktreePath, !FileManager.default.fileExists(atPath: worktree) {
            strip("Worktree not found at \(worktree.abbreviatedPath). It was removed outside the app; delete this session or recreate it.")
        } else if !runner.available {
            strip("\(runner.agent.title) CLI not found on PATH. Sessions cannot run until it is installed.")
        }
    }

    private func missingCheckout(in session: ChatSession) -> String? {
        store.workingDirectories(for: session).first {
            !FileManager.default.fileExists(atPath: $0)
        }
    }

    private func directory(for projectID: UUID, in session: ChatSession) -> String? {
        guard let checkout = store.checkoutProjects(for: session)
            .first(where: { $0.projectID == projectID }) else { return nil }
        return checkout.worktreePath ?? store.project(projectID)?.path
    }

    private func strip(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer()
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
            // The end of the content moves with it, and the scroll view is left holding
            // the offset that used to reach it, so it has to be sent there again.
            .background(GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.height, initial: true) {
                    guard transcriptPinnedToBottom else { return }
                    Task { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                }
            })
            // Rows measure again after the first layout - an attachment, an image, text
            // that wraps differently once it has its real width - and the end of the
            // transcript moves with them. One nudge once that settles lands on it.
            .task(id: sessionID) {
                transcriptWindow.reset()
                transcriptPinnedToBottom = true
                await Task.yield()
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
            .onChange(of: session.messages.count) { scrollToBottom(proxy, animated: true) }
            // A finished line is worth a glide. A long line is followed in coarse chunks
            // so streaming tokens do not each perform another scroll operation.
            .onChange(of: textShape) { old, new in
                scrollToBottom(proxy, animated: old.lines != new.lines)
            }
            .onChange(of: session.messages.last?.tools.count ?? 0) { scrollToBottom(proxy, animated: true) }
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
                Text("Ask for a change. \(runner.agent.title) runs in the project folder, so what it edits is your working tree.")
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
                MessageView(message: message,
                            projectPath: projectPath,
                            openChanges: { tab = .changes })
                    // Every message is on screen now, and a streaming turn rewrites
                    // the last one many times a second. Without this, each of those
                    // redraws every message in the transcript, parsing its markdown
                    // again on the way.
                    .equatable()
                    .transition(.fadeIn)
            }

            pendingQuestion
                .transition(.fadeIn)

            if showsThinking(state: state) {
                WorkingRow(runningTool: runningTool(session, root: projectPath),
                           since: runner.lastActivity(sessionID) ?? Date(),
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

    // "Bash · swift build" for the call in flight, so the wait has a subject. Nothing while
    // the model is only writing, which is what a plain "Thinking…" means.
    private func runningTool(_ session: ChatSession, root: String) -> String? {
        guard let last = session.messages.last, last.role == .assistant,
              let tool = last.tools.last(where: { $0.isRunning }) else { return nil }
        return ToolPresentationCache.presentation(for: tool, projectPath: root).label
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
        let blocked = !FileManager.default.fileExists(atPath: workingDirectory) || !runner.available
        let state = runner.state(sessionID)
        let busy = state.isBusy
        let canSend = !blocked && !runner.draft(sessionID).isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            contextReadout(session)
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
                              })

                if canSend {
                    Button(action: send) {
                        Image(systemName: busy ? "arrow.up.to.line" : "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(busy ? Theme.accent : Color.black.opacity(0.88)))
                    }
                    .buttonStyle(.plain)
                    .help(busy ? "Queue this for when the turn ends" : "Send (shift-return for a new line)")
                    .transition(.opacity)
                }

                if state == .stopping {
                    Image(systemName: "hourglass")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.field))
                        .help("Stopping this turn")
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
                    .help("Stop this turn")
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

    // What the next turn will run against, on the line the eye is already on when hitting
    // send: the branch it edits, the model, effort and permissions it runs with, and how
    // full the window is. The three run choices are pickers, so the session can be steered
    // without leaving the composer. A choice left on the app default keeps following
    // Settings, including later changes there; an override holds for this conversation
    // alone and is marked in the accent colour.
    @ViewBuilder private func contextReadout(_ session: ChatSession) -> some View {
        let repository = stats?.state == .ready ? stats : nil
        let usage = session.usage
        let agent = runner.agent
        HStack(spacing: 10) {
            if let repository { branchTag(repository) }
            if session.settings?.mcpServersEnabled == false {
                Text("MCP off")
                    .font(.mono(10.5, .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
            }
            modelMenu(lastRan: usage?.model(for: agent))
            effortMenu
            if agent == .claudeCode {
                permissionsMenu
            } else {
                codexAccessMenu
            }
            Spacer(minLength: 8)
            if let pullRequest = session.pullRequest { pullRequestTag(pullRequest) }
            if let fraction = usage?.contextFraction(for: agent) {
                contextMeter(fraction: fraction)
            }
        }
    }

    // MARK: - Run choices

    // The session's overrides, and the app defaults they fall back to. The same choices
    // the CLI hides behind /model, /effort and its permission modes, which cannot be
    // typed at an agent that is driven over a pipe.
    private var sessionSettings: SessionSettings {
        store.session(sessionID)?.settings ?? SessionSettings()
    }

    private func changeSettings(_ edit: (inout SessionSettings) -> Void) {
        var updated = sessionSettings
        edit(&updated)
        store.setSettings(updated, for: sessionID)
    }

    private func modelMenu(lastRan: String?) -> some View {
        let settings = sessionSettings
        let agent = runner.agent
        // Choices made while the other agent was active mean nothing to this one, so
        // they read as "nothing chosen" here the way the runner treats them.
        let override = ModelChoice.valid(settings.model, for: agent)
        let appDefault = ModelChoice.valid(runner.defaults.model, for: agent)
        // The chip names what the next turn will run on: the override, else the app
        // default, else whatever the CLI last reported it decided on its own.
        let label = override.map { ModelChoice.title(of: $0) }
            ?? appDefault.map { ModelChoice.title(of: $0) }
            ?? lastRan.map { ModelChoice.shortName(of: $0) }
            ?? "Default model"
        return settingMenu(label,
                           overridden: override != nil,
                           help: "The model this session runs on. Applies from the next turn.",
                           defaultTitle: defaultTitle(appDefault.map { ModelChoice.title(of: $0) }),
                           options: ModelChoice.options(for: agent).compactMap { choice in
                               choice.id.map { (id: $0, title: choice.title) }
                           },
                           selection: Binding(get: { override },
                                              set: { id in changeSettings { $0.model = id } }))
    }

    private var effortMenu: some View {
        let settings = sessionSettings
        let agent = runner.agent
        let override = EffortChoice.valid(settings.effort, for: agent)
        let appDefault = EffortChoice.valid(runner.defaults.effort, for: agent)
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

    private var permissionsMenu: some View {
        let settings = sessionSettings
        return settingMenu(PermissionMode.shortTitle(of: settings.permissionMode ?? runner.defaults.permissionMode),
                           overridden: settings.permissionMode != nil,
                           help: "How much the agent asks before it acts.",
                           defaultTitle: defaultTitle(PermissionMode.shortTitle(of: runner.defaults.permissionMode)),
                           options: PermissionMode.all.map { (id: $0.mode, title: $0.title) },
                           selection: Binding(get: { settings.permissionMode },
                                              set: { mode in changeSettings { $0.permissionMode = mode } }))
    }

    private var codexAccessMenu: some View {
        let settings = sessionSettings
        let override = CodexSandboxMode.valid(settings.codexSandboxMode)
        let appDefault = CodexSandboxMode.resolved(runner.defaults.codexSandboxMode)
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
        .help(overridden ? "\(help) Overridden for this session." : help)
    }

    // Where the work went. It appears the moment the agent opens one, and it is the only
    // thing on this line that leads out of the app, so it opens in the browser.
    private func pullRequestTag(_ pullRequest: PullRequest) -> some View {
        Button {
            guard let url = URL(string: pullRequest.url) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            Text("PR #\(pullRequest.number)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pullRequest.url)
    }

    // The branch the working tree is on, which for a session without a worktree is the
    // branch the agent is committing to.
    private func branchTag(_ repository: GitSnapshot) -> some View {
        Button { tab = .changes } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                Text(repository.branch)
                    .font(.mono(11, .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(repository.files.isEmpty
              ? "The working tree is clean. Opens Changes."
              : "Uncommitted work on this branch. Opens Changes.")
    }

    private func contextMeter(fraction: Double) -> some View {
        let percentage = Int((fraction * 100).rounded())
        let colour = if percentage >= 85 {
            Theme.deletion
        } else if percentage >= 70 {
            Theme.attention
        } else {
            Theme.dotOn
        }

        return HStack(spacing: 10) {
            Text("Context")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Meter(fraction: fraction, colour: colour, height: 5)
                .frame(width: 120)
            Text("\(percentage)%")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(colour)
        }
        .help("Context in use after the last turn.")
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
                        .help("Take it back into the composer to rework")
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
                        .help("Remove from the queue")
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

// What the agent is doing, and how long since it last said anything. A working turn
// reports something every few seconds, so the silence is the number worth watching: it is
// the only thing that separates a long build from a turn that will never come back.
private struct WorkingRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppSettings.self) private var appSettings

    let runningTool: String?
    let since: Date
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
            let word = waitingOnTasks ? "Waiting" : words.word(after: context.date.timeIntervalSince(started))
            let avatar = currentAvatar(at: context.date)
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
                    .id(word)
                    .transition(.opacity)
                if waitingOnTasks {
                    Text("for a background task to finish")
                        .font(.mono(12))
                        .foregroundStyle(.secondary)
                } else if let runningTool {
                    Text(runningTool)
                        .font(.mono(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if quiet >= Self.showQuietAfter, !waitingOnTasks {
                    Text("silent for \(elapsed(quiet))")
                        .font(.system(size: 11))
                        .foregroundStyle(quiet >= Self.concerningAfter
                                         ? ChatColor.warningText : .secondary)
                }
                Spacer(minLength: 0)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: word)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: avatar?.id)
            .help(quiet >= Self.concerningAfter && !waitingOnTasks
                  ? "Claude Code has sent nothing for a while. The log in Settings says what it last did."
                  : "")
        }
    }

    private func currentAvatar(at date: Date) -> AgentAvatar? {
        guard let index = AgentAvatarRotation.index(
            after: date.timeIntervalSince(started),
            count: appSettings.agentAvatars.count) else {
            return nil
        }
        return appSettings.agentAvatars[index]
    }

    private func elapsed(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        guard whole >= 60 else { return "\(whole)s" }
        return "\(whole / 60)m \(whole % 60)s"
    }
}
