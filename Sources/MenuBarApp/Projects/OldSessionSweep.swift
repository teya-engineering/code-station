import Foundation

// Clearing old sessions without being asked each time. This is the only place in the app
// that deletes a session nobody chose, so the rule it works to is the narrowest one: the
// session has gone quiet, it is not running, and git has said its worktree holds nothing.
// A worktree with uncommitted work, or one git could not read, is left where it is and
// stays in the review sheet for a person to decide on.
@MainActor
enum OldSessionSweep {
    static let interval: Duration = .seconds(3_600)
    // A backlog is cleared over several passes rather than in one go, so turning this on
    // with hundreds of stale sessions does not spend the next while shelling out to git.
    static let batchLimit = 50

    // The order is the sheet's order, oldest first, so a capped pass takes the sessions
    // that have been sitting the longest. A session that is running is never old, however
    // long ago its last turn was: it is busy right now, which is the opposite of stale.
    static func due(days: Int, in sessions: [ChatSession], now: Date = Date(),
                    isBusy: (UUID) -> Bool) -> [ChatSession] {
        Array(OldSessions.olderThan(days, in: sessions, now: now)
            .filter { !isBusy($0.id) }
            .prefix(batchLimit))
    }

    @discardableResult
    static func run(days: Int, store: ProjectStore, runner: SessionRunner,
                    inspect: SessionCost.Inspect = SessionCost.live) async -> Int {
        var deleted = 0
        let due = due(days: days, in: store.sessions) { runner.state($0).isBusy }
        // Reading git takes time, and the app keeps running while it does: a session that
        // has since been picked up or removed by hand is no longer ours to take, so this
        // is asked again on the far side of every wait.
        let stillStale = { (session: ChatSession) in
            store.session(session.id) != nil && !runner.state(session.id).isBusy
        }

        for session in due {
            guard !Task.isCancelled else { break }
            guard stillStale(session) else { continue }
            let worktrees = store.checkoutProjects(for: session).compactMap(\.worktreePath)
            let outcome = await SessionCost.settledOutcome(worktrees: worktrees,
                                                           inspect: inspect)
            guard outcome.losesNothing, stillStale(session) else { continue }

            SessionLog.note("auto deletion started outcome=\(outcome.label)", session: session.id)
            let result = await SessionLifecycle.remove(session, from: store, runner: runner)
            if case .failure(let failure) = result {
                SessionLog.note("auto deletion failed reason=\(failure.title)", session: session.id)
            } else {
                deleted += 1
                SessionLog.note("auto deletion finished", session: session.id)
            }
        }
        if deleted > 0 {
            SessionLog.note("old session sweep deleted count=\(deleted) days=\(days)")
        }
        return deleted
    }
}
