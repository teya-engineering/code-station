import Foundation

// Taking a project out of the app. The action is offered from three places - the sidebar's
// context menu and the banner in each detail pane - and all three make the same promises
// about what goes and what stays, so the whole removal lives here rather than in each of
// them: a promise kept in one copy and forgotten in another is a promise the app breaks.
@MainActor
public enum ProjectRemoval {
    // Every session with a checkout in this project, which is more than the sessions that
    // call it home: a workspace session dies with any one of its repositories.
    public static func sessions(using projectID: UUID, in store: ProjectStore) -> [ChatSession] {
        store.sidebarSessions.filter { session in
            store.checkoutProjects(for: session).contains { $0.projectID == projectID }
        }
    }

    // Sessions first, project last: a project dropped while one of its sessions survived
    // would leave that session with no home, so a session that refuses to go keeps the
    // project it belongs to. The sessions that did go are already gone by then, so what
    // is left is a project the reader can remove again once the refusal is dealt with.
    // `removeOwned` takes away what the host files under the project, such as the
    // commands saved against it, just before the project itself goes.
    public static func run(_ project: Project, in store: ProjectStore, runner: SessionRunner,
                           worktrees: WorktreeOperations = .live,
                           removeOwned: (UUID) -> Void = { _ in }) async
        -> Result<Void, SessionLifecycle.Failure> {
        if case .failure(let failure) = await SessionRemoval.run(
            sessions(using: project.id, in: store), in: store, runner: runner,
            worktrees: worktrees, groupNoun: project.kind == .adHoc ? "runs" : "sessions") {
            return .failure(failure)
        }
        removeOwned(project.id)
        store.removeProject(project.id)
        return .success(())
    }
}

// What a removal takes and leaves, as the GUI's impact dialog and the terminal's
// confirmation both say it: the project, task or workspace it happens in, a title and
// message, one row for each thing that goes and each thing that stays, a warning for what
// cannot be restored, and the action's label. Worked out on the host, which holds the
// sessions, worktrees and files it counts.
public struct RemoteImpact: Codable, Equatable, Sendable {
    public struct Subject: Codable, Equatable, Sendable {
        public var name: String
        public var kind: RemoteContainer.Kind

        public init(name: String, kind: RemoteContainer.Kind = .project) {
            self.name = name
            self.kind = kind
        }
    }

    public struct Row: Codable, Equatable, Sendable {
        public var title: String
        public var detail: String
        public var kept: Bool

        public init(title: String, detail: String, kept: Bool = false) {
            self.title = title
            self.detail = detail
            self.kept = kept
        }
    }

    public var title: String
    public var message: String?
    public var subject: Subject?
    public var rows: [Row]
    public var warning: String?
    public var action: String

    public init(title: String, message: String? = nil, subject: Subject? = nil, rows: [Row],
                warning: String? = nil, action: String) {
        self.title = title
        self.message = message
        self.subject = subject
        self.rows = rows
        self.warning = warning
        self.action = action
    }
}

