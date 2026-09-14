import Foundation

// Sessions pile up: every question asked in passing leaves one behind, and the ones that
// ran in a worktree leave a checkout on disk as well. Nothing here ever deletes on its
// own - it only works out what has gone quiet, so the app can offer to clear it.
enum OldSessions {
    static let dayRange = 1...365
    static let defaultDays = 3

    static func resolvedDays(_ days: Int) -> Int {
        min(max(days, dayRange.lowerBound), dayRange.upperBound)
    }

    // A session whose project is snoozed is not old, whatever its last turn says. The
    // deadline is asked for per session rather than read from a project here, so the
    // sheet can leave it out and keep showing what a snooze has taken from the count.
    typealias SnoozeDeadline = (ChatSession) -> Date?

    static func olderThan(_ days: Int, in sessions: [ChatSession], now: Date = Date(),
                          snoozedUntil: SnoozeDeadline = { _ in nil }) -> [ChatSession] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return sessions
            .filter { $0.lastActivity < cutoff && !ProjectSnooze.isActive(snoozedUntil($0), now: now) }
            .sorted { $0.lastActivity < $1.lastActivity }
    }

    // When the list changes next: either a session goes quiet for long enough, or a
    // snooze runs out and hands its sessions back.
    static func nextOldAt(_ days: Int, in sessions: [ChatSession], now: Date = Date(),
                          snoozedUntil: SnoozeDeadline = { _ in nil }) -> Date? {
        let age = Double(days) * 86_400
        let turningOld = sessions.map { $0.lastActivity.addingTimeInterval(age) }
        let waking = sessions.compactMap(snoozedUntil)
        return (turningOld + waking)
            .filter { $0 > now }
            .min()
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

// One policy owns the whole automatic-cleanup choice. The destructive modes are ordered
// by what they are allowed to take, so Settings cannot represent a contradictory pair of
// switches such as deleting saved work while keeping sessions that have nothing to lose.
enum OldSessionCleanupPolicy: String, CaseIterable {
    case review
    case deleteSafe
    case deleteAll

    var deletesAutomatically: Bool {
        self != .review
    }

    var includesSavedWork: Bool {
        self == .deleteAll
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

// The whole cost of removing a session. Generated Design files sit outside git, so a clean
// or absent worktree does not make a session safe to clear on its own.
struct SessionRemovalCost: Equatable {
    let worktree: SessionOutcome
    let deletesDesignArtifacts: Bool

    var label: String {
        guard deletesDesignArtifacts else { return worktree.label }
        return worktree.losesWork ? "would delete design and changes" : "would delete design"
    }

    var losesNothing: Bool {
        worktree.losesNothing && !deletesDesignArtifacts
    }

    var canSelect: Bool {
        worktree.canSelect
    }

    var losesWork: Bool {
        worktree.losesWork || deletesDesignArtifacts
    }
}

// What deleting a session would cost, as git answers it. The review sheet and the
// unattended sweep both ask this, so a box that arrives ticked and a session that goes on
// its own are decided by one rule rather than by two that could drift apart.
enum SessionCost {
    static let inspectionCommandTimeout: TimeInterval = 10

    typealias Inspect = @Sendable (String) async -> GitSnapshot

    static let live: Inspect = {
        await GitInspector.snapshot(at: $0, commandTimeout: inspectionCommandTimeout)
    }

    // Worktrees that are still on disk are the only ones worth asking git about. Without
    // one there is nothing to lose but the conversation.
    static func startingOutcome(worktrees: [String]) -> SessionOutcome {
        worktrees.contains { FileManager.default.fileExists(atPath: $0) }
            ? .checking : .historyOnly
    }

    static func startingCost(worktrees: [String], deletesDesignArtifacts: Bool)
        -> SessionRemovalCost {
        SessionRemovalCost(worktree: startingOutcome(worktrees: worktrees),
                           deletesDesignArtifacts: deletesDesignArtifacts)
    }

    // One worktree git could not read is enough to stop here. Silence from git is not the
    // same as an empty worktree, and only one of the two is safe to act on.
    static func settledOutcome(worktrees: [String],
                               inspect: Inspect = live) async -> SessionOutcome {
        let existingWorktrees = worktrees.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existingWorktrees.isEmpty else { return .historyOnly }

        var added = 0
        var removed = 0
        var hasChanges = false
        for path in existingWorktrees {
            let snapshot = await inspect(path)
            guard snapshot.state == .ready else { return .checkFailed }
            hasChanges = hasChanges || !snapshot.files.isEmpty
            added += snapshot.totalAdded
            removed += snapshot.totalRemoved
        }
        return hasChanges ? .wouldLoseWork(added: added, removed: removed) : .worktreeRemoved
    }

    static func settledCost(worktrees: [String], deletesDesignArtifacts: Bool,
                            inspect: Inspect = live) async -> SessionRemovalCost {
        let worktree = await settledOutcome(worktrees: worktrees, inspect: inspect)
        return SessionRemovalCost(worktree: worktree,
                                  deletesDesignArtifacts: deletesDesignArtifacts)
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
