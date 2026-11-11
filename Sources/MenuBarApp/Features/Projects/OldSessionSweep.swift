import Foundation

// Clearing old sessions without being asked each time. This is the only place in the app
// that deletes a session nobody chose, so it follows the explicit cleanup policy only
// after a full warning hour and only for sessions that are neither open nor running. The
// policy decides whether generated Design files and uncommitted work are protected, part
// of the unattended deletion, or held back until the person says yes.
@MainActor
enum OldSessionSweep {
    static let monitorInterval: Duration = .seconds(1)
    nonisolated static let gracePeriod: TimeInterval = 3_600
    nonisolated static let retryInterval: TimeInterval = 3_600
    // A backlog is cleared over several cohorts rather than in one go, so turning this on
    // with hundreds of stale sessions does not spend the next while shelling out to git.
    static let batchLimit = 50

    // What the sidebar puts next to its countdown: when the sweep runs, and how many
    // sessions it will take when it does.
    struct Deletion: Equatable {
        let at: Date
        let sessions: Int
    }

    // A session the sweep would have taken but will not without a yes. Nothing about it
    // runs out: it waits in the sidebar until someone answers or it stops being old.
    struct Parked: Equatable {
        enum Reason: Equatable {
            case unread
            case savedWork
        }

        let id: UUID
        let reason: Reason
    }

    // One cohort waits at a time. Its members are settled when the countdown starts, so a
    // session that goes quiet during the hour waits for the next cohort rather than
    // joining a deletion that has already been counted and shown. Members can still drop
    // out, so the number on the strip only ever falls.
    struct EligibilityBuffer {
        private(set) var cohort: [UUID] = []
        // Kept apart from the cohort and its clock: these are never deleted here, so they
        // have no deadline to count down to.
        private(set) var parked: [Parked] = []
        private var deadline: Date?
        // Settling a cohort reads git when the policy spares saved work. If every
        // candidate turns out to hold work there is nothing to arm, and asking again a
        // second later would read the same worktrees for the same answer.
        private var nextArmingAt: Date = .distantPast

        var deletion: Deletion? {
            deadline.map { Deletion(at: $0, sessions: cohort.count) }
        }

        var isArmed: Bool { deadline != nil }

        func canArm(now: Date) -> Bool { deadline == nil && now >= nextArmingAt }

        func isDue(now: Date) -> Bool {
            guard let deadline else { return false }
            return now >= deadline
        }

        mutating func arm(_ sessions: [UUID], now: Date) {
            guard !sessions.isEmpty else {
                nextArmingAt = now.addingTimeInterval(OldSessionSweep.retryInterval)
                return
            }
            cohort = sessions
            deadline = now.addingTimeInterval(OldSessionSweep.gracePeriod)
        }

        // A session picked up, pinned, snoozed or removed by hand is no longer ours to
        // take, so it leaves the cohort and the countdown covers one session fewer.
        mutating func keepOnly(_ eligible: Set<UUID>) {
            guard isArmed else { return }
            cohort = cohort.filter(eligible.contains)
            if cohort.isEmpty { disarm() }
        }

        mutating func disarm() {
            cohort = []
            deadline = nil
        }

        // Each settling pass decides the saved-work part of the list again, so a session
        // whose work has since been committed goes back to being swept like any other.
        mutating func parkSavedWork(_ ids: [UUID]) {
            parked = parked.filter { $0.reason == .unread }
            for id in ids { park(Parked(id: id, reason: .savedWork)) }
        }

        mutating func clearParked() {
            parked = []
        }

        mutating func park(_ session: Parked) {
            guard !parked.contains(where: { $0.id == session.id }) else { return }
            parked.append(session)
        }

        // A parked session leaves as soon as it is no longer old, or was parked for being
        // unread and has since been read. The way out costs no git read, so it is taken
        // on every pass rather than waiting for the next cohort.
        mutating func keepParkedOnly(_ candidates: Set<UUID>, isUnread: (UUID) -> Bool) {
            parked = parked.filter {
                candidates.contains($0.id) && ($0.reason != .unread || isUnread($0.id))
            }
        }
    }

    // The order is the sheet's order, oldest first, so a capped cohort takes the sessions
    // that have been sitting the longest. A session that is pinned, open, or running is
    // never eligible, however long ago its last turn was, and neither is one whose project
    // is snoozed: the filter is inherited, so the countdown in the sidebar and the
    // deletion behind it stop for that project together.
    static func due(days: Int, in sessions: [ChatSession], now: Date = Date(),
                    isBusy: (UUID) -> Bool, isOpen: (UUID) -> Bool,
                    snoozedUntil: OldSessions.SnoozeDeadline = { _ in nil },
                    isUnread: OldSessions.UnreadCheck = { _ in false }) -> [ChatSession] {
        OldSessions.olderThan(days, in: sessions, now: now, snoozedUntil: snoozedUntil,
                              isUnread: isUnread)
            .filter { !isBusy($0.id) && !isOpen($0.id) }
    }

