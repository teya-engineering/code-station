import Foundation

struct WorktreeOperations: Sendable {
    let addProject: @Sendable (String, String, UUID, String?) async
        -> Result<GitWorktree.Created, GitWorktree.Failure>
    let addWorkspaceProject: @Sendable (String, String, UUID, UUID) async
        -> Result<GitWorktree.Created, GitWorktree.Failure>
    let remove: @Sendable (String, String?, String?) async
        -> Result<Void, GitWorktree.Failure>

    static let live = WorktreeOperations(
        addProject: { path, name, sessionID, base in
            await GitWorktree.add(projectPath: path, projectName: name,
                                  sessionID: sessionID, from: base)
        },
        addWorkspaceProject: { path, name, projectID, sessionID in
            await GitWorktree.add(projectPath: path, projectName: name,
                                  projectID: projectID, sessionID: sessionID)
        },
        remove: { worktree, project, branch in
            await GitWorktree.remove(worktreePath: worktree,
                                     projectPath: project, branch: branch)
        })
}

@MainActor
enum SessionLifecycle {
    struct Failure: Error, Equatable {
        let title: String
        let message: String
    }

    static func createWorktreeSession(in project: Project, id sessionID: UUID,
                                      base: String?, agentAvatarName: String? = nil,
                                      store: ProjectStore,
                                      worktrees: WorktreeOperations = .live) async
        -> Result<ChatSession, Failure> {
        guard store.project(project.id) != nil else {
            return .failure(Failure(
                title: "Could not create the session",
                message: "The project is no longer in the app."))
        }

        switch await worktrees.addProject(project.path, project.name, sessionID, base) {
        case .failure(let failure):
            return .failure(Failure(title: "Could not create a worktree",
                                    message: failure.message))
        case .success(let created):
            guard store.project(project.id) != nil else {
                let cleanup = await worktrees.remove(created.path, project.path, created.branch)
                return .failure(Failure(
                    title: "Could not create the session",
                    message: cleanupMessage("The project is no longer in the app.",
                                            cleanup: cleanup)))
            }
            switch store.insertSession(in: project.id, id: sessionID,
                                       worktreePath: created.path,
                                       worktreeBranch: created.branch,
                                       agentAvatarName: agentAvatarName) {
            case .success(let session):
                return .success(session)
            case .failure(let failure):
                let cleanup = await worktrees.remove(created.path, project.path, created.branch)
                return .failure(Failure(
                    title: "Could not save the session",
                    message: cleanupMessage(failure.message, cleanup: cleanup)))
            }
        }
    }

    static func createWorkspaceSession(_ choice: WorkspaceSessionChoice,
                                       in workspace: ProjectWorkspace,
                                       store: ProjectStore,
                                       worktrees: WorktreeOperations = .live) async
        -> Result<ChatSession, Failure> {
        var checkouts: [SessionProject] = []
        var created: [CreatedWorktree] = []

        for selected in choice.projects {
            guard let project = store.project(selected.projectID) else {
                return await creationFailure(
                    "One of the workspace projects is no longer in the app.",
                    created: created, worktrees: worktrees)
            }

            guard selected.useWorktree else {
                checkouts.append(SessionProject(projectID: project.id,
                                                worktreePath: nil,
                                                worktreeBranch: nil))
                continue
            }

            switch await worktrees.addWorkspaceProject(
                project.path, project.name, project.id, choice.sessionID) {
            case .success(let worktree):
                checkouts.append(SessionProject(projectID: project.id,
                                                worktreePath: worktree.path,
                                                worktreeBranch: worktree.branch))
                created.append(CreatedWorktree(path: worktree.path,
                                               projectPath: project.path,
                                               branch: worktree.branch))
            case .failure(let failure):
                return await creationFailure(
                    failure.message,
                    title: "Could not create a worktree for \(project.name)",
                    created: created, worktrees: worktrees)
            }
        }

        guard store.workspace(workspace.id) != nil else {
            return await creationFailure(
                "The workspace no longer has a valid lead project.",
                created: created, worktrees: worktrees)
        }

        switch store.insertSession(in: workspace.id, id: choice.sessionID,
                                   projects: checkouts,
                                   agentAvatarName: choice.agentAvatarName) {
        case .success(let session):
            return .success(session)
        case .failure(let failure):
            return await creationFailure(
                failure.message,
                title: "Could not save the session",
                created: created, worktrees: worktrees)
        }
    }

    static func remove(_ session: ChatSession, from store: ProjectStore,
                       runner: SessionRunner,
                       worktrees: WorktreeOperations = .live) async -> Result<Void, Failure> {
        guard let current = store.session(session.id) else { return .success(()) }
        guard runner.beginRemoval(current.id) else {
            return .failure(Failure(
                title: "Could not delete the session",
                message: "Stop this session before deleting it."))
        }
        let pending: PendingSessionRemoval
        switch store.prepareSessionRemoval(current.id) {
        case .success(let prepared):
            pending = prepared
            runner.finishRemoval(current.id)
        case .failure(let failure):
            runner.cancelRemoval(current.id)
            return .failure(Failure(title: "Could not delete the session",
                                    message: failure.message))
        }

        return await finish(pending, in: store, worktrees: worktrees)
    }

    @discardableResult
    static func resumePendingRemovals(
        in store: ProjectStore,
        worktrees: WorktreeOperations = .live
    ) async -> [Failure] {
        var failures: [Failure] = []
        for pending in store.pendingSessionRemovals {
            if case .failure(let failure) = await finish(
                pending, in: store, worktrees: worktrees) {
                failures.append(failure)
            }
        }
        return failures
    }

    private static func finish(
        _ pending: PendingSessionRemoval,
        in store: ProjectStore,
        worktrees: WorktreeOperations
    ) async -> Result<Void, Failure> {
        var failures: [String] = []
        for removal in pending.worktrees {
            switch await worktrees.remove(removal.path, removal.projectPath, removal.branch) {
            case .success:
                break
            case .failure(let failure):
                failures.append(failure.message)
            }
        }
        guard failures.isEmpty else {
            return .failure(Failure(
                title: "Could not delete the session",
                message: failures.joined(separator: "\n")
                    + "\nThe deletion is saved and will be retried when the app opens."))
        }

        switch store.finishSessionRemoval(pending.id) {
        case .success:
            return .success(())
        case .failure(let failure):
            return .failure(Failure(title: "Could not finish deleting the session",
                                    message: failure.message))
        }
    }

    private struct CreatedWorktree {
        let path: String
        let projectPath: String?
        let branch: String?
    }

    private static func creationFailure(
        _ message: String,
        title: String = "Could not create the session",
        created: [CreatedWorktree],
        worktrees: WorktreeOperations
    ) async -> Result<ChatSession, Failure> {
        var cleanupFailures: [String] = []
        for worktree in created.reversed() {
            if case .failure(let failure) = await worktrees.remove(
                worktree.path, worktree.projectPath, worktree.branch) {
                cleanupFailures.append(failure.message)
            }
        }
        let detail = cleanupFailures.isEmpty
            ? message
            : message + " Cleanup also failed: " + cleanupFailures.joined(separator: " ")
        return .failure(Failure(title: title, message: detail))
    }

    private static func cleanupMessage(
        _ message: String,
        cleanup: Result<Void, GitWorktree.Failure>
    ) -> String {
        guard case .failure(let failure) = cleanup else { return message }
        return message + " Cleanup also failed: " + failure.message
    }
}
