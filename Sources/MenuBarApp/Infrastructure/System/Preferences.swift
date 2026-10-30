import Foundation

// The handful of things that are preferences rather than data: what was open last time.
// macOS has a place for these, so they do not belong in the file holding the projects.
// A preference takes the store as a parameter where a settings object or a test reads
// its own UserDefaults; convenience properties keep app-wide callers on the standard one.
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

    // A missing entry means the session has never made a choice, so the app-level default
    // decides whether a live turn opens the working set. A session-specific choice wins
    // on later turns and launches.
    static func workingSetVisibility(in store: UserDefaults = .standard) -> [UUID: Bool] {
        let saved = store.dictionary(forKey: "workingSetVisibility") ?? [:]
        return saved.reduce(into: [:]) { visibility, entry in
            guard let id = UUID(uuidString: entry.key), let isVisible = entry.value as? Bool else {
                return
            }
            visibility[id] = isVisible
        }
    }

    static func setWorkingSetVisible(_ visible: Bool, for sessionID: UUID,
                                     in store: UserDefaults = .standard) {
        var visibility = workingSetVisibility(in: store)
        visibility[sessionID] = visible
        store.set(Dictionary(uniqueKeysWithValues: visibility.map {
            ($0.key.uuidString, $0.value)
        }), forKey: "workingSetVisibility")
    }

    static func opensWorkingSetByDefault(in store: UserDefaults = .standard) -> Bool {
        store.bool(forKey: "opensWorkingSetByDefault")
    }

    static func setOpensWorkingSetByDefault(_ opens: Bool,
                                            in store: UserDefaults = .standard) {
        store.set(opens, forKey: "opensWorkingSetByDefault")
    }

    // The hidden buttons are saved rather than the shown ones, so a button added in a
    // later release appears until the person turns it off.
    static func hiddenHeaderButtons(in store: UserDefaults = .standard) -> Set<HeaderButton> {
        Set((store.stringArray(forKey: "hiddenHeaderButtons") ?? [])
            .compactMap(HeaderButton.init(rawValue:)))
    }

    static func setHiddenHeaderButtons(_ hidden: Set<HeaderButton>,
                                       in store: UserDefaults = .standard) {
        store.set(hidden.map(\.rawValue).sorted(), forKey: "hiddenHeaderButtons")
    }

    // Which agent runs the sessions. Everything else about an agent lives in its own
    // config; this is only the app's choice between them.
    static var agent: AgentKind {
        get { agent(in: store) }
        set { setAgent(newValue, in: store) }
    }

    static func agent(in store: UserDefaults) -> AgentKind {
        store.string(forKey: "agent").flatMap(AgentKind.init(rawValue:)) ?? .claudeCode
    }

    static func setAgent(_ agent: AgentKind, in store: UserDefaults) {
        store.set(agent.rawValue, forKey: "agent")
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
    // The second opinion lineup the person saved as their usual. Empty until they save one.
    static func secondOpinionLineup(in store: UserDefaults = .standard) -> [SecondOpinion.Reviewer] {
        guard let data = store.data(forKey: "secondOpinionLineup"),
              let lineup = try? JSONDecoder().decode([SecondOpinion.Reviewer].self, from: data) else { return [] }
        return lineup
    }

    static func setSecondOpinionLineup(_ lineup: [SecondOpinion.Reviewer], in store: UserDefaults = .standard) {
        store.set(try? JSONEncoder().encode(lineup), forKey: "secondOpinionLineup")
    }

    static func sessionDefaults(for agent: AgentKind, in store: UserDefaults = .standard) -> SessionSettings {
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

    static func setSessionDefaults(_ settings: SessionSettings, for agent: AgentKind,
                                   in store: UserDefaults = .standard) {
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

    // How much memory a single turn may hold before the app stops it to keep the Mac
    // usable. Stored as whole gigabytes, with zero meaning the automatic share.
    static func sessionMemoryLimit(in store: UserDefaults = .standard) -> SessionMemoryLimit {
        guard store.object(forKey: "sessionMemoryLimit") != nil else {
            return SessionMemoryLimit.fallback
        }
        return SessionMemoryLimit.resolved(store.integer(forKey: "sessionMemoryLimit"))
    }

    static func setSessionMemoryLimit(_ limit: SessionMemoryLimit,
                                      in store: UserDefaults = .standard) {
        store.set(limit.rawValue, forKey: "sessionMemoryLimit")
    }

    static func autoPruneOrphanedWorktrees(in store: UserDefaults = .standard) -> Bool {
        store.bool(forKey: "autoPruneOrphanedWorktrees")
    }

    static func setAutoPruneOrphanedWorktrees(
        _ enabled: Bool,
        in store: UserDefaults = .standard
    ) {
        store.set(enabled, forKey: "autoPruneOrphanedWorktrees")
    }

    static func skillsRefreshInterval(in store: UserDefaults = .standard)
        -> SkillsRefreshInterval {
        guard store.object(forKey: "skillsRefreshInterval") != nil else { return .fiveDays }
        return SkillsRefreshInterval(rawValue: store.integer(forKey: "skillsRefreshInterval"))
            ?? .fiveDays
    }

    static func setSkillsRefreshInterval(
        _ interval: SkillsRefreshInterval,
        in store: UserDefaults = .standard
    ) {
        store.set(interval.rawValue, forKey: "skillsRefreshInterval")
    }

    static func skillsLastRefresh(in store: UserDefaults = .standard) -> Date? {
        store.object(forKey: "skillsLastRefresh") as? Date
    }

    static func setSkillsLastRefresh(_ date: Date?, in store: UserDefaults = .standard) {
        store.set(date, forKey: "skillsLastRefresh")
    }

    static func appUpdateLastCheck(in store: UserDefaults = .standard) -> Date? {
        store.object(forKey: "appUpdateLastCheck") as? Date
    }

    static func setAppUpdateLastCheck(_ date: Date?, in store: UserDefaults = .standard) {
        store.set(date, forKey: "appUpdateLastCheck")
    }

    static func cachedAppUpdateRelease(
        in store: UserDefaults = .standard
    ) -> AppUpdateRelease? {
        guard let data = store.data(forKey: "cachedAppUpdateRelease") else { return nil }
        return try? JSONDecoder().decode(AppUpdateRelease.self, from: data)
    }

    static func setCachedAppUpdateRelease(
        _ release: AppUpdateRelease?,
        in store: UserDefaults = .standard
    ) {
        guard let release, let data = try? JSONEncoder().encode(release) else {
            store.removeObject(forKey: "cachedAppUpdateRelease")
            return
        }
        store.set(data, forKey: "cachedAppUpdateRelease")
    }

    static func dismissedAppUpdateVersion(in store: UserDefaults = .standard) -> String? {
        store.string(forKey: "dismissedAppUpdateVersion")
    }

    static func setDismissedAppUpdateVersion(
        _ version: String?,
        in store: UserDefaults = .standard
    ) {
        store.set(version, forKey: "dismissedAppUpdateVersion")
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

    static func skillsMarketplaces(in store: UserDefaults = .standard)
        -> [SkillMarketplaceConfiguration] {
        if let data = store.data(forKey: "skillsMarketplaces"),
           let saved = try? JSONDecoder().decode([SkillMarketplaceConfiguration].self, from: data) {
            return saved
        }
        return skillsMarketplace(in: store).map { [$0] } ?? []
    }

    static func setSkillsMarketplaces(_ marketplaces: [SkillMarketplaceConfiguration],
                                      in store: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(marketplaces) else { return }
        store.set(data, forKey: "skillsMarketplaces")
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
    static func projectSort(in store: UserDefaults = .standard) -> ProjectSort {
        store.string(forKey: "projectSort").flatMap(ProjectSort.init(rawValue:)) ?? .name
    }

    static func setProjectSort(_ sort: ProjectSort, in store: UserDefaults = .standard) {
        store.set(sort.rawValue, forKey: "projectSort")
    }

    // Whether the sidebar splits into sections by kind. An unset key reads as the flat
    // list the rail has always shown.
    static func projectGrouping(in store: UserDefaults = .standard) -> ProjectGrouping {
        store.string(forKey: "projectGrouping")
            .flatMap(ProjectGrouping.init(rawValue:)) ?? .flat
    }

    static func setProjectGrouping(
        _ grouping: ProjectGrouping,
        in store: UserDefaults = .standard
    ) {
        store.set(grouping.rawValue, forKey: "projectGrouping")
    }

    // Which terminal opens a shell in a window of its own. Held as a bundle ID so the
    // choice survives the app being moved or renamed. Unset follows the system.
    static var terminalBundleID: String? {
        get { terminalBundleID(in: store) }
        set { setTerminalBundleID(newValue, in: store) }
    }

    static func terminalBundleID(in store: UserDefaults = .standard) -> String? {
        text("terminalBundleID", in: store)
    }

    static func setTerminalBundleID(_ id: String?, in store: UserDefaults = .standard) {
        set(id, "terminalBundleID", in: store)
    }

    // The app the header's "Open in" button sends a session's folder to. With none
    // saved, it is Finder.
    static var openInBundleID: String? {
        get { text("openInBundleID", in: store) }
        set { set(newValue, "openInBundleID", in: store) }
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

    static func appearance(in store: UserDefaults = .standard) -> Appearance {
        store.string(forKey: "appearance").flatMap(Appearance.init(rawValue:)) ?? .system
    }

    static func setAppearance(_ appearance: Appearance, in store: UserDefaults = .standard) {
        store.set(appearance.rawValue, forKey: "appearance")
    }

    static func sunlightEnabled(in store: UserDefaults = .standard) -> Bool {
        store.bool(forKey: "sunlightEnabled")
    }

    static func setSunlightEnabled(_ enabled: Bool, in store: UserDefaults = .standard) {
        store.set(enabled, forKey: "sunlightEnabled")
    }

    static func sunlightMode(in store: UserDefaults = .standard) -> SunlightMode {
        store.string(forKey: "sunlightMode").flatMap(SunlightMode.init(rawValue:)) ?? .followsSun
    }

    static func setSunlightMode(_ mode: SunlightMode, in store: UserDefaults = .standard) {
        store.set(mode.rawValue, forKey: "sunlightMode")
    }

    // Kept inside the slider's range, so a value written by hand cannot ask for a colour
    // the window has no way to show.
    static func sunlightNightKelvin(in store: UserDefaults = .standard) -> Double {
        guard store.object(forKey: "sunlightNightKelvin") != nil else { return Sunlight.nightKelvin }
        let kelvin = store.double(forKey: "sunlightNightKelvin")
        return min(Sunlight.nightRange.upperBound, max(Sunlight.nightRange.lowerBound, kelvin))
    }

    static func setSunlightNightKelvin(_ kelvin: Double, in store: UserDefaults = .standard) {
        store.set(kelvin, forKey: "sunlightNightKelvin")
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
    static func textSize(in store: UserDefaults = .standard) -> TextSize {
        store.string(forKey: "textSize").flatMap(TextSize.init(rawValue:)) ?? .standard
    }

    static func setTextSize(_ textSize: TextSize, in store: UserDefaults = .standard) {
        store.set(textSize.rawValue, forKey: "textSize")
    }

    static func messageColour(in store: UserDefaults = .standard) -> MessageColour {
        store.string(forKey: "messageColour").flatMap(MessageColour.init(rawValue:))
            ?? .projectIcon
    }

    static func setMessageColour(_ colour: MessageColour, in store: UserDefaults = .standard) {
        store.set(colour.rawValue, forKey: "messageColour")
    }

    static func designAmbition(in store: UserDefaults = .standard) -> DesignAmbition {
        DesignAmbition.valid(store.string(forKey: "designAmbition")) ?? .fallback
    }

    static func setDesignAmbition(_ ambition: DesignAmbition, in store: UserDefaults = .standard) {
        store.set(ambition.rawValue, forKey: "designAmbition")
    }

    // The old catch-up preference maps directly to automatic recaps, so an existing opt-out
    // remains respected after the feature changes shape.
    static func sessionRecapsEnabled(in store: UserDefaults = .standard) -> Bool {
        if store.object(forKey: "sessionRecapsEnabled") != nil {
            return store.bool(forKey: "sessionRecapsEnabled")
        }
        if store.object(forKey: "sessionResumeBriefsEnabled") != nil {
            return store.bool(forKey: "sessionResumeBriefsEnabled")
        }
        return false
    }

    static func setSessionRecapsEnabled(
        _ enabled: Bool, in store: UserDefaults = .standard
    ) {
        store.set(enabled, forKey: "sessionRecapsEnabled")
    }

    // Off unless asked for: a suggestion is work the agent does on top of the turn, and
    // on the CLIs that cannot predict one themselves it is a whole extra run.
    static func promptSuggestionsEnabled(in store: UserDefaults = .standard) -> Bool {
        store.bool(forKey: "promptSuggestionsEnabled")
    }

    static func setPromptSuggestionsEnabled(
        _ enabled: Bool, in store: UserDefaults = .standard
    ) {
        store.set(enabled, forKey: "promptSuggestionsEnabled")
    }

    // Steering is the default: an agent that can take a prompt mid-turn uses it at its
    // next step, which is what someone typing while it works usually wants.
    static func midTurnPromptDelivery(
        in store: UserDefaults = .standard
    ) -> SessionRunner.PromptDelivery {
        store.string(forKey: "midTurnPromptDelivery")
            .flatMap(SessionRunner.PromptDelivery.init(rawValue:)) ?? .now
    }

    static func setMidTurnPromptDelivery(
        _ delivery: SessionRunner.PromptDelivery, in store: UserDefaults = .standard
    ) {
        store.set(delivery.rawValue, forKey: "midTurnPromptDelivery")
    }

    static func sessionTitlesEnabled(in store: UserDefaults = .standard) -> Bool {
        store.bool(forKey: "sessionTitlesEnabled")
    }

    static func setSessionTitlesEnabled(
        _ enabled: Bool, in store: UserDefaults = .standard
    ) {
        store.set(enabled, forKey: "sessionTitlesEnabled")
    }

    // What a finished session plays. An unset key reads as the standard sound: a turn
    // ending while the person is elsewhere is the moment they most want to hear about,
    // so it is on until they say otherwise.
    static func sessionFinishedSound(in store: UserDefaults = .standard) -> SessionSound {
        guard let raw = store.string(forKey: "sessionFinishedSound") else {
            return .standard
        }
        return SessionSound(rawValue: raw) ?? .standard
    }

    static func setSessionFinishedSound(_ sound: SessionSound,
                                        in store: UserDefaults = .standard) {
        store.set(sound.rawValue, forKey: "sessionFinishedSound")
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
    static func showCost(for agent: AgentKind, in store: UserDefaults = .standard) -> Bool {
        let key = showCostKey(agent)
        guard store.object(forKey: key) != nil else { return true }
        return store.bool(forKey: key)
    }

    static func setShowCost(
        _ shown: Bool,
        for agent: AgentKind,
        in store: UserDefaults = .standard
    ) {
        store.set(shown, forKey: showCostKey(agent))
    }

    private static func showCostKey(_ agent: AgentKind) -> String {
        "showCost-\(agent.rawValue)"
    }

    private static func text(_ key: String) -> String? {
        text(key, in: store)
    }

    private static func text(_ key: String, in store: UserDefaults) -> String? {
        store.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func uuid(_ key: String) -> UUID? {
        store.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    private static func set(_ text: String?, _ key: String) {
        set(text, key, in: store)
    }

    private static func set(_ text: String?, _ key: String, in store: UserDefaults) {
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
