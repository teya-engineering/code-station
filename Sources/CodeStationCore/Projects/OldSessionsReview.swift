import Foundation

extension OldSessions {
    // What the review sheet lists: old enough to offer, minus the ones in the middle of a
    // turn, which are busy right now rather than quiet. A snoozed project stays in, since
    // the sheet is where its snooze is shown and taken back.
    @MainActor
    public static func reviewable(days: Int, store: ProjectStore, runner: SessionRunner)
        -> [ChatSession] {
        olderThan(days, in: store.userSessions).filter { !runner.state($0.id).isBusy }
    }
}

// What the review says about its rows, worded once for the GUI's sheet and every
// station client.
extension OldSessions {
    // A tick is a promise the person has read the row. Past this many nobody reads the
    // whole list, so the ticking stops there.
    public static let preselectLimit = 50

    // "last turn 9 days ago · 4 turns · ⑂ code-station/pty-test · clean"
    public static func detail(of session: ChatSession, worktrees: [String],
                              cost: SessionRemovalCost, now: Date = Date()) -> String {
        var parts = ["last turn " + SessionAge.phrase(since: session.lastActivity, now: now)]
        if let turns = session.usage?.turns, turns > 0 {
            parts.append(counted(turns, "turn"))
        }
        if let path = worktrees.first {
            let label = worktrees.count == 1
                ? (session.worktreeBranch ?? (path as NSString).lastPathComponent)
                : "\(worktrees.count) worktrees"
            parts.append("⑂ " + label)
            switch cost.worktree {
            case .checking: parts.append("checking…")
            case .checkFailed: parts.append("check failed")
            case .wouldLoseWork(let added, let removed):
                parts.append("+\(added) -\(removed) uncommitted")
            default: parts.append("clean")
            }
        } else {
            parts.append("no worktree")
        }
        return parts.joined(separator: " · ")
    }

    public static func preselectNotice() -> String {
        "Only the first \(preselectLimit) sessions are ticked for you. Tick the rest by hand if you want those gone as well."
    }

    public static let everythingSnoozedNotice = "Every project is snoozed. Nothing is cleared until they come back."

    // What deleting would cost, worded for one session or for several. Only designs that
    // were never built are named: once a design has become code, its files are a copy of
    // something the checkout already holds.
    public static func unbuiltDesignCost(_ count: Int) -> String {
        if count == 1 {
            return "One session holds a design that was never implemented, so it is left unticked. "
                + "Deleting it permanently removes that design's HTML and local assets."
        }
        return "\(count) sessions hold designs that were never implemented, so they are left unticked. "
            + "Deleting them permanently removes those designs' HTML and local assets."
    }

    public static func dirtyWorktreeCost(_ count: Int) -> String {
        if count == 1 {
            return "One session has uncommitted changes in its worktree, so it is left unticked. "
                + "Deleting it loses those changes; its branch survives if git considers that safe."
        }
        return "\(count) sessions have uncommitted changes in their worktrees, so they are left unticked. "
            + "Deleting them loses those changes; their branches survive if git considers that safe."
    }

    // "Delete 3 sessions", the review's button.
    public static func deleteLabel(_ count: Int) -> String {
        count == 0 ? "Delete" : "Delete \(counted(count, "session"))"
    }

    // The second question, for chosen sessions that hold generated files or uncommitted
    // work. Nil when they cost nothing but history, which the review itself asked about.
    public static func savedWorkImpact(sessions: Int, unbuiltDesigns: Int, dirtyWorktrees: Int,
                                       action: String) -> RemoteImpact? {
        guard unbuiltDesigns > 0 || dirtyWorktrees > 0 else { return nil }
        var rows: [RemoteImpact.Row] = []
        if unbuiltDesigns > 0 {
            rows.append(.init(title: counted(unbuiltDesigns, "design") + " never implemented",
                              detail: "The HTML and local assets are permanently removed."))
        }
        if dirtyWorktrees > 0 {
            rows.append(.init(title: counted(dirtyWorktrees, "worktree") + " with uncommitted changes",
                              detail: "The changes are lost. Branches are kept if git considers that safe."))
        }
        return RemoteImpact(title: sessions == 1 ? "Delete a session with saved work?"
                                                 : "Delete sessions with saved work?",
                            message: "\(counted(sessions, "session")) will leave Code Station, along with this work.",
                            rows: rows, warning: "This work cannot be restored.", action: action)
    }
}
