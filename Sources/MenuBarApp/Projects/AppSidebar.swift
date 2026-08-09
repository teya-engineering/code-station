import AppKit
import SwiftUI

// The left navigation for the whole window: every project with its sessions, plus a
// pinned button that opens the app's tools and settings.
struct AppSidebar: View {
    let skills: SkillsManager
    let onConfigureServers: () -> Void
    let onOpenSkills: () -> Void
    let onOpenDocker: () -> Void
    let onOpenSettings: () -> Void
    let onOpenPostman: () -> Void
    let onOpenAI: () -> Void
    let onOpenTroubleshoot: () -> Void
    let onReviewOldSessions: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(AppSettings.self) private var appSettings
    @Environment(WorkingTreeWatch.self) private var workingTrees
    @Environment(ConfigStore.self) private var configs
    @Environment(DockerService.self) private var docker
    @Environment(PostmanAuthStore.self) private var postmanAuth
    @Environment(AIService.self) private var ai

    // A project is expanded by default while it is the selected one. Explicit choices
    // win over that default and are restored when the app opens again.
    @State private var expansion = Preferences.sidebarExpansion
    @State private var renamingID: UUID?
    @State private var choosingSessionKind: Project?
    @State private var choosingWorkspaceSession: ProjectWorkspace?
    @State private var showingNewWorkspace = false
    // A session that has just been created and has not been brought into view yet. Only
    // sessions the app itself opens are worth scrolling to: one the user clicked was
    // already under the pointer.
    @State private var sessionToReveal: UUID?
    // Projects whose full session list is shown. Anything else stops at the cap, with a
    // card that says how many are folded away: a project with dozens of sessions would
    // otherwise push every other project off the rail.
    @State private var showingAllSessions: Set<UUID> = []
    @State private var filterText = ""
    @State private var oldSessionSummary = OldSessionSummary()

    private static let sessionCap = 3
    private static let oldSessionRefreshInterval: Duration = .seconds(3_600)

