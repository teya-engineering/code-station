import Foundation

// Deleting a session. The action is offered from the sidebar's context menu and from every
// detail pane, and all of them take the same things away with it - the conversation, any
// worktrees, any generated Design files - so the description and the work live here rather
// than in each of them: a promise kept in one copy and forgotten in another is a promise
// the app breaks.
@MainActor
enum SessionRemoval {

    // The removal end to end: ask, do the work, and say so if any of it failed. A caller
    // that borrowed only a piece of this would be one forgotten error report away from a
    // button that looks like it did nothing.
    static func confirm(_ session: ChatSession, in store: ProjectStore, runner: SessionRunner,
                        workingTrees: WorkingTreeWatch, dialogs: DialogPresenter,
                        worktrees: WorktreeOperations = .live,
                        onSuccess: (() -> Void)? = nil) {
        dialogs.show(confirmation(for: session, in: store, workingTrees: workingTrees) {
            Task {
                switch await run([session], in: store, runner: runner, worktrees: worktrees) {
                case .success:
                    onSuccess?()
                case .failure(let failure):
                    dialogs.show(Dialog(title: failure.title, message: failure.message,
                                        actions: [.init(label: "OK", kind: .cancel)]))
                }
            }
        })
    }

    // What goes with the session, named before it goes. The worktrees are counted rather
    // than listed because they are the part of this that touches disk, and the dirty ones
    // are called out separately because they are the part that cannot be got back. A run
    // of a task keeps the folder it wrote in, which is worth saying: the folder belongs to
    // the task rather than to the run.
    static func confirmation(for session: ChatSession, in store: ProjectStore,
                             workingTrees: WorkingTreeWatch,
                             onConfirm: @escaping () -> Void) -> Dialog {
        let worktrees = store.checkoutProjects(for: session).compactMap(\.worktreePath)
        let dirty = worktrees.count { workingTrees.isDirty($0) }
        let removesDesign = store.hasDesignArtifacts(for: session)
        let isTaskRun = store.project(session.projectID)?.kind == .adHoc

        var consequences = ["Its conversation history is removed from the app."]
        if isTaskRun {
            consequences.append("Files it wrote in the task folder stay.")
        }
        if removesDesign {
            consequences.append("Its generated Design files are permanently removed.")
        }
        if !worktrees.isEmpty {
            consequences.append(
                "Its \(worktrees.count) worktree\(worktrees.count == 1 ? " goes" : "s go") with it."
                    + (dirty > 0
                       ? " \(dirty) \(dirty == 1 ? "has" : "have") uncommitted changes that will be lost."
                       : " Branches are kept if they have unmerged commits."))
        }

        let deleteLabel = if isTaskRun {
            "Delete run"
        } else if removesDesign {
            worktrees.isEmpty ? "Delete session and Design files" : "Delete session and files"
        } else {
            worktrees.isEmpty ? "Delete session" : "Delete session and worktrees"
        }
        return Dialog(
            title: "Delete \"\(session.title)\"?",
            message: consequences.joined(separator: " "),
            actions: [
                .init(label: deleteLabel, kind: .destructive, handler: onConfirm),
                .init(label: "Cancel", kind: .cancel)
            ])
    }

    // Removes each session, keeping going after one refuses so that a single session still
    // running does not strand the rest. One failure speaks for itself; several are worth
    // naming as a group before the reasons, so the count is not something the reader has
    // to work out.
    static func run(_ sessions: [ChatSession], in store: ProjectStore, runner: SessionRunner,
                    worktrees: WorktreeOperations = .live) async
        -> Result<Void, SessionLifecycle.Failure> {
        var failures: [SessionLifecycle.Failure] = []
        for session in sessions {
            if case .failure(let failure) = await SessionLifecycle.remove(
                session, from: store, runner: runner, worktrees: worktrees) {
                failures.append(failure)
            }
        }
        guard failures.isEmpty else {
            return .failure(SessionLifecycle.Failure(
                title: failures.count == 1 ? failures[0].title : "Could not delete some sessions",
                message: failures.map(\.message).joined(separator: "\n")))
        }
        return .success(())
    }
}
