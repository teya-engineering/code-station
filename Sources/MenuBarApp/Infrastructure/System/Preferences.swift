import Foundation

// One simple preference: the key it is saved under and the value a missing or unreadable
// entry reads as. Declaring it once keeps the key and the fallback from being repeated
// by every reader and writer.
struct Preference<Value: Sendable>: Sendable {
    let key: String
    let fallback: Value
    // Only a whole number carries a range. A value outside it moves to the nearer end,
    // so a number written by hand cannot ask for more than the app can show.
    let range: ClosedRange<Int>?

    init(_ key: String, fallback: Value) {
        self.key = key
        self.fallback = fallback
        range = nil
    }
}

extension Preference where Value: RawRepresentable, Value.RawValue == String {
    func read(in store: UserDefaults = .standard) -> Value {
        store.string(forKey: key).flatMap(Value.init(rawValue:)) ?? fallback
    }

    func write(_ value: Value, in store: UserDefaults = .standard) {
        store.set(value.rawValue, forKey: key)
    }
}

extension Preference where Value: RawRepresentable, Value.RawValue == Int {
    // The store reads a missing number as zero, which can be a real choice, so the
    // entry is looked for first.
    func read(in store: UserDefaults = .standard) -> Value {
        guard store.object(forKey: key) != nil else { return fallback }
        return Value(rawValue: store.integer(forKey: key)) ?? fallback
    }

    func write(_ value: Value, in store: UserDefaults = .standard) {
        store.set(value.rawValue, forKey: key)
    }
}

extension Preference where Value == Bool {
    func read(in store: UserDefaults = .standard) -> Bool {
        guard store.object(forKey: key) != nil else { return fallback }
        return store.bool(forKey: key)
    }

    func write(_ value: Bool, in store: UserDefaults = .standard) {
        store.set(value, forKey: key)
    }
}

extension Preference where Value == Int {
    init(_ key: String, fallback: Int, range: ClosedRange<Int>) {
        self.key = key
        self.fallback = fallback
        self.range = range
    }

    func read(in store: UserDefaults = .standard) -> Int {
        guard store.object(forKey: key) != nil else { return fallback }
        return clamped(store.integer(forKey: key))
    }

    func write(_ value: Int, in store: UserDefaults = .standard) {
        store.set(clamped(value), forKey: key)
    }

