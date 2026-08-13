import Foundation

struct SidebarSessionVisibility {
    static let initialLimit = 4

    private var showingAll: Set<UUID> = []
    private var pinned: [UUID: UUID] = [:]

    // The newest few sessions of a container, plus the one opened from outside the rail
    // when it sits below the fold. Opening a session is not a reason to unfold the whole
    // list behind it, so the tail stays under see-more.
    func visible<Session: Identifiable>(_ sessions: [Session],
                                        in containerID: UUID) -> [Session]
    where Session.ID == UUID {
        guard !showingAll.contains(containerID) else { return sessions }
        let head = sessions.prefix(Self.initialLimit)
        guard let pinnedID = pinned[containerID],
              !head.contains(where: { $0.id == pinnedID }),
              let session = sessions.first(where: { $0.id == pinnedID }) else {
            return Array(head)
        }
        return Array(head) + [session]
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
