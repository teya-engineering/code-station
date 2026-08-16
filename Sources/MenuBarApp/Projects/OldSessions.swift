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

    static func olderThan(_ days: Int, in sessions: [ChatSession], now: Date = Date()) -> [ChatSession] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return sessions
            .filter { $0.lastActivity < cutoff }
            .sorted { $0.lastActivity < $1.lastActivity }
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

    // One worktree git could not read is enough to stop here. Silence from git is not the
    // same as an empty worktree, and only one of the two is safe to act on.
    static func settledOutcome(worktrees: [String],
                               inspect: Inspect = live) async -> SessionOutcome {
        guard startingOutcome(worktrees: worktrees) == .checking else { return .historyOnly }

        var added = 0
        var removed = 0
        var hasChanges = false
        for path in worktrees {
            let snapshot = await inspect(path)
            guard snapshot.state == .ready else { return .checkFailed }
            hasChanges = hasChanges || !snapshot.files.isEmpty
            added += snapshot.totalAdded
            removed += snapshot.totalRemoved
        }
        return hasChanges ? .wouldLoseWork(added: added, removed: removed) : .worktreeRemoved
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