    private func clamped(_ value: Int) -> Int {
        guard let range else { return value }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

extension Preference where Value == String? {
    func read(in store: UserDefaults = .standard) -> String? {
        store.string(forKey: key) ?? fallback
    }

    func write(_ value: String?, in store: UserDefaults = .standard) {
        store.set(value, forKey: key)
    }
}

// The things that are preferences rather than data: choices made in Settings and small
// facts the app remembers between launches. macOS has a place for these, so they do not
// belong in the file holding the projects.
// A simple preference is declared once as a value and read and written through it. One
// with rules of its own, such as an older key it still honours, is a pair of functions.
// Both take the store, so a settings object or a test can use its own UserDefaults.
enum Preferences {
    static let hasCompletedOnboarding = Preference("hasCompletedOnboarding", fallback: false)

    // Where the last repository was cloned, since the next one usually goes beside it.
    static let cloneFolder = Preference<String?>("cloneFolder", fallback: nil)

    // The hidden folders of clones that have not ended, so the next launch can remove any
    // that a quit or a crash left behind.
    static func partialClones(in store: UserDefaults = .standard) -> [String] {
        store.stringArray(forKey: "partialClones") ?? []
    }

    static func setPartialClones(_ paths: [String], in store: UserDefaults = .standard) {
        store.set(paths, forKey: "partialClones")
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

    static let sidebarSessionLimit = Preference(
        "sidebarSessionLimit", fallback: SidebarSessionVisibility.defaultLimit,
        range: SidebarSessionVisibility.limitRange)

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
    static let agent = Preference("agent", fallback: AgentKind.claudeCode)

    // The bot choice preselected for new sessions. The built-in Default bot has a stable
    // name so sessions do not depend on a custom image file.
    static let defaultAgentAvatarName = Preference<String?>("defaultAgentAvatarName", fallback: nil)

    // What a second opinion starts from. A lineup saved before the Settings tab existed
    // becomes its usual seats, all ticked.
    static func secondOpinionDefaults(in store: UserDefaults = .standard) -> SecondOpinionDefaults {
        if let data = store.data(forKey: "secondOpinionDefaults"),
           let defaults = try? JSONDecoder().decode(SecondOpinionDefaults.self, from: data) {
            return defaults
        }
        var defaults = SecondOpinionDefaults()
        if let data = store.data(forKey: "secondOpinionLineup"),
           let lineup = try? JSONDecoder().decode([SecondOpinion.Reviewer].self, from: data) {
            defaults.seats = lineup.map { SecondOpinionDefaults.Seat(reviewer: $0) }
        }
        return defaults
    }

    static func setSecondOpinionDefaults(_ defaults: SecondOpinionDefaults, in store: UserDefaults = .standard) {
        store.set(try? JSONEncoder().encode(defaults), forKey: "secondOpinionDefaults")
    }

    // The usual reviewers an ask opens with. Empty until the person saves some.
    static func secondOpinionLineup(in store: UserDefaults = .standard) -> [SecondOpinion.Reviewer] {
        secondOpinionDefaults(in: store).lineup
    }

    static func setSecondOpinionLineup(_ lineup: [SecondOpinion.Reviewer], in store: UserDefaults = .standard) {
        var defaults = secondOpinionDefaults(in: store)
        defaults.makeUsual(lineup)
        setSecondOpinionDefaults(defaults, in: store)
    }

    // What a session runs with when it has not picked for itself. Defaults belong to the
    // agent that reads them, so one CLI's model and access choices cannot affect another.
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
        case .kiro:
            SessionSettings(model: text("kiroDefaultModel", in: store),
                            permissionMode: PermissionMode(stored: store.string(forKey: "kiroPermissionMode")))
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
        case .kiro:
            set(settings.model, "kiroDefaultModel", in: store)
            store.set((settings.permissionMode ?? .fallback).rawValue,
                      forKey: "kiroPermissionMode")
        }
    }

    // How long a session has to sit untouched before the app offers to clear it.
    static let oldSessionDays = Preference(
        "oldSessionDays", fallback: OldSessions.defaultDays, range: OldSessions.dayRange)

    // Whether old sessions go on their own after the warning hour. An older install kept
    // a four-way policy, or before that a single Boolean. Only "review" meant no, so
    // every other answer carries over as yes: what may be taken is now decided by the
    // ask list, which starts out asking about everything.
    static func oldSessionsDeleteOnTheirOwn(in store: UserDefaults = .standard) -> Bool {
        if store.object(forKey: "oldSessionsDeleteOnTheirOwn") != nil {
            return store.bool(forKey: "oldSessionsDeleteOnTheirOwn")
        }
        if let policy = store.string(forKey: "oldSessionCleanupPolicy") {
            return policy != "review"
        }
        guard store.object(forKey: "autoDeleteOldSessions") != nil else { return true }
        return store.bool(forKey: "autoDeleteOldSessions")
    }

    static func setOldSessionsDeleteOnTheirOwn(_ enabled: Bool,
                                               in store: UserDefaults = .standard) {
        store.set(enabled, forKey: "oldSessionsDeleteOnTheirOwn")
        store.removeObject(forKey: "oldSessionCleanupPolicy")
        store.removeObject(forKey: "autoDeleteOldSessions")
    }

    // The reasons on the "ask me first" list. An older install stored only the reasons
    // that could be turned off, and always asked about uncommitted changes and unbuilt
    // designs. Those two carry over as ticked, so no work starts going on its own
    // without the person choosing it.
    static func oldSessionAskReasons(in store: UserDefaults = .standard) -> Set<CleanupReason> {
        if let raw = store.stringArray(forKey: "oldSessionAskList") {
            return Set(raw.compactMap(CleanupReason.init(rawValue:)))
        }
        guard let legacy = store.stringArray(forKey: "oldSessionAskReasons") else {
            return CleanupRule.askedByDefault
        }
        return Set(legacy.compactMap(CleanupReason.init(rawValue:)))
            .union([.uncommittedChanges, .unbuiltDesign])
    }

    static func setOldSessionAskReasons(_ reasons: Set<CleanupReason>,
                                        in store: UserDefaults = .standard) {
        store.set(reasons.map(\.rawValue).sorted(), forKey: "oldSessionAskList")
        store.removeObject(forKey: "oldSessionAskReasons")
    }

    // The stored ages also mark the migration. A disabled master switch must become
    // six review-only choices once, without overriding later independent edits.
    static func migrateOldSessionRules(in store: UserDefaults) {
        guard store.dictionary(forKey: "oldSessionConditionDays") == nil else { return }
        if !oldSessionsDeleteOnTheirOwn(in: store) {
            setOldSessionAskReasons(Set(CleanupReason.allCases), in: store)
        }
        let days = oldSessionDays.read(in: store)
        setOldSessionConditionDays(Dictionary(uniqueKeysWithValues:
            CleanupReason.allCases.map { ($0, days) }), in: store)
    }

    static func oldSessionConditionDays(in store: UserDefaults) -> [CleanupReason: Int] {
        let values = store.dictionary(forKey: "oldSessionConditionDays") ?? [:]
        return Dictionary(uniqueKeysWithValues: CleanupReason.allCases.map { reason in
            (reason, OldSessions.resolvedDays(values[reason.rawValue] as? Int ?? OldSessions.defaultDays))
        })
    }

    static func setOldSessionConditionDays(_ values: [CleanupReason: Int], in store: UserDefaults) {
        store.set(Dictionary(uniqueKeysWithValues: values.map {
            ($0.key.rawValue, OldSessions.resolvedDays($0.value))
        }), forKey: "oldSessionConditionDays")
    }

    // Orphaned worktrees the person asked to hear about later, by path.
    static func orphanCleanupDeferrals(in store: UserDefaults = .standard) -> [String: Date] {
        store.dictionary(forKey: "orphanCleanupDeferrals") as? [String: Date] ?? [:]
    }

    static func setOrphanCleanupDeferrals(_ deferrals: [String: Date],
                                          in store: UserDefaults = .standard) {
        store.set(deferrals, forKey: "orphanCleanupDeferrals")
    }

    // How much memory a single turn may hold before the app stops it to keep the Mac
    // usable. Stored as whole gigabytes, with zero meaning the automatic share.
    static let sessionMemoryLimit = Preference("sessionMemoryLimit", fallback: SessionMemoryLimit.fallback)

    // Stats are off until the person turns them on, so nothing about how they work is
    // counted without their asking.
    static let statsEnabled = Preference("statsEnabled", fallback: false)

    // How many days a removed session's stats stay behind, counted from its last turn.
    // Zero means they go with the session.
    static let statsRemovedSessionDays = Preference(
        "statsRemovedSessionDays", fallback: StatsStore.defaultKeptDays,
        range: StatsStore.keptDayRange)

    // Whether orphaned worktrees are cleaned up by the same rule as old sessions. The key
    // keeps the name it was first saved under, so a choice made under it still counts.
    static let sweepsOrphanedWorktrees = Preference("autoPruneOrphanedWorktrees", fallback: false)

    static let skillsRefreshInterval = Preference(
        "skillsRefreshInterval", fallback: SkillsRefreshInterval.fiveDays)

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

    static let dismissedAppUpdateVersion = Preference<String?>(
        "dismissedAppUpdateVersion", fallback: nil)

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
    static let projectSort = Preference("projectSort", fallback: ProjectSort.name)

    // Whether the sidebar splits into sections by kind. An unset key reads as the flat
    // list the rail has always shown.
    static let projectGrouping = Preference("projectGrouping", fallback: ProjectGrouping.flat)

    // Which terminal opens a shell in a window of its own. Held as a bundle ID so the
    // choice survives the app being moved or renamed. Unset follows the system.
    static func terminalBundleID(in store: UserDefaults = .standard) -> String? {
        text("terminalBundleID", in: store)
    }

    static func setTerminalBundleID(_ id: String?, in store: UserDefaults = .standard) {
        set(id, "terminalBundleID", in: store)
    }

    // The app the header's "Open in" button sends a session's folder to. With none
    // saved, it is Finder.
    static func openInBundleID(in store: UserDefaults = .standard) -> String? {
        text("openInBundleID", in: store)
    }

    static func setOpenInBundleID(_ id: String?, in store: UserDefaults = .standard) {
        set(id, "openInBundleID", in: store)
    }

    static func openInAddedBundleIDs(in store: UserDefaults = .standard) -> [String] {
        store.stringArray(forKey: "openInAddedBundleIDs") ?? []
    }

    static func setOpenInAddedBundleIDs(_ ids: [String], in store: UserDefaults = .standard) {
        store.set(ids, forKey: "openInAddedBundleIDs")
    }

    static func openInAddedAppPaths(in store: UserDefaults = .standard) -> [String: String] {
        store.dictionary(forKey: "openInAddedAppPaths") as? [String: String] ?? [:]
    }

    static func setOpenInAddedAppPaths(_ paths: [String: String], in store: UserDefaults = .standard) {
        store.set(paths, forKey: "openInAddedAppPaths")
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

    static let appearance = Preference("appearance", fallback: Appearance.system)

    static let sunlightEnabled = Preference("sunlightEnabled", fallback: false)

    static let sunlightMode = Preference("sunlightMode", fallback: SunlightMode.followsSun)

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

    static let sidebarIconSet = Preference("sidebarIconSet", fallback: SidebarIconSet.diceBear)

    static let diceBearAvatarStyle = Preference(
        "diceBearAvatarStyle", fallback: DiceBearAvatarStyle.waves)

    // How large a session's own text is drawn. A reading size belongs to the person at the
    // machine rather than to any one session, so there is a single answer for the app.
    static let textSize = Preference("textSize", fallback: TextSize.standard)

    static let messageColour = Preference("messageColour", fallback: MessageColour.projectIcon)

    // How a transcript writes the time of each entry.
    static let timestampFormat = Preference("timestampFormat", fallback: TimestampFormat.off)

    // Which entries carry a time.
    static let timestampScope = Preference(
        "timestampScope", fallback: TimestampScope.messagesAndSteps)

    static let designAmbition = Preference("designAmbition", fallback: DesignAmbition.fallback)

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
    static let promptSuggestionsEnabled = Preference("promptSuggestionsEnabled", fallback: false)

    // Steering is the default: an agent that can take a prompt mid-turn uses it at its
    // next step, which is what someone typing while it works usually wants.
    static let midTurnPromptDelivery = Preference(
        "midTurnPromptDelivery", fallback: SessionRunner.PromptDelivery.now)

    static let sessionTitlesEnabled = Preference("sessionTitlesEnabled", fallback: false)

    // What a finished session plays. An unset key reads as the standard sound: a turn
    // ending while the person is elsewhere is the moment they most want to hear about,
    // so it is on until they say otherwise.
    static let sessionFinishedSound = Preference(
        "sessionFinishedSound", fallback: SessionSound.standard)

    // Mobile access exposes live session control to another device, so it stays off until
    // someone deliberately turns it on.
    static let mobileAccessEnabled = Preference("mobileAccessEnabled", fallback: false)

    static let mobilePairingLifetime = Preference(
        "mobilePairingLifetime", fallback: MobilePairingLifetime.standard)

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

    private static func text(_ key: String, in store: UserDefaults) -> String? {
        store.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func set(_ text: String?, _ key: String, in store: UserDefaults) {
        if let text, !text.isEmpty {
            store.set(text, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }
}
