import Foundation

// Deleting a session. The action is offered from the sidebar's context menu and from every
// detail pane, and all of them take the same things away with it - the conversation, any
// worktrees, any generated Design files - so the description and the work live here rather
// than in each of them: a promise kept in one copy and forgotten in another is a promise
// the app breaks.
@MainActor
public enum SessionRemoval {
    // Removes each session, keeping going after one refuses so that a single session still
    // running does not strand the rest. One failure speaks for itself; several are worth
    // naming as a group before the reasons, so the count is not something the reader has
    // to work out. The group is named by the caller, since a task's sessions are its runs.
    public static func run(_ sessions: [ChatSession], in store: ProjectStore, runner: SessionRunner,
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
