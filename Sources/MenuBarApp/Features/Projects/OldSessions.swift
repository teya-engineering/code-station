import Foundation

// Sessions pile up: every question asked in passing leaves one behind, and the ones that
// ran in a worktree leave a checkout on disk as well. Nothing here ever deletes on its
// own - it only works out what has gone quiet, so the app can offer to clear it.
enum OldSessions {
    static let dayRange = 1...30
    static let defaultDays = 3

    static func resolvedDays(_ days: Int) -> Int {
        min(max(days, dayRange.lowerBound), dayRange.upperBound)
    }

    // A session whose project is snoozed is not old, whatever its last turn says. The
    // deadline is asked for per session rather than read from a project here, so the
    // sheet can leave it out and keep showing what a snooze has taken from the count.
    typealias SnoozeDeadline = (ChatSession) -> Date?

    // A pinned session is never old: pinning is how a session is kept for good. One the
    // person asked to hear about later is kept until that date. Unread and snoozed
    // sessions do go old: they are not deleted on their own, but they are shown, so
    // nothing sits out of sight forever.
    static func olderThan(_ days: Int, in sessions: [ChatSession], now: Date = Date(),
                          snoozedUntil: SnoozeDeadline = { _ in nil }) -> [ChatSession] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return sessions
            .filter {
                !isKept($0, now: now) && $0.lastActivity < cutoff
                    && !ProjectSnooze.isActive(snoozedUntil($0), now: now)
            }
            .sorted { $0.lastActivity < $1.lastActivity }
    }

    static func isKept(_ session: ChatSession, now: Date = Date()) -> Bool {
        session.isPinned || isDeferred(session, now: now)
    }

    static func isDeferred(_ session: ChatSession, now: Date = Date()) -> Bool {
        guard let until = session.cleanupDeferredUntil else { return false }
        return until > now
    }

    // How long "ask again later" keeps a session or a worktree out of cleanup.
    static let deferral: TimeInterval = 7 * 86_400

    // What the review sheet lists: old enough to offer, minus the ones in the middle of a
    // turn, which are busy right now rather than quiet. A snoozed project stays in, since
    // the sheet is where its snooze is shown and taken back.
    @MainActor
    static func reviewable(days: Int, store: ProjectStore, runner: SessionRunner)
        -> [ChatSession] {
        olderThan(days, in: store.userSessions)
            .filter { !runner.state($0.id).isBusy }
    }

    // When the list changes next: either a session goes quiet for long enough, or a
    // project snooze or an "ask again later" runs out and hands its sessions back.
    static func nextOldAt(_ days: Int, in sessions: [ChatSession], now: Date = Date(),
                          snoozedUntil: SnoozeDeadline = { _ in nil }) -> Date? {
        let age = Double(days) * 86_400
        let turningOld = sessions.filter { !isKept($0, now: now) }
            .map { $0.lastActivity.addingTimeInterval(age) }
        let waking = sessions.compactMap(snoozedUntil)
            + sessions.filter { !$0.isPinned }.compactMap(\.cleanupDeferredUntil)
        return (turningOld + waking)
            .filter { $0 > now }
            .min()
    }
}

// What can hold an old session back for a yes. Each one is either work that deleting
// would throw away, or something the person has not looked at yet. The family decides
// where a session is grouped and what colour its chips are.
enum CleanupReason: String, CaseIterable, Codable, Sendable, Identifiable {
    case uncommittedChanges
    case unpushedCommits
    case unbuiltDesign
    case unread
    case snoozed

    enum Family: Equatable {
        case losesWork
        case notLookedAt
    }

    var id: Self { self }

    var family: Family {
        switch self {
        case .uncommittedChanges, .unpushedCommits, .unbuiltDesign: .losesWork
        case .unread, .snoozed: .notLookedAt
        }
    }

    var title: String {
        switch self {
        case .uncommittedChanges: "Uncommitted changes"
        case .unpushedCommits: "Commits not pushed"
        case .unbuiltDesign: "Design never built"
        case .unread: "Reply not read"
        case .snoozed: "Snoozed"
        }
    }

    var detail: String {
        switch self {
        case .uncommittedChanges: "Deleting would throw the changes away."
        case .unpushedCommits: "The branch has commits that exist nowhere else."
        case .unbuiltDesign: "The design files are the only copy of that work."
        case .unread: "A turn ended while you were away and you have not looked at it."
        case .snoozed: "You put it aside for later. It is shown, not deleted, once it is old."
        }
    }

    // The reasons a session has that need no git to know.
    static func attention(isUnread: Bool, isSnoozed: Bool) -> [CleanupReason] {
        (isUnread ? [.unread] : []) + (isSnoozed ? [.snoozed] : [])
    }
}