extension ProjectRemoval {
    // What removing the project or task takes: its sessions (and their worktrees) or
    // runs, the shortcuts saved against it, generated Design files, and a task's own
    // folder. A project's folder stays.
    public static func impact(of project: Project, in store: ProjectStore, savedShortcuts saved: Int = 0) -> RemoteImpact {
        let sessions = sessions(using: project.id, in: store)
        let count = sessions.count
        let designs = sessions.count { store.hasDesignArtifacts(for: $0) }
        let isTask = project.kind == .adHoc
        let noun = isTask ? "run" : "session"

        var rows: [RemoteImpact.Row]
        if isTask {
            rows = [.init(title: counted(count, "run"),
                          detail: count == 0 ? "No runs to remove." : "Run history is removed from Code Station.")]
        } else {
            let worktreeCount = sessions.reduce(0) {
                $0 + store.checkoutProjects(for: $1).compactMap(\.worktreePath).count
            }
            rows = [.init(
                title: "\(counted(count, "session")) and \(counted(worktreeCount, "worktree"))",
                detail: count == 0 ? "No sessions or worktrees to remove."
                    : "Session history is removed from Code Station."
                        + (worktreeCount > 0 ? " Worktrees are removed from disk." : ""))]
        }
        if saved > 0 {
            rows.append(.init(title: counted(saved, "saved shortcut"),
                              detail: "\(isTask ? "Task" : "Project") commands are permanently removed."))
        }
        if designs > 0 {
            rows.append(.init(title: "Generated Design files",
                              detail: "Permanently removed from \(counted(designs, noun))."))
        }
        if isTask {
            rows.append(.init(title: "Task folder",
                              detail: "Deleted from disk, with any files the runs left in it."))
        } else {
            rows.append(.init(title: "Original project folder stays",
                              detail: project.collapsedPath, kept: true))
        }

        let warning: String? = if isTask {
            "The task folder and run history cannot be restored."
        } else if count > 0 {
            "Session history cannot be restored."
        } else {
            nil
        }
        return RemoteImpact(title: isTask ? "Delete \(project.name)?" : "Remove \(project.name)?",
                            message: isTask
                                ? "This task and its runs will leave Code Station."
                                : "This project will leave Code Station and every workspace it belongs to.",
                            subject: .init(name: project.name, kind: isTask ? .task : .project),
                            rows: rows, warning: warning,
                            action: isTask ? "Delete task" : "Remove project")
    }

    // The project's own sessions that are not running, which clearing it takes.
    public static func idleSessions(in project: Project, store: ProjectStore, runner: SessionRunner) -> [ChatSession] {
        store.standaloneSessions(for: project.id).filter { !runner.isBusy($0.id, store: store) }
    }

    // What clearing the idle sessions takes: those sessions, their worktrees (saying when
    // some hold uncommitted work, by `isDirty` on a worktree's path) and Design files.
    // What is still running stays, and so does the folder. Nil when nothing is idle.
    public static func clearingImpact(of project: Project, in store: ProjectStore, runner: SessionRunner,
                                      isDirty: (String) -> Bool) -> RemoteImpact? {
        let idle = idleSessions(in: project, store: store, runner: runner)
        guard !idle.isEmpty else { return nil }
        let worktrees = idle.flatMap { store.checkoutProjects(for: $0).compactMap(\.worktreePath) }
        let dirty = worktrees.count(where: isDirty)
        let designs = idle.count { store.hasDesignArtifacts(for: $0) }
        let kept = store.standaloneSessions(for: project.id).count - idle.count

        var rows = [RemoteImpact.Row(title: counted(idle.count, "session"),
                                     detail: "Conversation history is removed from Code Station.")]
        if !worktrees.isEmpty {
            rows.append(.init(
                title: counted(worktrees.count, "worktree"),
                detail: "Removed from disk."
                    + (dirty > 0
                       ? " \(dirty) \(dirty == 1 ? "has" : "have") uncommitted changes that will be lost."
                       : " Branches are kept if they have unmerged commits.")))
        }
        if designs > 0 {
            rows.append(.init(title: "Generated Design files",
                              detail: "Permanently removed from \(counted(designs, "session"))."))
        }
        if kept > 0 {
            rows.append(.init(title: "\(counted(kept, "running session")) \(kept == 1 ? "stays" : "stay")",
                              detail: "Sessions that are still working are left alone.", kept: true))
        }
        rows.append(.init(title: "Original project folder stays", detail: project.collapsedPath, kept: true))

        return RemoteImpact(title: "Clear \(counted(idle.count, "session")) from \(project.name)?",
                            message: "Sessions that are not running will leave Code Station.",
                            subject: .init(name: project.name), rows: rows,
                            warning: dirty > 0
                                ? "Uncommitted changes and conversation history cannot be restored."
                                : "Conversation history cannot be restored.",
                            action: "Clear sessions")
    }
}
