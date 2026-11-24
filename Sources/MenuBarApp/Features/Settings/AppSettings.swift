import AppKit
import SwiftUI
import Observation

// The settings that Reset Appearance puts back, held together so a reset can be undone
// as one value.
struct AppearanceSettings: Equatable {
    var appearance: Appearance
    var sunlightEnabled: Bool
    var sunlightMode: SunlightMode
    var sunlightNightKelvin: Double
    var cursorEffects: CursorEffectsSettings
    var textSize: TextSize
    var messageColour: MessageColour
    var timestampFormat: TimestampFormat
    var timestampScope: TimestampScope
    var diceBearAvatarStyle: DiceBearAvatarStyle
    var sidebarIconSet: SidebarIconSet

    // Built from the fallbacks an empty store reads as, so a reset and a first launch
    // cannot disagree.
    static let standard = AppearanceSettings(
        appearance: Preferences.appearance.fallback,
        sunlightEnabled: Preferences.sunlightEnabled.fallback,
        sunlightMode: Preferences.sunlightMode.fallback,
        sunlightNightKelvin: Sunlight.nightKelvin,
        cursorEffects: CursorEffectsSettings(),
        textSize: Preferences.textSize.fallback,
        messageColour: Preferences.messageColour.fallback,
        timestampFormat: Preferences.timestampFormat.fallback,
        timestampScope: Preferences.timestampScope.fallback,
        diceBearAvatarStyle: Preferences.diceBearAvatarStyle.fallback,
        sidebarIconSet: Preferences.sidebarIconSet.fallback)
}

// What the app itself does, as opposed to what a session runs with. It is observed
// rather than read from UserDefaults where it is needed, so the sidebar's offer to clear
// old sessions follows the threshold the moment it is changed.
@MainActor
@Observable
final class AppSettings {
    var changesDiffLayout = DiffLayout.unified
    private let agentAvatarURL: URL
    @ObservationIgnored private let preferences: UserDefaults

    var sidebarSessionLimit: Int {
        didSet {
            let resolved = SidebarSessionVisibility.resolvedLimit(sidebarSessionLimit)
            guard resolved == sidebarSessionLimit else {
                sidebarSessionLimit = resolved
                return
            }
            Preferences.sidebarSessionLimit.write(sidebarSessionLimit, in: preferences)
        }
    }

    var oldSessionDays: Int {
        didSet { Preferences.oldSessionDays.write(oldSessionDays, in: preferences) }
    }

    var oldSessionConditionDays: [CleanupReason: Int] {
        didSet { Preferences.setOldSessionConditionDays(oldSessionConditionDays, in: preferences) }
    }

    var oldSessionsDeleteOnTheirOwn: Bool {
        didSet {
            Preferences.setOldSessionsDeleteOnTheirOwn(oldSessionsDeleteOnTheirOwn,
                                                       in: preferences)
        }
    }

    var oldSessionAskReasons: Set<CleanupReason> {
        didSet { Preferences.setOldSessionAskReasons(oldSessionAskReasons, in: preferences) }
    }

    var sessionMemoryLimit: SessionMemoryLimit {
        didSet { Preferences.sessionMemoryLimit.write(sessionMemoryLimit, in: preferences) }
    }

    var sweepsOrphanedWorktrees: Bool {
        didSet {
            Preferences.sweepsOrphanedWorktrees.write(sweepsOrphanedWorktrees, in: preferences)
        }
    }

    var statsEnabled: Bool {
        didSet { Preferences.statsEnabled.write(statsEnabled, in: preferences) }
    }

    var statsRemovedSessionDays: Int {
        didSet {
            Preferences.statsRemovedSessionDays.write(statsRemovedSessionDays, in: preferences)
        }
    }

    var cleanupRule: CleanupRule {
        CleanupRule(deletesOnItsOwn: oldSessionsDeleteOnTheirOwn,
                    asked: oldSessionAskReasons,
                    includesOrphans: sweepsOrphanedWorktrees,
                    days: oldSessionDays, conditionDays: oldSessionConditionDays)
    }

    var skillsRefreshInterval: SkillsRefreshInterval {
        didSet {
            Preferences.skillsRefreshInterval.write(skillsRefreshInterval, in: preferences)
        }
    }

    var projectSort: ProjectSort {
        didSet { Preferences.projectSort.write(projectSort, in: preferences) }
    }

    var projectGrouping: ProjectGrouping {
        didSet { Preferences.projectGrouping.write(projectGrouping, in: preferences) }
    }

