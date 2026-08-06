import Foundation

// The order the sidebar reads its projects in. "Last used" comes from the sessions
// rather than from the project: a project is only ever touched through a session, so
// the newest session under it is the last time anyone worked there.
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
        case .name: "Sort projects by name"
        case .lastUsed: "Sort projects by the newest session in each"
        }
    }

    func apply(to projects: [Project], sessions: [ChatSession]) -> [Project] {
        switch self {
        case .name:
            return projects.sorted(by: byName)
        case .lastUsed:
            let latest = lastActivity(in: sessions)
            return projects.sorted { a, b in
                // A project with no sessions has never been used, so it falls below the
                // ones that have. Equal times fall back to the name, so the list never
                // wobbles between redraws.
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
            let seen = latest[session.projectID] ?? .distantPast
            if session.lastActivity > seen { latest[session.projectID] = session.lastActivity }
        }
    }

    private func byName(_ a: Project, _ b: Project) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
