import Foundation

struct SidebarSessionVisibility {
    static let initialLimit = 4

    private var showingAll: Set<UUID> = []

    func visibleCount(for containerID: UUID, total: Int) -> Int {
        showingAll.contains(containerID) ? total : min(total, Self.initialLimit)
    }

    mutating func showAll(_ containerID: UUID) {
        showingAll.insert(containerID)
    }

    mutating func reset(_ containerID: UUID) {
        showingAll.remove(containerID)
    }
}
