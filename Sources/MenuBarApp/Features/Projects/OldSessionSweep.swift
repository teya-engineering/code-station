import Foundation

// Clearing old sessions without being asked each time. This is the only place in the app
// that deletes a session nobody chose, so it only ever takes what loses nothing and has
// been seen, after a full warning hour, and only sessions that are neither open nor
// running. Anything old with a reason on the "ask me first" list waits for a yes instead,
// however old it gets. Orphaned worktrees follow the same rule when the person has asked
// for that: a clean one goes with the countdown, one with changes waits.
@MainActor
enum OldSessionSweep {
    static let monitorInterval: Duration = .seconds(1)
    nonisolated static let gracePeriod: TimeInterval = 3_600
    nonisolated static let retryInterval: TimeInterval = 3_600
    // A backlog is cleared over several cohorts rather than in one go, so turning this on
    // with hundreds of stale sessions does not spend the next while shelling out to git.
    static let batchLimit = 50

    typealias PruneOrphans = ([OrphanedWorktree]) async -> Int

    // What the sidebar puts next to its countdown: when the sweep runs, and what it will
    // take when it does.
    struct Deletion: Equatable {
        let at: Date
        let sessions: Int
        var worktrees = 0

        var total: Int { sessions + worktrees }
    }

    // Something the sweep will not take without a yes, and why. Nothing about it runs
    // out: it waits until someone answers or it stops being old.
    struct Parked: Equatable, Identifiable {
        enum Item: Hashable {
            case session(UUID)
            case worktree(String)
        }

        let item: Item
        let reasons: [CleanupReason]

        var id: Item { item }

        var family: CleanupReason.Family {
            reasons.contains { $0.family == .losesWork } ? .losesWork : .notLookedAt
        }

        var sessionID: UUID? {
            if case .session(let id) = item { return id }
            return nil
        }
    }

    // What the window shows of the sweep: the countdown, who is in it, and what waits.
    // The sidebar and the review sheet read the same copy, so the count beside the
    // waiting line is always the number of rows the sheet lists.
    struct Status: Equatable {
        var deletion: Deletion?
        var cohort: [UUID] = []
        var worktreeCohort: [String] = []
        var parked: [Parked] = []
        // How much the last sweep in this run took, so an empty card can say it is empty
        // because the sweep just ran rather than because nothing was ever old.
        var swept = 0

        func goes(_ id: UUID) -> Bool { cohort.contains(id) }

        func waits(_ id: UUID) -> Bool { parked.contains { $0.item == .session(id) } }
    }

    // One cohort waits at a time. Its members are settled when the countdown starts, so a
    // session that goes quiet during the hour waits for the next cohort rather than
    // joining a deletion that has already been counted and shown. Members can still drop
    // out, so the number on the strip only ever falls.
    struct EligibilityBuffer {
        private(set) var cohort: [UUID] = []
        private(set) var worktreeCohort: [String] = []
        // Kept apart from the cohort and its clock: these are never deleted here, so they
        // have no deadline to count down to.
        private(set) var parked: [Parked] = []
        private var deadline: Date?
        // Settling a cohort reads git. If nothing turns out to be safe to take there is
        // nothing to arm, and asking again a second later would read the same worktrees
        // for the same answer.
        private var nextArmingAt: Date = .distantPast
        // What git said about each old session and orphan the last time it was asked. A
        // session with no answer yet is never taken, since nothing is known about it.
        private var settled: [UUID: SessionRemovalCost] = [:]
        private var orphanHasChanges: [String: Bool] = [:]

        var deletion: Deletion? {
            deadline.map {
                Deletion(at: $0, sessions: cohort.count, worktrees: worktreeCohort.count)
            }
        }

        func status(swept: Int) -> Status {
            Status(deletion: deletion, cohort: cohort, worktreeCohort: worktreeCohort,
                   parked: parked, swept: swept)
        }

        var isArmed: Bool { deadline != nil }

        func canArm(now: Date) -> Bool { deadline == nil && now >= nextArmingAt }

        func isDue(now: Date) -> Bool {
            guard let deadline else { return false }
            return now >= deadline
        }

        mutating func arm(_ sessions: [UUID], worktrees: [String] = [], now: Date) {
            guard !sessions.isEmpty || !worktrees.isEmpty else {
                nextArmingAt = now.addingTimeInterval(OldSessionSweep.retryInterval)
                return
            }
            cohort = sessions
            worktreeCohort = worktrees
            deadline = now.addingTimeInterval(OldSessionSweep.gracePeriod)
        }

        // A session picked up, pinned, put off or removed by hand is no longer ours to
        // take, so it leaves the cohort and the countdown covers one fewer.
        mutating func keepOnly(_ eligible: Set<UUID>, worktrees: Set<String> = []) {
            guard isArmed else { return }
            cohort = cohort.filter(eligible.contains)
            worktreeCohort = worktreeCohort.filter(worktrees.contains)
            if cohort.isEmpty && worktreeCohort.isEmpty { disarm() }
        }

        mutating func disarm() {
            cohort = []
            worktreeCohort = []
            deadline = nil
        }

