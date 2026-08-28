import Foundation

// Deleting a workspace. The action is offered from the sidebar's context menu and from the
// foot of the workspace's own screen, and both take the same things away with it - every
// session in it, their worktrees, any generated Design files - while the projects it
// groups stay where they are. The description and the work live here rather than in each
// of them: a promise kept in one copy and forgotten in another is a promise the app breaks.
@MainActor
enum WorkspaceRemoval {

    // The removal end to end: ask, do the work, and say so if any of it failed. A caller
    // that borrowed only a piece of this would be one forgotten error report away from a
    // button that looks like it did nothing.
    static func confirm(_ workspace: ProjectWorkspace, in store: ProjectStore,
                        runner: SessionRunner, dialogs: DialogPresenter,
                        worktrees: WorktreeOperations = .live) {
        dialogs.show(confirmation(for: workspace, in: store) {
            Task {
                if case .failure(let failure) = await run(workspace, in: store, runner: runner,
                                                          worktrees: worktrees) {
                    dialogs.show(.notice(failure.title, message: failure.message))
                }
            }
        })
    }

    // A workspace is only a grouping of folders added elsewhere, so the projects stay. Its
    // sessions cannot exist outside it and go with it, worktrees and all.
    static func confirmation(for workspace: ProjectWorkspace, in store: ProjectStore,
                             onConfirm: @escaping () -> Void) -> Dialog {
        let sessions = store.sessions(in: workspace.id)
        let designs = sessions.count { store.hasDesignArtifacts(for: $0) }
        var message = "This drops \(counted(sessions.count, "session")) and removes their worktrees. The \(workspace.projectIDs.count) projects it groups stay."
        if designs > 0 {
            message += designs == 1
                ? " One session contains generated Design files that are permanently removed."
                : " \(designs) sessions contain generated Design files that are permanently removed."
        }
        return .confirm("Delete \(workspace.name)?", message: message,
                        action: "Delete workspace", handler: onConfirm)
    }

    // Sessions first, workspace last: a session that refuses to go keeps the workspace it
    // belongs to, so a worktree that cannot be removed is never left behind as a checkout
    // nothing points at.
    static func run(_ workspace: ProjectWorkspace, in store: ProjectStore, runner: SessionRunner,
                    worktrees: WorktreeOperations = .live) async
        -> Result<Void, SessionLifecycle.Failure> {
        let result = await SessionRemoval.run(store.sessions(in: workspace.id), in: store,
                                              runner: runner, worktrees: worktrees)
        if case .success = result { store.removeWorkspace(workspace.id) }
        return result
    }
}
