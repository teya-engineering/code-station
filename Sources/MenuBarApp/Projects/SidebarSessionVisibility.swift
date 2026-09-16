import Foundation

struct SidebarSessionVisibility {
    static let limitRange = 2...10
    static let defaultLimit = 4

    private var showingAll: Set<UUID> = []
    private var pinned: [UUID: UUID] = [:]

    // The newest few sessions of a container, plus the one opened from outside the rail
    // when it sits below the fold. Opening a session is not a reason to unfold the whole
    // list behind it, so the tail stays under see-more. The one from below the fold stands
    // in for the oldest card instead of being added after it, so a list always draws the
    // same number of rows and nothing under the pointer moves when the selection changes.
    func visible<Session: Identifiable>(_ sessions: [Session],
                                        in containerID: UUID,
                                        limit: Int = Self.defaultLimit,
                                        selectedSessionID: UUID? = nil) -> [Session]
    where Session.ID == UUID {
        guard !showingAll.contains(containerID) else { return sessions }
        let resolved = Self.resolvedLimit(limit)
        let head = sessions.prefix(resolved)
        guard let pinnedID = selectedSessionID ?? pinned[containerID],
              !head.contains(where: { $0.id == pinnedID }),
              let session = sessions.first(where: { $0.id == pinnedID }) else {
            return Array(head)
        }
        return Array(head.prefix(resolved - 1)) + [session]
    }

    static func resolvedLimit(_ limit: Int) -> Int {
        min(max(limit, limitRange.lowerBound), limitRange.upperBound)
    }

    mutating func showAll(_ containerID: UUID) {
        showingAll.insert(containerID)
    }

    mutating func pin(_ sessionID: UUID, in containerID: UUID) {
        pinned[containerID] = sessionID
    }

    mutating func reset(_ containerID: UUID) {
        showingAll.remove(containerID)
        pinned[containerID] = nil
    }
}