        mutating func clearParked() {
            parked = []
            settled = [:]
            orphanHasChanges = [:]
        }

        func cost(of id: UUID) -> SessionRemovalCost? { settled[id] }

        func hasChanges(_ worktreeID: String) -> Bool? { orphanHasChanges[worktreeID] }

        mutating func settle(_ id: UUID, _ cost: SessionRemovalCost) {
            settled[id] = cost
        }

        mutating func settleOrphan(_ worktreeID: String, hasChanges: Bool?) {
            orphanHasChanges[worktreeID] = hasChanges
        }

        // Forgets what is no longer old, so the answers kept stay as small as the list.
        mutating func keepSettled(_ sessions: Set<UUID>, worktrees: Set<String>) {
            settled = settled.filter { sessions.contains($0.key) }
            orphanHasChanges = orphanHasChanges.filter { worktrees.contains($0.key) }
        }

        mutating func setParked(_ list: [Parked]) {
            if parked != list { parked = list }
        }
    }

    // The order is the sheet's order, oldest first, so a capped cohort takes the sessions
    // that have been sitting the longest. A session that is pinned, put off, open, or
    // running is never eligible, however long ago its last turn was, and neither is one
    // whose project is snoozed: the filter is inherited, so the countdown in the sidebar
    // and the deletion behind it stop for that project together.
    static func due(days: Int, in sessions: [ChatSession], now: Date = Date(),
                    isBusy: (UUID) -> Bool, isOpen: (UUID) -> Bool,
                    snoozedUntil: OldSessions.SnoozeDeadline = { _ in nil }) -> [ChatSession] {
        OldSessions.olderThan(days, in: sessions, now: now, snoozedUntil: snoozedUntil)
            .filter { !isBusy($0.id) && !isOpen($0.id) }
    }

    // The reasons a session has right now: the ones the store knows at once, and the ones
    // git last gave.
    static func reasons(of session: ChatSession, cost: SessionRemovalCost?,
                        store: ProjectStore, now: Date) -> [CleanupReason] {
        let attention = CleanupReason.attention(
            isUnread: store.isUnread(session.id),
            isSnoozed: session.snooze?.isActive(now: now) == true)
        return (cost?.reasons ?? []) + attention
    }

    @discardableResult
    static func run(days: Int, rule: CleanupRule,
                    store: ProjectStore, runner: SessionRunner,
                    buffer: inout EligibilityBuffer, now: Date = Date(),
                    orphans: [OrphanedWorktree] = [],
                    worktreeOperations: WorktreeOperations = .live,
                    inspect: SessionCost.Inspect = SessionCost.live,
                    pruneOrphans: PruneOrphans = { _ in 0 }) async -> Int {
        guard rule.deletesOnItsOwn else {
            buffer.disarm()
            buffer.clearParked()
            return 0
        }

        let isBusy = { (id: UUID) in runner.isBusy(id, store: store) }
        let isOpen = { (id: UUID) in store.selection == .session(id) }
        let snoozedUntil = { (session: ChatSession) in store.snoozeDeadline(for: session) }
        let orphans = rule.includesOrphans ? orphans : []

        var old = due(days: days, in: store.sidebarSessions, now: now,
                      isBusy: isBusy, isOpen: isOpen, snoozedUntil: snoozedUntil)
        buffer.keepSettled(Set(old.map(\.id)), worktrees: Set(orphans.map(\.id)))
        let known = settle(&buffer, old: old, orphans: orphans, rule: rule, store: store,
                           now: now)

        if buffer.canArm(now: now), !old.isEmpty || !orphans.isEmpty {
            for session in old.prefix(batchLimit) {
                guard !Task.isCancelled else { return 0 }
                buffer.settle(session.id, await cost(of: session, in: store, inspect: inspect))
            }
            for orphan in orphans.prefix(batchLimit) {
                guard !Task.isCancelled else { return 0 }
                buffer.settleOrphan(orphan.id, hasChanges: await hasChanges(orphan, inspect: inspect))
            }
            guard !Task.isCancelled else { return 0 }
            // Reading git takes time, and the store may have moved on while it did.
            old = due(days: days, in: store.sidebarSessions, now: now,
                      isBusy: isBusy, isOpen: isOpen, snoozedUntil: snoozedUntil)
            let goes = settle(&buffer, old: old, orphans: orphans, rule: rule, store: store,
                              now: now)
            buffer.arm(goes.sessions, worktrees: goes.worktrees, now: now)
            return 0
        }

        // Something git has already cleared can stop being held without a new read: a
        // session read, or a reason taken off the list. It starts its hour now rather
        // than waiting for the next pass over git, which reads it again at the end.
        if !buffer.isArmed, !known.sessions.isEmpty || !known.worktrees.isEmpty {
            buffer.arm(known.sessions, worktrees: known.worktrees, now: now)
            return 0
        }

        guard buffer.isDue(now: now) else { return 0 }

        // Reading git takes time, and the app keeps running while it does: a session that
        // has since been opened, picked up, or removed by hand is no longer ours to take,
        // so this is asked again on the far side of every wait.
        let stillStale = { (sessionID: UUID) in
            guard let session = store.session(sessionID) else { return false }
            return !OldSessions.isKept(session, now: now)
                && store.selection != .session(sessionID)
                && !runner.isBusy(sessionID, store: store)
                && !ProjectSnooze.isActive(store.snoozeDeadline(for: session), now: now)
        }

        var deleted = 0
        for sessionID in buffer.cohort {
            guard !Task.isCancelled else { break }
            guard stillStale(sessionID), let session = store.session(sessionID) else { continue }
            // An hour has passed since the cohort was settled, so the worktrees are read
            // once more. Work started in the meantime is still work, and sparing it
            // matters more than the count on the strip holding still.
            let cost = await cost(of: session, in: store, inspect: inspect)
            buffer.settle(sessionID, cost)
            guard cost.canSelect,
                  rule.held(reasons(of: session, cost: cost, store: store, now: now)).isEmpty,
                  stillStale(sessionID) else { continue }

            SessionLog.note("auto deletion started outcome=\(cost.label)", session: sessionID)
            let result = await SessionLifecycle.remove(
                session, from: store, runner: runner, worktrees: worktreeOperations)
            if case .failure(let failure) = result {
                SessionLog.note("auto deletion failed reason=\(failure.title)", session: sessionID)
            } else {
                deleted += 1
                SessionLog.note("auto deletion finished", session: sessionID)
            }
        }

        var cleanOrphans: [OrphanedWorktree] = []
        for worktreeID in buffer.worktreeCohort {
            guard !Task.isCancelled else { break }
            guard let orphan = orphans.first(where: { $0.id == worktreeID }),
                  !store.protectsWorktree(at: orphan.path) else { continue }
            let changes = await hasChanges(orphan, inspect: inspect)
            buffer.settleOrphan(worktreeID, hasChanges: changes)
            if changes == false { cleanOrphans.append(orphan) }
        }
        if !cleanOrphans.isEmpty, !Task.isCancelled {
            let pruned = await pruneOrphans(cleanOrphans)
            deleted += pruned
            SessionLog.note("orphan worktree sweep pruned count=\(pruned)")
        }

        // The cohort has had its turn either way. Anything it could not take is offered
        // again by the next one, which starts its own hour rather than inheriting this.
        buffer.disarm()
        let afterwards = due(days: days, in: store.sidebarSessions, now: now,
                             isBusy: isBusy, isOpen: isOpen, snoozedUntil: snoozedUntil)
        settle(&buffer, old: afterwards, orphans: orphans.filter { orphan in
            !cleanOrphans.contains { $0.id == orphan.id }
        }, rule: rule, store: store, now: now)
        if deleted > 0 {
            SessionLog.note("old session sweep deleted count=\(deleted) days=\(days)")
        }
        return deleted
    }

