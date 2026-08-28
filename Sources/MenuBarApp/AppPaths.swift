import Foundation

// Where the app keeps what it owns. macOS gives an app more than one home and they are
// not interchangeable: data the app manages lives in Application Support, secrets live in
// the Keychain, and small preferences live in UserDefaults.
enum AppPaths {
    // Bundle.main has no identifier when the binary is run straight from the build folder,
    // which is how the app runs in development.
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.teya.code-station"

    // The identifier the app answered to before it was renamed. Everything the app owns is
    // filed under the identifier - the data folder, the logs, the preferences and the
    // Keychain items - so the old one has to stay readable or an upgrade looks like a
    // fresh install. Keychain.swift reads it for the same reason.
    static let previousBundleID = "com.teya.conductor"

    private static var supportBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
    }

    static var support: URL {
        _ = adoptedPreviousBundle
        return supportBase.appendingPathComponent(bundleID)
    }

    // Carries what the old identifier owns over to the new one. A `static let` runs once
    // per launch and before any path below is handed out, so nothing has been created
    // under the new name yet and the moves below still see an empty destination.
    private static let adoptedPreviousBundle: Void = {
        guard bundleID != previousBundleID else { return }
        move(supportBase.appendingPathComponent(previousBundleID),
             to: supportBase.appendingPathComponent(bundleID))
        move(logsBase.appendingPathComponent(previousBundleID),
             to: logsBase.appendingPathComponent(bundleID))
        adoptDefaults(of: previousBundleID)
    }()

    // Preferences live in a domain named after the bundle, so the renamed app would start
    // with none of the choices the user made. A key already answered here wins, so this
    // can never undo a newer answer, and the marker keeps a later launch from reviving a
    // preference the user has since cleared.
    static func adoptDefaults(of domain: String, into store: UserDefaults = .standard) {
        let marker = "adoptedDefaultsFrom-\(domain)"
        guard !store.bool(forKey: marker) else { return }
        store.set(true, forKey: marker)
        guard let previous = store.persistentDomain(forName: domain) else { return }
        for (key, value) in previous where store.object(forKey: key) == nil {
            store.set(value, forKey: key)
        }
    }

    // A file the app owns, moved out of the directory an earlier version used if it is
    // still sitting there. Without the move, an upgrade would look like a fresh install.
    static func supportFile(_ name: String, movedFrom legacy: URL? = nil) -> URL {
        let url = support.appendingPathComponent(name)
        if let legacy { move(legacy, to: url) }
        return url
    }

    static func supportFile(_ name: String, moving candidates: [URL]) -> URL {
        let url = support.appendingPathComponent(name)
        move(candidates, to: url)
        return url
    }

    static func move(_ candidates: [URL], to url: URL) {
        for candidate in candidates { move(candidate, to: url) }
    }

    static func move(_ legacy: URL, to url: URL) {
        let files = FileManager.default
        guard files.fileExists(atPath: legacy.path), !files.fileExists(atPath: url.path) else { return }
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.moveItem(at: legacy, to: url)
    }

    // Where an earlier version kept everything, in the XDG style. The name is the one that
    // release wrote, so it stays as it is however the app is called now.
    static func legacy(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-conductor/\(name)")
    }

    // Logs go where macOS keeps logs rather than in Application Support, so Console and
    // the usual "collect the logs" habits find them without being told where to look.
    static var logs: URL {
        _ = adoptedPreviousBundle
        let url = logsBase.appendingPathComponent(bundleID)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var logsBase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    }

    // Creates an app-owned folder and optionally keeps reproducible or short-lived data
    // out of backups. The caller chooses whether that folder belongs under support or in
    // another app-owned location.
    static func directory(_ name: String, backedUp: Bool = true) -> URL {
        let url = support.appendingPathComponent(name)
        return directory(at: url, backedUp: backedUp)
    }

    static func directory(at url: URL, backedUp: Bool = true) -> URL {
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
// A preference takes the store as a parameter where a settings object or a test reads
// its own UserDefaults; the rest only ever read the standard one.
enum Preferences {
    private static var store: UserDefaults { .standard }

    static func hasCompletedOnboarding(in store: UserDefaults = .standard) -> Bool {
        store.bool(forKey: "hasCompletedOnboarding")
    }

    static func setHasCompletedOnboarding(_ completed: Bool, in store: UserDefaults = .standard) {
        store.set(completed, forKey: "hasCompletedOnboarding")
    }

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
    static func sidebarExpansion(in store: UserDefaults = .standard) -> [UUID: Bool] {
        let saved = store.dictionary(forKey: "sidebarExpansion") ?? [:]
        return saved.reduce(into: [:]) { expansion, entry in
            guard let id = UUID(uuidString: entry.key), let isExpanded = entry.value as? Bool else {
                return
            }
            expansion[id] = isExpanded
        }
    }

    static func setSidebarExpansion(_ expansion: [UUID: Bool], in store: UserDefaults = .standard) {
        guard !expansion.isEmpty else {
            store.removeObject(forKey: "sidebarExpansion")
            return
        }
        store.set(Dictionary(uniqueKeysWithValues: expansion.map {
            ($0.key.uuidString, $0.value)
        }), forKey: "sidebarExpansion")
    }

    // The sections the sidebar folds away, so a kind the user rarely touches costs the
    // rail a heading rather than a row each.
    static func collapsedSidebarGroups(in store: UserDefaults = .standard) -> Set<SidebarGroup> {
        let saved = store.array(forKey: "collapsedSidebarGroups") as? [String] ?? []
        return Set(saved.compactMap(SidebarGroup.init(rawValue:)))
    }

    static func setCollapsedSidebarGroups(_ groups: Set<SidebarGroup>,
                                          in store: UserDefaults = .standard) {
        guard !groups.isEmpty else {
            store.removeObject(forKey: "collapsedSidebarGroups")
            return
        }
        store.set(groups.map(\.rawValue), forKey: "collapsedSidebarGroups")
    }

    static func sidebarSessionLimit(in store: UserDefaults = .standard) -> Int {
        guard store.object(forKey: "sidebarSessionLimit") != nil else {
            return SidebarSessionVisibility.defaultLimit
        }
        return SidebarSessionVisibility.resolvedLimit(
            store.integer(forKey: "sidebarSessionLimit"))
    }

    static func setSidebarSessionLimit(_ limit: Int, in store: UserDefaults = .standard) {
        store.set(SidebarSessionVisibility.resolvedLimit(limit),
                  forKey: "sidebarSessionLimit")
    }

    // Which agent runs the sessions. Everything else about an agent lives in its own
    // config; this is only the app's choice between them.
    static var agent: AgentKind {
        get { store.string(forKey: "agent").flatMap(AgentKind.init(rawValue:)) ?? .claudeCode }
        set { store.set(newValue.rawValue, forKey: "agent") }
    }

    // The bot choice preselected for new sessions. The built-in Default bot has a stable
    // name so sessions do not depend on a custom image file.
    static func defaultAgentAvatarName(in store: UserDefaults = .standard) -> String? {
        store.string(forKey: "defaultAgentAvatarName")
    }

    static func setDefaultAgentAvatarName(_ name: String, in store: UserDefaults = .standard) {
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
                                ?? PermissionMode.fallback.rawValue)
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
            store.set(PermissionMode(stored: settings.permissionMode).rawValue,
                      forKey: "claudePermissionMode")
        case .codex:
            set(settings.model, "codexDefaultModel")
            set(settings.effort, "codexDefaultEffort")
            store.set(CodexSandboxMode.resolved(settings.codexSandboxMode).rawValue,
                      forKey: "codexSandboxMode")
        }
    }

    // How long a session has to sit untouched before the app offers to clear it.
    static func oldSessionDays(in store: UserDefaults = .standard) -> Int {
        guard store.object(forKey: "oldSessionDays") != nil else {
            return OldSessions.defaultDays
        }
        return OldSessions.resolvedDays(store.integer(forKey: "oldSessionDays"))
    }

    static func setOldSessionDays(_ days: Int, in store: UserDefaults = .standard) {
        store.set(OldSessions.resolvedDays(days), forKey: "oldSessionDays")
    }

    // What happens after a session has remained old for the warning hour. The old Boolean
    // maps to the equivalent safe choice, so an upgrade does not make cleanup more
    // destructive than the person previously allowed.
    static func oldSessionCleanupPolicy(in store: UserDefaults = .standard)
        -> OldSessionCleanupPolicy {
        if let rawValue = store.string(forKey: "oldSessionCleanupPolicy"),
           let policy = OldSessionCleanupPolicy(rawValue: rawValue) {
            return policy
        }
        guard store.object(forKey: "autoDeleteOldSessions") != nil else { return .deleteAll }
        return store.bool(forKey: "autoDeleteOldSessions") ? .deleteSafe : .review
    }

    static func setOldSessionCleanupPolicy(_ policy: OldSessionCleanupPolicy,
                                           in store: UserDefaults = .standard) {
        store.set(policy.rawValue, forKey: "oldSessionCleanupPolicy")
        store.removeObject(forKey: "autoDeleteOldSessions")
    }

    static var skillsRefreshInterval: SkillsRefreshInterval {
        get {
            guard store.object(forKey: "skillsRefreshInterval") != nil else { return .fiveDays }
            return SkillsRefreshInterval(rawValue: store.integer(forKey: "skillsRefreshInterval"))
                ?? .fiveDays
        }
        set { store.set(newValue.rawValue, forKey: "skillsRefreshInterval") }
    }

    static func skillsLastRefresh(in store: UserDefaults = .standard) -> Date? {
        store.object(forKey: "skillsLastRefresh") as? Date
    }

    static func setSkillsLastRefresh(_ date: Date?, in store: UserDefaults = .standard) {
        store.set(date, forKey: "skillsLastRefresh")
    }

    // The skills a diagnosis is told to use. The choice belongs to the person rather than
    // to any one problem, so the next Troubleshoot opens with the last one already made.
    static func troubleshootSkills(in store: UserDefaults = .standard) -> Set<String> {
        Set(store.array(forKey: "troubleshootSkills") as? [String] ?? [])
    }

    static func setTroubleshootSkills(_ skills: Set<String>, in store: UserDefaults = .standard) {
        guard !skills.isEmpty else {
            store.removeObject(forKey: "troubleshootSkills")
            return
        }
        store.set(skills.sorted(), forKey: "troubleshootSkills")
    }

    static func skillsMarketplace(in store: UserDefaults = .standard)
        -> SkillMarketplaceConfiguration? {
        guard let data = store.data(forKey: "skillsMarketplace") else { return nil }
        return try? JSONDecoder().decode(SkillMarketplaceConfiguration.self, from: data)
    }

    static func setSkillsMarketplace(_ marketplace: SkillMarketplaceConfiguration?,
                                     in store: UserDefaults = .standard) {
        guard let marketplace, let data = try? JSONEncoder().encode(marketplace) else {
            store.removeObject(forKey: "skillsMarketplace")
            return
        }
        store.set(data, forKey: "skillsMarketplace")
    }

    // How the sidebar orders projects. An unset key reads as the alphabetical order,
    // which is the one the list has always been in.
    static var projectSort: ProjectSort {
        get { store.string(forKey: "projectSort").flatMap(ProjectSort.init(rawValue:)) ?? .name }
        set { store.set(newValue.rawValue, forKey: "projectSort") }
    }

    // Whether the sidebar splits into sections by kind. An unset key reads as the flat
    // list the rail has always shown.
    static var projectGrouping: ProjectGrouping {
        get {
            store.string(forKey: "projectGrouping")
                .flatMap(ProjectGrouping.init(rawValue:)) ?? .flat
        }
        set { store.set(newValue.rawValue, forKey: "projectGrouping") }
    }

    // Which terminal opens a shell in a window of its own. Held as a bundle ID so the
    // choice survives the app being moved or renamed. Unset follows the system.
    static var terminalBundleID: String? {
        get { text("terminalBundleID") }
        set { set(newValue, "terminalBundleID") }
    }

    // A saved external site file sits ahead of the conventional and bundled locations.
    // Imported first-run configuration uses the conventional Application Support file.
    static func siteDefaultsURL(in store: UserDefaults = .standard) -> URL? {
        store.string(forKey: "siteDefaultsPath").map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
    }

    static func setSiteDefaultsURL(_ url: URL?, in store: UserDefaults = .standard) {
        guard let url else {
            store.removeObject(forKey: "siteDefaultsPath")
            return
        }
        store.set(url.standardizedFileURL.path, forKey: "siteDefaultsPath")
    }

    static var appearance: Appearance {
        get { store.string(forKey: "appearance").flatMap(Appearance.init(rawValue:)) ?? .system }
        set { store.set(newValue.rawValue, forKey: "appearance") }
    }

    static func sidebarIconSet(in store: UserDefaults = .standard) -> SidebarIconSet {
        store.string(forKey: "sidebarIconSet").flatMap(SidebarIconSet.init(rawValue:))
            ?? .diceBear
    }

    static func setSidebarIconSet(_ iconSet: SidebarIconSet, in store: UserDefaults = .standard) {
        store.set(iconSet.rawValue, forKey: "sidebarIconSet")
    }

    static func diceBearAvatarStyle(in store: UserDefaults = .standard) -> DiceBearAvatarStyle {
        store.string(forKey: "diceBearAvatarStyle")
            .flatMap(DiceBearAvatarStyle.init(rawValue:)) ?? .waves
    }

    static func setDiceBearAvatarStyle(_ style: DiceBearAvatarStyle,
                                       in store: UserDefaults = .standard) {
        store.set(style.rawValue, forKey: "diceBearAvatarStyle")
    }

    // How large a session's own text is drawn. A reading size belongs to the person at the
    // machine rather than to any one session, so there is a single answer for the app.
    static var textSize: TextSize {
        get { store.string(forKey: "textSize").flatMap(TextSize.init(rawValue:)) ?? .standard }
        set { store.set(newValue.rawValue, forKey: "textSize") }
    }

    static func designEnabled(in store: UserDefaults = .standard) -> Bool {
        store.bool(forKey: "designEnabled")
    }

    static func setDesignEnabled(_ enabled: Bool, in store: UserDefaults = .standard) {
        store.set(enabled, forKey: "designEnabled")
    }

    // Mobile access exposes live session control to another device, so it stays off until
    // someone deliberately opts into the experimental surface.
    static func mobileAccessEnabled(in store: UserDefaults = .standard) -> Bool {
        store.bool(forKey: "mobileAccessEnabled")
    }

    static func setMobileAccessEnabled(_ enabled: Bool, in store: UserDefaults = .standard) {
        store.set(enabled, forKey: "mobileAccessEnabled")
    }

    // Whether what a session has spent is shown. Kept per agent, like the session
    // defaults are, because what a CLI reports about cost is its own business. On unless
    // it is turned off: the figure is still recorded either way, so this only decides
    // whether it is on screen.
    static func showCost(for agent: AgentKind) -> Bool {
        let key = showCostKey(agent)
        guard store.object(forKey: key) != nil else { return true }
        return store.bool(forKey: key)
    }

    static func setShowCost(_ shown: Bool, for agent: AgentKind) {
        store.set(shown, forKey: showCostKey(agent))
    }

    private static func showCostKey(_ agent: AgentKind) -> String {
        "showCost-\(agent.rawValue)"
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
