import Foundation

public enum SidebarItem: Identifiable {
    case project(Project)
    case workspace(ProjectWorkspace)

    public var id: UUID {
        switch self {
        case .project(let project): project.id
        case .workspace(let workspace): workspace.id
        }
    }

    public var name: String {
        switch self {
        case .project(let project): project.name
        case .workspace(let workspace): workspace.name
        }
    }

    public var group: SidebarGroup {
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

    var sidebarPlacement: SidebarPlacement? {
        switch self {
        case .project(let project): project.sidebarPlacement
        case .workspace(let workspace): workspace.sidebarPlacement
        }
    }
}

// The kinds the rail can be split into, in the order the sections are shown. The raw
// value is written to preferences, so it has to stay as it is.
public enum SidebarGroup: String, CaseIterable, Codable, Sendable {
    case tasks
    case workspaces
    case projects

    public var title: String {
        switch self {
        case .tasks: "Tasks"
        case .workspaces: "Workspaces"
        case .projects: "Projects"
        }
    }
}

// How many session cards a sidebar container shows before "See N more…": the GUI's
// "Sessions shown" setting, within the range its menu offers.
public enum SidebarSessionLimit {
    public static let range = 2...10
    public static let defaultLimit = 4

    public static func resolved(_ limit: Int) -> Int {
        min(max(limit, range.lowerBound), range.upperBound)
    }
}

// A run of the rail under one heading. A flat list is a single section with no group,
// and a section without a heading cannot be folded away.
public struct SidebarSection: Identifiable {
    public let group: SidebarGroup?
    public let items: [SidebarItem]

    public var id: String { group?.rawValue ?? "" }
}

// Grouping splits the rail into kinds; the chosen sort still orders each section.
public enum ProjectGrouping: String, CaseIterable, Identifiable, Codable, Sendable {
    case flat
    case kind

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .flat: "Ungrouped"
        case .kind: "By type"
        }
    }

    public var hint: String {
        switch self {
        case .flat: "Everything in one list"
        case .kind: "Tasks, workspaces and projects"
        }
    }

    public var icon: String { self == .flat ? "list.bullet" : "square.grid.2x2" }

    public func sections(of items: [SidebarItem]) -> [SidebarSection] {
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
// session shown under a project or workspace is the last time anyone worked there. A row
// the person dragged to a new place keeps that place until it is used again.
public enum ProjectSort: String, CaseIterable, Identifiable, Codable, Sendable {
    case name
    case lastUsed

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .name: "Name, A to Z"
        case .lastUsed: "Last used"
        }
    }

    public var hint: String {
        switch self {
        case .name: "Find a project by its name"
        case .lastUsed: "Pick up where you left off"
        }
    }

    public var icon: String { self == .name ? "textformat.abc" : "clock" }

    public func apply(to items: [SidebarItem], sessions: [ChatSession]) -> [SidebarItem] {
        let pinned = Self.pinnedIDs(of: items, sessions: sessions)

        switch self {
        case .name:
            return items.sorted { a, b in
                let aIsPinned = pinned.contains(a.id)
                if aIsPinned != pinned.contains(b.id) { return aIsPinned }
                return byName(a, b)
            }
        case .lastUsed:
            let latest = Self.sortDates(of: items, sessions: sessions)
            return items.sorted { a, b in
                let aIsPinned = pinned.contains(a.id)
                if aIsPinned != pinned.contains(b.id) { return aIsPinned }
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

    // Whether a row counts as pinned in the order `apply` gives: a pinned session pins
    // the row it sits under.
    public static func pinnedIDs(of items: [SidebarItem], sessions: [ChatSession]) -> Set<UUID> {
        let pinnedContainerIDs = Set(sessions.lazy.filter(\.isPinned).map {
            $0.workspaceID ?? $0.projectID
        })
        return Set(items.lazy.filter { $0.isPinned || pinnedContainerIDs.contains($0.id) }.map(\.id))
    }

    // The date each row is ordered by under "Last used". The sessions' own drag places
    // are left out: moving a session inside its row says nothing about the row.
    public static func sortDates(of items: [SidebarItem], sessions: [ChatSession]) -> [UUID: Date] {
        let activity: [UUID: Date] = sessions.reduce(into: [:]) { latest, session in
            let containerID = session.workspaceID ?? session.projectID
            let seen = latest[containerID] ?? .distantPast
            if session.lastActivity > seen { latest[containerID] = session.lastActivity }
        }
        return items.reduce(into: [:]) { dates, item in
            dates[item.id] = item.sidebarPlacement?.sortDate(activity: activity[item.id])
                ?? activity[item.id]
        }
    }

    private func byName(_ a: SidebarItem, _ b: SidebarItem) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}

public enum SessionSort {
    public static func pinnedFirstByLastActivity(_ a: ChatSession, _ b: ChatSession) -> Bool {
        if a.isPinned != b.isPinned { return a.isPinned }
        return a.sidebarDate > b.sidebarDate
    }
}
