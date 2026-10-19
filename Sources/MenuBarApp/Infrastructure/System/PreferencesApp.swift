import CodeStationCore
import Foundation

// The preferences only the window app reads, or whose types still live in the app.
// The engine's own preferences are in the core's `Preferences`.
extension Preferences {
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

    static func appearance(in store: UserDefaults = .standard) -> Appearance {
        store.string(forKey: "appearance").flatMap(Appearance.init(rawValue:)) ?? .system
    }

    static func setAppearance(_ appearance: Appearance, in store: UserDefaults = .standard) {
        store.set(appearance.rawValue, forKey: "appearance")
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
}
