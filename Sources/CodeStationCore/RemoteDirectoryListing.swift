import Foundation

// How the store and the runner become the list a remote reader browses: a project, then
// the sessions that have run in it, newest first. The phone and the station commands
// façade both read the list from here, so they cannot drift apart on ordering or on the
// word a session's state is given.
public enum RemoteDirectoryListing {
    // The colours a project is drawn in, as hex strings. Only the GUI knows its palette,
    // so a front end without one leaves them empty.
    public typealias Tint = (_ projectName: String) -> (tint: String, ink: String)

    public static func noTint(_ projectName: String) -> (tint: String, ink: String) { ("", "") }

    // A session in a workspace is listed under the project that leads it and says which
    // workspace it belongs to. Projects with the most recent activity come first, and
    // ties go by name.
    @MainActor
    public static func directory(store: ProjectStore, runner: SessionRunner,
                                 title: String, scope: String, canCreate: Bool,
                                 includesSession: (ChatSession) -> Bool = { _ in true },
                                 includesProject: (UUID) -> Bool = { _ in true },
                                 tint: Tint = noTint) -> RemoteDirectory {
        let sessions = store.sidebarSessions.filter(includesSession)
        var rows: [UUID: [RemoteSessionRow]] = [:]
        for session in sessions.sorted(by: { $0.lastActivity > $1.lastActivity }) {
            rows[session.projectID, default: []].append(row(session, store: store, runner: runner))
        }

        let visible = store.projects.filter { includesProject($0.id) }
        let ordered = visible.sorted { first, second in
            let left = rows[first.id]?.first?.lastActivity ?? .distantPast
            let right = rows[second.id]?.first?.lastActivity ?? .distantPast
            guard left != right else {
                return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
            }
            return left > right
        }

        return RemoteDirectory(
            title: title,
            scope: scope,
            canCreate: canCreate,
            projects: ordered.map { project in
                let colours = tint(project.name)
                return RemoteProject(id: project.id.uuidString,
                                     name: project.name,
                                     path: project.collapsedPath,
                                     tint: colours.tint,
                                     tintInk: colours.ink,
                                     isGit: project.isGitRepository,
                                     isMissing: store.isMissing(project),
                                     sessions: rows[project.id] ?? [],
                                     schedule: project.task?.schedule.map(RemoteSchedule.init))
            })
    }

    // The GUI's sidebar tree: every project, task and workspace in the shared sort, with
    // pinned ones first, each holding its sessions pinned first and then by last use. A
    // workspace's sessions sit under the workspace and not under the project leading it.
    // `uncommitted` says whether a session's folders hold uncommitted work, as far as the
    // caller has looked.
    @MainActor
    public static func tree(store: ProjectStore, runner: SessionRunner,
                            arrangement: RemoteArrangement,
                            uncommitted: (ChatSession) -> Bool = { _ in false }) -> [RemoteContainer] {
        let sessions = store.sidebarSessions
        let items = store.projects.map(SidebarItem.project) + store.workspaces.map(SidebarItem.workspace)
        let grouped = Dictionary(grouping: sessions) { $0.workspaceID ?? $0.projectID }
        return arrangement.sort.apply(to: items, sessions: sessions).map { item in
            let members = (grouped[item.id] ?? []).sorted(by: SessionSort.pinnedFirstByLastActivity)
            let rows = members.map { session in
                var row = row(session, store: store, runner: runner)
                row.hasUncommittedChanges = uncommitted(session)
                row.folder = store.workingDirectories(for: session).first
                return row
            }
            var container = container(item, sessions: rows, store: store)
            // Read as each card reads its own state, so a folded row counts exactly the
            // cards that would say NEEDS YOU once it is opened.
            container.needsYou = members.count { SessionTone($0.id, store: store, runner: runner) == .needsYou }
            container.running = members.count { runner.isBusy($0.id, store: store) }
            return container
        }
    }

