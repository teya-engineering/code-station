import Foundation

// Where the app keeps what it owns. macOS gives an app more than one home and they are
// not interchangeable: data the app manages lives in Application Support, secrets live in
// the Keychain, and small preferences live in UserDefaults.
public enum AppPaths {
    // Bundle.main has no identifier when the binary is run straight from the build folder,
    // which is how the app runs in development.
    public static let bundleID = Bundle.main.bundleIdentifier ?? stationID

    // The identifier the station's files and preferences are filed under, whichever
    // binary is reading them: the app, or the terminal front end outside its bundle.
    public static let stationID = "com.teya.code-station"

    // The identifier the app answered to before it was renamed. Everything the app owns is
    // filed under the identifier - the data folder, the logs, the preferences and the
    // Keychain items - so the old one has to stay readable or an upgrade looks like a
    // fresh install. Keychain.swift reads it for the same reason.
    public static let previousBundleID = "com.teya.conductor"

    private static var supportBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
    }

    public static var support: URL {
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
    static func adoptDefaults(of domain: String, into store: UserDefaults = Preferences.defaults) {
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
    public static func supportFile(_ name: String, movedFrom legacy: URL? = nil) -> URL {
        let url = support.appendingPathComponent(name)
        if let legacy { move(legacy, to: url) }
        return url
    }

    public static func supportFile(_ name: String, moving candidates: [URL]) -> URL {
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
    public static func legacy(_ name: String) -> URL {
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
    public static func directory(_ name: String, backedUp: Bool = true) -> URL {
        let url = support.appendingPathComponent(name)
        return directory(at: url, backedUp: backedUp)
    }

    public static func directory(at url: URL, backedUp: Bool = true) -> URL {
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
// its own UserDefaults; convenience properties keep app-wide callers on the standard one.
public enum Preferences {
    package static var store: UserDefaults { defaults }

    // Where preferences are read and written. The app's own domain is the standard one,
    // since it is named after the bundle. A binary outside the bundle, such as the
    // terminal front end started from a symlink, would read a domain of its own instead,
    // so it calls `followStation()` first and reads the app's domain by name.
    public static var defaults: UserDefaults { stationDefaults ?? .standard }

    // Set once, at startup, before anything reads a preference.
    nonisolated(unsafe) private static var stationDefaults: UserDefaults?

    public static func followStation() {
        guard Bundle.main.bundleIdentifier != AppPaths.stationID else { return }
        stationDefaults = UserDefaults(suiteName: AppPaths.stationID)
    }

    public static func hasCompletedOnboarding(in store: UserDefaults = Preferences.defaults) -> Bool {
        store.bool(forKey: "hasCompletedOnboarding")
    }

    public static func setHasCompletedOnboarding(_ completed: Bool, in store: UserDefaults = Preferences.defaults) {
        store.set(completed, forKey: "hasCompletedOnboarding")
    }

    public static var selectedSessionID: UUID? {
        get { uuid("selectedSessionID") }
        set { set(newValue, "selectedSessionID") }
    }

    public static var selectedProjectID: UUID? {
        get { uuid("selectedProjectID") }
        set { set(newValue, "selectedProjectID") }
    }

    public static var selectedWorkspaceID: UUID? {
        get { uuid("selectedWorkspaceID") }
        set { set(newValue, "selectedWorkspaceID") }
    }

    // A missing entry means the session has never made a choice, so the app-level default
    // decides whether a live turn opens the working set. A session-specific choice wins
    // on later turns and launches.
    public static func workingSetVisibility(in store: UserDefaults = Preferences.defaults) -> [UUID: Bool] {
        let saved = store.dictionary(forKey: "workingSetVisibility") ?? [:]
        return saved.reduce(into: [:]) { visibility, entry in
            guard let id = UUID(uuidString: entry.key), let isVisible = entry.value as? Bool else {
                return
            }
            visibility[id] = isVisible
        }
    }

    public static func setWorkingSetVisible(_ visible: Bool, for sessionID: UUID,
                                     in store: UserDefaults = Preferences.defaults) {
        var visibility = workingSetVisibility(in: store)
        visibility[sessionID] = visible
        store.set(Dictionary(uniqueKeysWithValues: visibility.map {
            ($0.key.uuidString, $0.value)
        }), forKey: "workingSetVisibility")
    }

    public static func opensWorkingSetByDefault(in store: UserDefaults = Preferences.defaults) -> Bool {
        store.bool(forKey: "opensWorkingSetByDefault")
    }

    public static func setOpensWorkingSetByDefault(_ opens: Bool,
                                            in store: UserDefaults = Preferences.defaults) {
        store.set(opens, forKey: "opensWorkingSetByDefault")
    }

    // Which agent runs the sessions. Everything else about an agent lives in its own
    // config; this is only the app's choice between them.
    public static var agent: AgentKind {
        get { agent(in: store) }
        set { setAgent(newValue, in: store) }
    }

    public static func agent(in store: UserDefaults) -> AgentKind {
        store.string(forKey: "agent").flatMap(AgentKind.init(rawValue:)) ?? .claudeCode
    }

    public static func setAgent(_ agent: AgentKind, in store: UserDefaults) {
        store.set(agent.rawValue, forKey: "agent")
    }

    // The bot choice preselected for new sessions. The built-in Default bot has a stable
    // name so sessions do not depend on a custom image file.
    public static func defaultAgentAvatarName(in store: UserDefaults = Preferences.defaults) -> String? {
        store.string(forKey: "defaultAgentAvatarName")
    }

    public static func setDefaultAgentAvatarName(_ name: String, in store: UserDefaults = Preferences.defaults) {
        store.set(name, forKey: "defaultAgentAvatarName")
    }

    // What a session runs with when it has not picked for itself. Defaults belong to the
    // agent that reads them, so one CLI's model and access choices cannot affect another.
    // The second opinion lineup the person saved as their usual. Empty until they save one.
    public static func secondOpinionLineup(in store: UserDefaults = Preferences.defaults) -> [SecondOpinion.Reviewer] {
        guard let data = store.data(forKey: "secondOpinionLineup"),
              let lineup = try? JSONDecoder().decode([SecondOpinion.Reviewer].self, from: data) else { return [] }
        return lineup
    }

    public static func setSecondOpinionLineup(_ lineup: [SecondOpinion.Reviewer], in store: UserDefaults = Preferences.defaults) {
        store.set(try? JSONEncoder().encode(lineup), forKey: "secondOpinionLineup")
    }

    public static func sessionDefaults(for agent: AgentKind, in store: UserDefaults = Preferences.defaults) -> SessionSettings {
        switch agent {
        case .claudeCode:
            SessionSettings(model: text("claudeDefaultModel", in: store) ?? text("defaultModel", in: store),
                            effort: text("claudeDefaultEffort", in: store) ?? text("defaultEffort", in: store),
                            permissionMode: PermissionMode(stored: store.string(forKey: "claudePermissionMode")
                                ?? store.string(forKey: "permissionMode")))
        case .codex:
            SessionSettings(model: text("codexDefaultModel", in: store) ?? text("defaultModel", in: store),
                            effort: text("codexDefaultEffort", in: store) ?? text("defaultEffort", in: store),
                            codexSandboxMode: .resolved(store.string(forKey: "codexSandboxMode")))
        case .copilot:
            SessionSettings(model: text("copilotDefaultModel", in: store),
                            effort: text("copilotDefaultEffort", in: store),
                            copilotAccessMode: .resolved(store.string(forKey: "copilotAccessMode")))
        }
    }

    public static func setSessionDefaults(_ settings: SessionSettings, for agent: AgentKind,
                                          in store: UserDefaults = Preferences.defaults) {
        switch agent {
        case .claudeCode:
            set(settings.model, "claudeDefaultModel", in: store)
            set(settings.effort, "claudeDefaultEffort", in: store)
            store.set((settings.permissionMode ?? .fallback).rawValue,
                      forKey: "claudePermissionMode")
        case .codex:
            set(settings.model, "codexDefaultModel", in: store)
            set(settings.effort, "codexDefaultEffort", in: store)
            store.set((settings.codexSandboxMode ?? .workspaceWrite).rawValue,
                      forKey: "codexSandboxMode")
        case .copilot:
            set(settings.model, "copilotDefaultModel", in: store)
            set(settings.effort, "copilotDefaultEffort", in: store)
            store.set((settings.copilotAccessMode ?? .workspace).rawValue,
                      forKey: "copilotAccessMode")
        }
    }

    public static func autoPruneOrphanedWorktrees(in store: UserDefaults = Preferences.defaults) -> Bool {
        store.bool(forKey: "autoPruneOrphanedWorktrees")
    }

    public static func setAutoPruneOrphanedWorktrees(
        _ enabled: Bool,
        in store: UserDefaults = Preferences.defaults
    ) {
        store.set(enabled, forKey: "autoPruneOrphanedWorktrees")
    }

    // Which terminal opens a shell in a window of its own. Held as a bundle ID so the
    // choice survives the app being moved or renamed. Unset follows the system.
    public static var terminalBundleID: String? {
        get { terminalBundleID(in: store) }
        set { setTerminalBundleID(newValue, in: store) }
    }

    public static func terminalBundleID(in store: UserDefaults = Preferences.defaults) -> String? {
        text("terminalBundleID", in: store)
    }

    public static func setTerminalBundleID(_ id: String?, in store: UserDefaults = Preferences.defaults) {
        set(id, "terminalBundleID", in: store)
    }

    // The app the header's "Open in" button sends a session's folder to. With none
    // saved, it is Finder.
    public static var openInBundleID: String? {
        get { text("openInBundleID", in: store) }
        set { set(newValue, "openInBundleID", in: store) }
    }

    // A saved external site file sits ahead of the conventional and bundled locations.
    // Imported first-run configuration uses the conventional Application Support file.
    public static func siteDefaultsURL(in store: UserDefaults = Preferences.defaults) -> URL? {
        store.string(forKey: "siteDefaultsPath").map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
    }

    public static func setSiteDefaultsURL(_ url: URL?, in store: UserDefaults = Preferences.defaults) {
        guard let url else {
            store.removeObject(forKey: "siteDefaultsPath")
            return
        }
        store.set(url.standardizedFileURL.path, forKey: "siteDefaultsPath")
    }

    public static func designAmbition(in store: UserDefaults = Preferences.defaults) -> DesignAmbition {
        DesignAmbition.valid(store.string(forKey: "designAmbition")) ?? .fallback
    }

    public static func setDesignAmbition(_ ambition: DesignAmbition, in store: UserDefaults = Preferences.defaults) {
        store.set(ambition.rawValue, forKey: "designAmbition")
    }

    // The old catch-up preference maps directly to automatic recaps, so an existing opt-out
    // remains respected after the feature changes shape.
    public static func sessionRecapsEnabled(in store: UserDefaults = Preferences.defaults) -> Bool {
        if store.object(forKey: "sessionRecapsEnabled") != nil {
            return store.bool(forKey: "sessionRecapsEnabled")
        }
        if store.object(forKey: "sessionResumeBriefsEnabled") != nil {
            return store.bool(forKey: "sessionResumeBriefsEnabled")
        }
        return false
    }

    public static func setSessionRecapsEnabled(
        _ enabled: Bool, in store: UserDefaults = Preferences.defaults
    ) {
        store.set(enabled, forKey: "sessionRecapsEnabled")
    }

    // Off unless asked for: a suggestion is work the agent does on top of the turn, and
    // on the CLIs that cannot predict one themselves it is a whole extra run.
    public static func promptSuggestionsEnabled(in store: UserDefaults = Preferences.defaults) -> Bool {
        store.bool(forKey: "promptSuggestionsEnabled")
    }

    public static func setPromptSuggestionsEnabled(
        _ enabled: Bool, in store: UserDefaults = Preferences.defaults
    ) {
        store.set(enabled, forKey: "promptSuggestionsEnabled")
    }

    public static func sessionTitlesEnabled(in store: UserDefaults = Preferences.defaults) -> Bool {
        store.bool(forKey: "sessionTitlesEnabled")
    }

    public static func setSessionTitlesEnabled(
        _ enabled: Bool, in store: UserDefaults = Preferences.defaults
    ) {
        store.set(enabled, forKey: "sessionTitlesEnabled")
    }

    // Mobile access exposes live session control to another device, so it stays off until
    // someone deliberately opts into the experimental surface.
    public static func mobileAccessEnabled(in store: UserDefaults = Preferences.defaults) -> Bool {
        store.bool(forKey: "mobileAccessEnabled")
    }

    public static func setMobileAccessEnabled(_ enabled: Bool, in store: UserDefaults = Preferences.defaults) {
        store.set(enabled, forKey: "mobileAccessEnabled")
    }

    // Whether what a session has spent is shown. Kept per agent, like the session
    // defaults are, because what a CLI reports about cost is its own business. On unless
    // it is turned off: the figure is still recorded either way, so this only decides
    // whether it is on screen.
    public static func showCost(for agent: AgentKind, in store: UserDefaults = Preferences.defaults) -> Bool {
        let key = showCostKey(agent)
        guard store.object(forKey: key) != nil else { return true }
        return store.bool(forKey: key)
    }

    public static func setShowCost(
        _ shown: Bool,
        for agent: AgentKind,
        in store: UserDefaults = Preferences.defaults
    ) {
        store.set(shown, forKey: showCostKey(agent))
    }

    private static func showCostKey(_ agent: AgentKind) -> String {
        "showCost-\(agent.rawValue)"
    }

    package static func text(_ key: String) -> String? {
        text(key, in: store)
    }

    package static func text(_ key: String, in store: UserDefaults) -> String? {
        store.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    package static func uuid(_ key: String) -> UUID? {
        store.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    package static func set(_ text: String?, _ key: String) {
        set(text, key, in: store)
    }

    package static func set(_ text: String?, _ key: String, in store: UserDefaults) {
        if let text, !text.isEmpty {
            store.set(text, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    package static func set(_ id: UUID?, _ key: String) {
        set(id?.uuidString, key)
    }
}
