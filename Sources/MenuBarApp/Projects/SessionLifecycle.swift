import Foundation

// A checkout a session records whose folder is no longer on disk, and which the app still
// has what it needs to build again. Worked out once, so the banner that offers the rebuild,
// the confirmation that describes it and the rebuild itself all speak about the same set of
// folders rather than each deciding for itself.
struct LostCheckout: Equatable, Sendable {
    let path: String
    let branch: String
    let projectPath: String
}

// A lost checkout paired with where its commits would come from. That pairing is the whole
// of what a rebuild can honestly promise, so it is made before the offer and carried
// through to the work.
struct PlannedRebuild: Equatable, Sendable {
    let checkout: LostCheckout
    let source: GitWorktree.RestoreSource
}

struct WorktreeOperations: Sendable {
    let addProject: @Sendable (String, String, UUID, String?) async
        -> Result<GitWorktree.Created, GitWorktree.Failure>
    let addWorkspaceProject: @Sendable (String, String, UUID, UUID, String?) async
        -> Result<GitWorktree.Created, GitWorktree.Failure>
    let remove: @Sendable (String, String?, String?) async
        -> Result<Void, GitWorktree.Failure>
    // Defaulted, unlike its neighbours, so the stubs that only ever add or remove a worktree
    // do not have to name an operation they never reach.
    var restore: @Sendable (PlannedRebuild) async -> Result<Void, GitWorktree.Failure> = {
        await GitWorktree.restore(worktreePath: $0.checkout.path, branch: $0.checkout.branch,
                                  projectPath: $0.checkout.projectPath, from: $0.source)
    }

