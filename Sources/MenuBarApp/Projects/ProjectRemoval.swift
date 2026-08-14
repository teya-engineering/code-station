import Foundation

// Taking a project out of the app. The action is offered from three places - the sidebar's
// context menu and the banner in each detail pane - and all three make the same promises
// about what goes and what stays, so the whole removal lives here rather than in each of
// them: a promise kept in one copy and forgotten in another is a promise the app breaks.
@MainActor
enum ProjectRemoval {

    // The removal end to end: ask, do the work, and say so if any of it failed. A caller
    // that borrowed only a piece of this would be one forgotten error report away from a
    // button that looks like it did nothing.
    static func confirm(_ project: Project, in store: ProjectStore, runner: SessionRunner,
                        dialogs: DialogPresenter, worktrees: WorktreeOperations = .live) {
        dialogs.show(confirmation(for: project, in: store) {
            Task {
                if case .failure(let failure) = await run(project, in: store, runner: runner,
                                                          worktrees: worktrees) {
                    dialogs.show(Dialog(title: failure.title, message: failure.message,
                                        actions: [.init(label: "OK", kind: .cancel)]))
                }
            }
        })
    }

    // Every session with a checkout in this project, which is more than the sessions that
    // call it home: a workspace session dies with any one of its repositories.
    static func sessions(using projectID: UUID, in store: ProjectStore) -> [ChatSession] {
        store.sidebarSessions.filter { session in
            store.checkoutProjects(for: session).contains { $0.projectID == projectID }
        }
    }

    // A task's folder was created by the app inside its own support directory, so deleting
    // the task takes the folder with it. A folder the user chose always stays.
    static func confirmation(for project: Project, in store: ProjectStore,
                             onConfirm: @escaping () -> Void) -> Dialog {
        let count = sessions(using: project.id, in: store).count
        let isTask = project.kind == .adHoc
        return Dialog(
            title: isTask ? "Delete \(project.name)?" : "Remove \(project.name)?",
            message: isTask
                ? "This drops its \(count) run\(count == 1 ? "" : "s") and deletes the task's folder, including any files the runs left in it."
                : "This drops \(count) session\(count == 1 ? "" : "s") that use it and removes their worktrees. It is also removed from every workspace. The folder itself stays on disk.",
            actions: [
                .init(label: isTask ? "Delete task" : "Remove project",
                      kind: .destructive, handler: onConfirm),
                .init(label: "Cancel", kind: .cancel)
            ])
    }

    // Sessions first, project last: a project dropped while one of its sessions survived
    // would leave that session with no home, so a session that refuses to go keeps the
    // project it belongs to. The sessions that did go are already gone by then, so what
    // is left is a project the reader can remove again once the refusal is dealt with.
    static func run(_ project: Project, in store: ProjectStore, runner: SessionRunner,
                    worktrees: WorktreeOperations = .live) async
        -> Result<Void, SessionLifecycle.Failure> {
        var failures: [SessionLifecycle.Failure] = []
        for session in sessions(using: project.id, in: store) {
            if case .failure(let failure) = await SessionLifecycle.remove(
                session, from: store, runner: runner, worktrees: worktrees) {
                failures.append(failure)
            }
        }
        guard failures.isEmpty else {
            // One failure speaks for itself; several are worth naming as a group before
            // the reasons, so the count is not something the reader has to work out.
            return .failure(SessionLifecycle.Failure(
                title: failures.count == 1
                    ? failures[0].title
                    : (project.kind == .adHoc
                       ? "Could not delete some runs"
                       : "Could not delete some sessions"),
                message: failures.map(\.message).joined(separator: "\n")))
        }
        store.removeProject(project.id)
        return .success(())
    }
}
