import Foundation

// Where the app keeps what it owns. macOS gives an app more than one home and they are
// not interchangeable: data the app manages lives in Application Support, secrets live in
// the Keychain, and small preferences live in UserDefaults.
enum AppPaths {
    // Bundle.main has no identifier when the binary is run straight from the build folder,
    // which is how the app runs in development.
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.teya.conductor"

    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(bundleID)
    }

    // A file the app owns, moved out of the directory an earlier version used if it is
    // still sitting there. Without the move, an upgrade would look like a fresh install.
    static func supportFile(_ name: String, movedFrom legacy: URL? = nil) -> URL {
        let url = support.appendingPathComponent(name)
        if let legacy { move(legacy, to: url) }
        return url
    }

    static func move(_ legacy: URL, to url: URL) {
        let files = FileManager.default
        guard files.fileExists(atPath: legacy.path), !files.fileExists(atPath: url.path) else { return }
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.moveItem(at: legacy, to: url)
    }

    // Where an earlier version kept everything, in the XDG style.
    static func legacy(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-conductor/\(name)")
    }

    // Logs go where macOS keeps logs rather than in Application Support, so Console and
    // the usual "collect the logs" habits find them without being told where to look.
    static var logs: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(bundleID)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // Worktrees are git checkouts holding work that is not committed yet, so they cannot
    // live in Caches where the system is free to reclaim them. They are kept out of
    // backups instead, since a checkout is reproducible from the repository it came from.
    static func directory(_ name: String, backedUp: Bool = true) -> URL {
        let url = support.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if !backedUp {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = url
            try? mutable.setResourceValues(values)
        }
        return url
    }
}

// The handful of things that are preferences rather than data: what was open last time.
// macOS has a place for these, so they do not belong in the file holding the projects.
enum Preferences {
    private static var store: UserDefaults { .standard }

    static var selectedSessionID: UUID? {
        get { uuid("selectedSessionID") }
        set { set(newValue, "selectedSessionID") }
    }

    static var selectedProjectID: UUID? {
        get { uuid("selectedProjectID") }
        set { set(newValue, "selectedProjectID") }
    }

    static var selectedWorkspaceID: UUID? {
        get { uuid("selectedWorkspaceID") }
        set { set(newValue, "selectedWorkspaceID") }
    }

    // A missing entry keeps the sidebar's normal first-use behavior. Once a project or
    // workspace has been opened or closed, its own choice survives every later launch.
    static var sidebarExpansion: [UUID: Bool] {
        get { sidebarExpansion(in: store) }
        set { setSidebarExpansion(newValue, in: store) }
    }

    // Which agent runs the sessions. Everything else about an agent lives in its own
    // config; this is only the app's choice between them.
    static var agent: AgentKind {
        get { store.string(forKey: "agent").flatMap(AgentKind.init(rawValue:)) ?? .claudeCode }
        set { store.set(newValue.rawValue, forKey: "agent") }
    }

    // The bot choice preselected for new sessions. Non-bot is stored as an explicit
    // name so it stays distinct from sessions created before bot choices existed.
    static func defaultAgentAvatarName(in store: UserDefaults) -> String? {
        store.string(forKey: "defaultAgentAvatarName")
    }

    static func setDefaultAgentAvatarName(_ name: String, in store: UserDefaults) {
        store.set(name, forKey: "defaultAgentAvatarName")
    }

    // What a session runs with when it has not picked for itself. Defaults belong to the
    // agent that reads them, so one CLI's model and access choices cannot affect another.
    static func sessionDefaults(for agent: AgentKind) -> SessionSettings {
        switch agent {
        case .claudeCode:
            SessionSettings(model: text("claudeDefaultModel") ?? text("defaultModel"),
                            effort: text("claudeDefaultEffort") ?? text("defaultEffort"),
                            permissionMode: store.string(forKey: "claudePermissionMode")
                                ?? store.string(forKey: "permissionMode")
                                ?? "acceptEdits")
        case .codex:
            SessionSettings(model: text("codexDefaultModel") ?? text("defaultModel"),
                            effort: text("codexDefaultEffort") ?? text("defaultEffort"),
                            codexSandboxMode: store.string(forKey: "codexSandboxMode")
                                ?? CodexSandboxMode.workspaceWrite.rawValue)
        }
    }

    static func setSessionDefaults(_ settings: SessionSettings, for agent: AgentKind) {
        switch agent {
        case .claudeCode:
            set(settings.model, "claudeDefaultModel")
            set(settings.effort, "claudeDefaultEffort")
            store.set(settings.permissionMode ?? "acceptEdits", forKey: "claudePermissionMode")
        case .codex:
            set(settings.model, "codexDefaultModel")
            set(settings.effort, "codexDefaultEffort")
            store.set(CodexSandboxMode.resolved(settings.codexSandboxMode).rawValue,
                      forKey: "codexSandboxMode")
        }
    }

    // How long a session has to sit untouched before the app offers to clear it.
    static var oldSessionDays: Int {
        get { oldSessionDays(in: store) }
        set { store.set(OldSessions.resolvedDays(newValue), forKey: "oldSessionDays") }
    }

    static func oldSessionDays(in store: UserDefaults) -> Int {
        guard store.object(forKey: "oldSessionDays") != nil else {
            return OldSessions.defaultDays
        }
        return OldSessions.resolvedDays(store.integer(forKey: "oldSessionDays"))
    }

    static var skillsRefreshInterval: SkillsRefreshInterval {
        get {
            guard store.object(forKey: "skillsRefreshInterval") != nil else { return .fiveDays }
            return SkillsRefreshInterval(rawValue: store.integer(forKey: "skillsRefreshInterval"))
                ?? .fiveDays
        }
        set { store.set(newValue.rawValue, forKey: "skillsRefreshInterval") }
    }

    static var skillsLastRefresh: Date? {
        get { store.object(forKey: "skillsLastRefresh") as? Date }
        set { store.set(newValue, forKey: "skillsLastRefresh") }
    }

    // How the sidebar orders projects. An unset key reads as the alphabetical order,
    // which is the one the list has always been in.
    static var projectSort: ProjectSort {
        get { store.string(forKey: "projectSort").flatMap(ProjectSort.init(rawValue:)) ?? .name }
        set { store.set(newValue.rawValue, forKey: "projectSort") }
    }

    static func sidebarExpansion(in store: UserDefaults) -> [UUID: Bool] {
        let saved = store.dictionary(forKey: "sidebarExpansion") ?? [:]
        return saved.reduce(into: [:]) { expansion, entry in
            guard let id = UUID(uuidString: entry.key), let isExpanded = entry.value as? Bool else {
                return
            }
            expansion[id] = isExpanded
        }
    }

    static func setSidebarExpansion(_ expansion: [UUID: Bool], in store: UserDefaults) {
        guard !expansion.isEmpty else {
            store.removeObject(forKey: "sidebarExpansion")
            return
        }
        store.set(Dictionary(uniqueKeysWithValues: expansion.map {
            ($0.key.uuidString, $0.value)
        }), forKey: "sidebarExpansion")
    }

    private static func text(_ key: String) -> String? {
        store.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func uuid(_ key: String) -> UUID? {
        store.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    private static func set(_ text: String?, _ key: String) {
        if let text, !text.isEmpty {
            store.set(text, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    private static func set(_ id: UUID?, _ key: String) {
        set(id?.uuidString, key)
    }
}
