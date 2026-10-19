import Foundation

// The preferences whose types belong to the project store and its sessions.
extension Preferences {
    // The sections the sidebar folds away, so a kind the user rarely touches costs the
    // rail a heading rather than a row each.
    public static func collapsedSidebarGroups(in store: UserDefaults = Preferences.defaults) -> Set<SidebarGroup> {
        let saved = store.array(forKey: "collapsedSidebarGroups") as? [String] ?? []
        return Set(saved.compactMap(SidebarGroup.init(rawValue:)))
    }

    public static func setCollapsedSidebarGroups(_ groups: Set<SidebarGroup>,
                                          in store: UserDefaults = Preferences.defaults) {
        guard !groups.isEmpty else {
            store.removeObject(forKey: "collapsedSidebarGroups")
            return
        }
        store.set(groups.map(\.rawValue), forKey: "collapsedSidebarGroups")
    }

    // Which sidebar rows the person opened or closed. A missing entry keeps the sidebar's
    // first-use behaviour; once a project or workspace has been opened or closed, its own
    // choice survives every later launch. Every front end starts from it.
    public static func sidebarExpansion(in store: UserDefaults = Preferences.defaults) -> [UUID: Bool] {
        let saved = store.dictionary(forKey: "sidebarExpansion") ?? [:]
        return saved.reduce(into: [:]) { expansion, entry in
            guard let id = UUID(uuidString: entry.key), let isExpanded = entry.value as? Bool else {
                return
            }
            expansion[id] = isExpanded
        }
    }

    public static func setSidebarExpansion(_ expansion: [UUID: Bool],
                                           in store: UserDefaults = Preferences.defaults) {
        guard !expansion.isEmpty else {
            store.removeObject(forKey: "sidebarExpansion")
            return
        }
        store.set(Dictionary(uniqueKeysWithValues: expansion.map {
            ($0.key.uuidString, $0.value)
        }), forKey: "sidebarExpansion")
    }

    // How many session cards a sidebar container shows before "See more" ("Sessions
    // shown" in the GUI's settings).
    public static func sidebarSessionLimit(in store: UserDefaults = Preferences.defaults) -> Int {
        guard store.object(forKey: "sidebarSessionLimit") != nil else {
            return SidebarSessionLimit.defaultLimit
        }
        return SidebarSessionLimit.resolved(store.integer(forKey: "sidebarSessionLimit"))
    }

    public static func setSidebarSessionLimit(_ limit: Int, in store: UserDefaults = Preferences.defaults) {
        store.set(SidebarSessionLimit.resolved(limit), forKey: "sidebarSessionLimit")
    }

    // How long a session has to sit untouched before the app offers to clear it.
    public static func oldSessionDays(in store: UserDefaults = Preferences.defaults) -> Int {
        guard store.object(forKey: "oldSessionDays") != nil else {
            return OldSessions.defaultDays
        }
        return OldSessions.resolvedDays(store.integer(forKey: "oldSessionDays"))
    }

    public static func setOldSessionDays(_ days: Int, in store: UserDefaults = Preferences.defaults) {
        store.set(OldSessions.resolvedDays(days), forKey: "oldSessionDays")
    }

    // What happens after a session has remained old for the warning hour. The old Boolean
    // maps to the equivalent safe choice, so an upgrade does not make cleanup more
    // destructive than the person previously allowed.
    public static func oldSessionCleanupPolicy(in store: UserDefaults = Preferences.defaults)
        -> OldSessionCleanupPolicy {
        if let rawValue = store.string(forKey: "oldSessionCleanupPolicy"),
           let policy = OldSessionCleanupPolicy(rawValue: rawValue) {
            return policy
        }
        guard store.object(forKey: "autoDeleteOldSessions") != nil else { return .deleteAll }
        return store.bool(forKey: "autoDeleteOldSessions") ? .deleteSafe : .review
    }

    public static func setOldSessionCleanupPolicy(_ policy: OldSessionCleanupPolicy,
                                           in store: UserDefaults = Preferences.defaults) {
        store.set(policy.rawValue, forKey: "oldSessionCleanupPolicy")
        store.removeObject(forKey: "autoDeleteOldSessions")
    }

    // How the sidebar orders projects. An unset key reads as the alphabetical order,
    // which is the one the list has always been in.
    public static func projectSort(in store: UserDefaults = Preferences.defaults) -> ProjectSort {
        store.string(forKey: "projectSort").flatMap(ProjectSort.init(rawValue:)) ?? .name
    }

    public static func setProjectSort(_ sort: ProjectSort, in store: UserDefaults = Preferences.defaults) {
        store.set(sort.rawValue, forKey: "projectSort")
    }

    // Whether the sidebar splits into sections by kind. An unset key reads as the flat
    // list the rail has always shown.
    public static func projectGrouping(in store: UserDefaults = Preferences.defaults) -> ProjectGrouping {
        store.string(forKey: "projectGrouping")
            .flatMap(ProjectGrouping.init(rawValue:)) ?? .flat
    }

    public static func setProjectGrouping(
        _ grouping: ProjectGrouping,
        in store: UserDefaults = Preferences.defaults
    ) {
        store.set(grouping.rawValue, forKey: "projectGrouping")
    }
}
