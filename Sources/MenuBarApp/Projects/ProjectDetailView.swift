import AppKit
import SwiftUI

// The state of one repository and the sessions running in it: what git thinks of the
// folder, which worktrees are still checked out, and every conversation that has touched
// it. Opening a session is the point where its transcript takes over the pane.
struct ProjectDetailView: View {
    let projectID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(AppSettings.self) private var appSettings
    @Environment(WorkingTreeWatch.self) private var workingTrees
    @Environment(TerminalStore.self) private var terminals

    private enum Tab: Hashable { case sessions, changes, explorer }

    @State private var tab: Tab = .sessions
    @State private var choosingSessionKind: Project?
    @State private var terminalFocused = false
    @State private var git: GitSnapshot?
    @State private var orphanedWorktrees: [GitWorktree.Orphaned] = []
    @State private var pruningOrphans = false
    @State private var openShortcutRun: ShortcutRun?
    @State private var shortcutEditor: ShortcutEditorRequest?

    private var terminalScope: TerminalScope { .project(projectID) }

    var body: some View {
        if let project = store.project(projectID) {
            VStack(spacing: 0) {
                header(project)
                statusStrip(project)
                if store.isMissing(project) { missingFolder(project) }
                content(project)
                if let openShortcutRun {
                    ShortcutOutputDrawer(run: openShortcutRun) { self.openShortcutRun = nil }
                }
                if terminals.isOpen(terminalScope) {
                    TerminalDrawer(scope: terminalScope,
                                   directory: project.path,
                                   focusTerminal: $terminalFocused)
                }
            }
            .background(Theme.background)
            .background(terminalShortcut(project))
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
            .task(id: project.path) {
                openShortcutRun = nil
                git = await GitInspector.snapshot(at: project.path, lane: .interactive)
            }
            // A session ending is the moment the folder is most likely to have moved on.
            .task(id: store.standaloneSessions(for: projectID).map(\.summary)) {
                git = await GitInspector.snapshot(at: project.path, lane: .interactive)
            }
            .task(id: orphanRefreshID(project)) { await refreshWorktrees(for: project) }
            .sheet(item: $choosingSessionKind) { project in
                NewSessionView(project: project) { choice in
                    startSession(choice, in: project)
                }
                .appOverlays()
            }
        } else {
            PaneMessage(icon: "folder.badge.questionmark",
                        title: "This project is gone",
                        detail: "Choose another project from the sidebar.")
        }
    }

    // MARK: - Header

