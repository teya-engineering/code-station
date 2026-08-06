import SwiftUI

// The detail pane for one Claude Code conversation: the transcript or the working tree
// diff, with a real shell docked underneath. The terminal shares the screen rather
// than replacing it, so a build and what the agent did are one glance apart.
struct SessionView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(TerminalStore.self) private var terminals
    let sessionID: UUID

    private enum Tab: Hashable { case chat, changes, explorer }

    @State private var tab: Tab = .chat
    @State private var dropTargeted = false
    @State private var terminalFocused = false
    @State private var composerFocused = false

    // Working tree totals for the header; refreshed as tools finish so the numbers
    // track the run rather than only its end.
    @State private var stats: GitSnapshot?
    @State private var statsTask: Task<Void, Never>?

    private let bottomAnchor = "transcript-bottom"

    var body: some View {
        // The sidebar can delete a session or its project while it is on screen.
        if let session = store.session(sessionID), let project = store.project(session.projectID) {
            let workingDirectory = session.worktreePath ?? project.path
            VStack(spacing: 0) {
                header(session: session, project: project)
                warningStrip(session: session, project: project)

                switch tab {
                case .chat:
                    transcript(session)
                    Divider().overlay(Theme.hairline)
                    composer(session: session, project: project)
                case .changes:
                    ChangesView(root: workingDirectory)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .explorer:
                    ExplorerView(root: workingDirectory)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if terminals.isOpen(sessionID) {
                    TerminalDrawer(sessionID: sessionID,
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
                refreshStats(workingDirectory)
                store.findPullRequest(in: sessionID)
            }
            .onChange(of: completedToolCount) { refreshStats(workingDirectory) }
            .onChange(of: runner.state(sessionID)) { _, state in
                if !state.isBusy { refreshStats(workingDirectory) }
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
                Text(session.title)
                    .font(.serif(22, .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 8) {
                    Text(project.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    // A worktree path is long and mostly noise, so it is held short here;
                    // the full path is a hover away. The branch is not repeated either,
                    // since the composer's footer already names it.
                    Text((session.worktreePath ?? project.path).abbreviatedPath)
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
                TabToggle(tab: $tab)
                TerminalToggle(isOpen: terminals.isOpen(sessionID)) {
                    toggleTerminal(directory: session.worktreePath ?? project.path)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    // "+38 -6 in 3 files": what the working tree looks like right now. Clicking it
    // opens the full diff.
    @ViewBuilder private var diffStats: some View {
        if let stats, stats.state == .ready, !stats.files.isEmpty {
            Button { tab = .changes } label: {
                HStack(spacing: 6) {
                    Text("+\(stats.totalAdded)").foregroundStyle(Theme.addition)
                    Text("-\(stats.totalRemoved)").foregroundStyle(Theme.deletion)
                    Text("in \(stats.files.count) file\(stats.files.count == 1 ? "" : "s")")
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

    private func refreshStats(_ root: String) {
        statsTask?.cancel()
        statsTask = Task {
            let snapshot = await GitInspector.snapshot(at: root)
            if !Task.isCancelled { stats = snapshot }
        }
    }

    // Control-backtick reaches the terminal from the keyboard: it opens the drawer if
    // it is shut, and otherwise moves focus between the composer and the shell. A
    // hidden button is how a shortcut gets a home when there is no menu item for it.
    private func terminalShortcut(directory: String) -> some View {
        Button("") {
            if !terminals.isOpen(sessionID) {
                terminals.setOpen(true, for: sessionID, directory: directory)
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
        let opening = !terminals.isOpen(sessionID)
        terminals.setOpen(opening, for: sessionID, directory: directory)
        terminalFocused = opening
        if !opening { composerFocused = true }
    }

    private struct TabToggle: View {
        @Binding var tab: Tab

        var body: some View {
            HStack(spacing: 2) {
                segment("Chat", .chat)
                segment("Changes", .changes)
                segment("Explorer", .explorer)
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.05)))
        }

        private func segment(_ label: String, _ value: Tab) -> some View {
            let active = tab == value
            return Button { tab = value } label: {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(active ? Color.white : .clear)
                            .shadow(color: .black.opacity(active ? 0.08 : 0), radius: 1, y: 0.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func warningStrip(session: ChatSession, project: Project) -> some View {
        if store.isMissing(project) {
            strip("Folder not found at \(project.collapsedPath). Move it back or remove the project.")
        } else if let worktree = session.worktreePath, !FileManager.default.fileExists(atPath: worktree) {
            strip("Worktree not found at \(worktree.abbreviatedPath). It was removed outside the app; delete this session or recreate it.")
        } else if !runner.available {
            strip("Claude Code CLI not found on PATH. Sessions cannot run until it is installed.")
        }
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

        return ScrollViewReader { proxy in
            ScrollView {
                transcriptContent(session, state: state, projectPath: projectPath)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    // Capped so prose keeps a readable line length, and centered so a
                    // wide window pads both sides instead of piling space on the right.
                    // Wider than a chat app's usual measure: diffs and tool output make
                    // better use of the room than paragraphs do.
                    .frame(maxWidth: 960, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    // The soft landing for anything new: a fresh row fades in and the
                    // rows above it glide up rather than jumping. Keyed on the shape of
                    // the transcript, not its text, so it plays once per whole arrival
                    // and never while a line is still being typed into.
                    .animation(.easeOut(duration: 0.2), value: transcriptShape(session, state: state))
            }
            // Opening a transcript starts at the end, where the conversation is.
            .defaultScrollAnchor(.bottom)
            // The pane changes height under a transcript that is already there: the
            // composer grows a line, the terminal drawer opens, the window is resized.
            // The end of the content moves with it, and the scroll view is left holding
            // the offset that used to reach it, so it has to be sent there again.
            .background(GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.height) {
                    Task { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                }
            })
            // Rows measure again after the first layout - an attachment, an image, text
            // that wraps differently once it has its real width - and the end of the
            // transcript moves with them. One nudge once that settles lands on it.
            .task(id: sessionID) {
                await Task.yield()
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
            .onChange(of: session.messages.count) { scrollToBottom(proxy, animated: true) }
            // A finished line is worth a glide; tokens landing inside one are not.
            .onChange(of: session.messages.last?.text ?? "") { old, new in
                scrollToBottom(proxy, animated: newlineCount(old) != newlineCount(new))
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
    // are built eagerly anyway, so there is nothing much to save by being lazy and a
    // whole class of blank pane to avoid. It also keeps a tool card that was opened
    // open once it has been scrolled past.
    private func transcriptContent(_ session: ChatSession, state: SessionState,
                                   projectPath: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if session.messages.isEmpty {
                Text("Ask for a change. Claude Code runs in the project folder, so what it edits is your working tree.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }

            ForEach(session.messages) { message in
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
                           since: runner.lastActivity(sessionID) ?? Date())
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
        // Animating every streamed token makes the transcript jitter, so only whole
        // arrivals - a message, a tool row, a finished line - are worth animating.
        if animated {
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

    private func transcriptShape(_ session: ChatSession, state: SessionState) -> TranscriptShape {
        TranscriptShape(messages: session.messages.count,
                        tools: session.messages.last?.tools.count ?? 0,
                        lines: newlineCount(session.messages.last?.text ?? ""),
                        state: state,
                        question: runner.question(sessionID)?.id)
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
        let busy = runner.state(sessionID).isBusy
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
                              onSubmit: send)

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
                }

                if busy {
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
        HStack(spacing: 10) {
            if let repository { branchTag(repository) }
            modelMenu(lastRan: usage?.model)
            effortMenu
            permissionsMenu
            Spacer(minLength: 8)
            if let pullRequest = session.pullRequest { pullRequestTag(pullRequest) }
            if let usage, let fraction = usage.contextFraction {
                contextMeter(usage, fraction: fraction)
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
        // The chip names what the next turn will run on: the override, else the app
        // default, else whatever the CLI last reported it decided on its own.
        let label = settings.model.map { ModelChoice.title(of: $0) }
            ?? runner.defaults.model.map { ModelChoice.title(of: $0) }
            ?? lastRan.map { ModelChoice.shortName(of: $0) }
            ?? "Default model"
        return settingMenu(label,
                           overridden: settings.model != nil,
                           help: "The model this session runs on. Applies from the next turn.",
                           defaultTitle: defaultTitle(runner.defaults.model.map { ModelChoice.title(of: $0) }),
                           options: ModelChoice.all.compactMap { choice in
                               choice.id.map { (id: $0, title: choice.title) }
                           },
                           selection: Binding(get: { settings.model },
                                              set: { id in changeSettings { $0.model = id } }))
    }

    private var effortMenu: some View {
        let settings = sessionSettings
        let chosen = settings.effort ?? runner.defaults.effort
        return settingMenu(chosen.map { "\(EffortChoice.summary(of: $0)) effort" } ?? "Default effort",
                           overridden: settings.effort != nil,
                           help: "How long the model thinks before it answers.",
                           defaultTitle: defaultTitle(runner.defaults.effort.map { EffortChoice.summary(of: $0) }),
                           options: EffortChoice.all.compactMap { choice in
                               choice.id.map { (id: $0, title: choice.title) }
                           },
                           selection: Binding(get: { settings.effort },
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

    // The first row of every menu, naming what following the default currently means.
    private func defaultTitle(_ resolved: String?) -> String {
        resolved.map { "Use the default (\($0))" } ?? "Use the default"
    }

    private func settingMenu(_ label: String, overridden: Bool, help: String,
                             defaultTitle: String,
                             options: [(id: String, title: String)],
                             selection: Binding<String?>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: overridden ? .semibold : .regular))
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
        }
        .foregroundStyle(overridden ? Theme.accent : Color.secondary)
        .fixedSize()
        .appMenu {
            var entries: [MenuEntry] = [
                .item(defaultTitle, checked: selection.wrappedValue == nil) {
                    selection.wrappedValue = nil
                },
                .separator,
            ]
            entries += options.map { option in
                MenuEntry.item(option.title, checked: selection.wrappedValue == option.id) {
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
    // branch the agent is committing to. Uncommitted work is named alongside it: on a
    // shared branch that is the difference between a safe turn and a mess.
    private func branchTag(_ repository: GitSnapshot) -> some View {
        Button { tab = .changes } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                Text(repository.branch)
                    .font(.mono(11, .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !repository.files.isEmpty {
                    Text("\(repository.files.count) changed")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(repository.files.isEmpty
              ? "The working tree is clean. Opens Changes."
              : "Uncommitted work on this branch. Opens Changes.")
    }

    private func contextMeter(_ usage: SessionUsage, fraction: Double) -> some View {
        let tight = fraction > 0.85
        return HStack(spacing: 10) {
            Text("Context")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Meter(fraction: fraction, colour: tight ? Theme.deletion : Theme.accent, height: 5)
                .frame(width: 120)
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tight ? Theme.deletion : Color.primary)
            Text("\(formattedTokens(usage.contextTokens)) / \(formattedTokens(usage.contextWindow))")
                .font(.mono(11))
                .foregroundStyle(.secondary)
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
                            runner.unqueue(item.id, sessionID: sessionID)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
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

    private func send() {
        let draft = runner.draft(sessionID)
        let prompt = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !draft.attachments.isEmpty else { return }
        runner.send(prompt, attachments: draft.attachments, sessionID: sessionID, store: store)
        runner.clearDraft(sessionID)
    }
}

// What the agent is doing, and how long since it last said anything. A working turn
// reports something every few seconds, so the silence is the number worth watching: it is
// the only thing that separates a long build from a turn that will never come back.
private struct WorkingRow: View {
    let runningTool: String?
    let since: Date

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
            let word = words.word(after: context.date.timeIntervalSince(started))
            HStack(spacing: 8) {
                WorkingGlyph()
                Text("\(word)…")
                    .font(.mono(12, .medium))
                    .foregroundStyle(.primary)
                    .id(word)
                    .transition(.opacity)
                if let runningTool {
                    Text(runningTool)
                        .font(.mono(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if quiet >= Self.showQuietAfter {
                    Text("silent for \(elapsed(quiet))")
                        .font(.system(size: 11))
                        .foregroundStyle(quiet >= Self.concerningAfter
                                         ? ChatColor.warningText : .secondary)
                }
                Spacer(minLength: 0)
            }
            .animation(.easeInOut(duration: 0.25), value: word)
            .help(quiet >= Self.concerningAfter
                  ? "Claude Code has sent nothing for a while. The log in Settings says what it last did."
                  : "")
        }
    }

    private func elapsed(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        guard whole >= 60 else { return "\(whole)s" }
        return "\(whole / 60)m \(whole % 60)s"
    }
}
