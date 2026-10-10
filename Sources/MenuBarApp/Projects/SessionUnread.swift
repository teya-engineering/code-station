import Foundation

enum SessionUnread {
    // Read offers to clear either kind of unread, so a session that ended unseen can be
    // let go without opening it.
    @MainActor
    static func menuEntry(for sessionID: UUID, store: ProjectStore) -> MenuEntry {
        if store.isUnread(sessionID) {
            .item("Mark as read", icon: "envelope.open") { store.markRead(sessionID) }
        } else {
            .item("Mark as unread", icon: "envelope.badge") {
                store.setMarkedUnread(true, for: sessionID)
            }
        }
    }
}
