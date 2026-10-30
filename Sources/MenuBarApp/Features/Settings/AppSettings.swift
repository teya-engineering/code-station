import AppKit
import SwiftUI
import Observation

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
            Preferences.setSidebarSessionLimit(sidebarSessionLimit, in: preferences)
        }
    }

    var oldSessionDays: Int {
        didSet { Preferences.setOldSessionDays(oldSessionDays, in: preferences) }
    }

    var oldSessionCleanupPolicy: OldSessionCleanupPolicy {
        didSet {
            Preferences.setOldSessionCleanupPolicy(oldSessionCleanupPolicy, in: preferences)
        }
    }

    var sessionMemoryLimit: SessionMemoryLimit {
        didSet { Preferences.setSessionMemoryLimit(sessionMemoryLimit, in: preferences) }
    }

    var autoPruneOrphanedWorktrees: Bool {
        didSet {
            Preferences.setAutoPruneOrphanedWorktrees(autoPruneOrphanedWorktrees,
                                                      in: preferences)
        }
    }

    var skillsRefreshInterval: SkillsRefreshInterval {
        didSet {
            Preferences.setSkillsRefreshInterval(skillsRefreshInterval, in: preferences)
        }
    }

    var projectSort: ProjectSort {
        didSet { Preferences.setProjectSort(projectSort, in: preferences) }
    }

    var projectGrouping: ProjectGrouping {
        didSet { Preferences.setProjectGrouping(projectGrouping, in: preferences) }
    }

    // Which app a shell opens in when it opens in a window of its own. nil means no app
    // was picked, so the drawer inside this app is what the terminal button offers first.
    var terminalBundleID: String? {
        didSet { Preferences.setTerminalBundleID(terminalBundleID, in: preferences) }
    }

    var opensTerminalInDrawer: Bool { terminalBundleID == nil }

    var appearance: Appearance {
        didSet {
            Preferences.setAppearance(appearance, in: preferences)
            appearance.apply()
        }
    }

    // Warms every window with the sun, on top of whichever appearance is chosen.
    var sunlightEnabled: Bool {
        didSet { Preferences.setSunlightEnabled(sunlightEnabled, in: preferences) }
    }

    var sunlightMode: SunlightMode {
        didSet { Preferences.setSunlightMode(sunlightMode, in: preferences) }
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
            Preferences.setSidebarIconSet(sidebarIconSet, in: preferences)
        }
    }

    var cursorEffects: CursorEffectsSettings {
        didSet { Preferences.setCursorEffects(cursorEffects, in: preferences) }
    }

    var opensWorkingSetByDefault: Bool {
        didSet {
            Preferences.setOpensWorkingSetByDefault(opensWorkingSetByDefault,
                                                    in: preferences)
        }
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
            Preferences.setDiceBearAvatarStyle(diceBearAvatarStyle, in: preferences)
        }
    }

    var textSize: TextSize {
        didSet { Preferences.setTextSize(textSize, in: preferences) }
    }

    var messageColour: MessageColour {
        didSet { Preferences.setMessageColour(messageColour, in: preferences) }
    }

    var mobileAccessEnabled: Bool {
        didSet { Preferences.setMobileAccessEnabled(mobileAccessEnabled, in: preferences) }
    }

    var sessionRecapsEnabled: Bool {
        didSet {
            Preferences.setSessionRecapsEnabled(sessionRecapsEnabled, in: preferences)
        }
    }

    var sessionTitlesEnabled: Bool {
        didSet {
            Preferences.setSessionTitlesEnabled(sessionTitlesEnabled, in: preferences)
        }
    }

    var promptSuggestionsEnabled: Bool {
        didSet {
            Preferences.setPromptSuggestionsEnabled(promptSuggestionsEnabled, in: preferences)
        }
    }

    // What Return does with a prompt typed while a turn runs.
    var midTurnPromptDelivery: SessionRunner.PromptDelivery {
        didSet {
            Preferences.setMidTurnPromptDelivery(midTurnPromptDelivery, in: preferences)
        }
    }

    // The Design ambition a session follows until it picks its own.
    var designAmbition: DesignAmbition {
        didSet { Preferences.setDesignAmbition(designAmbition, in: preferences) }
    }

    var sessionFinishedSound: SessionSound {
        didSet {
            Preferences.setSessionFinishedSound(sessionFinishedSound, in: preferences)
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
        oldSessionDays = Preferences.oldSessionDays(in: preferences)
        oldSessionCleanupPolicy = Preferences.oldSessionCleanupPolicy(in: preferences)
        autoPruneOrphanedWorktrees = Preferences.autoPruneOrphanedWorktrees(in: preferences)
        sessionMemoryLimit = Preferences.sessionMemoryLimit(in: preferences)
        sidebarSessionLimit = Preferences.sidebarSessionLimit(in: preferences)
        skillsRefreshInterval = Preferences.skillsRefreshInterval(in: preferences)
        projectSort = Preferences.projectSort(in: preferences)
        projectGrouping = Preferences.projectGrouping(in: preferences)
        terminalBundleID = Preferences.terminalBundleID(in: preferences)
        appearance = Preferences.appearance(in: preferences)
        sunlightEnabled = Preferences.sunlightEnabled(in: preferences)
        sunlightMode = Preferences.sunlightMode(in: preferences)
        sunlightNightKelvin = Preferences.sunlightNightKelvin(in: preferences)
        cursorEffects = Preferences.cursorEffects(in: preferences)
        sidebarIconSet = Preferences.sidebarIconSet(in: preferences)
        opensWorkingSetByDefault = Preferences.opensWorkingSetByDefault(in: preferences)
        hiddenHeaderButtons = Preferences.hiddenHeaderButtons(in: preferences)
        diceBearAvatarStyle = Preferences.diceBearAvatarStyle(in: preferences)
        textSize = Preferences.textSize(in: preferences)
        messageColour = Preferences.messageColour(in: preferences)
        mobileAccessEnabled = Preferences.mobileAccessEnabled(in: preferences)
        sessionRecapsEnabled = Preferences.sessionRecapsEnabled(in: preferences)
        sessionTitlesEnabled = Preferences.sessionTitlesEnabled(in: preferences)
        promptSuggestionsEnabled = Preferences.promptSuggestionsEnabled(in: preferences)
        midTurnPromptDelivery = Preferences.midTurnPromptDelivery(in: preferences)
        sessionFinishedSound = Preferences.sessionFinishedSound(in: preferences)
        designAmbition = Preferences.designAmbition(in: preferences)
        hasCompletedOnboarding = Preferences.hasCompletedOnboarding(in: preferences)
        costShown = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map {
            ($0, Preferences.showCost(for: $0, in: preferences))
        })
        let avatars = AgentAvatarFile.loadAll(from: agentAvatarURL)
        let preferredName = Preferences.defaultAgentAvatarName(in: preferences)
        agentAvatars = avatars
        defaultAgentAvatarName = AgentAvatarSelection.resolvedName(
            preferredName,
            availableNames: avatars.map { $0.url.lastPathComponent })
        if preferredName != defaultAgentAvatarName {
            Preferences.setDefaultAgentAvatarName(defaultAgentAvatarName, in: preferences)
        }
    }

    func resetAppearance() {
        appearance = .system
        sunlightEnabled = false
        sunlightMode = .followsSun
        sunlightNightKelvin = Sunlight.nightKelvin
        cursorEffects = CursorEffectsSettings()
        textSize = .standard
        messageColour = .projectIcon
        diceBearAvatarStyle = .waves
        sidebarIconSet = .diceBear
        opensWorkingSetByDefault = false
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        Preferences.setHasCompletedOnboarding(true, in: preferences)
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
        Preferences.setDefaultAgentAvatarName(name, in: preferences)
    }
}

// Settings is a setup job rather than somewhere to sit, so it is a sheet over the
// window, the way the MCP config manager is.
