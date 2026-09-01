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

    var group: SidebarGroup {
        switch self {
        case .workspace: .workspaces
        case .project(let project): project.kind == .adHoc ? .tasks : .projects
        }
    }

    var isPinned: Bool {
        switch self {
        case .project(let project): project.isPinned
        case .workspace(let workspace): workspace.isPinned
        }
    }
}

// The kinds the rail can be split into, in the order the sections are shown. The raw
// value is written to preferences, so it has to stay as it is.
enum SidebarGroup: String, CaseIterable {
    case tasks
    case workspaces
    case projects

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .workspaces: "Workspaces"
        case .projects: "Projects"
        }
    }
}

// A run of the rail under one heading. A flat list is a single section with no group,
// and a section without a heading cannot be folded away.
struct SidebarSection: Identifiable {
    let group: SidebarGroup?
    let items: [SidebarItem]

    var id: String { group?.rawValue ?? "" }
}

// Grouping splits the rail into kinds; the chosen sort still orders each section.
enum ProjectGrouping: String, CaseIterable, Identifiable {
    case flat
    case kind

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flat: "None"
        case .kind: "By Type"
        }
    }

    var hint: String {
        switch self {
        case .flat: "One list with everything in it"
        case .kind: "Tasks, workspaces, and projects under their own headings"
        }
    }

    func sections(of items: [SidebarItem]) -> [SidebarSection] {
        switch self {
        case .flat:
            return [SidebarSection(group: nil, items: items)]
        case .kind:
            return SidebarGroup.allCases.compactMap { group in
                let members = items.filter { $0.group == group }
                return members.isEmpty ? nil : SidebarSection(group: group, items: members)
            }
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
        let pinnedContainerIDs = Set(sessions.lazy.filter(\.isPinned).map {
            $0.workspaceID ?? $0.projectID
        })

        switch self {
        case .name:
            return items.sorted { a, b in
                let aIsPinned = a.isPinned || pinnedContainerIDs.contains(a.id)
                let bIsPinned = b.isPinned || pinnedContainerIDs.contains(b.id)
                if aIsPinned != bIsPinned { return aIsPinned }
                return byName(a, b)
            }
        case .lastUsed:
            let latest = lastActivity(in: sessions)
            return items.sorted { a, b in
                let aIsPinned = a.isPinned || pinnedContainerIDs.contains(a.id)
                let bIsPinned = b.isPinned || pinnedContainerIDs.contains(b.id)
                if aIsPinned != bIsPinned { return aIsPinned }
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

enum SessionSort {
    static func pinnedFirstByLastActivity(_ a: ChatSession, _ b: ChatSession) -> Bool {
        if a.isPinned != b.isPinned { return a.isPinned }
        return a.lastActivity > b.lastActivity
    }
}
