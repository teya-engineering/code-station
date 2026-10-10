import Foundation

// Where the person dropped a row in the "Last used" order. That order is a date, so a
// drop gives the row a date between its new neighbours rather than a position. It is
// kept apart from the real activity time, which a row still shows and which the old
// session cleanup reads, and which a transcript write would put back anyway.
//
// Work done after the drop is newer than the drop, so it moves the row the way it
// always would.
struct SidebarPlacement: Codable, Equatable, Sendable {
    var date: Date
    var placedAt: Date

    func sortDate(activity: Date?) -> Date {
        guard let activity, activity > placedAt else { return date }
        return activity
    }

    struct Row: Equatable {
        let id: UUID
        let isPinned: Bool
        let date: Date?
    }

    // `rows` is the list as it is drawn, newest first. Pinned rows always sit above the
    // rest, so a row only moves among rows on the same side of that line. Rows with no
    // date sit at the bottom in name order, and no date can put a row in among them.
    static func date(moving id: UUID, beside targetID: UUID, after: Bool,
                     in rows: [Row], now: Date = Date()) -> Date? {
        guard id != targetID, let moved = rows.first(where: { $0.id == id }) else { return nil }
        let peers = rows.filter { $0.id != id && $0.isPinned == moved.isPinned }
        guard let target = peers.firstIndex(where: { $0.id == targetID }) else { return nil }
        let index = after ? target + 1 : target
        let above = index > 0 ? peers[index - 1] : nil
        let below = index < peers.count ? peers[index] : nil

        if let above {
            guard let top = above.date else { return nil }
            guard let bottom = below?.date else { return top.addingTimeInterval(-1) }
            return Date(timeIntervalSinceReferenceDate:
                (top.timeIntervalSinceReferenceDate + bottom.timeIntervalSinceReferenceDate) / 2)
        }
        return below?.date?.addingTimeInterval(1) ?? now
    }
}