    @discardableResult
    static func run(days: Int, policy: OldSessionCleanupPolicy,
                    store: ProjectStore, runner: SessionRunner,
                    buffer: inout EligibilityBuffer, now: Date = Date(),
                    worktreeOperations: WorktreeOperations = .live,
                    inspect: SessionCost.Inspect = SessionCost.live) async -> Int {
        guard policy.deletesAutomatically else {
            buffer.disarm()
            buffer.clearParked()
            return 0
        }

        let isBusy = { (id: UUID) in runner.isBusy(id, store: store) }
        let isOpen = { (id: UUID) in store.selection == .session(id) }
        let snoozedUntil = { (session: ChatSession) in store.snoozeDeadline(for: session) }
        let eligible = due(days: days, in: store.sidebarSessions, now: now,
                           isBusy: isBusy, isOpen: isOpen, snoozedUntil: snoozedUntil,
                           isUnread: store.isUnread)
        buffer.keepOnly(Set(eligible.map(\.id)))

        // Unread is the one thing that keeps a session out of the sweep and still lets
        // it be offered for a yes, so it is left out of this list only. Knowing a session
        // is unread costs no git read, so these are picked up on every pass.
        if policy.asksAboutRest {
            let oldByAge = due(days: days, in: store.sidebarSessions, now: now,
                               isBusy: isBusy, isOpen: isOpen, snoozedUntil: snoozedUntil)
            buffer.keepParkedOnly(Set(oldByAge.map(\.id)), isUnread: store.isUnread)
            for session in oldByAge where store.isUnread(session.id) {
                buffer.park(Parked(id: session.id, reason: .unread))
            }
        } else {
            buffer.clearParked()
        }

        if buffer.canArm(now: now), !eligible.isEmpty {
            var cohort: [UUID] = []
            var savedWork: [UUID] = []
            for session in eligible.prefix(batchLimit) {
                guard !Task.isCancelled else { return 0 }
                // Under a policy that spares saved work the cohort is settled before the
                // countdown starts, so the number the sidebar shows is the number the
                // sweep will take rather than a ceiling on it.
                if policy.includesSavedWork {
                    cohort.append(session.id)
                    continue
                }
                let cost = await cost(of: session, in: store, inspect: inspect)
                if cost.losesNothing {
                    cohort.append(session.id)
                } else if policy.asksAboutRest, cost.losesWork {
                    savedWork.append(session.id)
                }
            }
            guard !Task.isCancelled else { return 0 }
            buffer.arm(cohort, now: now)
            if policy.asksAboutRest { buffer.parkSavedWork(savedWork) }
            return 0
        }

        guard buffer.isDue(now: now) else { return 0 }

        // Reading git takes time, and the app keeps running while it does: a session that
        // has since been opened, picked up, or removed by hand is no longer ours to take,
        // so this is asked again on the far side of every wait.
        let stillStale = { (sessionID: UUID) in
            guard let session = store.session(sessionID) else { return false }
            return !OldSessions.isKept(session, now: now, isUnread: store.isUnread)
                && store.selection != .session(sessionID)
                && !runner.isBusy(sessionID, store: store)
                && !ProjectSnooze.isActive(store.snoozeDeadline(for: session), now: now)
        }

        var deleted = 0
        for sessionID in buffer.cohort {
            guard !Task.isCancelled else { break }
            guard stillStale(sessionID), let session = store.session(sessionID) else { continue }
            var settled: SessionRemovalCost?
            if !policy.includesSavedWork {
                // An hour has passed since the cohort was settled, so the worktrees are
                // read once more. Work started in the meantime is still work, and sparing
                // it matters more than the count on the strip holding still.
                let cost = await cost(of: session, in: store, inspect: inspect)
                guard cost.losesNothing else {
                    if policy.asksAboutRest, cost.losesWork, stillStale(sessionID) {
                        buffer.park(Parked(id: sessionID, reason: .savedWork))
                    }
                    continue
                }
                settled = cost
            }
            guard stillStale(sessionID) else { continue }

            let outcome = settled?.label ?? "unchecked"
            SessionLog.note(
                "auto deletion started policy=\(policy.rawValue) outcome=\(outcome)",
                session: sessionID)
            let result = await SessionLifecycle.remove(
                session, from: store, runner: runner, worktrees: worktreeOperations)
            if case .failure(let failure) = result {
                SessionLog.note("auto deletion failed reason=\(failure.title)", session: sessionID)
            } else {
                deleted += 1
                SessionLog.note("auto deletion finished", session: sessionID)
            }
        }
        // The cohort has had its turn either way. Anything it could not take is offered
        // again by the next one, which starts its own hour rather than inheriting this.
        buffer.disarm()
        if deleted > 0 {
            SessionLog.note("old session sweep deleted count=\(deleted) days=\(days)")
        }
        return deleted
    }

    private static func cost(of session: ChatSession, in store: ProjectStore,
                             inspect: SessionCost.Inspect) async -> SessionRemovalCost {
        await SessionCost.settledCost(
            worktrees: store.checkoutProjects(for: session).compactMap(\.worktreePath),
            design: store.designCost(for: session),
            inspect: inspect)
    }
}