    private struct OldSessionSummary: Equatable {
        var sessions = 0
        var worktrees = 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            projectList
            Spacer(minLength: 0)
            bottomBar
        }
        .frame(width: 330)
        .background(Theme.sidebar)
        .task { await watchWorkingTrees() }
        .task(id: oldSessionDays) { await refreshOldSessionsHourly() }
        .onChange(of: store.sessions.count) { _, _ in refreshOldSessions() }
        .sheet(item: $choosingSessionKind) { project in
            NewSessionView(project: project) { choice in
                startSession(choice, in: project)
            }
            .appOverlays()
        }
        .sheet(item: $choosingWorkspaceSession) { workspace in
            NewWorkspaceSessionView(workspace: workspace) { choice in
                startWorkspaceSession(choice, in: workspace)
            }
            .appOverlays()
        }
        .sheet(isPresented: $showingNewWorkspace) {
            NewWorkspaceView { workspace in
                setExpanded(true, for: workspace.id)
                choosingWorkspaceSession = workspace
            }
            .appOverlays()
        }
    }

    // MARK: - Heading

    private var heading: some View {
        let notices = sessionNotices
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let logo = AppArt.logo {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 40, height: 40)
                        // The art carries its own margin, so it is pulled back to sit on
                        // the same left edge as the text below it.
                        .padding(.leading, -6)
                }
                Text("Teya Conductor")
                    .font(.serif(18, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                if !notices.isEmpty {
                    let active = notices.filter { $0.notice != .finished }.count
                    StatusPill(text: active > 0 ? "\(active) RUNNING" : "\(notices.count) FINISHED",
                               running: active > 0,
                               tint: active > 0 ? nil : Theme.attention,
                               disclosure: true)
                        .appMenu { sessionNoticeMenu }
                        .appTooltip("Show active and unread sessions")
                }
            }
            .padding(.horizontal, 20)
            .headerBand(Theme.sidebar)

            sortBar
            filterBar
        }
    }

    // The order decides what the whole rail under it means, so it sits above the list in
    // the open rather than behind a menu.
    private var sortBar: some View {
        HStack(spacing: 6) {
            Text("SORT")
                .font(.mono(9.5, .semibold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            ForEach(ProjectSort.allCases) { option in
                SortChip(title: option.label,
                         hint: option.hint,
                         selected: appSettings.projectSort == option) {
                    appSettings.projectSort = option
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // Narrows the list to projects whose name contains what is typed. It filters rather
    // than searches: the rail keeps its order and simply drops the rows that do not match.
    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("Filter projects", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .appTooltip("Clear filter")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private struct NoticedSession {
        let session: ChatSession
        let project: Project
        let notice: SessionNotice
    }

    private var sessionNotices: [NoticedSession] {
        store.sessions.compactMap { session in
            guard let project = store.project(session.projectID),
                  let notice = SessionNotice(
                    isBusy: runner.state(session.id).isBusy,
                    needsInput: runner.question(session.id) != nil,
                    finishedUnseen: store.hasFinished(session.id)) else { return nil }
            return NoticedSession(session: session, project: project, notice: notice)
        }
        .sorted {
            if $0.notice != $1.notice { return $0.notice.rawValue < $1.notice.rawValue }
            return $0.session.lastActivity > $1.session.lastActivity
        }
    }

    private var sessionNoticeMenu: [MenuEntry] {
        let notices = sessionNotices
        var entries: [MenuEntry] = []
        for (index, noticed) in notices.enumerated() {
            if index > 0, notices[index - 1].notice != noticed.notice {
                entries.append(.separator)
            }
            entries.append(.item(
                noticed.session.title,
                checked: isSelected(noticed.session),
                badge: noticed.notice.badge,
                badgeTint: noticed.notice.tint,
                subtitle: noticed.session.workspaceID.flatMap(store.workspace)?.name
                    ?? noticed.project.name,
                detail: RelativeTime.short(noticed.session.lastActivity)) {
                    store.selectSession(noticed.session.id)
                })
        }
        return entries
    }

    // MARK: - Projects

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.projects.isEmpty && store.workspaces.isEmpty {
                Text("No projects yet. Add a folder and Claude Code will run right inside it.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            } else if orderedProjects.isEmpty && orderedWorkspaces.isEmpty {
                Text("No project or workspace matches \"\(filterText.trimmingCharacters(in: .whitespaces))\".")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            } else {
                // Grouped once per redraw: every row below reads from this, and a
                // streaming reply redraws the rail on every token.
                let grouped = groupedSessions
                let workspaceGroups = groupedWorkspaceSessions
                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(orderedWorkspaces) { workspace in
                                workspaceSection(workspace,
                                                 sessions: workspaceGroups[workspace.id] ?? [])
                                    .id(workspace.id)
                            }
                            ForEach(orderedProjects) { project in
                                projectSection(project, sessions: grouped[project.id] ?? [])
                                    .id(project.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                        // Keyed on what decides whether a session block is on screen, so the
                        // reveal plays wherever the change came from: a click on the project
                        // row, or the first session arriving under an already open one.
                        // Easing out rather than a spring: the block must not overshoot its
                        // own height, or it opens onto a gap under the last card.
                        .animation(.easeOut(duration: 0.26),
                                   value: revealKey(grouped, workspaceGroups: workspaceGroups))
                        .animation(.easeOut(duration: 0.22), value: appSettings.projectSort)
                        .animation(.easeOut(duration: 0.22), value: filterText)
                    }
                    .task(id: sessionToReveal) { await reveal(with: scroller) }
                }
            }
        }
    }

    private var orderedProjects: [Project] {
        let ordered = appSettings.projectSort.apply(to: store.projects, sessions: store.sessions)
        let query = filterText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return ordered }
        return ordered.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var orderedWorkspaces: [ProjectWorkspace] {
        let ordered = store.workspaces.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let query = filterText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return ordered }
        return ordered.filter { workspace in
            workspace.name.localizedCaseInsensitiveContains(query)
                || workspace.projectIDs.compactMap(store.project)
                    .contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
    }

    // Every session under its project, newest first - the order the cards are drawn in.
    private var groupedSessions: [UUID: [ChatSession]] {
        var groups = Dictionary(grouping: store.sessions.filter { $0.workspaceID == nil },
                                by: \.projectID)
        for key in groups.keys { groups[key]?.sort { $0.createdAt > $1.createdAt } }
        return groups
    }

    private var groupedWorkspaceSessions: [UUID: [ChatSession]] {
        let groups = Dictionary(grouping: store.sessions.compactMap { session in
            session.workspaceID.map { ($0, session) }
        }, by: \.0)
        return groups.mapValues { rows in rows.map(\.1).sorted { $0.createdAt > $1.createdAt } }
    }

    private func workspaceSection(_ workspace: ProjectWorkspace,
                                  sessions: [ChatSession]) -> some View {
        let expanded = isExpanded(workspace)
        let running = sessions.filter { runner.state($0.id).isBusy }.count
        let projects = workspace.projectIDs.compactMap(store.project)

        return VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeaderRow(
                workspace: workspace,
                projects: projects,
                selected: store.selection == .workspace(workspace.id),
                isExpanded: expanded,
                sessionCount: sessions.count,
                runningCount: running,
                finishedCount: store.finishedCount(inWorkspace: workspace.id),
                onNewSession: { choosingWorkspaceSession = workspace }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                store.selectWorkspace(workspace.id)
                setExpanded(!expanded, for: workspace.id)
                if expanded { showingAllSessions.remove(workspace.id) }
            }
            .appContextMenu {
                [.item("New session") { choosingWorkspaceSession = workspace }]
            }

            if expanded, !sessions.isEmpty {
                let visible = visibleWorkspaceSessions(workspace, sessions: sessions)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(visible) { session in
                        if let lead = store.project(session.projectID) {
                            let busy = runner.state(session.id).isBusy
                            let finished = store.hasFinished(session.id)
                            let folders = store.workingDirectories(for: session)
                            SessionCard(session: session,
                                        selected: isSelected(session),
                                        busy: busy,
                                        finished: finished,
                                        activity: activitySummary(session, project: lead,
                                                                  busy: busy, finished: finished),
                                        added: session.summary.added,
                                        removed: session.summary.removed,
                                        branch: workspaceBranch(session),
                                        uncommitted: folders.contains(where: workingTrees.isDirty),
                                        onDelete: { confirmRemoveSession(session) })
                                .contentShape(Rectangle())
                                .onTapGesture { store.selectSession(session.id) }
                                .appContextMenu {
                                    [.item("Delete session", kind: .destructive) {
                                        confirmRemoveSession(session)
                                    }]
                                }
                        }
                    }
                    if sessions.count > Self.sessionCap {
                        let hidden = sessions.count - visible.count
                        SeeMoreCard(title: hidden > 0 ? "See \(hidden) more…" : "Show fewer") {
                            if hidden > 0 {
                                showingAllSessions.insert(workspace.id)
                            } else {
                                showingAllSessions.remove(workspace.id)
                            }
                        }
                    }
                }
                .padding(.leading, 14)
                .padding(.top, 6)
                .transition(.reveal)
            }
        }
    }

    private func visibleWorkspaceSessions(_ workspace: ProjectWorkspace,
                                          sessions: [ChatSession]) -> [ChatSession] {
        guard sessions.count > Self.sessionCap,
              !showingAllSessions.contains(workspace.id) else { return sessions }
        return Array(sessions.prefix(Self.sessionCap))
    }

    private func workspaceBranch(_ session: ChatSession) -> String? {
        let checkouts = store.checkoutProjects(for: session)
        let branches = checkouts.compactMap(\.worktreeBranch)
        guard let first = branches.first else {
            return "\(checkouts.count) projects"
        }
        return branches.allSatisfy { $0 == first }
            ? "\(first) · \(checkouts.count) repos"
            : "\(checkouts.count) repos"
    }

    private func projectSection(_ project: Project, sessions: [ChatSession]) -> some View {
        let expanded = isExpanded(project)
        let running = sessions.filter { runner.state($0.id).isBusy }.count

        // The row and its sessions are one stack so the gap between them belongs to the
        // block that slides: an outer spacing would stay behind for a frame as the block
        // goes, which reads as the row jumping at the end of the close.
        return VStack(alignment: .leading, spacing: 0) {
            ProjectHeaderRow(
                project: project,
                isExpanded: expanded,
                isMissing: store.isMissing(project),
                sessionCount: sessions.count,
                runningCount: running,
                finishedCount: store.finishedCount(in: project.id),
                cost: sessions.reduce(0) { $0 + ($1.usage?.costUSD ?? 0) },
                clearableCount: sessions.count - running,
                isRenaming: renamingID == project.id,
                onNewSession: { requestNewSession(in: project) },
                onClearSessions: { confirmClearSessions(in: project) },
                onRename: { name in
                    store.renameProject(project.id, to: name)
                    renamingID = nil
                },
                onCancelRename: { renamingID = nil }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                store.selectProject(project.id)
                setExpanded(!expanded, for: project.id)
                // Closing a project puts its list away, and putting it away includes the
                // tail the user had unfolded: the next open starts back at the cap.
                if expanded { showingAllSessions.remove(project.id) }
            }
            .appContextMenu {
                [.item("Rename…") { renamingID = project.id },
                 .item("New session") { requestNewSession(in: project) },
                 .separator,
                 .item("Reveal in Finder") {
                     NSWorkspace.shared.activateFileViewerSelecting([project.url])
                 },
                 .item("Open in Terminal") { openInTerminal(project) },
                 .separator,
                 .item("Clear idle sessions", kind: .destructive) { confirmClearSessions(in: project) },
                 .item("Remove project", kind: .destructive) { confirmRemoveProject(project) }]
            }

            // An expanded project with nothing under it draws no block at all: an empty one
            // still carries its padding, which reads as the row shifting on every click.
            if expanded, !sessions.isEmpty {
                let visible = visibleSessions(of: project, in: sessions)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(visible) { session in
                        let busy = runner.state(session.id).isBusy
                        let finished = store.hasFinished(session.id)
                        SessionCard(session: session,
                                    selected: isSelected(session),
                                    busy: busy,
                                    finished: finished,
                                    activity: activitySummary(session, project: project,
                                                              busy: busy, finished: finished),
                                    added: session.summary.added,
                                    removed: session.summary.removed,
                                    branch: branch(session, project: project),
                                    uncommitted: workingTrees.isDirty(folder(session, project: project)),
                                    onDelete: { confirmRemoveSession(session) })
                            .contentShape(Rectangle())
                            .onTapGesture {
                                store.selectSession(session.id)
                            }
                            .appContextMenu {
                                [.item("Delete session", kind: .destructive) {
                                    confirmRemoveSession(session)
                                }]
                            }
                    }
                    if sessions.count > Self.sessionCap {
                        let hidden = sessions.count - visible.count
                        SeeMoreCard(title: hidden > 0 ? "See \(hidden) more…" : "Show fewer") {
                            if hidden > 0 {
                                showingAllSessions.insert(project.id)
                            } else {
                                showingAllSessions.remove(project.id)
                            }
                        }
                    }
                }
                // Sessions sit inset from their project row, so the nesting is visible
                // without a line or a marker to draw it.
                .padding(.leading, 14)
                .padding(.top, 6)
                .transition(.reveal)
            }
        }
    }

    private func isExpanded(_ project: Project) -> Bool {
        expansion[project.id] ?? (project.id == store.selectedProject?.id)
    }

    private func isExpanded(_ workspace: ProjectWorkspace) -> Bool {
        expansion[workspace.id] ?? true
    }

    private func setExpanded(_ isExpanded: Bool, for id: UUID) {
        expansion[id] = isExpanded
        Preferences.sidebarExpansion = expansion
    }

    // The cards a project actually draws: all of them once the user has asked to see
    // more, the newest few otherwise. Newest-first order means what is folded away is
    // the tail that matters least.
    private func visibleSessions(of project: Project, in sessions: [ChatSession]) -> [ChatSession] {
        guard sessions.count > Self.sessionCap,
              !showingAllSessions.contains(project.id) else { return sessions }
        return Array(sessions.prefix(Self.sessionCap))
    }

    // Keyed on the cards that are drawn rather than the sessions that exist, so the
    // slide plays for see-more the same as for a session arriving or leaving.
    private func revealKey(_ grouped: [UUID: [ChatSession]],
                           workspaceGroups: [UUID: [ChatSession]]) -> [UUID: Int] {
        var key: [UUID: Int] = [:]
        for project in store.projects where isExpanded(project) {
            key[project.id] = visibleSessions(of: project, in: grouped[project.id] ?? []).count
        }
        for workspace in store.workspaces where isExpanded(workspace) {
            key[workspace.id] = visibleWorkspaceSessions(
                workspace, sessions: workspaceGroups[workspace.id] ?? []).count
        }
        return key
    }

    // Brings a session the app has just opened into view. It scrolls to the project rather
    // than to the card, so what arrives on screen is the whole block with its row: a card on
    // its own, pinned to the top edge with its project above the fold, does not say what was
    // opened. The newest session sorts first, so it is the card directly under that row.
    //
    // Creating a session also reorders the list under the recent sort, which is what makes
    // this needed at all: the project leaves wherever the user was looking and lands at the
    // top, off screen.
    private func reveal(with scroller: ScrollViewProxy) async {
        guard let id = sessionToReveal, let session = store.session(id) else { return }
        // The card is created by the same change that asked for this, so the list has to be
        // laid out again before there is anything to scroll to.
        await Task.yield()
        withAnimation(.easeOut(duration: 0.26)) {
            scroller.scrollTo(session.workspaceID ?? session.projectID, anchor: .top)
        }
    }

    // MARK: - Creating and removing sessions

    // A git repository gets the folder-or-worktree choice; a plain folder has no
    // worktrees to offer, so the session is just created.
    private func requestNewSession(in project: Project) {
        guard FileManager.default.fileExists(atPath: project.path + "/.git") else {
            startSession(.folder(agent: runner.agent), in: project)
            return
        }
        choosingSessionKind = project
    }

    private func startSession(_ choice: NewSessionChoice, in project: Project) {
        // A collapsed project keeps its new session hidden, and starting work in a project
        // is the clearest sign yet that it wants to be open.
        setExpanded(true, for: project.id)
        switch choice {
        case .worktree(let sessionID, let base, let agent):
            createWorktreeSession(in: project, id: sessionID, base: base, agent: agent)
        case .folder(let agent):
            switch store.insertSession(in: project.id) {
            case .success(let session):
                runner.agent = agent
                sessionToReveal = session.id
            case .failure(let failure):
                showLifecycleFailure(SessionLifecycle.Failure(
                    title: "Could not create the session", message: failure.message))
            }
        }
    }

    // Worktrees are created as one transaction from the user's point of view. If any
    // repository fails, the ones already created are removed before the error is shown.
    private func startWorkspaceSession(_ choice: WorkspaceSessionChoice,
                                       in workspace: ProjectWorkspace) {
        setExpanded(true, for: workspace.id)
        Task {
            switch await SessionLifecycle.createWorkspaceSession(
                choice, in: workspace, store: store) {
            case .success:
                runner.agent = choice.agent
                sessionToReveal = choice.sessionID
            case .failure(let failure):
                showLifecycleFailure(failure)
            }
        }
    }

    private func confirmRemoveSession(_ session: ChatSession) {
        let worktrees = store.checkoutProjects(for: session).compactMap(\.worktreePath)
        let dirty = worktrees.filter(workingTrees.isDirty).count
        dialogs.show(Dialog(
            title: "Delete \"\(session.title)\"?",
            message: worktrees.isEmpty
                ? "Its conversation history is removed from the app."
                : "Its \(worktrees.count) worktree\(worktrees.count == 1 ? "" : "s") go with it."
                    + (dirty > 0
                       ? " \(dirty) \(dirty == 1 ? "has" : "have") uncommitted changes that will be lost."
                       : " Branches are kept if they have unmerged commits."),
            actions: [
                .init(label: worktrees.isEmpty ? "Delete session" : "Delete session and worktrees",
                      kind: .destructive) {
                    removeSessions([session])
                },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    // Clearing a project keeps whatever is still running and takes the rest, worktrees
    // included. The message counts the worktrees separately: they are the part of this
    // that touches disk, and the part that can take uncommitted work with it.
    private func confirmClearSessions(in project: Project) {
        let idle = idleSessions(in: project)
        guard !idle.isEmpty else { return }
        let worktrees = idle.filter { $0.worktreePath != nil }.count
        let dirty = idle.filter { $0.worktreePath.map(workingTrees.isDirty) ?? false }.count
        let kept = store.standaloneSessions(for: project.id).count - idle.count
        var message = "Their conversation history is removed from the app."
        if worktrees > 0 {
            message = "\(worktrees) of them ran in a worktree. Uncommitted changes there are lost, and branches are kept only where they have unmerged commits."
        }
        if dirty > 0 {
            message += " \(dirty) of those worktree\(dirty == 1 ? " has" : "s have") uncommitted changes right now."
        }
        if kept > 0 {
            message += " The \(kept) still running stay\(kept == 1 ? "s" : "")."
        }
        dialogs.show(Dialog(
            title: "Clear \(idle.count) session\(idle.count == 1 ? "" : "s") from \(project.name)?",
            message: message,
            actions: [
                .init(label: "Clear sessions", kind: .destructive) {
                    removeSessions(idle)
                },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    private func idleSessions(in project: Project) -> [ChatSession] {
        store.standaloneSessions(for: project.id).filter { !runner.state($0.id).isBusy }
    }

    private func confirmRemoveProject(_ project: Project) {
        let affected = sessions(using: project.id)
        let count = affected.count
        dialogs.show(Dialog(
            title: "Remove \(project.name)?",
            message: "This drops \(count) session\(count == 1 ? "" : "s") that use it and removes their worktrees. It is also removed from every workspace. The folder itself stays on disk.",
            actions: [
                .init(label: "Remove project", kind: .destructive) { removeProject(project) },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    // The session id is chosen up front so the worktree folder and branch can carry
    // it before the session exists, which is also what lets the sheet name both.
    private func createWorktreeSession(in project: Project, id sessionID: UUID, base: String?,
                                       agent: AgentKind) {
        Task {
            switch await SessionLifecycle.createWorktreeSession(
                in: project, id: sessionID, base: base, store: store) {
            case .success:
                runner.agent = agent
                sessionToReveal = sessionID
            case .failure(let failure):
                showLifecycleFailure(failure)
            }
        }
    }

    private func removeProject(_ project: Project) {
        let affected = sessions(using: project.id)
        removeSessions(affected) { store.removeProject(project.id) }
    }

    private func removeSessions(_ sessions: [ChatSession], onSuccess: (() -> Void)? = nil) {
        Task {
            var failures: [SessionLifecycle.Failure] = []
            for session in sessions {
                if case .failure(let failure) = await SessionLifecycle.remove(
                    session, from: store, runner: runner) {
                    failures.append(failure)
                }
            }
            guard failures.isEmpty else {
                showLifecycleFailure(SessionLifecycle.Failure(
                    title: failures.count == 1
                        ? failures[0].title
                        : "Could not delete some sessions",
                    message: failures.map(\.message).joined(separator: "\n")))
                return
            }
            onSuccess?()
        }
    }

    private func showLifecycleFailure(_ failure: SessionLifecycle.Failure) {
        dialogs.show(Dialog(title: failure.title, message: failure.message,
                            actions: [.init(label: "OK", kind: .cancel)]))
    }

    private func sessions(using projectID: UUID) -> [ChatSession] {
        store.sessions.filter { session in
            store.checkoutProjects(for: session).contains { $0.projectID == projectID }
        }
    }

    // The line under a session's title. A running session shows the call in flight
    // ("Bash · swift build"), which only its own transcript knows and which it has in
    // memory for as long as it runs. Everything else reads from the summary, so a
    // session says where it left off without its conversation being loaded at all.
    private func activitySummary(_ session: ChatSession, project: Project,
                                 busy: Bool, finished: Bool) -> String? {
        // A turn writes into the message it opened, so a call still in flight can only
        // be in the last one.
        if busy, let running = session.messages.last?.tools.last(where: { $0.isRunning }) {
            let root = folder(session, project: project)
            return ToolPresentationCache.presentation(for: running, projectPath: root).label
        }
        guard let last = session.summary.lastTool else { return nil }
        return (finished ? "ended after " : "last: ") + last
    }

    // A worktree session owns its branch; anything else works on whatever the project
    // folder has checked out.
    private func branch(_ session: ChatSession, project: Project) -> String? {
        session.worktreeBranch ?? GitHead.branch(at: project.path)
    }

    private func isSelected(_ session: ChatSession) -> Bool {
        if case .session(let id) = store.selection { return id == session.id }
        return false
    }

    // MARK: - Uncommitted work

    // Only the folders behind cards that are on screen are looked at, and the list is
    // rebuilt on every pass so opening a project starts watching what it holds.
    private func watchWorkingTrees() async {
        while !Task.isCancelled {
            workingTrees.refresh(watchedFolders)
            try? await Task.sleep(for: WorkingTreeWatch.interval)
        }
    }

    private var watchedFolders: Set<String> {
        var folders: Set<String> = []
        let grouped = groupedSessions
        for project in store.projects where isExpanded(project) {
            for session in visibleSessions(of: project, in: grouped[project.id] ?? []) {
                folders.insert(folder(session, project: project))
            }
        }
        let workspaceGroups = groupedWorkspaceSessions
        for workspace in store.workspaces where isExpanded(workspace) {
            for session in visibleWorkspaceSessions(
                workspace, sessions: workspaceGroups[workspace.id] ?? []) {
                folders.formUnion(store.workingDirectories(for: session))
            }
        }
        return folders
    }

    // Where a session's files actually are: its own worktree, or the project folder it
    // shares with every other session that has no worktree.
    private func folder(_ session: ChatSession, project: Project) -> String {
        session.worktreePath ?? project.path
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if oldSessionSummary.sessions > 0 { oldSessionsStrip(oldSessionSummary) }

            HStack(spacing: 8) {
                Button(action: addProject) {
                    Text("+ Add project")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black.opacity(0.88)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .subtleButtonGlow()

                Button { showingNewWorkspace = true } label: {
                    VStack(spacing: 1) {
                        Text("+ Workspace")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Multi-project")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .subtleButtonGlow()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            ToolsButton(showsUpdate: skills.updateCount > 0, entries: toolsMenu)
                .padding(.horizontal, 16)
                .padding(.bottom, runner.available ? 16 : 6)

            if !runner.available {
                Text("\(runner.agent.title) was not found on PATH.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }

    // Sessions pile up quietly, and the worktrees behind them take real disk. The strip
    // says how much has gone stale and hands it to a screen that explains what clearing
    // each one would cost; it never offers to do anything on its own.
    private func oldSessionsStrip(_ summary: OldSessionSummary) -> some View {
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(summary.sessions) session\(summary.sessions == 1 ? "" : "s") older than \(oldSessionDays) day\(oldSessionDays == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if summary.worktrees > 0 {
                    Text(summary.worktrees == 1 ? "one worktree remains"
                                                : "\(summary.worktrees) worktrees remain")
                        .font(.mono(11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(action: onReviewOldSessions) {
                Text("Review")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.black.opacity(0.035)))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // The setup and utility screens are folded behind one button so the rail
    // belongs to the projects. Each card carries its state under the name - the count,
    // the environment, whether the model server is up - so folding them away costs a
    // click but not the glance.
    private func toolsMenu() -> [MenuEntry] {
        // The count docker shows is from its last look; asking again now means the menu
        // is at most one open behind, without polling a CLI while the menu sits closed.
        Task { await docker.refresh() }
        return [
            .cards([
                MenuCardItem(label: "MCP servers", icon: "server.rack",
                             detail: "\(configs.servers.count)", handler: onConfigureServers),
                MenuCardItem(label: "Skills", icon: "sparkles",
                             showsUpdate: skills.updateCount > 0,
                             detail: "Claude + Codex", handler: onOpenSkills),
                MenuCardItem(label: "Docker", icon: "shippingbox.fill",
                             detail: dockerDetail.text, detailColour: dockerDetail.colour,
                             handler: onOpenDocker),
                MenuCardItem(label: "Postman", icon: "paperplane.fill",
                             detail: postmanAuth.active.envValue,
                             detailColour: postmanAuth.active.accent, handler: onOpenPostman),
                MenuCardItem(label: "Local AI", icon: "cpu",
                             detail: aiDetail.text, detailColour: aiDetail.colour,
                             handler: onOpenAI),
                MenuCardItem(label: "Troubleshoot", icon: "stethoscope",
                             detail: "Agent diagnosis",
                             handler: onOpenTroubleshoot)
            ]),
            .separator,
            .item("Settings", detail: "⌘,", action: onOpenSettings)
        ]
    }

    private var dockerDetail: (text: String, colour: Color?) {
        guard docker.hasLoaded else { return ("checking…", nil) }
        guard docker.failure == nil else { return ("unavailable", Theme.deletion) }
        guard !docker.containers.isEmpty else { return ("none running", nil) }
        return ("\(docker.containers.count) running", Theme.addition)
    }

    private var aiDetail: (text: String, colour: Color?) {
        switch ai.state {
        case .running, .runningExternally: ("running", Theme.addition)
        case .starting: ("loading…", nil)
        case .failed: ("failed", Theme.deletion)
        case .stopped: ("not running", nil)
        }
    }

    private var oldSessionDays: Int { appSettings.oldSessionDays }

    private func refreshOldSessions() {
        let sessions = OldSessions.olderThan(oldSessionDays, in: store.sessions)
            .filter { !runner.state($0.id).isBusy }
        let worktrees = sessions.reduce(0) { count, session in
            count + store.checkoutProjects(for: session).compactMap(\.worktreePath).count
        }
        oldSessionSummary = OldSessionSummary(sessions: sessions.count, worktrees: worktrees)
    }

    private func refreshOldSessionsHourly() async {
        while !Task.isCancelled {
            refreshOldSessions()
            do {
                try await Task.sleep(for: Self.oldSessionRefreshInterval)
            } catch {
                return
            }
        }
    }

    // MARK: - Actions

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Pick the folder Claude Code should work in."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // A folder that is already a project comes back as nil, and the store has
        // pointed itself at the existing one, so there is nothing to report.
        let added = store.addProject(at: url)
        if let id = added?.id ?? store.selectedProjectID { setExpanded(true, for: id) }
    }

    // Opening a folder on its own would just reveal it in Finder, so name the app.
    private func openInTerminal(_ project: Project) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([project.url],
                                withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Reveal

// A block that opens and closes by its own height, so the rows under it move at the same
// rate rather than being displaced in one step. Fading alone leaves the space taken from
// the first frame, which reads as the list jumping and the block catching up.
private extension AnyTransition {
    static var reveal: AnyTransition {
        .modifier(active: RevealModifier(progress: 0), identity: RevealModifier(progress: 1))
    }
}

private struct RevealModifier: ViewModifier, @MainActor Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // The cards trail the edge they come out from by a few points, so the block
        // arrives rather than simply being uncovered. The offset is drawn, not laid out,
        // so it costs the reveal no height.
        RevealLayout(progress: progress) { content.offset(y: (progress - 1) * 6) }
            .clipped()
            // Only the last stretch fades: a card cut in half by the clip is the one
            // frame worth softening, and fading throughout would wash out the rest.
            .opacity(min(1, progress * 2.5))
    }
}

// Reports a fraction of what the content asks for while still laying the content out at
// full size, pinned to the top: the block is uncovered from the top down instead of being
// squashed, which is what makes it read as a slide rather than a stretch.
private struct RevealLayout: Layout, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(proposal)
        return CGSize(width: size.width, height: size.height * progress)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let size = content.sizeThatFits(proposal)
        content.place(at: CGPoint(x: bounds.minX, y: bounds.minY),
                      anchor: .topLeading,
                      proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

// MARK: - Rows

// The one pinned button under the project list. Its menu opens above it at the same
// width, so it reads as the button unfolding rather than a menu landing on the rail.
private struct ToolsButton: View {
    let showsUpdate: Bool
    let entries: () -> [MenuEntry]

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text("Tools and settings")
                .font(.system(size: 13, weight: .semibold))
            if showsUpdate {
                UpdateIndicator()
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Theme.field : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        .subtleButtonGlow()
        .appMenu(edge: .top, matchWidth: true, entries)
        .onHover { hovering = $0 }
    }
}

// One of the orders the project list can be in. The chosen one is filled rather than
// outlined, so which is on reads from the shape alone without having to read the words.
private struct SortChip: View {
    let title: String
    let hint: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.mono(9.5, .semibold))
                .kerning(0.5)
                .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Theme.accent
                                   : hovering ? Theme.field : Color.black.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? Color.clear : Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appTooltip(hint)
        .onHover { hovering = $0 }
    }
}

// One line per workspace. The paired tiles distinguish it from a single project without
// introducing another icon language into the sidebar.
private struct WorkspaceHeaderRow: View {
    let workspace: ProjectWorkspace
    let projects: [Project]
    let selected: Bool
    let isExpanded: Bool
    let sessionCount: Int
    let runningCount: Int
    let finishedCount: Int
    let onNewSession: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.accent)
                    .frame(width: 10, height: 17)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.secret)
                    .frame(width: 10, height: 17)
            }
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))

            HStack(spacing: 5) {
                Text(workspace.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if finishedCount > 0 { FinishedDot() }
            }

            Spacer(minLength: 8)

            ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    Text("\(projects.count) PROJECTS")
                        .font(.mono(9.5, .semibold))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .opacity(hovering ? 0 : 1)

                if hovering {
                    RowAction(icon: "plus", title: "New", action: onNewSession)
                        .appTooltip("New multi-project session")
                }
            }
            .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(selected ? Theme.accent.opacity(0.13)
                           : isExpanded ? Theme.accent.opacity(0.08)
                           : hovering ? Color.black.opacity(0.03) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(selected ? Theme.accent.opacity(0.22) : .clear))
        .overlay(alignment: .topTrailing) {
            if runningCount > 0 {
                Text("\(runningCount)")
                    .font(.mono(9, .semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Circle().fill(Theme.dotOn))
                    .offset(x: 3, y: -3)
            }
        }
        .appTooltip {
            Tooltip(
                title: workspace.name,
                subtitle: projects.map(\.name).joined(separator: " + "),
                rows: [Tooltip.Row(label: "Sessions", value: "\(sessionCount)"),
                       Tooltip.Row(label: "Projects", value: "\(projects.count)")])
        }
        .onHover { hovering = $0 }
    }
}

// One line per project: who it is, and the way in. The sessions themselves carry the
// detail, so the row stays a heading rather than competing with the cards under it, and
// its numbers live in the hint where they cost the line no room.
private struct ProjectHeaderRow: View {
    let project: Project
    let isExpanded: Bool
    let isMissing: Bool
    let sessionCount: Int
    let runningCount: Int
    let finishedCount: Int
    let cost: Double
    let clearableCount: Int
    let isRenaming: Bool
    let onNewSession: () -> Void
    let onClearSessions: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            MonogramTile(name: project.name, badge: runningCount)

            if isRenaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .focused($focused)
                    .onSubmit { onRename(draft) }
                    .onExitCommand(perform: onCancelRename)
            } else {
                HStack(spacing: 5) {
                    if isMissing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text(project.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if finishedCount > 0 { FinishedDot() }
                }
                Spacer(minLength: 8)

                // The chevron says which way the row goes; under the pointer it gives way
                // to the two things you come to a project row to do. The buttons carry
                // their word beside the glyph, so they take more room than the chevron
                // did: the name gives way while the pointer is on the row, which costs
                // nothing to read since the pointer is here for the buttons.
                ZStack(alignment: .trailing) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(hovering ? 0 : isExpanded ? 0 : 1)
                    if hovering {
                        HStack(spacing: 10) {
                            // A running session is doing work nobody asked to throw away,
                            // so the bin is only offered once there is something idle to
                            // clear.
                            if clearableCount > 0 {
                                RowAction(icon: "trash", title: "Delete", action: onClearSessions)
                                    .appTooltip("Clear \(clearableCount) idle session\(clearableCount == 1 ? "" : "s")")
                            }
                            RowAction(icon: "plus", title: "New", action: onNewSession)
                                .appTooltip("New session")
                        }
                        .fixedSize()
                    }
                }
                .frame(minWidth: 35, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(isExpanded ? Color.black.opacity(0.05) : hovering ? Color.black.opacity(0.03) : .clear))
        .appTooltip { tooltip }
        .onHover { hovering = $0 }
        .onChange(of: isRenaming, initial: true) { _, renaming in
            guard renaming else { return }
            draft = project.name
            focused = true
        }
    }

    // The path is the only thing that tells two projects of the same name apart, so it
    // leads the hint. The counts under it are the ones the row itself no longer carries.
    private var tooltip: Tooltip {
        var rows = [Tooltip.Row(label: "Sessions", value: "\(sessionCount)")]
        if runningCount > 0 {
            rows.append(Tooltip.Row(label: "Running", value: "\(runningCount)"))
        }
        if finishedCount > 0 {
            rows.append(Tooltip.Row(label: "Finished while away", value: "\(finishedCount)"))
        }
        if cost > 0 {
            rows.append(Tooltip.Row(label: "Spent", value: Money.short(cost)))
        }
        return Tooltip(title: project.name,
                       subtitle: project.collapsedPath,
                       note: isMissing ? "This folder is no longer on disk." : nil,
                       rows: rows)
    }
}

// A hover action on the project row: the glyph with its word beside it, so what the
// button does is read rather than guessed.
private struct RowAction: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// The project's initial, tinted from its name, with the number of sessions running in
// it hanging off the corner.
private struct MonogramTile: View {
    let name: String
    let badge: Int

    var body: some View {
        let tint = Theme.monogram(for: name)
        RoundedRectangle(cornerRadius: 8)
            .fill(tint.opacity(0.16))
            .frame(width: 30, height: 30)
            .overlay(
                Text(String(name.prefix(1)).uppercased())
                    .font(.mono(12, .semibold))
                    .foregroundStyle(tint)
            )
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Theme.dotOn))
                        .overlay(Circle().stroke(Theme.sidebar, lineWidth: 1.5))
                        .offset(x: 5, y: -5)
                }
            }
    }
}

// A turn ended in a session that was not on screen. It stays until that session is
// opened, which is the only thing that counts as having read it.
private struct FinishedDot: View {
    var body: some View {
        Circle()
            .fill(Theme.attention)
            .frame(width: 7, height: 7)
    }
}

// The session's folder holds work git does not have. It rides at the top of the card
// beside the state, because it is not what the session is doing: it is what deleting the
// session would cost.
private struct UncommittedMark: View {
    var body: some View {
        Image(systemName: "pencil.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(Theme.attention)
    }
}

// A session as a card rather than a row: state at the top, what it is doing in the
// middle, what it has produced at the bottom. It is the unit of the sidebar, so it
// carries enough to decide whether to open it without opening it.
private struct SessionCard: View {
    let session: ChatSession
    let selected: Bool
    let busy: Bool
    let finished: Bool
    let activity: String?
    let added: Int
    let removed: Int
    let branch: String?
    let uncommitted: Bool
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StateDot(colour: stateColour, pulsing: busy)
                Text(stateWord)
                    .font(.mono(9.5, .semibold))
                    .kerning(0.6)
                    .foregroundStyle(stateColour)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if session.worktreePath != nil {
                    StatusPill(text: "WT", running: false)
                }
                if uncommitted { UncommittedMark() }
                Spacer(minLength: 6)
                // The timestamp hides in place rather than being taken out, and the button
                // that replaces it is an overlay, so the card is one size whether or not
                // the pointer is on it.
                Text(RelativeTime.short(session.lastActivity))
                    .font(.mono(10))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 0 : 1)
                    .overlay(alignment: .trailing) {
                        if hovering {
                            Button(action: onDelete) {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .appTooltip("Delete session")
                        }
                    }
            }

            HStack(spacing: 6) {
                if session.isTroubleshooting {
                    StatusPill(text: "Troubleshoot", running: false, tint: Theme.secret)
                        .fixedSize()
                }
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ActivityLine(activity: activity)

            // Only a running session gets a bar, and it is how full its context is: the
            // one number that says how much room the session has left to keep going.
            if busy {
                Meter(fraction: session.usage?.contextFraction ?? 0, colour: Theme.dotOn, height: 4)
                    .padding(.top, 1)
            }

            if hasFooter {
                HStack(spacing: 7) {
                    if added > 0 {
                        Text("+\(added)")
                            .font(.mono(11, .medium))
                            .foregroundStyle(Theme.addition)
                    }
                    if removed > 0 {
                        Text("-\(removed)")
                            .font(.mono(11, .medium))
                            .foregroundStyle(Theme.deletion)
                    }
                    if let branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                            .font(.mono(10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    if let usage = session.usage, usage.turns > 0 {
                        // The cost stays out of the card: it reads as a bill, which on a
                        // subscription it is not. The tooltip still carries it.
                        Text("\(usage.turns) turn\(usage.turns == 1 ? "" : "s")")
                            .font(.mono(10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(cardStroke, lineWidth: bordered ? 1.5 : 1))
        .animation(.easeOut(duration: 0.25), value: [busy, finished])
        .appTooltip { tooltip }
        .onHover { hovering = $0 }
    }

    // The card truncates a title to one line and says nothing about where the session
    // runs, so the hint carries both, along with the numbers the footer drops when the
    // rail is narrow.
    private var tooltip: Tooltip {
        var rows = [Tooltip.Row(label: "State", value: stateWord)]
        if let branch {
            rows.append(Tooltip.Row(label: "Branch", value: branch))
        }
        if added > 0 || removed > 0 {
            rows.append(Tooltip.Row(label: "Changes", value: "+\(added) -\(removed)"))
        }
        if let usage = session.usage, usage.turns > 0 {
            rows.append(Tooltip.Row(label: "Turns", value: "\(usage.turns)"))
            rows.append(Tooltip.Row(label: "Spent", value: Money.short(usage.costUSD)))
        }
        if let context = session.usage?.contextFraction, context > 0 {
            rows.append(Tooltip.Row(label: "Context", value: "\(Int(context * 100))%"))
        }
        rows.append(Tooltip.Row(label: "Last active",
                                value: session.lastActivity.formatted(date: .abbreviated,
                                                                      time: .shortened)))
        return Tooltip(title: session.title,
                       subtitle: session.worktreePath?.abbreviatedPath,
                       note: note,
                       rows: rows)
    }

    // What is worth knowing before deleting this session outranks where it runs, and a
    // worktree session says both at once: the folder that would go is its own.
    private var note: String? {
        if uncommitted {
            return session.worktreePath == nil
                ? "Uncommitted changes in the project folder."
                : "Uncommitted changes in this worktree. Deleting the session loses them."
        }
        return session.worktreePath == nil ? nil : "Runs in its own git worktree."
    }

    private var hasFooter: Bool {
        added > 0 || removed > 0 || branch != nil || (session.usage?.turns ?? 0) > 0
    }

    // What the card is doing outranks selection, since a column of sessions is read for
    // its state first.
    private var stateWord: String {
        if busy { return "Running" }
        if finished { return "Finished while away" }
        return "Idle"
    }

    private var stateColour: Color {
        if busy { return Theme.accent }
        if finished { return Theme.attention }
        return Color.secondary
    }

    private var bordered: Bool { busy || finished || selected }

    // White is what being open looks like, so only the selected card gets it - two white
    // cards in the rail read as two open sessions. A card that is doing something says so
    // through its border, its state light and its word, which no other card has.
    private var cardFill: Color {
        if selected { return Theme.card }
        return hovering ? Color.black.opacity(0.05) : Color.black.opacity(0.035)
    }

    private var cardStroke: Color {
        if busy { return Theme.accent }
        if finished { return Theme.attention.opacity(0.7) }
        if selected { return Color.black.opacity(0.30) }
        return .clear
    }
}

// The card at the end of a capped session list. It wears the same shape as the cards
// above it so the column stays one column, but stays quieter than any of them: it is
// a control, not a session.
private struct SeeMoreCard: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 11)
                    .fill(hovering ? Color.black.opacity(0.05) : Color.black.opacity(0.02)))
                .overlay(RoundedRectangle(cornerRadius: 11)
                    .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// The state light at the top of a session card. It breathes while the session runs,
// which is the only movement in the sidebar and so reads as "this one is live".
private struct StateDot: View {
    let colour: Color
    let pulsing: Bool

    @State private var dim = false

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: 7, height: 7)
            .opacity(pulsing && dim ? 0.35 : 1)
            .animation(pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                       value: dim)
            .onAppear { dim = pulsing }
            .onChange(of: pulsing) { _, running in dim = running }
    }
}

// What the session is doing right now, under its title. Most tool calls finish in a
// few milliseconds, so the line holds for a moment before it gives way: long enough
// to read, and only ever replaced by the next call rather than by an empty gap.
private struct ActivityLine: View {
    let activity: String?

    private static let minimumDwell: TimeInterval = 1

    @State private var shown: String?
    @State private var shownAt = Date.distantPast

    var body: some View {
        Group {
            if let shown {
                Text("↳ \(shown)")
                    .font(.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Arriving text is the news, so it lands at once; leaving text
                    // fades so the row does not blink.
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.3), value: shown)
        // A newer value cancels the wait for the older one, which is what keeps the
        // hold from delaying anything the user would rather see.
        .task(id: activity) { await settle(on: activity) }
    }

    private func settle(on next: String?) async {
        let elapsed = Date().timeIntervalSince(shownAt)
        if shown != nil, elapsed < Self.minimumDwell {
            try? await Task.sleep(for: .seconds(Self.minimumDwell - elapsed))
            guard !Task.isCancelled else { return }
        }
        shown = next
        if next != nil { shownAt = Date() }
    }
}

// State as a word rather than a dot, so a glance down the rail reads as text. The
// old-sessions sheet borrows it for the same worktree badge the session cards wear.
struct StatusPill: View {
    let text: String
    let running: Bool
    var tint: Color? = nil
    var disclosure = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text.uppercased())
                .font(.mono(9.5, .semibold))
                .kerning(0.5)
            if disclosure {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
        }
        .foregroundStyle(colour)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(fill))
    }

    private var colour: Color { tint ?? (running ? Theme.addition : Color.secondary) }

    private var fill: Color {
        tint?.opacity(0.14) ?? (running ? Theme.dotOn.opacity(0.18) : Color.black.opacity(0.05))
    }
}

private extension SessionNotice {
    var badge: String {
        switch self {
        case .needsInput: "INPUT"
        case .running: "RUNNING"
        case .finished: "FINISHED"
        }
    }

    var tint: Color {
        switch self {
        case .running: Theme.addition
        case .needsInput, .finished: Theme.attention
        }
    }
}

// Always two decimals: a session that has spent eight cents should read as $0.08 next
// to one that has spent three dollars, so the column lines up.
private enum Money {
    static func short(_ amount: Double) -> String { String(format: "$%.2f", amount) }
}

// "2m", "3h", "2d": short enough to sit at the end of a narrow row.
private enum RelativeTime {
    static func short(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / 604_800))w"
        }
    }
}
