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
                    dialogs.show(.notice(failure.title, message: failure.message))
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
        let checkouts = store.checkoutProjects(for: session)
        let worktrees = checkouts.compactMap(\.worktreePath)
        let dirty = worktrees.count { workingTrees.isDirty($0) }
        let removesDesign = store.hasDesignArtifacts(for: session)
        let project = store.project(session.projectID)
        let isTaskRun = project?.kind == .adHoc

        var rows = [Dialog.Impact.Row(title: "Conversation history",
                                      detail: "Removed from Code Station.")]
        if removesDesign {
            rows.append(.init(title: "Generated Design files", detail: "Permanently removed."))
        }
        if !worktrees.isEmpty {
            rows.append(.init(
                title: counted(worktrees.count, "worktree"),
                detail: "Removed from disk."
                    + (dirty > 0
                       ? " \(dirty) \(dirty == 1 ? "has" : "have") uncommitted changes that will be lost."
                       : " Branches are kept if they have unmerged commits.")))
        }
        if isTaskRun {
            rows.append(.init(title: "Task folder stays",
                              detail: "Files this run wrote in it are kept.", kept: true))
        } else {
            // A checkout without a worktree is the project folder itself, which the session
            // only borrowed.
            let shared = checkouts.filter { $0.worktreePath == nil }
                .compactMap { store.project($0.projectID)?.collapsedPath }
            if !shared.isEmpty {
                rows.append(.init(title: shared.count == 1 ? "Project folder stays" : "Project folders stay",
                                  detail: shared.joined(separator: "\n"), kept: true))
            }
        }

        let subject: Dialog.Impact.Subject? = if let workspace = session.workspaceID.flatMap(store.workspace) {
            .init(name: workspace.name, kind: .workspace)
        } else if let project {
            .init(name: project.name, kind: isTaskRun ? .task : .project)
        } else {
            nil
        }
        let deleteLabel = if isTaskRun {
            "Delete run"
        } else if removesDesign {
            worktrees.isEmpty ? "Delete session and Design files" : "Delete session and files"
        } else {
            worktrees.isEmpty ? "Delete session" : "Delete session and worktrees"
        }
        return .impact(isTaskRun ? "Delete this run?" : "Delete this session?",
                       message: session.title,
                       subject: subject, rows: rows,
                       warning: dirty > 0
                           ? "Uncommitted changes and conversation history cannot be restored."
                           : "Conversation history cannot be restored.",
                       compact: true, action: deleteLabel, handler: onConfirm)
    }

    // Removes each session, keeping going after one refuses so that a single session still
    // running does not strand the rest. One failure speaks for itself; several are worth
    // naming as a group before the reasons, so the count is not something the reader has
    // to work out. The group is named by the caller, since a task's sessions are its runs.
    static func run(_ sessions: [ChatSession], in store: ProjectStore, runner: SessionRunner,
                    worktrees: WorktreeOperations = .live, groupNoun: String = "sessions") async
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
                title: failures.count == 1 ? failures[0].title : "Could not delete some \(groupNoun)",
                message: failures.map(\.message).joined(separator: "\n")))
        }
        return .success(())
    }
}
