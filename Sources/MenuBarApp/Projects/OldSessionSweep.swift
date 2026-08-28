import Foundation

// Clearing old sessions without being asked each time. This is the only place in the app
// that deletes a session nobody chose, so it follows the explicit cleanup policy only
// after the session has remained eligible through a full warning hour and is neither open
// nor running. The policy decides whether generated Design files and uncommitted work are
// protected or are part of the unattended deletion.
@MainActor
enum OldSessionSweep {
    static let interval: Duration = .seconds(3_600)
    nonisolated static let gracePeriod: TimeInterval = 3_600
    // A backlog is cleared over several passes rather than in one go, so turning this on
    // with hundreds of stale sessions does not spend the next while shelling out to git.
    static let batchLimit = 50

    // The first pass only arms a session. Keeping the time in memory gives every newly
    // eligible session a full warning hour, including the first pass after launch.
    struct EligibilityBuffer {
        private var firstSeenAt: [UUID: Date] = [:]

        var nextReadyAt: Date? {
            firstSeenAt.values
                .map { $0.addingTimeInterval(OldSessionSweep.gracePeriod) }
                .min()
        }

        mutating func ready(_ sessions: [ChatSession], now: Date) -> [ChatSession] {
            let eligibleIDs = Set(sessions.map(\.id))
            firstSeenAt = firstSeenAt.filter { eligibleIDs.contains($0.key) }

            for session in sessions where firstSeenAt[session.id] == nil {
                firstSeenAt[session.id] = now
            }

            return sessions.filter { session in
                guard let firstSeen = firstSeenAt[session.id] else { return false }
                return now.timeIntervalSince(firstSeen) >= gracePeriod
            }
        }

        mutating func remove(_ sessionID: UUID) {
            firstSeenAt[sessionID] = nil
        }
    }

    // The order is the sheet's order, oldest first, so a capped pass takes the sessions
    // that have been sitting the longest. A session that is open or running is never old,
    // however long ago its last turn was: it is in use right now, which is the opposite
    // of stale.
    static func due(days: Int, in sessions: [ChatSession], now: Date = Date(),
                    isBusy: (UUID) -> Bool, isOpen: (UUID) -> Bool) -> [ChatSession] {
        Array(OldSessions.olderThan(days, in: sessions, now: now)
            .filter { !isBusy($0.id) && !isOpen($0.id) }
            .prefix(batchLimit))
    }

    @discardableResult
    static func run(days: Int, policy: OldSessionCleanupPolicy,
                    store: ProjectStore, runner: SessionRunner,
                    buffer: inout EligibilityBuffer, now: Date = Date(),
                    worktreeOperations: WorktreeOperations = .live,
                    inspect: SessionCost.Inspect = SessionCost.live) async -> Int {
        guard policy.deletesAutomatically else { return 0 }
        var deleted = 0
        let eligible = due(days: days, in: store.userSessions, now: now,
                           isBusy: { runner.state($0).isBusy },
                           isOpen: { store.selection == .session($0) })
        let due = buffer.ready(eligible, now: now)
        // Reading git takes time, and the app keeps running while it does: a session that
        // has since been opened, picked up, or removed by hand is no longer ours to take,
        // so this is asked again on the far side of every wait.
        let stillStale = { (session: ChatSession) in
            store.session(session.id) != nil
                && store.selection != .session(session.id)
                && !runner.state(session.id).isBusy
        }

        for session in due {
            guard !Task.isCancelled else { break }
            guard stillStale(session) else { continue }
            var cost: SessionRemovalCost?
            if !policy.includesSavedWork {
                let settled = await SessionCost.settledCost(
                    worktrees: store.checkoutProjects(for: session).compactMap(\.worktreePath),
                    deletesDesignArtifacts: store.hasDesignArtifacts(for: session),
                    inspect: inspect)
                guard settled.losesNothing else { continue }
                cost = settled
            }
            guard stillStale(session) else { continue }

            let outcome = cost?.label ?? "unchecked"
            SessionLog.note(
                "auto deletion started policy=\(policy.rawValue) outcome=\(outcome)",
                session: session.id)
            let result = await SessionLifecycle.remove(
                session, from: store, runner: runner, worktrees: worktreeOperations)
            if case .failure(let failure) = result {
                SessionLog.note("auto deletion failed reason=\(failure.title)", session: session.id)
            } else {
                buffer.remove(session.id)
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
