import Foundation

enum SidebarItem: Identifiable {
    case project(Project)
    case workspace(ProjectWorkspace)

    var id: UUID {
        switch self {
        case .project(let project): project.id
        case .workspace(let workspace): workspace.id
        }
    }

    var name: String {
        switch self {
        case .project(let project): project.name
        case .workspace(let workspace): workspace.name
        }
    }
}

// "Last used" comes from the sessions rather than from the container: the newest
// session shown under a project or workspace is the last time anyone worked there.
enum ProjectSort: String, CaseIterable, Identifiable {
    case name
    case lastUsed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "A-Z"
        case .lastUsed: "Last used"
        }
    }

    var hint: String {
        switch self {
        case .name: "Sort projects and workspaces by name"
        case .lastUsed: "Sort projects and workspaces by their newest session"
        }
    }

    func apply(to items: [SidebarItem], sessions: [ChatSession]) -> [SidebarItem] {
        switch self {
        case .name:
            return items.sorted(by: byName)
        case .lastUsed:
            let latest = lastActivity(in: sessions)
            return items.sorted { a, b in
                // An item with no sessions has never been used, so it falls below the ones
                // that have. Equal times fall back to the name, so the list never wobbles.
                switch (latest[a.id], latest[b.id]) {
                case let (left?, right?): return left == right ? byName(a, b) : left > right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return byName(a, b)
                }
            }
        }
    }

    private func lastActivity(in sessions: [ChatSession]) -> [UUID: Date] {
        sessions.reduce(into: [:]) { latest, session in
            let containerID = session.workspaceID ?? session.projectID
            let seen = latest[containerID] ?? .distantPast
            if session.lastActivity > seen { latest[containerID] = session.lastActivity }
        }
    }

    private func byName(_ a: SidebarItem, _ b: SidebarItem) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