    // Sorts what is old into what waits for a yes and what may go, from what is known
    // right now. The waiting list is rebuilt on every pass, so reading a session or
    // taking a reason off the ask list moves it at once. Only what git has already said
    // is safe can go: a session or worktree nobody has looked into is neither.
    @discardableResult
    private static func settle(_ buffer: inout EligibilityBuffer, old: [ChatSession],
                               orphans: [OrphanedWorktree], rule: CleanupRule,
                               store: ProjectStore, now: Date)
        -> (sessions: [UUID], worktrees: [String]) {
        var parked: [Parked] = []
        var goes: [UUID] = []
        for session in old {
            let cost = buffer.cost(of: session.id)
            let held = rule.held(reasons(of: session, cost: cost, store: store, now: now))
            if !held.isEmpty {
                parked.append(Parked(item: .session(session.id), reasons: held))
            } else if let cost, cost.canSelect {
                goes.append(session.id)
            }
        }
        var cleanWorktrees: [String] = []
        for orphan in orphans {
            switch buffer.hasChanges(orphan.id) {
            case true?:
                parked.append(Parked(item: .worktree(orphan.id), reasons: [.uncommittedChanges]))
            case false?:
                cleanWorktrees.append(orphan.id)
            case nil:
                break
            }
        }
        buffer.setParked(parked)
        buffer.keepOnly(Set(goes), worktrees: Set(cleanWorktrees))
        return (Array(goes.prefix(batchLimit)), Array(cleanWorktrees.prefix(batchLimit)))
    }

    private static func cost(of session: ChatSession, in store: ProjectStore,
                             inspect: SessionCost.Inspect) async -> SessionRemovalCost {
        await SessionCost.settledCost(
            worktrees: store.checkoutProjects(for: session).compactMap(\.worktreePath),
            design: store.designCost(for: session),
            inspect: inspect)
    }

    // Nil when git could not read it, which is never taken as clean.
    private static func hasChanges(_ orphan: OrphanedWorktree,
                                   inspect: SessionCost.Inspect) async -> Bool? {
        let outcome = await SessionCost.settledOutcome(worktrees: [orphan.path], inspect: inspect)
        switch outcome {
        case .wouldLoseWork: return true
        case .worktreeRemoved, .historyOnly: return false
        case .checking, .checkFailed: return nil
        }
    }
}
