import AppKit
import SwiftUI

// The state of one repository and the sessions running in it: what git thinks of the
// folder, which worktrees are still checked out, and every conversation that has touched
// it. Opening a session is the point where its transcript takes over the pane.
struct ProjectDetailView: View {
    let projectID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
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

    private var terminalScope: TerminalScope { .project(projectID) }

    var body: some View {
        if let project = store.project(projectID) {
            VStack(spacing: 0) {
                header(project)
                if store.isMissing(project) { missingFolder(project) }
                content(project)
                if terminals.isOpen(terminalScope) {
                    TerminalDrawer(scope: terminalScope,
                                   directory: project.path,
                                   focusTerminal: $terminalFocused)
                }
            }
            .background(Theme.background)
            .background(terminalShortcut(project))
            .task(id: project.path) {
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

    private func header(_ project: Project) -> some View {
        HStack(spacing: 12) {
            ProjectDot(tint: Theme.projectTint(for: project.name))
            Text(project.name)
                .font(.serif(17, .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(project.collapsedPath)
                .font(.mono(10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .layoutPriority(-1)
            if let summary = gitChip { MonoChip(text: summary) }

            Spacer(minLength: 12)

            // Held at their natural width so a long project name is what gives way,
            // rather than the controls shrinking until their labels wrap.
            HStack(spacing: 12) {
                HeaderTabToggle(selection: $tab,
                                options: [("Sessions", .sessions),
                                          ("Changes", .changes),
                                          ("Explorer", .explorer)])
                TerminalToggle(isOpen: terminals.isOpen(terminalScope)) {
                    toggleTerminal(directory: project.path)
                }
                .disabled(store.isMissing(project))
                .opacity(store.isMissing(project) ? 0.4 : 1)

                ActionButton(title: "New session", tone: .green, size: 12) {
                    requestNewSession(in: project)
                }
                .disabled(store.isMissing(project))
                .opacity(store.isMissing(project) ? 0.45 : 1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, 24)
        .headerBand()
    }

    // "main · 3 dirty": the two things about a repository worth carrying in a header.
    private var gitChip: String? {
        guard let git, git.state == .ready, !git.branch.isEmpty else { return nil }
        let dirty = git.files.count
        return dirty == 0 ? "\(git.branch) · clean" : "\(git.branch) · \(dirty) dirty"
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
                repository(project)
                sessionList(project, sessions: available)
                defaults(project)
            }
            .padding(24)
        }
    }

    private func repository(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionRule(title: "REPOSITORY") {
                InlineLink(title: "Reveal in Finder") { reveal(project) }
            }

            if let git, git.state == .ready {
                HStack(alignment: .top, spacing: 24) {
                    figure("BRANCH", value: git.branch.isEmpty ? "—" : git.branch)
                    figure("AHEAD / BEHIND", value: "\(git.ahead) / \(git.behind)")
                    figure("UNCOMMITTED",
                           value: git.files.isEmpty ? "clean" : "\(git.files.count) files",
                           tone: git.files.isEmpty ? nil : Theme.attentionText)
                    lastCommit(git)
                }
            } else {
                Text(gitUnavailable)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
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

    private func figure(_ label: String, value: String, tone: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.mono(9.5))
                .kerning(1.1)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.mono(13, .semibold))
                .foregroundStyle(tone ?? Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func lastCommit(_ git: GitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LAST COMMIT")
                .font(.mono(9.5))
                .kerning(1.1)
                .foregroundStyle(.tertiary)
            Text(git.lastCommitSubject.map { subject in
                git.lastCommitDate.map { "\(RelativeTime.short($0)) ago · \(subject)" } ?? subject
            } ?? "nothing committed yet")
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func missingFolder(_ project: Project) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Folder not found at \(project.collapsedPath). Move it back or remove the project before starting a session.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ChatColor.warningText)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(ChatColor.warningBackground)
    }

    // MARK: - Creating and removing

    // A git repository gets the folder-or-worktree choice; a plain folder can start
    // directly because there is no checkout choice to make.
    private func requestNewSession(in project: Project) {
        guard !store.isMissing(project) else { return }
        guard project.isGitRepository else {
            startSession(.folder(agent: runner.agent,
                                 model: runner.defaults.model,
                                 agentAvatarName: appSettings.defaultAgentAvatarName),
                         in: project)
            return
        }
        choosingSessionKind = project
    }

    private func startSession(_ choice: NewSessionChoice, in project: Project) {
        switch choice {
        case .worktree(let sessionID, let base, let agent, let model, let agentAvatarName):
            createWorktreeSession(in: project, id: sessionID, base: base, agent: agent,
                                  model: model, agentAvatarName: agentAvatarName)
        case .folder(let agent, let model, let agentAvatarName):
            switch store.insertSession(in: project.id, agent: agent, model: model,
                                       agentAvatarName: agentAvatarName) {
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
                                       agent: AgentKind, model: String?, agentAvatarName: String?) {
        Task {
            switch await SessionLifecycle.createWorktreeSession(
                in: project, id: sessionID, base: base,
                agent: agent, model: model,
                agentAvatarName: agentAvatarName, store: store) {
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
        let worktree = session.worktreePath
        dialogs.show(Dialog(
            title: worktree == nil
                ? "Delete \"\(session.title)\"?"
                : "Remove the worktree for \"\(session.title)\"?",
            message: worktree.map { path in
                let changes = workingTrees.isDirty(path)
                    ? "Its worktree at \(path.abbreviatedPath) has uncommitted changes, and they are lost with it."
                    : "Its worktree at \(path.abbreviatedPath) goes with it, along with anything uncommitted there."
                return changes + " The session goes with the worktree. The branch is kept if it has unmerged commits."
            } ?? "Its conversation history is removed from the app.",
            actions: [
                .init(label: worktree == nil ? "Delete session" : "Remove worktree and session",
                      kind: .destructive) {
                    remove([session])
                },
                .init(label: "Cancel", kind: .cancel)
            ]))
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
            var failures: [SessionLifecycle.Failure] = []
            for session in sessions {
                if case .failure(let failure) = await SessionLifecycle.remove(
                    session, from: store, runner: runner) {
                    failures.append(failure)
                }
            }
            guard !failures.isEmpty else { return }
            dialogs.show(Dialog(
                title: failures.count == 1 ? failures[0].title : "Could not delete some sessions",
                message: failures.map(\.message).joined(separator: "\n"),
                actions: [.init(label: "OK", kind: .cancel)]))
        }
    }

    private func reveal(_ project: Project) {
        NSWorkspace.shared.activateFileViewerSelecting([project.url])
    }
}

// One session as a row. Project and Workspace share it, so the two screens cannot drift
// apart on what a session is: state and title on the left, what it is doing and where in
// the middle, its diff and last activity on the right, and one way in.
struct SessionRow: View {
    // Where the session's files live. A single project says it in one line; a workspace
    // has one chip per repository, so mixed checkout modes are visible at a glance.
    enum Detail {
        case location(String)
        case repositories([Repository])
    }

    struct Repository: Identifiable {
        let id: UUID
        let label: String
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
            .frame(width: 320, alignment: .leading)

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
                    HStack(spacing: 7) {
                        ForEach(repositories) { repository in
                            HStack(spacing: 5) {
                                ProjectDot(tint: repository.tint, size: 5)
                                Text(repository.label)
                                    .font(.mono(10))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.field))
                        }
                    }
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

            HStack(spacing: 7) {
                ActionButton(title: "Open", height: 30, size: 12, action: onOpen)
                // Destructive actions live in the menu: a bare bin in a row is one
                // mis-click from losing a conversation.
                GlyphButton(icon: "ellipsis")
                    .appMenu(menu)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(hovering ? Theme.field : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(tone.ring, lineWidth: tone.ringWidth))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: onOpen)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}
