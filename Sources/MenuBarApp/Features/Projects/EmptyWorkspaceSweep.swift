import Foundation

// A workspace made for a short job can remove itself once it has sat with no session for
// the days chosen when it was made. Removing it only removes the grouping: it holds no
// session by then, and its projects and their files stay. It follows the old session
// sweep's promise of a full warning hour, so nothing goes without a countdown first.
// It is its own rule rather than part of old session cleanup: the person turned it on
// for this workspace, so the old session setting does not switch it off.
@MainActor
enum EmptyWorkspaceSweep {
    static let monitorInterval: Duration = .seconds(1)

    // What the sidebar counts down to, and which workspaces go when it ends.
    struct Removal: Equatable {
        let at: Date
        let workspaces: [UUID]

        func goes(_ id: UUID) -> Bool { workspaces.contains(id) }
    }

    // When a workspace has sat empty long enough to be removed, or nil while it is kept:
    // removal is off, it holds a session, or nothing says when it went empty.
    nonisolated static func turnsOldAt(_ workspace: ProjectWorkspace,
                                       holdsSessions: Bool) -> Date? {
        guard let days = workspace.removeWhenEmptyAfterDays, !holdsSessions,
              let since = workspace.emptySince else { return nil }
        return since.addingTimeInterval(Double(OldSessions.resolvedDays(days)) * 86_400)
    }

    nonisolated static func due(_ workspaces: [ProjectWorkspace], now: Date,
                                holdsSessions: (UUID) -> Bool) -> [UUID] {
        workspaces.compactMap { workspace in
            guard let at = turnsOldAt(workspace, holdsSessions: holdsSessions(workspace.id)),
                  at <= now else { return nil }
            return workspace.id
        }
    }

    // One cohort waits at a time, as with old sessions. A workspace that turns old during
    // the hour waits for the next one, so the number on the strip only ever falls.
    struct Buffer {
        private(set) var removal: Removal?

        // Hands back the workspaces whose hour has ended. A workspace that gets a session
        // or is kept for good during the hour drops out of the cohort.
        mutating func step(due: [UUID], now: Date) -> [UUID] {
            if let armed = removal {
                let still = armed.workspaces.filter(due.contains)
                guard !still.isEmpty else {
                    removal = nil
                    return []
                }
                guard now >= armed.at else {
                    if still != armed.workspaces { removal = Removal(at: armed.at, workspaces: still) }
                    return []
                }
                removal = nil
                return still
            }
            if !due.isEmpty {
                removal = Removal(at: now.addingTimeInterval(OldSessionSweep.gracePeriod),
                                  workspaces: due)
            }
            return []
        }
    }

    // One pass: settles the cohort and removes what its hour has run out on. Each one is
    // checked again right before it goes, so a session started a moment ago keeps it.
    @discardableResult
    static func run(store: ProjectStore, buffer: inout Buffer,
                    now: Date = Date()) -> [ProjectWorkspace] {
        let due = due(store.workspaces, now: now,
                      holdsSessions: { store.holdsSessions(workspace: $0) })
        var removed: [ProjectWorkspace] = []
        for id in buffer.step(due: due, now: now) {
            guard let workspace = store.workspace(id),
                  turnsOldAt(workspace, holdsSessions: store.holdsSessions(workspace: id))
                      .map({ $0 <= now }) == true else { continue }
            store.removeWorkspace(id)
            removed.append(workspace)
            SessionLog.note("empty workspace removed days=\(workspace.removeWhenEmptyAfterDays ?? 0)")
        }
        return removed
    }

    // "Removed Fix flaky login tests. Its 3 projects stay."
    nonisolated static func removedNote(_ removed: [ProjectWorkspace]) -> String {
        guard removed.count == 1, let workspace = removed.first else {
            return "Removed \(counted(removed.count, "empty workspace")). Their projects stay."
        }
        let projects = workspace.projectIDs.count
        return "Removed \(workspace.name). Its \(counted(projects, "project")) \(projects == 1 ? "stays" : "stay")."
    }

    // The line under a workspace that will remove itself: how long it has, and whether
    // it is in its final hour.
    struct LifeLine: Equatable {
        let text: String
        let isFinalHour: Bool
    }

    nonisolated static func lifeLine(for workspace: ProjectWorkspace, holdsSessions: Bool,
                                     removalAt: Date?, now: Date = Date()) -> LifeLine? {
        guard workspace.removeWhenEmptyAfterDays != nil else { return nil }
        if holdsSessions { return LifeLine(text: "Kept while it has sessions", isFinalHour: false) }
        if let removalAt {
            let minutes = max(1, Int(ceil(removalAt.timeIntervalSince(now) / 60)))
            return LifeLine(text: "Goes in \(minutes) min", isFinalHour: true)
        }
        guard let turnsOld = turnsOldAt(workspace, holdsSessions: false) else { return nil }
        let left = turnsOld.timeIntervalSince(now)
        let when = if left <= 0 {
            "Goes within the hour"
        } else if left < 86_400 {
            "Goes in \(counted(Int(ceil(left / 3_600)), "hour"))"
        } else {
            "Goes in \(counted(Int(ceil(left / 86_400)), "day"))"
        }
        let quietDays = workspace.emptySince.map { Int(max(0, now.timeIntervalSince($0)) / 86_400) } ?? 0
        let why = quietDays > 0
            ? " · no session for \(counted(quietDays, "day"))"
            : " if no session starts"
        return LifeLine(text: when + why, isFinalHour: false)
    }
}