    @MainActor
    private static func container(_ item: SidebarItem, sessions rows: [RemoteSessionRow],
                                  store: ProjectStore) -> RemoteContainer {
        switch item {
        case .project(let project):
            RemoteContainer(id: project.id.uuidString,
                            kind: project.kind == .adHoc ? .task : .project,
                            name: project.name, path: project.collapsedPath,
                            isPinned: project.isPinned, isMissing: store.isMissing(project),
                            unread: store.unreadCount(in: project.id), sessions: rows,
                            schedule: project.task?.schedule.map(RemoteSchedule.init))
                .with(folder: project.path,
                      snoozedUntil: ProjectSnooze.isActive(project.snoozedUntil) ? project.snoozedUntil : nil)
        case .workspace(let workspace):
            RemoteContainer(id: workspace.id.uuidString, kind: .workspace,
                            name: workspace.name,
                            path: workspace.projectIDs.compactMap(store.project).map(\.name)
                                .joined(separator: " + "),
                            isPinned: workspace.isPinned, isMissing: false,
                            unread: store.unreadCount(inWorkspace: workspace.id), sessions: rows,
                            members: workspace.projectIDs.compactMap(store.project).map(\.name))
        }
    }

    @MainActor
    public static func row(_ session: ChatSession, store: ProjectStore,
                           runner: SessionRunner) -> RemoteSessionRow {
        let live = LiveConversation.id(of: session.id, store: store, runner: runner)
        let question = runner.question(live)
        var row = RemoteSessionRow(
            id: session.id.uuidString,
            title: session.title,
            agent: session.agent.title,
            workspace: session.workspaceID.flatMap(store.workspace)?.name,
            branch: session.worktreeBranch
                ?? session.sessionProjects?.compactMap(\.worktreeBranch).first,
            state: SessionTone(session.id, store: store, runner: runner).word,
            conversation: live == session.id ? .main : .design,
            lastActivity: session.lastActivity,
            added: session.summary.added,
            removed: session.summary.removed,
            failure: failure(runner.state(live)),
            needsInput: question.map { $0.isQuestion ? "question" : "permission" },
            isPinned: session.isPinned,
            isUnread: store.isUnread(session.id))
        row.activity = activity(session, store: store, runner: runner)
        let coverage = store.worktreeCoverage(for: session)
        row.worktree = coverage.isComplete ? .all : coverage.isPartial ? .partial : nil
        row.isTroubleshooting = session.isTroubleshooting
        // Read as the GUI's Needs you stack reads it (`SidebarNotices`).
        if let notice = SessionNotice(isBusy: runner.state(live).isBusy, needsInput: question != nil,
                                      finishedUnseen: store.hasFinished(session.id)) {
            row.notice = RemoteNotice(kind: RemoteNotice.Kind(notice), reason: notice.reason(question: question))
        }
        return row
    }

    // The line under a card's title, as the GUI's rail words it: the call in flight while
    // a turn runs, what holds the turn open, or the last call. A pending permission is
    // left out, since the state word and its reason already say so. Nil when there is
    // nothing to say.
    @MainActor
    static func activity(_ session: ChatSession, store: ProjectStore, runner: SessionRunner) -> String? {
        let live = LiveConversation.of(session.id, store: store, runner: runner) ?? session
        let runningTool = runner.state(live.id).isBusy ? runner.runningTool(live.id) : nil
        let tasks = runner.backgroundTasks(live.id)
        guard runningTool != nil || !tasks.isEmpty || live.summary.lastTool != nil else { return nil }
        return SessionActivity.line(permission: nil, runningTool: runningTool,
                                    root: store.workingDirectory(for: session) ?? "",
                                    lastTool: live.summary.lastTool,
                                    finished: store.hasFinished(session.id),
                                    backgroundTasks: tasks)
    }

    // What the old-sessions strip counts, as the GUI's `OldSessionsWatch` counts it, but
    // without reading worktrees off disk: sessions past the shared age, not busy, and the
    // projects whose snooze holds some back.
    @MainActor
    public static func oldSessions(store: ProjectStore, runner: SessionRunner, days: Int,
                                   now: Date = Date()) -> (sessions: Int, snoozedProjects: Int) {
        let old = OldSessions.olderThan(days, in: store.sidebarSessions, now: now)
            .filter { !runner.isBusy($0.id, store: store) }
        let heldBack = old.filter { ProjectSnooze.isActive(store.snoozeDeadline(for: $0), now: now) }
        return (old.count - heldBack.count, Set(heldBack.map(\.projectID)).count)
    }

    public static func failure(_ state: SessionState) -> String? {
        if case .failed(let message) = state { return message }
        return nil
    }
}