    // Which app a shell opens in when it opens in a window of its own. nil means no app
    // was picked, so the drawer inside this app is what the terminal button offers first.
    var terminalBundleID: String? {
        didSet { Preferences.setTerminalBundleID(terminalBundleID, in: preferences) }
    }

    var opensTerminalInDrawer: Bool { terminalBundleID == nil }

    // How far back the drawer's shells can be scrolled. Open tabs take a new size at once.
    var terminalScrollback: Int {
        didSet {
            let resolved = TerminalScrollback.resolved(terminalScrollback)
            guard resolved == terminalScrollback else {
                terminalScrollback = resolved
                return
            }
            Preferences.terminalScrollback.write(terminalScrollback, in: preferences)
        }
    }

    var appearance: Appearance {
        didSet {
            Preferences.appearance.write(appearance, in: preferences)
            appearance.apply()
        }
    }

    // Warms every window with the sun, on top of whichever appearance is chosen.
    var sunlightEnabled: Bool {
        didSet { Preferences.sunlightEnabled.write(sunlightEnabled, in: preferences) }
    }

    var sunlightMode: SunlightMode {
        didSet { Preferences.sunlightMode.write(sunlightMode, in: preferences) }
    }

    // The colour the window reaches once the sun is down, or keeps all day when the
    // warmth is fixed, in kelvin.
    var sunlightNightKelvin: Double {
        didSet { Preferences.setSunlightNightKelvin(sunlightNightKelvin, in: preferences) }
    }

    // Held while the warmth slider is being dragged, so the window shows the night colour
    // being chosen even in the middle of the day. Never saved.
    var sunlightPreviewing = false

    var sidebarIconSet: SidebarIconSet {
        didSet {
            Preferences.sidebarIconSet.write(sidebarIconSet, in: preferences)
        }
    }

    var cursorEffects: CursorEffectsSettings {
        didSet { Preferences.setCursorEffects(cursorEffects, in: preferences) }
    }

    private var hiddenHeaderButtons: Set<HeaderButton> {
        didSet { Preferences.setHiddenHeaderButtons(hiddenHeaderButtons, in: preferences) }
    }

    func shows(_ button: HeaderButton) -> Bool { !hiddenHeaderButtons.contains(button) }

    func setShows(_ shown: Bool, _ button: HeaderButton) {
        if shown {
            hiddenHeaderButtons.remove(button)
        } else {
            hiddenHeaderButtons.insert(button)
        }
    }

    var diceBearAvatarStyle: DiceBearAvatarStyle {
        didSet {
            Preferences.diceBearAvatarStyle.write(diceBearAvatarStyle, in: preferences)
        }
    }

    var textSize: TextSize {
        didSet { Preferences.textSize.write(textSize, in: preferences) }
    }

    var keyBindings: KeyBindings {
        didSet { Preferences.setKeyBindings(keyBindings, in: preferences) }
    }

    var messageColour: MessageColour {
        didSet { Preferences.messageColour.write(messageColour, in: preferences) }
    }

    var timestampFormat: TimestampFormat {
        didSet { Preferences.timestampFormat.write(timestampFormat, in: preferences) }
    }

    var timestampScope: TimestampScope {
        didSet { Preferences.timestampScope.write(timestampScope, in: preferences) }
    }

    var transcriptTimestamps: TranscriptTimestamps {
        TranscriptTimestamps(format: timestampFormat, scope: timestampScope,
                             today: CalendarDay.shared.today)
    }

    var mobileAccessEnabled: Bool {
        didSet { Preferences.mobileAccessEnabled.write(mobileAccessEnabled, in: preferences) }
    }

    var mobilePairingLifetime: MobilePairingLifetime {
        didSet { Preferences.mobilePairingLifetime.write(mobilePairingLifetime, in: preferences) }
    }

    var sessionRecapsEnabled: Bool {
        didSet {
            Preferences.setSessionRecapsEnabled(sessionRecapsEnabled, in: preferences)
        }
    }

    var sessionTitlesEnabled: Bool {
        didSet {
            Preferences.sessionTitlesEnabled.write(sessionTitlesEnabled, in: preferences)
        }
    }

    var promptSuggestionsEnabled: Bool {
        didSet {
            Preferences.promptSuggestionsEnabled.write(promptSuggestionsEnabled, in: preferences)
        }
    }

    // What Return does with a prompt typed while a turn runs.
    var midTurnPromptDelivery: SessionRunner.PromptDelivery {
        didSet {
            Preferences.midTurnPromptDelivery.write(midTurnPromptDelivery, in: preferences)
        }
    }

    // The Design ambition a session follows until it picks its own.
    var designAmbition: DesignAmbition {
        didSet { Preferences.designAmbition.write(designAmbition, in: preferences) }
    }

