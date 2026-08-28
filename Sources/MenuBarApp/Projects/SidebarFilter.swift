import Foundation

// What the text in the sidebar filter box matches. A row answers to its own name, and a
// session to what is written on its card: its title and the label in front of it. An
// empty filter matches everything, so the rail is whole again as soon as the box is
// cleared.
struct SidebarFilter {
    let query: String

    init(_ text: String) {
        query = text.trimmed
    }

    var isActive: Bool { !query.isEmpty }

    // A workspace passes its projects as the other names, since its row is written with
    // them and the user reads the workspace by what is inside it.
    func matches(name: String, orAnyOf otherNames: [String] = []) -> Bool {
        guard isActive else { return true }
        return ([name] + otherNames).contains { $0.localizedCaseInsensitiveContains(query) }
    }

    func matches(_ session: ChatSession) -> Bool {
        guard isActive else { return true }
        if session.title.localizedCaseInsensitiveContains(query) { return true }
        return session.isTroubleshooting
            && SidebarFilter.troubleshootLabel.localizedCaseInsensitiveContains(query)
    }

    func sessions(from sessions: [ChatSession], revealingAll: Bool = false) -> [ChatSession] {
        guard isActive, !revealingAll else { return sessions }
        return sessions.filter(matches)
    }

    // The word the card shows in place of a kind, matched as it is read rather than as it
    // is drawn: the chip is upper case, but nobody types it that way.
    private static let troubleshootLabel = "troubleshoot"
}