// What the person allows cleanup to do on its own. One switch turns the countdown on;
// the ask list names what still needs a yes.
struct CleanupRule: Equatable, Sendable {
    var deletesOnItsOwn: Bool
    var asked: Set<CleanupReason>
    // Orphaned worktrees follow the same rule: a clean one goes with the countdown, one
    // with changes waits.
    var includesOrphans: Bool

    static let askedByDefault = Set(CleanupReason.allCases)

    func asks(_ reason: CleanupReason) -> Bool {
        asked.contains(reason)
    }

    // The reasons that hold a session back under this rule. An empty answer means it
    // goes on its own.
    func held(_ reasons: [CleanupReason]) -> [CleanupReason] {
        reasons.filter(asks)
    }
}

// An extra day before one project's old sessions are offered for deletion or taken by
// the unattended sweep. Snooze is the third answer the review sheet can give - "not this
// project, not yet" - without moving the global threshold or pinning sessions one by one.
enum ProjectSnooze {
    static let step: TimeInterval = 86_400

    static func isActive(_ deadline: Date?, now: Date = Date()) -> Bool {
        guard let deadline else { return false }
        return deadline > now
    }

    // Each press adds a day to the deadline the project already has, so a second press
    // extends the snooze instead of restarting it from today.
    static func extended(_ deadline: Date?, now: Date = Date()) -> Date {
        max(now, deadline ?? now).addingTimeInterval(step)
    }

    // Days still to run, rounded up: the sidebar badge shows "1d" through the final day
    // rather than dropping to nothing while the sessions are still held back.
    static func remainingDays(until deadline: Date, now: Date = Date()) -> Int {
        max(1, Int(ceil(deadline.timeIntervalSince(now) / step)))
    }

    static func badge(until deadline: Date, now: Date = Date()) -> String {
        "\(remainingDays(until: deadline, now: now))d"
    }

    // "15 Sep", the day the sessions come back.
    static func wakeDay(_ deadline: Date) -> String {
        deadline.formatted(.dateTime.day().month(.abbreviated))
    }

    // "code-station snoozed until tomorrow", or "snoozed for 2 days" once pressed twice.
    static func title(_ projectName: String, until deadline: Date, now: Date = Date()) -> String {
        let days = remainingDays(until: deadline, now: now)
        let when = days == 1 ? "until tomorrow" : "for \(counted(days, "day"))"
        return "\(projectName) snoozed \(when)"
    }

    // "2 sessions · back on 15 Sep"
    static func detail(sessions: Int, until deadline: Date) -> String {
        "\(counted(sessions, "session")) · back on \(wakeDay(deadline))"
    }
}

// What deleting one session would actually do. The worktree side of it can only be
// answered by git, so it starts as "not looked at yet" and is filled in once the review
// sheet has asked.
enum SessionOutcome: Equatable {
    // No worktree, or one that is no longer on disk: only the conversation goes.
    case historyOnly
    case checking
    case checkFailed
    case worktreeRemoved
    // Uncommitted work in the worktree, which deleting would take with it.
    case wouldLoseWork(added: Int, removed: Int)

    var label: String {
        switch self {
        case .historyOnly: "history only"
        case .checking: "checking…"
        case .checkFailed: "check failed"
        case .worktreeRemoved: "will remove worktree"
        case .wouldLoseWork: "would lose work"
        }
    }

    // Costs nothing but the conversation. Only these arrive ticked, and only these are
    // ever cleared without being asked about. A worktree counts as one of them once git
    // has said it is clean, never while the answer is still coming.
    var losesNothing: Bool {
        self == .historyOnly || self == .worktreeRemoved
    }

    var canSelect: Bool {
        self != .checking && self != .checkFailed
    }

    var losesWork: Bool {
        if case .wouldLoseWork = self { return true }
        return false
    }
}

// What the generated Design files of a session are worth. They sit outside git, so what
// happens to them is decided here rather than by what git says about the worktree.
enum DesignCost: Equatable {
    case absent
    // The design was handed over and turned into code, so the files are a record of
    // something the worktree already holds.
    case implemented
    // Never built, which makes these files the only copy of that work.
    case unimplemented
}

// The whole cost of removing a session: what git can answer about the worktree, and what
// the design behind the session is worth.
struct SessionRemovalCost: Equatable {
    let worktree: SessionOutcome
    let design: DesignCost
    // Commits in the worktrees that no remote has. The branch is usually kept when the
    // worktree goes, but it is still the only copy, so it is a reason to ask.
    var unpushedCommits = 0

    // Before anything has been looked at. Nothing can be ticked from here, and the row
    // says so, which is what a session shows while its cost is still being worked out.
    static let unchecked = SessionRemovalCost(worktree: .checking, design: .absent)