    static let live = WorktreeOperations(
        addProject: { path, name, sessionID, base in
            await GitWorktree.add(projectPath: path, projectName: name,
                                  sessionID: sessionID, from: base)
        },
        addWorkspaceProject: { path, name, projectID, sessionID, base in
            await GitWorktree.add(projectPath: path, projectName: name,
                                  projectID: projectID, sessionID: sessionID, from: base)
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
                                      base: String?, agent: AgentKind = .claudeCode,
                                      model: String? = nil, agentAvatarName: String? = nil,
                                      mode: SessionMode = .chat,
                                      store: ProjectStore,
                                      worktrees: WorktreeOperations = .live) async
        -> Result<ChatSession, Failure> {
        guard store.project(project.id) != nil else {
            return .failure(Failure(
                title: "Could not create the session",
                message: "The project is no longer in the app."))
        }

        let planned = GitWorktree.plan(projectName: project.name, sessionID: sessionID)
        var reservations = [planned.path]
        store.reserveWorktree(at: planned.path, for: project.id)
        defer {
            for path in reservations {
                store.releaseWorktreeReservation(at: path, for: project.id)
            }
        }

        switch await worktrees.addProject(project.path, project.name, sessionID, base) {
        case .failure(let failure):
            return .failure(Failure(title: "Could not create a worktree",
                                    message: failure.message))
        case .success(let created):
            if !reservations.contains(created.path) {
                reservations.append(created.path)
                store.reserveWorktree(at: created.path, for: project.id)
            }
            let worktree = CreatedWorktree(path: created.path, projectPath: project.path,
                                           branch: created.branch)
            guard store.project(project.id) != nil else {
                return await creationFailure("The project is no longer in the app.",
                                             created: [worktree], worktrees: worktrees)
            }
            switch store.insertSession(in: project.id,
                                       worktreePath: created.path,
                                       worktreeBranch: created.branch,
                                       seed: .init(id: sessionID, agent: agent, model: model,
                                                   agentAvatarName: agentAvatarName,
                                                   mode: mode)) {
            case .success(let session):
                return .success(session)
            case .failure(let failure):
                return await creationFailure(failure.message,
                                             title: "Could not save the session",
                                             created: [worktree], worktrees: worktrees)
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
        var reservations: [(projectID: UUID, path: String)] = []
        defer {
            for reservation in reservations {
                store.releaseWorktreeReservation(at: reservation.path,
                                                 for: reservation.projectID)
            }
        }

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

            let planned = GitWorktree.plan(projectName: project.name, projectID: project.id,
                                           sessionID: choice.sessionID)
            store.reserveWorktree(at: planned.path, for: project.id)
            reservations.append((project.id, planned.path))
            switch await worktrees.addWorkspaceProject(
                project.path, project.name, project.id, choice.sessionID, selected.base) {
            case .success(let worktree):
                if worktree.path != planned.path {
                    store.reserveWorktree(at: worktree.path, for: project.id)
                    reservations.append((project.id, worktree.path))
                }
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

        switch store.insertSession(in: workspace.id, projects: checkouts,
                                   seed: .init(id: choice.sessionID, agent: choice.agent,
                                               model: choice.model,
                                               agentAvatarName: choice.agentAvatarName,
                                               mode: choice.mode)) {
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
        let design = current.isDesignSession ? nil : store.designSession(for: current.id)
        guard runner.beginRemoval(current.id) else {
            return .failure(Failure(
                title: "Could not delete the session",
                message: "Stop this session before deleting it."))
        }
        if let design {
            guard runner.beginRemoval(design.id) else {
                runner.cancelRemoval(current.id)
                return .failure(Failure(
                    title: "Could not delete the session",
                    message: "Stop its Design session before deleting it."))
            }
            switch store.removeSession(design.id) {
            case .success:
                runner.finishRemoval(design.id)
            case .failure(let failure):
                runner.cancelRemoval(design.id)
                runner.cancelRemoval(current.id)
                return .failure(Failure(title: "Could not delete the Design session",
                                        message: failure.message))
            }
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

    // MARK: - Rebuilding a lost checkout

    // Every folder the session works in that is not there any more, in the order the session
    // lists them. A handful of stat calls, cheap enough to keep asking on a timer.
    static func missingDirectories(of session: ChatSession, in store: ProjectStore) -> [String] {
        store.workingDirectories(for: session).filter {
            !FileManager.default.fileExists(atPath: $0)
        }
    }

    // The lost folders a rebuild could put back, which is fewer than the folders that are
    // gone. A workspace member checked out in the project folder itself has no worktree of
    // its own, so there is nothing here to rebuild: putting the user's own directory back is
    // not something the app can offer.
    static func rebuildableCheckouts(of session: ChatSession,
                                     in store: ProjectStore) -> [LostCheckout] {
        store.checkoutProjects(for: session).compactMap { checkout in
            guard let path = checkout.worktreePath,
                  !FileManager.default.fileExists(atPath: path),
                  let branch = checkout.worktreeBranch,
                  let project = store.project(checkout.projectID),
                  FileManager.default.fileExists(atPath: project.path) else { return nil }
            return LostCheckout(path: path, branch: branch, projectPath: project.path)
        }
    }

    // Asked before the rebuild is offered, so the confirmation can name the source, and
    // handed to `rebuild` unchanged so the work matches the description. A checkout git
    // cannot answer for drops out: with no answer there is nothing honest to promise.
    static func planRebuild(_ checkouts: [LostCheckout],
                            source: (String, String) async -> GitWorktree.RestoreSource?
                                = { await GitWorktree.restoreSource(of: $0, projectPath: $1) })
        async -> [PlannedRebuild] {
        var plan: [PlannedRebuild] = []
        for checkout in checkouts {
            guard let found = await source(checkout.branch, checkout.projectPath) else { continue }
            plan.append(PlannedRebuild(checkout: checkout, source: found))
        }
        return plan
    }

    // Nothing is written to the store, which is the point: `GitWorktree.plan` derives a
    // checkout's path and branch from the session id, so what comes back is what the session
    // already records, and a record that was never wrong does not need correcting. The
    // conversation keeps its history because the session was never replaced.
    static func rebuild(_ plan: [PlannedRebuild],
                        worktrees: WorktreeOperations = .live) async -> Result<Void, Failure> {
        var failures: [String] = []
        for step in plan {
            if case .failure(let failure) = await worktrees.restore(step) {
                failures.append(failure.message)
            }
        }
        guard failures.isEmpty else {
            return .failure(Failure(
                title: failures.count == plan.count ? "Could not rebuild the checkout"
                                                    : "Only some folders came back",
                message: failures.joined(separator: "\n")))
        }
        return .success(())
    }

    // Where the work comes from goes first and is named. Someone pressing the button is
    // asking one question - do I get my commits back - and a sentence about consequences
    // that reads the same whichever case they are in does not answer it.
    static func rebuildMessage(for plan: [PlannedRebuild]) -> String {
        if plan.count == 1, let only = plan.first {
            let branch = only.checkout.branch
            switch only.source {
            case .localBranch:
                return "\(branch) is still on this machine, so its commits come back. "
                    + "Anything never committed is gone."
            case .remoteBranch(let ref):
                return "\(branch) is gone from this machine, but \(shortRef(ref)) still has it, "
                    + "so its commits come back. Anything never committed is gone."
            case .projectHead:
                return "\(branch) is gone from this machine and from every remote. The folder "
                    + "starts from the project's current checkout, and work committed only on "
                    + "that branch cannot be recovered."
            }
        }

        let kept = plan.count { $0.source.keepsCommits }
        let lost = plan.count - kept
        var lines: [String] = []
        if kept > 0 {
            lines.append(kept == 1
                ? "One still has its branch, here or on a remote, so its commits come back."
                : "\(kept) still have their branch, here or on a remote, so their commits "
                    + "come back.")
        }
        if lost > 0 {
            lines.append((lost == 1 ? "One has lost its branch everywhere and starts"
                                    : "\(lost) have lost their branch everywhere and start")
                + " from the project's current checkout. Work committed only there cannot be "
                + "recovered.")
        }
        return lines.joined(separator: "\n\n")
    }

    // refs/remotes/origin/code-station/abc reads as origin/code-station/abc, the name git uses
    // everywhere else the reader sees it.
    private static func shortRef(_ ref: String) -> String {
        let prefix = "refs/remotes/"
        return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
    }

    @discardableResult
    static func resumePendingRemovals(
        in store: ProjectStore,
        worktrees: WorktreeOperations = .live
    ) async -> [Failure] {
        // Checkouts moved aside by the last run are unlinked from here, since a deletion
        // the app was killed part way through leaves the folder waiting rather than gone.
        WorktreeTrash.empty()
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

    // A session that could not be made leaves nothing behind: the worktrees made for it
    // go too, newest first, and a cleanup that fails is said alongside the reason.
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
}