    // Which project this is, and nothing else: its colour, its full name - never cut
    // short - the views it can be read in, and the one action the screen is offering.
    // The state of the folder reads on the strip under this one. The path is only a
    // tooltip: it says the same thing the name does, at four times the length.
    private func header(_ project: Project) -> some View {
        // Asked once for the whole row: it is a stat call, and the row redraws often.
        let missing = store.isMissing(project)
        return HStack(spacing: 12) {
            ProjectDot(tint: Theme.projectTint(for: project.name))
            Text(project.name)
                .font(.serif(17, .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .appTooltip(project.collapsedPath)

            Spacer(minLength: 12)

            // Held at their natural width so a long project name is what gives way,
            // rather than the controls shrinking until their labels wrap.
            HStack(spacing: 12) {
                if appSettings.mobileAccessEnabled {
                    MobileAccessButton(scope: .project(project.id))
                }
                HeaderTabToggle(selection: $tab,
                                options: [("Sessions", .sessions),
                                          ("Changes", .changes),
                                          ("Explorer", .explorer)])
                TerminalToggle(isOpen: terminals.isOpen(terminalScope),
                               directory: project.path) {
                    toggleTerminal(directory: project.path)
                }
                .disabled(missing)
                .opacity(missing ? 0.4 : 1)

                ActionButton(title: "New session", tone: .green, size: 12) {
                    requestNewSession(in: project)
                }
                .disabled(missing)
                .opacity(missing ? 0.45 : 1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, 24)
        .headerBand()
    }

    // MARK: - Status strip

    // Repository state stays beside the project name so the session list remains above
    // the fold.
    private func statusStrip(_ project: Project) -> some View {
        HStack(spacing: 14) {
            if let git, git.state == .ready {
                checkout(git)
            } else {
                // The strip has room for the verdict; the tooltip carries the explanation.
                StatusCaps(text: gitVerdict).appTooltip(gitUnavailable)
            }

            StatusRule()
            shortcutsControl(project)

            Spacer(minLength: 12)

            if let git, git.state == .ready { lastCommit(git) }
            InlineLink(title: "Reveal in Finder", size: 11.5) { reveal(project) }
                .fixedSize()
                .layoutPriority(1)
        }
        .statusBand(padding: 24)
    }

    // Branch, drift and dirtiness as one reading, because they are one question: what
    // state is this checkout in. Ahead and behind only appear when they are not zero -
    // "0 / 0" is a figure that has to be read to learn there is nothing to say. Clicking
    // opens the changes, which is what the reading is about.
    private func checkout(_ git: GitSnapshot) -> some View {
        let dirty = git.files.count
        return Button { tab = .changes } label: {
            HStack(spacing: 9) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(git.branch.isEmpty ? "detached" : git.branch)
                        .font(.mono(11, .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if git.ahead > 0 { drift("arrow.up", count: git.ahead) }
                if git.behind > 0 { drift("arrow.down", count: git.behind) }
                StatusCaps(text: dirty == 0
                               ? "CLEAN"
                               : "\(dirty) UNCOMMITTED FILE\(dirty == 1 ? "" : "S")",
                           tint: dirty == 0 ? Color.secondary : Theme.attentionText)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appTooltip(driftSentence(git))
    }

    private func drift(_ icon: String, count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
            Text("\(count)")
                .font(.mono(10.5, .semibold))
        }
        .foregroundStyle(.secondary)
    }

    private func driftSentence(_ git: GitSnapshot) -> String {
        var parts: [String] = []
        if git.ahead > 0 { parts.append("\(git.ahead) commit\(git.ahead == 1 ? "" : "s") to push") }
        if git.behind > 0 { parts.append("\(git.behind) to pull") }
        return parts.isEmpty ? "Open Changes" : parts.joined(separator: ", ") + ". Open Changes."
    }

    // The line that says the folder has moved on since you last looked, so it is worth
    // reading before starting a session in it.
    private func lastCommit(_ git: GitSnapshot) -> some View {
        HStack(spacing: 7) {
            if let subject = git.lastCommitSubject {
                if let date = git.lastCommitDate {
                    StatusCaps(text: age(date), tint: Color.secondary.opacity(0.75))
                    StatusDot()
                }
                StatusValue(text: subject)
            } else {
                StatusValue(text: "nothing committed yet", tint: Color.secondary.opacity(0.75))
            }
        }
    }

    // "JUST NOW" rather than "NOW AGO", which is what the short form turns into when the
    // commit is a minute old.
    private func age(_ date: Date) -> String {
        let short = RelativeTime.short(date)
        return short == "now" ? "JUST NOW" : "\(short.uppercased()) AGO"
    }

    // The commands available to this project, collapsed to a count and a menu. They are
    // worth a whole row of chips in a session, where running the tests is part of the
    // work in front of you; here they are one more thing the folder has, so they take the
    // room of one reading. A run happens in the project folder, since a project screen is
    // not looking at any one worktree.
    private func shortcutsControl(_ project: Project) -> some View {
        let saved = shortcuts.shortcuts(for: project.id)
        let running = shortcuts.runningCount(of: saved)
        let failed = shortcuts.failureCount(of: saved)
        let tint = running > 0 ? Theme.accent : failed > 0 ? Theme.deletion : Color.secondary
        return HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(saved.isEmpty ? "Add" : "\(saved.count)")
                .font(.mono(10.5, .semibold))
            if running > 0 { RunningDot(size: 5) }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(running > 0 || failed > 0 ? tint.opacity(0.5) : Theme.border))
        .appMenu { shortcutMenu(project, saved: saved) }
        .appTooltip(saved.isEmpty
                    ? "Save a command for this project"
                    : "\(saved.count) saved command\(saved.count == 1 ? "" : "s"), run in the project folder")
    }

    private func shortcutMenu(_ project: Project, saved: [CommandShortcut]) -> [MenuEntry] {
        var entries: [MenuEntry] = saved.map { shortcut in
            let run = ShortcutRun(shortcut.id, in: shortcut.directory(projectPath: project.path))
            let state = shortcuts.state(run)
            return .item(state.isActive ? "Stop \(shortcut.name)" : shortcut.name,
                         subtitle: shortcut.command,
                         detail: shortcutDetail(shortcut, state: state),
                         detailColour: colour(of: state)) {
                toggle(run)
            }
        }
        if !entries.isEmpty {
            entries.append(.separator)
            if openShortcutRun != nil {
                entries.append(.item("Hide output") { openShortcutRun = nil })
            }
        }
        entries.append(.item("New shortcut…", icon: "plus") {
            shortcutEditor = ShortcutEditorRequest(projectID: project.id,
                                                   projectName: project.name)
        })
        return entries
    }

    private func shortcutDetail(_ shortcut: CommandShortcut,
                                state: ShortcutStore.State) -> String? {
        let stateDetail = detail(of: state)
        guard shortcut.availableInAllProjects else { return stateDetail }
        return stateDetail.map { "all projects · \($0)" } ?? "all projects"
    }

    private func detail(of state: ShortcutStore.State) -> String? {
        switch state {
        case .stopped: nil
        case .running(let since): "running · \(RelativeTime.duration(since: since))"
        case .finished: "exit 0"
        case .failed(_, let code, _): code.map { "exit \($0)" } ?? "failed"
        }
    }

    private func colour(of state: ShortcutStore.State) -> Color? {
        switch state {
        case .failed: Theme.deletion
        case .finished: Theme.addition
        default: nil
        }
    }

    // Starting a run opens its output, the way it does in a session: a command is worth
    // running because of what it prints.
    private func toggle(_ run: ShortcutRun) {
        if shortcuts.state(run).isActive {
            shortcuts.stop(run)
        } else {
            shortcuts.start(run)
            openShortcutRun = run
        }
    }

    @ViewBuilder private func content(_ project: Project) -> some View {
        switch tab {
        case .sessions:
            sessions(project)
        case .changes:
            ChangesView(root: project.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .explorer:
            ExplorerView(root: project.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sessions tab

    private func sessions(_ project: Project) -> some View {
        let available = store.standaloneSessions(for: project.id)
            .sorted { $0.lastActivity > $1.lastActivity }
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                sessionList(project, sessions: available)
                defaults(project)
            }
            .padding(24)
        }
    }

    private var gitVerdict: String {
        switch git?.state {
        case .notARepo: "NOT A GIT REPOSITORY"
        case .gitMissing: "GIT NOT FOUND"
        case .missingFolder: "FOLDER MISSING"
        case .failed: "GIT COULD NOT READ THIS FOLDER"
        case .ready, nil: "READING…"
        }
    }

    private var gitUnavailable: String {
        switch git?.state {
        case .notARepo: "This folder is not a git repository, so there is nothing to track."
        case .gitMissing: "git was not found on PATH."
        case .missingFolder: "The folder is no longer on disk."
        case .failed(let message): message
        case .ready, nil: "Reading the repository…"
        }
    }

    private func sessionList(_ project: Project, sessions: [ChatSession]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionRule(title: "SESSIONS · \(sessions.count)") {
                if !sessions.isEmpty {
                    Text(sessions.map { tone($0) }.tally)
                        .font(.mono(10))
                        .kerning(0.6)
                        .foregroundStyle(.tertiary)
                }
            }

            if !orphanedWorktrees.isEmpty { orphanedStrip(project) }

            if sessions.isEmpty {
                emptySessions(project)
            } else {
                LazyVStack(spacing: 9) {
                    ForEach(sessions) { session in
                        SessionRow(session: session,
                                   tone: tone(session),
                                   branch: branch(session, project: project),
                                   activity: SessionActivity.line(for: session, store: store,
                                                                  runner: runner),
                                   detail: .location(location(session, project: project)),
                                   onOpen: { store.selectSession(session.id) },
                                   menu: { sessionMenu(session, project: project) })
                    }
                }
            }
        }
    }

    private func defaults(_ project: Project) -> some View {
        FooterStrip(title: "Session defaults", detail: defaultsSummary) {
            InlineLink(title: "Change →", size: 12.5) {
                requestNewSession(in: project)
            }
        }
    }

    // What the next session will start with, read from the app defaults the new-session
    // sheet would preselect.
    private var defaultsSummary: String {
        let agent = runner.agent
        let settings = runner.defaults(for: agent)
        var parts = [agent.title]
        if let model = ModelChoice.valid(settings.model, for: agent) {
            parts.append(ModelChoice.title(of: model))
        }
        if let effort = EffortChoice.valid(settings.effort, for: agent) {
            parts.append("\(EffortChoice.summary(of: effort, agent: agent)) effort")
        }
        if agent == .codex {
            parts.append(CodexSandboxMode.resolved(settings.codexSandboxMode).summary.lowercased())
        } else {
            parts.append(PermissionMode.shortTitle(of: settings.permissionMode).lowercased())
        }
        return parts.joined(separator: " · ")
    }

    private func emptySessions(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No sessions yet")
                .font(.system(size: 14, weight: .semibold))
            Text("Start a session when you are ready to work in this project.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            ActionButton(title: "Start a new session", tone: .green) {
                requestNewSession(in: project)
            }
            .disabled(store.isMissing(project))
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    // MARK: - Reading a session

    private func tone(_ session: ChatSession) -> SessionTone {
        SessionTone(session.id, store: store, runner: runner)
    }

    private func location(_ session: ChatSession, project: Project) -> String {
        let path = session.worktreePath ?? project.path
        let count = workingTrees.uncommittedFileCount(at: path)
        let state = count == 0 ? "clean" : "\(count) uncommitted"
        return "\(path.abbreviatedPath) · \(state)"
    }

    private func branch(_ session: ChatSession, project: Project) -> String? {
        session.worktreeBranch ?? GitHead.branch(at: project.path)
    }

    private func sessionMenu(_ session: ChatSession, project: Project) -> [MenuEntry] {
        [
            .item("Open session") { store.selectSession(session.id) },
            .item("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: session.worktreePath ?? project.path)])
            },
            .separator,
            .item(session.worktreePath == nil ? "Delete session" : "Remove worktree",
                  kind: .destructive) { confirmRemove(session) }
        ]
    }

    // A worktree is represented by its session everywhere else. The only separate rows
    // are registered app checkouts which no session points at any more.
    private func orphanedStrip(_ project: Project) -> some View {
        let count = orphanedWorktrees.count
        return HStack(spacing: 11) {
            Text("ORPHANED")
                .font(.mono(9.5, .semibold))
                .kerning(1.1)
                .foregroundStyle(Theme.attentionText)
            Text("\(count) worktree\(count == 1 ? "" : "s") with no session")
                .font(.system(size: 12.5, weight: .semibold))
                .fixedSize()
            Text(orphanedSummary)
                .font(.mono(10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            ActionButton(title: pruningOrphans ? "Pruning…" : "Prune all",
                         tone: .outlined, height: 28, size: 11.5) {
                confirmPruneOrphans(project)
            }
            .disabled(pruningOrphans)
            .opacity(pruningOrphans ? 0.55 : 1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.attention.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Theme.attention.opacity(0.35), lineWidth: 1.2))
    }

    private var orphanedSummary: String {
        var parts = orphanedWorktrees.compactMap(\.branch)
        let bytes = orphanedWorktrees.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        if bytes > 0 { parts.append(bytes.formatted(.byteCount(style: .file))) }
        return parts.joined(separator: " · ")
    }

    private func activeWorktreePaths(for project: Project) -> Set<String> {
        Set(store.sessions.flatMap { session in
            store.checkoutProjects(for: session).compactMap { checkout in
                checkout.projectID == project.id ? checkout.worktreePath : nil
            }
        })
    }

    private func orphanRefreshID(_ project: Project) -> [String] {
        let active = activeWorktreePaths(for: project)
        let pending = store.pendingSessionRemovals.flatMap(\.worktrees)
            .filter { $0.projectPath == project.path }
            .map { "pending:" + $0.path }
        return (Array(active) + pending).sorted()
    }

    private func refreshWorktrees(for project: Project) async {
        let active = activeWorktreePaths(for: project)
        workingTrees.refresh(active.union([project.path]))
        orphanedWorktrees = await GitWorktree.orphaned(
            projectPath: project.path, excluding: active)
    }

    // MARK: - Terminal

    private func terminalShortcut(_ project: Project) -> some View {
        Button("") {
            if !terminals.isOpen(terminalScope) {
                terminals.setOpen(true, for: terminalScope, directory: project.path)
                terminalFocused = true
            } else {
                terminalFocused.toggle()
            }
        }
        .keyboardShortcut("`", modifiers: .control)
        .opacity(0)
        .disabled(store.isMissing(project))
    }

    private func toggleTerminal(directory: String) {
        let opening = !terminals.isOpen(terminalScope)
        terminals.setOpen(opening, for: terminalScope, directory: directory)
        terminalFocused = opening
    }

    // The banner asks for a removal, so it carries the button for it: the same action
    // sits in the sidebar's context menu, which is not where someone reading this looks.
    private func missingFolder(_ project: Project) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Folder not found at \(project.collapsedPath). Move it back or remove the project before starting a session.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            ActionButton(title: "Remove project", tone: .outlined, height: 28, size: 11.5) {
                ProjectRemoval.confirm(project, in: store, runner: runner, shortcuts: shortcuts,
                               dialogs: dialogs)
            }
            .fixedSize()
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.warningText)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Theme.warningBackground)
    }

    // MARK: - Creating and removing

    // Every session chooses its conversation mode up front. Git repositories also offer
    // an isolated worktree, while plain folders show only their direct folder.
    private func requestNewSession(in project: Project) {
        guard !store.isMissing(project) else { return }
        choosingSessionKind = project
    }

    private func startSession(_ choice: NewSessionChoice, in project: Project) {
        switch choice {
        case .worktree(let sessionID, let base, let agent, let model, let agentAvatarName,
                       let mode):
            createWorktreeSession(in: project, id: sessionID, base: base, agent: agent,
                                  model: model, agentAvatarName: agentAvatarName, mode: mode)
        case .folder(let sessionID, let agent, let model, let agentAvatarName, let mode):
            switch store.insertSession(
                in: project.id,
                seed: .init(id: sessionID, agent: agent, model: model,
                            agentAvatarName: agentAvatarName, mode: mode)) {
            case .success:
                break
            case .failure(let failure):
                dialogs.show(Dialog(
                    title: "Could not create the session",
                    message: failure.message,
                    actions: [.init(label: "OK", kind: .cancel)]))
            }
        }
    }

    private func createWorktreeSession(in project: Project, id sessionID: UUID, base: String?,
                                       agent: AgentKind, model: String?, agentAvatarName: String?,
                                       mode: SessionMode) {
        Task {
            switch await SessionLifecycle.createWorktreeSession(
                in: project, id: sessionID, base: base,
                agent: agent, model: model,
                agentAvatarName: agentAvatarName, mode: mode, store: store) {
            case .success:
                break
            case .failure(let failure):
                dialogs.show(Dialog(
                    title: failure.title,
                    message: failure.message,
                    actions: [.init(label: "OK", kind: .cancel)]))
            }
        }
    }

    private func confirmRemove(_ session: ChatSession) {
        dialogs.show(SessionRemoval.confirmation(for: session, in: store,
                                                 workingTrees: workingTrees) {
            remove([session])
        })
    }

    private func confirmPruneOrphans(_ project: Project) {
        let count = orphanedWorktrees.count
        guard count > 0 else { return }
        dialogs.show(Dialog(
            title: "Prune \(count) orphaned worktree\(count == 1 ? "" : "s")?",
            message: "These checkouts have no session. Any uncommitted changes in them will be lost. Branches are kept when they have unmerged commits.",
            actions: [
                .init(label: "Prune all", kind: .destructive) { pruneOrphans(project) },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    private func pruneOrphans(_ project: Project) {
        let orphans = orphanedWorktrees
        pruningOrphans = true
        Task {
            var messages: [String] = []
            for orphan in orphans {
                if case .failure(let failure) = await GitWorktree.remove(
                    worktreePath: orphan.path,
                    projectPath: project.path,
                    branch: orphan.branch) {
                    messages.append(failure.message)
                }
            }
            messages += await SessionLifecycle.resumePendingRemovals(in: store).map(\.message)
            await refreshWorktrees(for: project)
            pruningOrphans = false
            guard !messages.isEmpty else { return }
            dialogs.show(Dialog(
                title: "Could not prune some worktrees",
                message: messages.joined(separator: "\n"),
                actions: [.init(label: "OK", kind: .cancel)]))
        }
    }

    private func remove(_ sessions: [ChatSession]) {
        Task {
            if case .failure(let failure) = await SessionRemoval.run(
                sessions, in: store, runner: runner) {
                dialogs.show(Dialog(title: failure.title, message: failure.message,
                                    actions: [.init(label: "OK", kind: .cancel)]))
            }
        }
    }

    private func reveal(_ project: Project) {
        NSWorkspace.shared.activateFileViewerSelecting([project.url])
    }
}

// One session as a row. Project and Workspace share it, so the two screens cannot drift
// apart on what a session is: state and title on the left, what it is doing and where in
// the middle, and its diff, last activity and menu on the right. The row itself opens the
// session, leaving the scarce trailing space for actions that are not available elsewhere.
struct SessionRow: View {
    // Where the session's files live. A single project says it in one line; a workspace
    // names its first repositories and keeps the complete checkout detail in a tooltip.
    enum Detail {
        case location(String)
        case repositories([Repository])
    }

    struct Repository: Identifiable {
        let id: UUID
        let name: String
        let usesWorktree: Bool
        let tint: Theme.ProjectTint
    }

    let session: ChatSession
    let tone: SessionTone
    let branch: String?
    let activity: String
    let detail: Detail
    let onOpen: () -> Void
    let menu: () -> [MenuEntry]

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    StateLight(tone: tone)
                    Text(tone.word)
                        .font(.mono(9, .semibold))
                        .kerning(0.9)
                        .foregroundStyle(tone.colour)
                    if let branch {
                        Text(branch)
                            .font(.mono(9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text(session.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 320, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text(activity)
                    .font(.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch detail {
                case .location(let text):
                    Text(text)
                        .font(.mono(10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                case .repositories(let repositories):
                    repositoryDetails(repositories)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                DiffPair(added: session.summary.added,
                         removed: session.summary.removed, size: 11.5, spacing: 6)
                Text(RelativeTime.stamp(session.lastActivity))
                    .font(.mono(10.5))
                    .foregroundStyle(.tertiary)
            }

            // Destructive actions live in the menu: a bare bin in a row is one
            // mis-click from losing a conversation.
            GlyphButton(icon: "ellipsis")
                .appMenu(menu)
                .appTooltip("More session actions")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(hovering ? Theme.field : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(tone.ring, lineWidth: tone.ringWidth))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: onOpen)
        .accessibilityAction(named: "Open session", onOpen)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private func repositoryDetails(_ repositories: [Repository]) -> some View {
        if repositories.isEmpty {
            Text("No repositories")
                .font(.mono(10.5))
                .foregroundStyle(.tertiary)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    ForEach(Array(repositories.prefix(2))) { repository in
                        repositoryChip(repository,
                                       showsMode: hasMixedCheckoutModes(repositories))
                    }
                    if repositories.count > 2 {
                        MonoChip(text: "+\(repositories.count - 2)", size: 9.5)
                    }
                    if !hasMixedCheckoutModes(repositories) {
                        Text(checkoutSummary(repositories))
                            .font(.mono(9.5, .semibold))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                }
                .fixedSize(horizontal: true, vertical: false)

                HStack(spacing: 7) {
                    ProjectDot(tint: repositories[0].tint, size: 5)
                    Text("\(repositories.count) repositories")
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(checkoutSummary(repositories))
                }
                .font(.mono(10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

                Text("\(repositories.count) repositories · \(checkoutSummary(repositories))")
                    .font(.mono(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .appTooltip {
                Tooltip(
                    title: "Repositories in this session",
                    rows: repositories.map {
                        Tooltip.Row(label: $0.name,
                                    value: $0.usesWorktree ? "Worktree" : "Folder")
                    })
            }
        }
    }

    private func repositoryChip(_ repository: Repository, showsMode: Bool) -> some View {
        HStack(spacing: 5) {
            ProjectDot(tint: repository.tint, size: 5)
            Text(repository.name)
                .font(.mono(10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if showsMode {
                Text("· \(repository.usesWorktree ? "worktree" : "folder")")
                    .font(.mono(9.5, .semibold))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.field))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func hasMixedCheckoutModes(_ repositories: [Repository]) -> Bool {
        repositories.contains(where: \.usesWorktree)
            && repositories.contains { !$0.usesWorktree }
    }

    private func checkoutSummary(_ repositories: [Repository]) -> String {
        let worktrees = repositories.count(where: \.usesWorktree)
        let folders = repositories.count - worktrees
        if folders == 0 { return count(worktrees, singular: "worktree") }
        if worktrees == 0 { return count(folders, singular: "folder") }
        return "\(count(worktrees, singular: "worktree")) · \(count(folders, singular: "folder"))"
    }

    private func count(_ value: Int, singular: String) -> String {
        "\(value) \(singular)\(value == 1 ? "" : "s")"
    }
}