    var label: String {
        guard worktree.canSelect else { return worktree.label }
        return switch design {
        case .absent: worktree.label
        case .implemented: worktree.losesWork ? worktree.label : "will remove design files"
        case .unimplemented: worktree.losesWork
            ? "would delete unbuilt design and changes" : "would delete unbuilt design"
        }
    }

    var losesNothing: Bool {
        worktree.losesNothing && design != .unimplemented
    }

    // Something on disk goes with the session, but nothing that cannot be got back: a
    // clean worktree, or the files of a design that has already become code.
    var removesFiles: Bool {
        worktree == .worktreeRemoved || design == .implemented
    }

    var canSelect: Bool {
        worktree.canSelect
    }

    var losesWork: Bool {
        worktree.losesWork || design == .unimplemented
    }

    var reasons: [CleanupReason] {
        var reasons: [CleanupReason] = []
        if worktree.losesWork { reasons.append(.uncommittedChanges) }
        if unpushedCommits > 0 { reasons.append(.unpushedCommits) }
        if design == .unimplemented { reasons.append(.unbuiltDesign) }
        return reasons
    }
}

// What deleting a session would cost, as git answers it. The review sheet and the
// unattended sweep both ask this, so a box that arrives ticked and a session that goes on
// its own are decided by one rule rather than by two that could drift apart.
enum SessionCost {
    static let inspectionCommandTimeout: TimeInterval = 10

    typealias Inspect = @Sendable (String) async -> GitSnapshot

    static let live: Inspect = { path in
        var snapshot = await GitInspector.snapshot(at: path,
                                                   commandTimeout: inspectionCommandTimeout)
        if snapshot.state == .ready {
            snapshot.unpushedCommits = await GitInspector.unpushedCommitCount(
                at: path, commandTimeout: inspectionCommandTimeout)
        }
        return snapshot
    }

    // Worktrees that are still on disk are the only ones worth asking git about. Without
    // one there is nothing to lose but the conversation.
    static func startingOutcome(worktrees: [String]) -> SessionOutcome {
        worktrees.contains { FileManager.default.fileExists(atPath: $0) }
            ? .checking : .historyOnly
    }

    static func startingCost(worktrees: [String], design: DesignCost)
        -> SessionRemovalCost {
        SessionRemovalCost(worktree: startingOutcome(worktrees: worktrees), design: design)
    }

    // One worktree git could not read is enough to stop here. Silence from git is not the
    // same as an empty worktree, and only one of the two is safe to act on.
    static func settledOutcome(worktrees: [String],
                               inspect: Inspect = live) async -> SessionOutcome {
        await settledCost(worktrees: worktrees, design: .absent, inspect: inspect).worktree
    }

    static func settledCost(worktrees: [String], design: DesignCost,
                            inspect: Inspect = live) async -> SessionRemovalCost {
        let existingWorktrees = worktrees.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existingWorktrees.isEmpty else {
            return SessionRemovalCost(worktree: .historyOnly, design: design)
        }

        var added = 0
        var removed = 0
        var unpushed = 0
        var hasChanges = false
        for path in existingWorktrees {
            let snapshot = await inspect(path)
            guard snapshot.state == .ready else {
                return SessionRemovalCost(worktree: .checkFailed, design: design)
            }
            hasChanges = hasChanges || !snapshot.files.isEmpty
            added += snapshot.totalAdded
            removed += snapshot.totalRemoved
            unpushed += snapshot.unpushedCommits
        }
        return SessionRemovalCost(
            worktree: hasChanges ? .wouldLoseWork(added: added, removed: removed) : .worktreeRemoved,
            design: design,
            unpushedCommits: unpushed)
    }
}

// "12 days ago", counted from the last turn. Days are the only unit this deals in: the
// threshold is in days, so an answer in hours would not line up with the question.
enum SessionAge {
    static func phrase(since date: Date, now: Date = Date()) -> String {
        let days = Int(max(0, now.timeIntervalSince(date)) / 86_400)
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        default: return "\(days) days ago"
        }
    }
}

// A clock face stays compact in the sidebar and makes the warning hour's remaining time
// precise. Its final five minutes are urgent. Rounding up keeps it from showing zero
// before the sweep is actually due.
enum CleanupCountdown {
    private static let urgentThreshold: TimeInterval = 5 * 60

    static func isUrgent(until deadline: Date, now: Date = Date()) -> Bool {
        deadline.timeIntervalSince(now) <= urgentThreshold
    }

    static func text(until deadline: Date, now: Date = Date()) -> String {
        let totalSeconds = max(0, Int(ceil(deadline.timeIntervalSince(now))))
        let hours = totalSeconds / 3_600
        let minutes = totalSeconds % 3_600 / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
