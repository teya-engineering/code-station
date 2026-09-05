import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// Whether macOS launches the app when the user logs in. The system owns this state, so
// it is read back from the service rather than stored by us.
@MainActor
@Observable
final class LoginItem {
    private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    private(set) var failure: String?

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    // Registering only works for an app bundle, so a binary run straight from the build
    // folder gets an error here rather than a toggle that silently does nothing.
    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        refresh()
    }
}

// What the app itself does, as opposed to what a session runs with. It is observed
// rather than read from UserDefaults where it is needed, so the sidebar's offer to clear
// old sessions follows the threshold the moment it is changed.
@MainActor
@Observable
final class AppSettings {
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

    // nil follows whatever macOS hands a .command file, so the app has a sensible terminal
    // before the user has thought about it.
    var terminalBundleID: String? {
        didSet { Preferences.setTerminalBundleID(terminalBundleID, in: preferences) }
    }

    var appearance: Appearance {
        didSet {
            Preferences.setAppearance(appearance, in: preferences)
            appearance.apply()
        }
    }

    var sidebarIconSet: SidebarIconSet {
        didSet {
            Preferences.setSidebarIconSet(sidebarIconSet, in: preferences)
        }
    }

    var opensWorkingSetByDefault: Bool {
        didSet {
            Preferences.setOpensWorkingSetByDefault(opensWorkingSetByDefault,
                                                    in: preferences)
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

    var designEnabled: Bool {
        didSet { Preferences.setDesignEnabled(designEnabled, in: preferences) }
    }

    var mobileAccessEnabled: Bool {
        didSet { Preferences.setMobileAccessEnabled(mobileAccessEnabled, in: preferences) }
    }

    var sessionRecapsEnabled: Bool {
        didSet {
            Preferences.setSessionRecapsEnabled(sessionRecapsEnabled, in: preferences)
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
        sidebarSessionLimit = Preferences.sidebarSessionLimit(in: preferences)
        skillsRefreshInterval = Preferences.skillsRefreshInterval(in: preferences)
        projectSort = Preferences.projectSort(in: preferences)
        projectGrouping = Preferences.projectGrouping(in: preferences)
        terminalBundleID = Preferences.terminalBundleID(in: preferences)
        appearance = Preferences.appearance(in: preferences)
        sidebarIconSet = Preferences.sidebarIconSet(in: preferences)
        opensWorkingSetByDefault = Preferences.opensWorkingSetByDefault(in: preferences)
        diceBearAvatarStyle = Preferences.diceBearAvatarStyle(in: preferences)
        textSize = Preferences.textSize(in: preferences)
        designEnabled = Preferences.designEnabled(in: preferences)
        mobileAccessEnabled = Preferences.mobileAccessEnabled(in: preferences)
        sessionRecapsEnabled = Preferences.sessionRecapsEnabled(in: preferences)
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
        textSize = .standard
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
struct SettingsView: View {
    @Environment(LoginItem.self) private var loginItem
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var settings
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.dismiss) private var dismiss

    let skills: SkillsManager

    @State private var reviewingOldSessions = false
    @State private var showingLog = false
    @State private var tab = SettingsTab.general
    @State private var searchText = ""
    @State private var searchTarget: SettingsSearchTarget?
    @State private var searchResultID: String?
    @State private var searchedAgent: AgentKind?
    @State private var botDraft = BotDraft()
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                navigation
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            paneHeading
                            tabContent
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.fadeIn)
                    }
                    .scrollIndicators(.visible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                    .id(tab)
                    .onChange(of: searchTarget) { _, target in
                        guard let target else { return }
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo(target.id, anchor: .top)
                        }
                    }
                }
            }
            settingsFooter
        }
        .frame(width: 960, height: 680)
        .background(Theme.background)
        .onAppear { loginItem.refresh() }
        .sheet(isPresented: $reviewingOldSessions) { OldSessionsView().appOverlays() }
        .sheet(isPresented: $showingLog) { LogView().appOverlays() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppMark()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            Text("Settings")
                .font(.serif(18))
            Spacer(minLength: 0)
            Text("Teya Code Station")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Search settings", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .focused($searchFocused)
                    .onChange(of: searchText) { _, query in
                        selectFirstSearchResult(for: query)
                    }
                if searchText.isEmpty {
                    Text("⌘F")
                        .font(.mono(9))
                        .foregroundStyle(.tertiary)
                } else {
                    Button {
                        searchText = ""
                        searchTarget = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .fieldSurface(cornerRadius: 9)

            Button { searchFocused = true } label: { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

            if searchText.isBlank {
                VStack(spacing: 4) {
                    ForEach(SettingsTab.allCases, id: \.self) { choice in
                        SettingsNavigationItem(
                            title: choice.title,
                            symbol: choice.symbol,
                            selected: tab == choice) {
                                tab = choice
                                searchTarget = nil
                            }
                    }
                }
            } else if searchResults.isEmpty {
                Text("No settings found")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(searchResults) { result in
                            SettingsSearchResultItem(
                                result: result,
                                selected: searchResultID == result.id) {
                                    select(result)
                                }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            Spacer(minLength: 16)
        }
        .padding(14)
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
        }
    }

    private var searchResults: [SettingsSearchResult] {
        SettingsSearchIndex.results(for: searchText)
    }

    private func selectFirstSearchResult(for query: String) {
        guard let result = SettingsSearchIndex.results(for: query).first else {
            searchTarget = nil
            searchResultID = nil
            return
        }
        select(result)
    }

    private func select(_ result: SettingsSearchResult) {
        tab = result.tab
        searchTarget = result.target
        searchResultID = result.id
        searchedAgent = result.agent
    }

    private var paneHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tab.title)
                .font(.serif(26))
            Text(tab.note)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsFooter: some View {
        SheetFooter(dismiss: { dismiss() }) {
            Circle()
                .fill(Theme.dotOn)
                .frame(width: 7, height: 7)
                .background(Circle()
                    .fill(Theme.dotOn.opacity(0.12))
                    .frame(width: 13, height: 13))
                .accessibilityHidden(true)
            Text("Changes save automatically")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if tab == .appearance {
                InlineLink(title: "Reset Appearance", action: settings.resetAppearance)
                    .padding(.leading, 6)
            }
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .general:
            VStack(alignment: .leading, spacing: 20) {
                sidebar.id(SettingsSearchTarget.generalSidebar.id)
                recaps.id(SettingsSearchTarget.generalRecaps.id)
                oldSessions.id(SettingsSearchTarget.generalOldSessions.id)
                orphanedWorktrees.id(SettingsSearchTarget.generalOrphanedWorktrees.id)
                skillRefresh.id(SettingsSearchTarget.generalSkills.id)
                system.id(SettingsSearchTarget.generalSystem.id)
            }
            .transition(.fadeIn)
        case .appearance:
            VStack(alignment: .leading, spacing: 20) {
                appearance.id(SettingsSearchTarget.appearanceTheme.id)
                workingSet.id(SettingsSearchTarget.appearanceWorkingSet.id)
                personalisation
            }
            .transition(.fadeIn)
        case .agents:
            AgentSettingsView(selectedAgent: runner.agent,
                              requestedAgent: searchedAgent)
            .transition(.fadeIn)
        case .advanced:
            VStack(alignment: .leading, spacing: 20) {
                SiteConfigurationSection(skills: skills)
            }
            .transition(.fadeIn)
        case .experimental:
            experimentalFeatures.id(SettingsSearchTarget.experimentalFeatures.id)
            .transition(.fadeIn)
        }
    }

    private var sidebar: some View {
        ChoiceBlock("SIDEBAR") {
            SettingsCard {
                HStack(alignment: .top, spacing: 12) {
                    settingCopy(
                        title: "Sessions shown",
                        detail: "How many recent sessions each project and workspace lists before See more.")
                    Spacer(minLength: 0)
                    OptionMenu(value: "\(settings.sidebarSessionLimit)") {
                        SidebarSessionVisibility.limitRange.map { limit in
                            .item("\(limit)", checked: settings.sidebarSessionLimit == limit) {
                                settings.sidebarSessionLimit = limit
                            }
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Sessions shown per sidebar list: \(settings.sidebarSessionLimit)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }
        }
    }

    private var recaps: some View {
        @Bindable var settings = settings
        return ChoiceBlock("SESSION RETURN") {
            SettingsCard {
                SettingsToggleRow(
                    "Automatic session recaps",
                    detail: "Creates a short recap after a turn finishes while you are in another session or app. You can still request one manually when this is off.",
                    isOn: $settings.sessionRecapsEnabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            }
        }
    }

    // The threshold and cleanup policy are separate choices: one says when a session is
    // old, while the other says what the app may do once the warning hour has passed.
    private var oldSessions: some View {
        @Bindable var settings = settings
        let days = settings.oldSessionDays
        let stale = OldSessions.olderThan(days, in: store.userSessions).count

        return ChoiceBlock("OLD SESSIONS") {
            SettingsCard {
                HStack(alignment: .top, spacing: 12) {
                    settingCopy(
                        title: "Count a session as old after",
                        detail: "Counted from its last turn. The sidebar offers to clear them.")
                    Spacer(minLength: 0)
                    DayField(days: $settings.oldSessionDays)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)

                SettingsRowDivider()

                OptionRow(
                    title: "Review before deleting",
                    detail: "Old sessions stay in the app until you delete them from the review screen.",
                    selected: settings.oldSessionCleanupPolicy == .review) {
                        settings.oldSessionCleanupPolicy = .review
                }

                SettingsRowDivider()

                OptionRow(
                    title: "Delete without asking when nothing would be lost",
                    detail: "After one warning hour, removes sessions with no Design files and no uncommitted worktree changes.",
                    selected: settings.oldSessionCleanupPolicy == .deleteSafe) {
                        settings.oldSessionCleanupPolicy = .deleteSafe
                }

                SettingsRowDivider()

                OptionRow(
                    title: "Delete without asking even when work would be lost",
                    detail: "After one warning hour, removes every old session, including generated Design files and uncommitted worktree changes.",
                    selected: settings.oldSessionCleanupPolicy == .deleteAll,
                    warning: true) {
                        settings.oldSessionCleanupPolicy = .deleteAll
                }

                SettingsRowDivider()

                HStack(spacing: 10) {
                    Text(stale == 0
                         ? "Nothing is older than that right now."
                         : "\(counted(stale, "session")) \(stale == 1 ? "is" : "are") older than that right now.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    InlineLink(title: "Review them…") { reviewingOldSessions = true }
                        .disabled(stale == 0)
                        .opacity(stale == 0 ? 0.4 : 1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }
        }
    }

    private var orphanedWorktrees: some View {
        @Bindable var settings = settings
        return ChoiceBlock("ORPHANED WORKTREES") {
            SettingsCard {
                SettingsToggleRow(
                    "Prune automatically",
                    detail: "After one warning hour, removes app-created worktrees that no session owns. Uncommitted changes are lost; branches with unmerged commits are kept.",
                    isOn: $settings.autoPruneOrphanedWorktrees)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            }
        }
    }

    private var skillRefresh: some View {
        ChoiceBlock("SKILLS") {
            SettingsCard {
                HStack(alignment: .top, spacing: 12) {
                    settingCopy(
                        title: "Refresh the skills list",
                        detail: "Checks the marketplace for new versions. You can still refresh it from Skills at any time.")
                    Spacer(minLength: 0)
                    OptionMenu(value: settings.skillsRefreshInterval.title) {
                        SkillsRefreshInterval.allCases.map { interval in
                            .item(interval.title,
                                  checked: settings.skillsRefreshInterval == interval) {
                                settings.skillsRefreshInterval = interval
                            }
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }
        }
    }

    private var appearance: some View {
        ChoiceBlock("THEME") {
            SettingsCard {
                HStack(alignment: .center, spacing: 20) {
                    settingCopy(
                        title: "Theme",
                        detail: "Follow macOS or keep the app in one appearance.")
                        .frame(width: 160, alignment: .leading)

                    HStack(spacing: 9) {
                        ForEach(Appearance.allCases) { choice in
                            SettingsThemeChoice(
                                appearance: choice,
                                selected: settings.appearance == choice) {
                                    settings.appearance = choice
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(14)

                SettingsRowDivider()

                HStack(alignment: .center, spacing: 20) {
                    settingCopy(
                        title: "Session text",
                        detail: "Changes transcripts, diffs, tool output, and terminals.")
                        .frame(width: 160, alignment: .leading)

                    Spacer(minLength: 0)

                    HStack(spacing: 4) {
                        ForEach(TextSize.allCases) { size in
                            ChoicePill(title: size.label, selected: settings.textSize == size) {
                                settings.textSize = size
                            }
                            .accessibilityLabel("Session text size: \(size.label)")
                            .accessibilityValue(settings.textSize == size ? "Selected" : "Not selected")
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private var workingSet: some View {
        @Bindable var settings = settings
        return ChoiceBlock("SESSION LAYOUT") {
            SettingsCard {
                SettingsToggleRow(
                    "Open working set automatically",
                    detail: "Opens the Working Set when an agent starts work in a session with no saved panel choice. Opening or closing it yourself is remembered.",
                    isOn: $settings.opensWorkingSetByDefault)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            }
        }
    }

    // Sidebar icons and the default bot each carry a preview and compact controls.
    private var personalisation: some View {
        ChoiceBlock("PERSONALISATION") {
            HStack(alignment: .top, spacing: 12) {
                sidebarIcons.id(SettingsSearchTarget.appearanceSidebarIcons.id)
                botImage.id(SettingsSearchTarget.appearanceDefaultBot.id)
            }
        }
    }

    // The shape both cards of the pair wear: copy and preview followed by compact controls.
    private func personalisationCard<Head: View, Controls: View>(
        @ViewBuilder head: () -> Head,
        @ViewBuilder controls: () -> Controls) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 11) {
                VStack(alignment: .leading, spacing: 11) { head() }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 7) { controls() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
        }
    }

    // A sample gets a sunken panel of its own instead of floating beside the copy, so it
    // reads as a sample of the setting rather than as an icon decorating the label.
    private func previewPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(Theme.sunken, cornerRadius: 10, border: Theme.settingsHairline)
    }

    // One control behind its own small label. The fixed gutter keeps the controls in a
    // card aligned with each other whatever their labels say.
    private func controlRow<Content: View>(_ label: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 9) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            content()
        }
        // A shared row height puts the two cards' control stacks on the same lines, not
        // just on the same bottom edge.
        .frame(minHeight: 32)
    }

    private var sidebarIcons: some View {
        personalisationCard {
            settingCopy(
                title: "Sidebar icons",
                detail: "Give projects a distinct, recognisable look.")

            previewPanel { sidebarIconPreview }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Sidebar icon preview")
                .accessibilityValue(sidebarIconStyleLabel)
        } controls: {
            controlRow("Style") {
                OptionMenu(value: sidebarIconStyleLabel) { sidebarIconStyleMenu }
                    .accessibilityLabel("Sidebar icon style: \(sidebarIconStyleLabel)")
            }
        }
    }

    private var sidebarIconStyleLabel: String {
        switch settings.sidebarIconSet {
        case .monograms: "Monogram"
        case .diceBear: settings.diceBearAvatarStyle.label
        }
    }

    private var sidebarIconStyleMenu: [MenuEntry] {
        var entries: [MenuEntry] = [
            .item("Monogram", image: sidebarIconMonogramImage, imageShape: .tile,
                  checked: settings.sidebarIconSet == .monograms) {
                settings.sidebarIconSet = .monograms
            },
        ]
        entries.append(contentsOf:
            DiceBearAvatarStyle.allCases.map { style in
                .item(style.label,
                      image: SidebarAvatar.preview.artworkImage(style: style),
                      imageShape: .tile,
                      checked: settings.sidebarIconSet == .diceBear
                        && settings.diceBearAvatarStyle == style) {
                    settings.diceBearAvatarStyle = style
                    settings.sidebarIconSet = .diceBear
                }
            })
        return entries
    }

    private var sidebarIconMonogramImage: NSImage? {
        let name = "atlas-web"
        let renderer = ImageRenderer(content: ProjectTileView(
            name: name,
            tint: Theme.projectTint(for: name),
            side: 22))
        renderer.scale = 2
        return renderer.nsImage
    }

    // A miniature of the sidebar, drawn with the tile the rail itself uses, so a style is
    // judged in the place it will be seen instead of on one floating icon.
    @ViewBuilder private var sidebarIconPreview: some View {
        VStack(spacing: 2) {
            ForEach(Array(Self.previewProjects.enumerated()), id: \.element.id) { index, project in
                HStack(spacing: 9) {
                    SidebarIdentityTile(
                        avatar: SidebarAvatar(subject: .project, id: project.id),
                        name: project.name,
                        tint: Theme.projectTint(for: project.name),
                        side: 22)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                        Text(project.collapsedPath)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background {
                    // The lead row wears the selected treatment, the way one project is
                    // always the open one in the rail.
                    if index == 0 {
                        RoundedRectangle(cornerRadius: 8).fill(Theme.card)
                    }
                }
            }
        }
        .padding(8)
    }

    // Fixed examples keep repository names and paths out of settings screenshots.
    private static let previewProjects = [
        Project(id: UUID(uuidString: "5A3B0000-0000-4000-8000-000000000001")!,
                name: "atlas-web", path: "~/Developer/atlas-web"),
        Project(id: UUID(uuidString: "5A3B0000-0000-4000-8000-000000000002")!,
                name: "orbit-api", path: "~/Developer/orbit-api"),
        Project(id: UUID(uuidString: "5A3B0000-0000-4000-8000-000000000003")!,
                name: "harbor-mobile", path: "~/Developer/harbor-mobile"),
        Project(id: UUID(uuidString: "5A3B0000-0000-4000-8000-000000000004")!,
                name: "summit-infra", path: "~/Developer/summit-infra"),
    ]

    // MARK: - Terminal

    private var system: some View {
        ChoiceBlock("SYSTEM") {
            SettingsCard {
                terminal
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                SettingsRowDivider()
                startAtLogin
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                SettingsRowDivider()
                log
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            }
        }
    }

    private var terminal: some View {
        // Reading the stored choice here is what ties this row to the setting, so the name
        // and icon change the moment a different terminal is picked.
        let chosen = settings.terminalBundleID
        let app = SystemTerminal.appURL

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Terminal")
                    .font(.system(size: 13, weight: .semibold))
                Text(chosen == nil
                     ? "\"Open in \(SystemTerminal.name(of: app))\" follows the app macOS opens .command files with. Pick one to keep it fixed."
                     : "\"Open in \(SystemTerminal.name(of: app))\" opens a shell in a window of its own.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            OptionMenu(value: SystemTerminal.name(of: app)) { terminalMenu }
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Terminal: \(SystemTerminal.name(of: app))")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var terminalMenu: [MenuEntry] {
        let system = SystemTerminal.systemDefault
        var entries: [MenuEntry] = [
            .item("System default",
                  image: NSWorkspace.shared.icon(forFile: system.path),
                  checked: settings.terminalBundleID == nil,
                  subtitle: "Currently \(SystemTerminal.name(of: system)).") {
                settings.terminalBundleID = nil
            },
            .separator
        ]
        entries.append(contentsOf: SystemTerminal.installed.compactMap { url in
            guard let id = SystemTerminal.bundleID(of: url) else { return nil }
            return .item(SystemTerminal.name(of: url),
                         image: NSWorkspace.shared.icon(forFile: url.path),
                         checked: settings.terminalBundleID == id) {
                settings.terminalBundleID = id
            }
        })
        entries.append(.separator)
        entries.append(.item("Choose…", icon: "folder") { chooseTerminal() })
        return entries
    }

    // The list only holds apps that say they run shell scripts, and not every terminal
    // says so, so there is a way to name one the list never offered.
    private func chooseTerminal() {
        guard let url = FilePicker.chooseFile(prompt: "Choose",
                                              message: "Pick the terminal to open a shell in.",
                                              types: [.application],
                                              directory: URL(fileURLWithPath: "/Applications"))
        else { return }

        guard let id = SystemTerminal.bundleID(of: url) else {
            dialogs.show(.notice(
                "Could not use that app",
                message: "\(SystemTerminal.name(of: url)) does not look like an application macOS can open."))
            return
        }
        settings.terminalBundleID = id
    }

    private var startAtLogin: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsToggleRow(
                "Start at login",
                detail: "Opens Teya Code Station when you log in, so sessions are there waiting.",
                isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))

            if let failure = loginItem.failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var experimentalFeatures: some View {
        @Bindable var settings = settings
        return ChoiceBlock("EXPERIMENTAL") {
            SettingsCard {
                SettingsToggleRow(
                    "Design",
                    detail: "Adds a Design workspace to sessions for visual ideas and prototypes.",
                    isOn: $settings.designEnabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)

                SettingsRowDivider()

                SettingsToggleRow(
                    "Mobile access",
                    detail: "Puts a QR code on Home, on every project and on every session. A phone on the same trusted Wi-Fi can read and run whatever the code it scanned covers.",
                    isOn: $settings.mobileAccessEnabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            }
        }
    }

    private var botImage: some View {
        personalisationCard {
            settingCopy(
                title: "Default bot",
                detail: "Used when a new session begins.")

            previewPanel {
                HStack(spacing: 11) {
                    AgentAvatarView(image: defaultBot.displayImage(for: nil), size: 38)
                    Text(defaultBot.personality.sampleLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(botPreviewBubble.fill(Theme.card))
                        .overlay(botPreviewBubble.stroke(Theme.border))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Default bot preview")
            .accessibilityValue("\(defaultBotTitle): \(defaultBot.personality.sampleLine)")
        } controls: {
            controlRow("Bot") { defaultBotPicker }

            controlRow("Bots") {
                HStack(spacing: 8) {
                    ForEach(botRoster) { avatar in
                        botRosterChip(avatar)
                    }
                    if settings.agentAvatars.count < AgentAvatarFile.maxCount {
                        addBotSlot
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // The corner nearest the avatar is squared off, so the bubble points at the bot doing
    // the talking.
    private var botPreviewBubble: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 11,
                               bottomLeadingRadius: 4,
                               bottomTrailingRadius: 11,
                               topTrailingRadius: 11)
    }

    // The built-in bot leads the roster: it is a choice like the others, and without it
    // there would be no chip to ring while it is the default.
    private var botRoster: [AgentAvatar] {
        [AgentAvatarSelection.avatar(named: nil, from: [])] + settings.agentAvatars
    }

    private var defaultBot: AgentAvatar {
        AgentAvatarSelection.avatar(
            named: settings.defaultAgentAvatarName,
            from: settings.agentAvatars)
    }

    private var defaultBotTitle: String {
        defaultBot.personality.title
    }

    private var defaultBotPicker: some View {
        OptionMenu(value: defaultBotTitle) { defaultBotMenu }
            .accessibilityLabel("Default bot: \(defaultBotTitle)")
    }

    private func settingCopy(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var defaultBotMenu: [MenuEntry] {
        var entries: [MenuEntry] = [
            .item(AgentPersonality.standard.title,
                  image: AgentAvatarSelection.avatar(named: nil, from: [])
                      .displayImage(for: nil),
                  checked: settings.defaultAgentAvatarName == AgentAvatarSelection.defaultName,
                  subtitle: AgentPersonality.standard.detail) {
                settings.setDefaultAgentAvatarName(AgentAvatarSelection.defaultName)
            }
        ]
        if !settings.agentAvatars.isEmpty {
            entries.append(.separator)
        }
        entries.append(contentsOf: settings.agentAvatars.map { avatar in
            .item(avatar.personality.title,
                  image: avatar.displayImage(for: nil),
                  checked: settings.defaultAgentAvatarName == avatar.url.lastPathComponent,
                  subtitle: avatar.personality.detail) {
                settings.setDefaultAgentAvatarName(avatar.url.lastPathComponent)
            }
        })
        return entries
    }

    // Clicking a chip makes that bot the default, so the roster and the dropdown are one
    // selection. What is left - the bot's personality, removing it - hangs off the chip's
    // own menu, which keeps the narrower card down to two control rows.
    @ViewBuilder private func botRosterChip(_ avatar: AgentAvatar) -> some View {
        let selected = avatar.id == defaultBot.id
        let name = avatar.url.lastPathComponent
        let chip = Button {
            settings.setDefaultAgentAvatarName(name)
        } label: {
            AgentAvatarView(image: avatar.displayImage(for: nil), size: 26)
                .padding(3)
                .overlay {
                    if selected {
                        Circle().stroke(Theme.accent, lineWidth: 2)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Default bot: \(avatar.personality.title)")
        .accessibilityValue(selected ? "Selected" : "Not selected")

        // The built-in bot is not the user's to rename or remove, so it carries no menu.
        if name == AgentAvatarSelection.defaultName {
            chip.appTooltip(avatar.personality.title)
        } else {
            chip
                .appTooltip("\(avatar.personality.title) - right-click to change or remove")
                .appContextMenu { botChipMenu(for: avatar) }
        }
    }

    private func botChipMenu(for avatar: AgentAvatar) -> [MenuEntry] {
        personalityMenu(for: avatar) + [
            .separator,
            .item("Remove bot", kind: .destructive, icon: "trash") {
                removeBotImage(avatar)
            }
        ]
    }

    // The empty slot at the end of the roster is where a new bot goes, so adding one costs
    // the card no control of its own.
    private var addBotSlot: some View {
        Button(action: startBotDraft) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background {
                    Circle().stroke(Theme.settingsBorder,
                                    style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .appTooltip("Add bot")
        .accessibilityLabel("Add bot")
    }

    private func personalityMenu(for avatar: AgentAvatar) -> [MenuEntry] {
        AgentPersonality.allCases.map { personality in
            .item(
                personality.title,
                checked: avatar.personality == personality,
                subtitle: personality.detail) {
                    setPersonality(personality, for: avatar)
                }
        }
    }

    // The whole bot is put together in one dialog, and the photo is chosen from inside it,
    // so the file chooser never opens before the user has asked for a bot at all.
    private func startBotDraft() {
        botDraft.reset()
        showBotDraft()
    }

    private func showBotDraft() {
        let draft = botDraft
        dialogs.show(Dialog(
            title: "Add a bot",
            message: "Pick a personality, and a photo if you have one. The session's working messages will sound like this bot.",
            content: AnyView(BotDraftEditor(draft: draft, chooseImage: chooseBotImage)),
            actions: [
                .init(label: "Add bot", kind: .primary, handler: importBotDraft),
                .init(label: "Cancel", kind: .cancel, handler: draft.reset)
            ],
            onCancel: draft.reset,
            width: 460))
    }

    private func chooseBotImage() {
        guard let url = FilePicker.chooseFile(prompt: "Choose",
                                              message: "Pick a photo for this bot.",
                                              types: [.image]) else { return }

        guard let image = AgentAvatarFile.load(from: url) else {
            // The draft dialog is still open behind this, so its own button brings it back
            // rather than dropping the half-made bot.
            dialogs.show(Dialog(
                title: "Could not read that photo",
                message: AgentAvatarError.couldNotReadImage.localizedDescription,
                actions: [.init(label: "OK", kind: .cancel, handler: showBotDraft)],
                onCancel: showBotDraft))
            return
        }
        botDraft.url = url
        botDraft.image = image
    }

    private func importBotDraft() {
        let url = botDraft.url
        let personality = botDraft.personality
        botDraft.reset()
        do {
            if let url {
                try settings.importAgentAvatars(from: [url], personality: personality)
            } else {
                try settings.addStockAgentAvatar(personality: personality)
            }
        } catch {
            showBotImageFailure(error)
        }
    }

    private func setPersonality(_ personality: AgentPersonality, for avatar: AgentAvatar) {
        do {
            try settings.setPersonality(personality, for: avatar)
        } catch {
            showBotImageFailure(error)
        }
    }

    private func removeBotImage(_ avatar: AgentAvatar) {
        do {
            try settings.removeAgentAvatar(avatar)
        } catch {
            showBotImageFailure(error)
        }
    }

    private func showBotImageFailure(_ error: Error) {
        dialogs.show(.notice("Could not update the bots", message: error.localizedDescription))
    }

    // A turn that stops moving looks the same as one that is working, and the transcript
    // keeps no record of the difference. This is where that record is.
    private var log: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Session log")
                    .font(.system(size: 13, weight: .semibold))
                Text("Every line Claude Code sent, and what the app did with it. Worth opening when a turn seems stuck.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            InlineLink(title: "Open") { showingLog = true }
            InlineLink(title: "Reveal") { SessionLog.revealInFinder() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsNavigationItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                Spacer(minLength: 0)
                Circle()
                    .fill(selected ? Theme.accent : .clear)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Theme.card : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(focused ? Theme.accent : selected ? Theme.border : .clear,
                        lineWidth: focused ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

private struct SettingsSearchResultItem: View {
    let result: SettingsSearchResult
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: result.tab.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    Text(result.tab.title)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .surface(selected ? Theme.card : .clear, cornerRadius: 9,
                     border: selected ? Theme.border : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsThemeChoice: View {
    let appearance: Appearance
    let selected: Bool
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                SettingsThemePreview(appearance: appearance)
                    .frame(height: 44)
                    .accessibilityHidden(true)

                HStack(spacing: 6) {
                    Text(appearance.label)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .opacity(selected ? 1 : 0)
                }
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Theme.field)
            }
            .frame(maxWidth: .infinity)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(focused || selected ? Theme.accent : Theme.border,
                        lineWidth: focused ? 2 : selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .accessibilityLabel("\(appearance.label) theme")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

private struct SettingsThemePreview: View {
    let appearance: Appearance

    var body: some View {
        switch appearance {
        case .system:
            HStack(spacing: 0) {
                preview(dark: false)
                preview(dark: true)
            }
        case .light:
            preview(dark: false)
        case .dark:
            preview(dark: true)
        }
    }

    private func preview(dark: Bool) -> some View {
        ZStack {
            (dark ? Color(red: 0.082, green: 0.082, blue: 0.067)
                  : Color(red: 0.969, green: 0.957, blue: 0.918))

            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(dark
                          ? Color(red: 0.18, green: 0.18, blue: 0.16)
                          : Color(red: 0.91, green: 0.90, blue: 0.85))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(dark ? Color.white.opacity(0.15) : Color.black.opacity(0.12))
                        .frame(maxWidth: .infinity, minHeight: 7)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(dark
                              ? Color(red: 0.58, green: 0.76, blue: 0.60).opacity(0.55)
                              : Theme.accentFill.opacity(0.32))
                        .frame(maxWidth: .infinity, minHeight: 7)
                }
            }
            .padding(7)
            .surface(dark
                     ? Color(red: 0.125, green: 0.122, blue: 0.114)
                     : Color(red: 1, green: 0.992, blue: 0.965),
                     cornerRadius: 5,
                     border: dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
            .padding(7)
        }
    }
}

// The bot being put together in the add dialog. It is a reference type so the dialog's
// own buttons can read the choices made in its content while it stays open.
@MainActor
@Observable
final class BotDraft {
    var url: URL?
    var image: NSImage?
    var personality = AgentPersonality.standard

    func reset() {
        url = nil
        image = nil
        personality = .standard
    }
}

private struct BotDraftEditor: View {
    @Bindable var draft: BotDraft
    let chooseImage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AgentAvatarView(
                    image: draft.image ?? AgentAvatarArt.image(for: draft.personality),
                    size: 48)

                ActionButton(title: draft.image == nil ? "Add a photo…" : "Change photo…",
                             tone: .sunken, height: 34, icon: "photo.badge.plus",
                             action: chooseImage)

                Spacer(minLength: 0)
            }
            .padding(.top, 4)

            PersonalityPicker(selection: $draft.personality)
        }
    }
}

private struct PersonalityPicker: View {
    @Binding var selection: AgentPersonality

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(AgentPersonality.allCases, id: \.self) { personality in
                Button { selection = personality } label: {
                    HStack(spacing: 9) {
                        AgentAvatarView(
                            image: AgentAvatarArt.image(for: personality),
                            size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(personality.title)
                                .font(.system(size: 12, weight: .semibold))
                            Text(personality.detail)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                    .surface(selection == personality ? Theme.field : Theme.card,
                             cornerRadius: 9,
                             border: selection == personality
                                 ? Theme.accent.opacity(0.55) : Theme.border)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }
}

private struct DayField: View {
    @Binding var days: Int

    private var value: Binding<Int> {
        Binding(
            get: { days },
            set: { days = OldSessions.resolvedDays($0) }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("Days", value: value, format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 36)
                .accessibilityLabel("Old session age in days")
            Text(days == 1 ? "day" : "days")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .fieldSurface(cornerRadius: 9)
    }
}

enum SettingsSearchTarget: String, Hashable {
    case generalSidebar
    case generalRecaps
    case generalOldSessions
    case generalOrphanedWorktrees
    case generalSkills
    case generalSystem
    case appearanceTheme
    case appearanceWorkingSet
    case appearanceSidebarIcons
    case appearanceDefaultBot
    case agentDefault
    case agentConfigure
    case agentDetails
    case agentUsage
    case agentModel
    case agentEffort
    case agentPermissions
    case agentCost
    case agentFiles
    case advancedConfiguration
    case advancedReset
    case experimentalFeatures

    var id: String { rawValue }
}

struct SettingsSearchResult: Identifiable, Equatable {
    let title: String
    let tab: SettingsTab
    let target: SettingsSearchTarget
    let keywords: String
    var agent: AgentKind?

    var id: String {
        [tab.title, agent?.title, title].compactMap { $0 }.joined(separator: ":")
    }
}

enum SettingsSearchIndex {
    static let entries = [
        result("Sessions shown", .general, .generalSidebar,
               "sidebar recent project workspace see more limit"),
        result("Automatic session recaps", .general, .generalRecaps,
               "recap catch up return summary conversation finish away manual toggle"),
        result("Old sessions", .general, .generalOldSessions,
               "count old after days delete automatically review clear stale design saved work uncommitted"),
        result("Orphaned worktrees", .general, .generalOrphanedWorktrees,
               "git checkout prune automatically no session disk cleanup uncommitted branch"),
        result("Skills refresh", .general, .generalSkills,
               "skills marketplace refresh versions interval daily"),
        result("Terminal", .general, .generalSystem,
               "system open shell command app"),
        result("Start at login", .general, .generalSystem,
               "system launch log in startup"),
        result("Session log", .general, .generalSystem,
               "system open reveal stuck diagnostics"),
        result("Theme", .appearance, .appearanceTheme,
               "appearance system light dark macos"),
        result("Session text", .appearance, .appearanceTheme,
               "appearance size small regular large transcript diff terminal"),
        result("Open working set automatically", .appearance, .appearanceWorkingSet,
               "appearance session layout panel sidebar default first turn agent closed open"),
        result("Sidebar icons", .appearance, .appearanceSidebarIcons,
               "appearance style monogram dicebear motion still animated"),
        result("Default bot", .appearance, .appearanceDefaultBot,
               "appearance avatar image personality photo add"),
        result("Default agent", .agents, .agentDefault,
               "claude code codex new sessions"),
        result("Configure agent", .agents, .agentConfigure,
               "switch account settings claude code codex"),
        result("Claude Code account", .agents, .agentDetails,
               "connected refresh version plan path sign in login", agent: .claudeCode),
        result("Codex account", .agents, .agentDetails,
               "connected refresh auth version plan path sign in login", agent: .codex),
        result("Claude Code usage", .agents, .agentUsage,
               "limits meters current weekly updated reset", agent: .claudeCode),
        result("Codex usage", .agents, .agentUsage,
               "limits meters current weekly updated reset", agent: .codex),
        result("Model", .agents, .agentModel,
               "default opus sonnet haiku fable sol terra luna"),
        result("Effort", .agents, .agentEffort,
               "thinking default low medium high extra max"),
        result("Permissions", .agents, .agentPermissions,
               "accept edits ask risky manual sandbox access"),
        result("Cost", .agents, .agentCost,
               "spent dollars session usage show"),
        result("Agent files", .agents, .agentFiles,
               "claude settings json codex config toml reveal"),
        result("Current configuration", .advanced, .advancedConfiguration,
               "json environments api access credentials oauth shared defaults starter requests mcp presets skills marketplace shortcuts"),
        result("Reset from file", .advanced, .advancedReset,
               "repository url github load choose file restore aspects"),
        result("Design", .experimental, .experimentalFeatures,
               "visual ideas prototypes feature"),
        result("Mobile access", .experimental, .experimentalFeatures,
               "qr code phone wifi experimental")
    ]

    static func results(for query: String) -> [SettingsSearchResult] {
        let words = query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !words.isEmpty else { return [] }
        let phrase = words.joined(separator: " ")
        return entries.enumerated().filter { _, entry in
            let haystack = "\(entry.title) \(entry.tab.title) \(entry.keywords)".lowercased()
            return words.allSatisfy(haystack.contains)
        }
        .sorted { lhs, rhs in
            let leftRank = rank(lhs.element, phrase: phrase, words: words)
            let rightRank = rank(rhs.element, phrase: phrase, words: words)
            return leftRank == rightRank ? lhs.offset < rhs.offset : leftRank < rightRank
        }
        .map(\.element)
    }

    private static func rank(_ entry: SettingsSearchResult,
                             phrase: String,
                             words: [String]) -> Int {
        let title = entry.title.lowercased()
        if title == phrase { return 0 }
        if title.hasPrefix(phrase) { return 1 }
        if title.contains(phrase) { return 2 }
        if words.allSatisfy(title.contains) { return 3 }
        return 4
    }

    private static func result(_ title: String,
                               _ tab: SettingsTab,
                               _ target: SettingsSearchTarget,
                               _ keywords: String,
                               agent: AgentKind? = nil) -> SettingsSearchResult {
        SettingsSearchResult(title: title,
                             tab: tab,
                             target: target,
                             keywords: keywords,
                             agent: agent)
    }
}

enum SettingsTab: CaseIterable, Hashable {
    case general
    case appearance
    case agents
    case advanced
    case experimental

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .agents: "Agents"
        case .advanced: "Advanced"
        case .experimental: "Experimental"
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .appearance: "paintpalette"
        case .agents: "cpu"
        case .advanced: "gearshape"
        case .experimental: "flask"
        }
    }

    var note: String {
        switch self {
        case .general: "Settings for Teya Code Station."
        case .appearance: "Make Code Station comfortable to read and easy to recognise at a glance."
        case .agents: "Choose an agent and set how it runs."
        case .advanced: "Manage shared configuration and other advanced settings."
        case .experimental: "Try features that are still in development."
        }
    }
}