    var sessionFinishedSound: SessionSound {
        didSet {
            Preferences.sessionFinishedSound.write(sessionFinishedSound, in: preferences)
        }
    }

    // Whether the money a session has spent is on screen, one answer per agent. The
    // choice sits with the agent because only some CLIs report a cost at all.
    private var costShown: [AgentKind: Bool]

    private(set) var agentAvatars: [AgentAvatar]
    private(set) var defaultAgentAvatarName: String
    private(set) var hasCompletedOnboarding: Bool

    init(agentAvatarURL: URL = AppPaths.supportFile("agent-avatar.png"),
         preferences: UserDefaults = .standard) {
        self.agentAvatarURL = agentAvatarURL
        self.preferences = preferences
        Preferences.migrateOldSessionRules(in: preferences)
        oldSessionConditionDays = Preferences.oldSessionConditionDays(in: preferences)
        oldSessionDays = Preferences.oldSessionDays.read(in: preferences)
        oldSessionsDeleteOnTheirOwn = Preferences.oldSessionsDeleteOnTheirOwn(in: preferences)
        oldSessionAskReasons = Preferences.oldSessionAskReasons(in: preferences)
        sweepsOrphanedWorktrees = Preferences.sweepsOrphanedWorktrees.read(in: preferences)
        sessionMemoryLimit = Preferences.sessionMemoryLimit.read(in: preferences)
        statsEnabled = Preferences.statsEnabled.read(in: preferences)
        statsRemovedSessionDays = Preferences.statsRemovedSessionDays.read(in: preferences)
        sidebarSessionLimit = Preferences.sidebarSessionLimit.read(in: preferences)
        skillsRefreshInterval = Preferences.skillsRefreshInterval.read(in: preferences)
        projectSort = Preferences.projectSort.read(in: preferences)
        projectGrouping = Preferences.projectGrouping.read(in: preferences)
        terminalBundleID = Preferences.terminalBundleID(in: preferences)
        terminalScrollback = Preferences.terminalScrollback.read(in: preferences)
        appearance = Preferences.appearance.read(in: preferences)
        sunlightEnabled = Preferences.sunlightEnabled.read(in: preferences)
        sunlightMode = Preferences.sunlightMode.read(in: preferences)
        sunlightNightKelvin = Preferences.sunlightNightKelvin(in: preferences)
        cursorEffects = Preferences.cursorEffects(in: preferences)
        sidebarIconSet = Preferences.sidebarIconSet.read(in: preferences)
        hiddenHeaderButtons = Preferences.hiddenHeaderButtons(in: preferences)
        diceBearAvatarStyle = Preferences.diceBearAvatarStyle.read(in: preferences)
        textSize = Preferences.textSize.read(in: preferences)
        keyBindings = Preferences.keyBindings(in: preferences)
        messageColour = Preferences.messageColour.read(in: preferences)
        timestampFormat = Preferences.timestampFormat.read(in: preferences)
        timestampScope = Preferences.timestampScope.read(in: preferences)
        mobileAccessEnabled = Preferences.mobileAccessEnabled.read(in: preferences)
        mobilePairingLifetime = Preferences.mobilePairingLifetime.read(in: preferences)
        sessionRecapsEnabled = Preferences.sessionRecapsEnabled(in: preferences)
        sessionTitlesEnabled = Preferences.sessionTitlesEnabled.read(in: preferences)
        promptSuggestionsEnabled = Preferences.promptSuggestionsEnabled.read(in: preferences)
        midTurnPromptDelivery = Preferences.midTurnPromptDelivery.read(in: preferences)
        sessionFinishedSound = Preferences.sessionFinishedSound.read(in: preferences)
        designAmbition = Preferences.designAmbition.read(in: preferences)
        hasCompletedOnboarding = Preferences.hasCompletedOnboarding.read(in: preferences)
        costShown = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map {
            ($0, Preferences.showCost(for: $0, in: preferences))
        })
        let avatars = AgentAvatarFile.loadAll(from: agentAvatarURL)
        let preferredName = Preferences.defaultAgentAvatarName.read(in: preferences)
        agentAvatars = avatars
        defaultAgentAvatarName = AgentAvatarSelection.resolvedName(
            preferredName,
            availableNames: avatars.map { $0.url.lastPathComponent })
        if preferredName != defaultAgentAvatarName {
            Preferences.defaultAgentAvatarName.write(defaultAgentAvatarName, in: preferences)
        }
    }

    var appearanceSettings: AppearanceSettings {
        get {
            AppearanceSettings(
                appearance: appearance, sunlightEnabled: sunlightEnabled,
                sunlightMode: sunlightMode, sunlightNightKelvin: sunlightNightKelvin,
                cursorEffects: cursorEffects, textSize: textSize,
                messageColour: messageColour, timestampFormat: timestampFormat,
                timestampScope: timestampScope, diceBearAvatarStyle: diceBearAvatarStyle,
                sidebarIconSet: sidebarIconSet)
        }
        set {
            appearance = newValue.appearance
            sunlightEnabled = newValue.sunlightEnabled
            sunlightMode = newValue.sunlightMode
            sunlightNightKelvin = newValue.sunlightNightKelvin
            cursorEffects = newValue.cursorEffects
            textSize = newValue.textSize
            messageColour = newValue.messageColour
            timestampFormat = newValue.timestampFormat
            timestampScope = newValue.timestampScope
            diceBearAvatarStyle = newValue.diceBearAvatarStyle
            sidebarIconSet = newValue.sidebarIconSet
        }
    }

    func resetAppearance() {
        appearanceSettings = .standard
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        Preferences.hasCompletedOnboarding.write(true, in: preferences)
    }

    func shouldShowOnboarding(hasExistingWork: Bool) -> Bool {
        guard !hasCompletedOnboarding else { return false }
        // A populated project store proves the app has already been used, even when an
        // older build had no onboarding preference to save.
        guard !hasExistingWork else {
            completeOnboarding()
            return false
        }
        return true
    }

    func showsCost(for agent: AgentKind) -> Bool { costShown[agent] ?? true }

    func setShowsCost(_ shown: Bool, for agent: AgentKind) {
        costShown[agent] = shown
        Preferences.setShowCost(shown, for: agent, in: preferences)
    }

    func importAgentAvatars(from urls: [URL], personality: AgentPersonality = .standard) throws {
        add(try AgentAvatarFile.importImages(
            from: urls,
            to: agentAvatarURL,
            personality: personality))
    }

    func addStockAgentAvatar(personality: AgentPersonality) throws {
        add(try AgentAvatarFile.addStockPicture(
            personality: personality,
            to: agentAvatarURL))
    }

    private func add(_ avatars: [AgentAvatar]) {
        agentAvatars.append(contentsOf: avatars)
    }

    func setPersonality(_ personality: AgentPersonality, for avatar: AgentAvatar) throws {
        let updated = try AgentAvatarFile.setPersonality(
            personality, for: avatar, baseURL: agentAvatarURL)
        guard let index = agentAvatars.firstIndex(where: { $0.id == avatar.id }) else { return }
        agentAvatars[index] = updated
    }

    func saveBot(_ draft: BotDraft) throws {
        let saved = try AgentAvatarFile.save(personality: draft.personality, picture: draft.picture,
                                             photoData: draft.photoData, replacing: draft.avatar,
                                             to: agentAvatarURL)
        if let index = agentAvatars.firstIndex(where: { $0.id == saved.id }) {
            agentAvatars[index] = saved
        } else {
            agentAvatars.append(saved)
        }
        if draft.isDefault {
            setDefaultAgentAvatarName(saved.url.lastPathComponent)
        } else if defaultAgentAvatarName == saved.url.lastPathComponent {
            setDefaultAgentAvatarName(AgentAvatarSelection.defaultName)
        }
    }

    func removeAgentAvatar(_ avatar: AgentAvatar) throws {
        defer { reloadAgentAvatars() }
        try AgentAvatarFile.remove(at: avatar.url, from: agentAvatarURL)
    }

    func removeAgentAvatars() throws {
        defer { reloadAgentAvatars() }
        try AgentAvatarFile.removeAll(from: agentAvatarURL)
    }

    // Removing an avatar can take the chosen default with it, so the list and the default
    // are read back together and the built-in bot takes over when needed.
    private func reloadAgentAvatars() {
        agentAvatars = AgentAvatarFile.loadAll(from: agentAvatarURL)
        let resolvedDefault = AgentAvatarSelection.resolvedName(
            defaultAgentAvatarName,
            availableNames: agentAvatars.map { $0.url.lastPathComponent })
        if resolvedDefault != defaultAgentAvatarName {
            setDefaultAgentAvatarName(resolvedDefault)
        }
    }

    func setDefaultAgentAvatarName(_ name: String) {
        guard name == AgentAvatarSelection.defaultName
                || agentAvatars.contains(where: { $0.url.lastPathComponent == name }) else {
            return
        }
        defaultAgentAvatarName = name
        Preferences.defaultAgentAvatarName.write(name, in: preferences)
    }
}
