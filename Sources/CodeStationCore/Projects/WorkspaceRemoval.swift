import Foundation

// Deleting a workspace. The action is offered from the sidebar's context menu and from the
// foot of the workspace's own screen, and both take the same things away with it - every
// session in it, their worktrees, any generated Design files - while the projects it
// groups stay where they are. The description and the work live here rather than in each
// of them: a promise kept in one copy and forgotten in another is a promise the app breaks.
@MainActor
public enum WorkspaceRemoval {
    // Sessions first, workspace last: a session that refuses to go keeps the workspace it
    // belongs to, so a worktree that cannot be removed is never left behind as a checkout
    // nothing points at.
    public static func run(_ workspace: ProjectWorkspace, in store: ProjectStore, runner: SessionRunner,
                    worktrees: WorktreeOperations = .live) async
        -> Result<Void, SessionLifecycle.Failure> {
        let result = await SessionRemoval.run(store.sessions(in: workspace.id), in: store,
                                              runner: runner, worktrees: worktrees)
        if case .success = result { store.removeWorkspace(workspace.id) }
        return result
    }
}

extension WorkspaceRemoval {
    // What deleting the workspace takes and leaves, as the GUI's dialog and the terminal's
    // confirmation both say it. A workspace is only a grouping of folders added
    // elsewhere, so the projects stay. Its sessions cannot exist outside it and go with
    // it, worktrees and all.
    public static func impact(of workspace: ProjectWorkspace, in store: ProjectStore) -> RemoteImpact {
        let sessions = store.sessions(in: workspace.id)
        let count = sessions.count
        let designs = sessions.count { store.hasDesignArtifacts(for: $0) }
        let worktreeCount = sessions.reduce(0) {
            $0 + store.checkoutProjects(for: $1).compactMap(\.worktreePath).count
        }
        let projectNames = workspace.projectIDs.compactMap { store.project($0)?.name }

        var rows = [RemoteImpact.Row(
            title: "\(counted(count, "session")) and \(counted(worktreeCount, "worktree"))",
            detail: count == 0 ? "No sessions or worktrees to remove."
                : "Session history is removed from Code Station."
                    + (worktreeCount > 0 ? " Worktrees are removed from disk." : ""))]
        if designs > 0 {
            rows.append(.init(title: "Generated Design files",
                              detail: "Permanently removed from \(counted(designs, "session"))."))
        }
        rows.append(.init(title: projectNames.count == 1 ? "Its project stays" : "Its projects stay",
                          detail: projectNames.isEmpty
                              ? "Projects and their folders are not touched."
                              : projectNames.joined(separator: ", "),
                          kept: true))

        return RemoteImpact(title: "Delete \(workspace.name)?",
                            message: "This workspace and its sessions will leave Code Station.",
                            subject: .init(name: workspace.name, kind: .workspace),
                            rows: rows, warning: count > 0 ? "Session history cannot be restored." : nil,
                            action: "Delete workspace")
    }
}
