import Foundation

struct SidebarSessionVisibility {
    static let initialLimit = 4

    private var additionalVisible: [UUID: Int] = [:]
    private var showingAll: Set<UUID> = []

    func visibleCount(for containerID: UUID, total: Int) -> Int {
        guard !showingAll.contains(containerID) else { return total }
        return min(total, Self.initialLimit + additionalVisible[containerID, default: 0])
    }

    mutating func preserveVisibleSessions(added: Int, previousTotal: Int,
                                          in containerID: UUID) {
        guard added > 0, !showingAll.contains(containerID) else { return }
        let previousVisible = visibleCount(for: containerID, total: previousTotal)
        additionalVisible[containerID] = max(
            0, previousVisible + added - Self.initialLimit)
    }

    mutating func showAll(_ containerID: UUID) {
        showingAll.insert(containerID)
        additionalVisible.removeValue(forKey: containerID)
    }

    mutating func reset(_ containerID: UUID) {
        showingAll.remove(containerID)
        additionalVisible.removeValue(forKey: containerID)
    }
}
