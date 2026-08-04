import SwiftUI

// The detail pane for one Claude Code conversation: the transcript or the working tree
// diff, with a real shell docked underneath. The terminal shares the screen rather
// than replacing it, so a build and what the agent did are one glance apart.
struct SessionView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(TerminalStore.self) private var terminals
    let sessionID: UUID

    private enum Tab: Hashable { case chat, changes }

    @State private var tab: Tab = .chat
    @State private var draft = ""
    @State private var terminalFocused = false
    @FocusState private var composerFocused: Bool

    // Working tree totals for the header; refreshed as tools finish so the numbers
    // track the run rather than only its end.
    @State private var stats: GitSnapshot?
    @State private var statsTask: Task<Void, Never>?

    private let bottomAnchor = "transcript-bottom"

    var body: some View {
        // The sidebar can delete a session or its project while it is on screen.
        if let session = store.session(sessionID), let project = store.project(session.projectID) {
            VStack(spacing: 0) {
                header(session: session, project: project)
                Divider().overlay(Theme.hairline)
                warningStrip(session: session, project: project)

                switch tab {
                case .chat:
                    transcript(session)
                    Divider().overlay(Theme.hairline)
                    composer(session: session, project: project)
                case .changes:
                    ChangesView(root: session.worktreePath ?? project.path)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if terminals.isOpen(sessionID) {
                    TerminalDrawer(sessionID: sessionID,
                                   directory: session.worktreePath ?? project.path,
                                   focusTerminal: $terminalFocused)
                }
            }
            .background(Theme.background)
            .onAppear { composerFocused = true }
            .background(terminalShortcut(directory: session.worktreePath ?? project.path))
            .onChange(of: terminalFocused) { _, focused in
                if focused { composerFocused = false }
            }
            .task(id: sessionID) { refreshStats(session.worktreePath ?? project.path) }
            .onChange(of: completedToolCount) { refreshStats(session.worktreePath ?? project.path) }
            .onChange(of: runner.state(sessionID)) { _, state in
                if !state.isBusy { refreshStats(session.worktreePath ?? project.path) }
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
                    Text((session.worktreePath ?? project.path).abbreviatedPath)
                        .font(.mono(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let branch = session.worktreeBranch {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10))
                            Text(branch).font(.mono(11))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                }
            }

            Spacer(minLength: 12)

            diffStats
            TabToggle(tab: $tab)
            TerminalToggle(isOpen: terminals.isOpen(sessionID)) {
                toggleTerminal(directory: session.worktreePath ?? project.path)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.card)
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
                LazyVStack(alignment: .leading, spacing: 18) {
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
                    }

                    if showsThinking(session, state: state) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
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
                    }

                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            .onChange(of: session.messages.count) { scrollToBottom(proxy, animated: true) }
            .onChange(of: session.messages.last?.text ?? "") { scrollToBottom(proxy, animated: false) }
            .onChange(of: session.messages.last?.tools.count ?? 0) { scrollToBottom(proxy, animated: false) }
            .onChange(of: state) { scrollToBottom(proxy, animated: true) }
        }
    }

    // While a turn is starting there is no assistant message yet, and while tools run
    // there is one with no text in it. Both should look like Claude is working.
    private func showsThinking(_ session: ChatSession, state: SessionState) -> Bool {
        guard state.isBusy else { return false }
        guard let last = session.messages.last, last.role == .assistant else { return true }
        return last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        // Animating every streamed token makes the transcript jitter, so only the
        // arrival of a whole message is worth animating.
        if animated {
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: - Composer

    private func composer(session: ChatSession, project: Project) -> some View {
        let workingDirectory = session.worktreePath ?? project.path
        let blocked = !FileManager.default.fileExists(atPath: workingDirectory) || !runner.available
        let busy = runner.state(sessionID).isBusy
        let canSend = !busy && !blocked && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return HStack(alignment: .bottom, spacing: 10) {
            // A vertical-axis TextField gives us return-to-send and shift-return for a
            // newline for free; TextEditor would need an NSView to intercept the key.
            TextField(busy ? "Claude Code is working…" : "Ask for a change, ^` for the terminal", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...10)
                .focused($composerFocused)
                .disabled(busy || blocked)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))

            // While a turn runs, the send button becomes the stop button.
            if busy {
                Button {
                    runner.stop(sessionID)
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.deletion))
                }
                .buttonStyle(.plain)
                .help("Stop this turn")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.black.opacity(canSend ? 0.88 : 0.22)))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send (shift-return for a new line)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.card)
    }

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !runner.state(sessionID).isBusy else { return }
        runner.send(prompt, sessionID: sessionID, store: store)
        draft = ""
    }
}
