import Foundation

// Sessions pile up: every question asked in passing leaves one behind, and the ones that
// ran in a worktree leave a checkout on disk as well. Nothing here ever deletes on its
// own - it only works out what has gone quiet, so the app can offer to clear it.
enum OldSessions {
    // Anything below this would call a session old while it is still the one being worked
    // on; anything above it stops being an offer worth making.
    static let dayRange = 1...90

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
    case worktreeRemoved
    // Uncommitted work in the worktree, which deleting would take with it.
    case wouldLoseWork(added: Int, removed: Int)

    var label: String {
        switch self {
        case .historyOnly: "history only"
        case .checking: "checking…"
        case .worktreeRemoved: "worktree removed"
        case .wouldLoseWork: "would lose work"
        }
    }

    // Only the outcome that costs nothing but history is safe to tick for the user. A
    // worktree stays untouched until git has said it is clean, so a slow repository can
    // never leave a box ticked that the user did not read.
    var isSafeToPreselect: Bool {
        self == .historyOnly || self == .worktreeRemoved
    }

    var losesWork: Bool {
        if case .wouldLoseWork = self { return true }
        return false
    }
}

// Removing a session means the conversation and, if it had one, the worktree it ran in.
// The sidebar and the old-sessions sheet both do it, and they have to do it the same way.
@MainActor
enum SessionRemoval {
    static func remove(_ session: ChatSession, from store: ProjectStore) {
        let project = store.project(session.projectID)
        store.removeSession(session.id)
        guard let worktree = session.worktreePath, let project else { return }
        Task {
            await GitWorktree.remove(worktreePath: worktree,
                                     projectPath: project.path,
                                     branch: session.worktreeBranch)
        }
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
