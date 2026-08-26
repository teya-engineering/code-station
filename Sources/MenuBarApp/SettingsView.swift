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

    var oldSessionDays = Preferences.oldSessionDays {
        didSet { Preferences.oldSessionDays = oldSessionDays }
    }

    var autoDeleteOldSessions = Preferences.autoDeleteOldSessions {
        didSet { Preferences.autoDeleteOldSessions = autoDeleteOldSessions }
    }

    var skillsRefreshInterval = Preferences.skillsRefreshInterval {
        didSet { Preferences.skillsRefreshInterval = skillsRefreshInterval }
    }

    var projectSort = Preferences.projectSort {
        didSet { Preferences.projectSort = projectSort }
    }

    var projectGrouping = Preferences.projectGrouping {
        didSet { Preferences.projectGrouping = projectGrouping }
    }

    // nil follows whatever macOS hands a .command file, so the app has a sensible terminal
    // before the user has thought about it.
    var terminalBundleID = Preferences.terminalBundleID {
        didSet { Preferences.terminalBundleID = terminalBundleID }
    }

    var appearance = Preferences.appearance {
        didSet {
            Preferences.appearance = appearance
            appearance.apply()
        }
    }

    var sidebarIconSet: SidebarIconSet {
        didSet {
            Preferences.setSidebarIconSet(sidebarIconSet, in: preferences)
            if sidebarIconSet == .monograms {
                sidebarIconMotion = .still
            }
        }
    }

    var sidebarIconMotion: SidebarIconMotion {
        didSet {
            guard sidebarIconSet == .diceBear || sidebarIconMotion == .still else {
                sidebarIconMotion = .still
                return
            }
            Preferences.setSidebarIconMotion(sidebarIconMotion, in: preferences)
            if sidebarIconMotion == .animated, !diceBearAvatarStyle.supportsAnimation {
                diceBearAvatarStyle = .squircles
            }
        }
    }

    var diceBearAvatarStyle: DiceBearAvatarStyle {
        didSet {
            guard sidebarIconMotion == .still || diceBearAvatarStyle.supportsAnimation else {
                diceBearAvatarStyle = oldValue
                return
            }
            Preferences.setDiceBearAvatarStyle(diceBearAvatarStyle, in: preferences)
        }
    }

    var textSize = Preferences.textSize {
        didSet { Preferences.textSize = textSize }
    }

    var designEnabled = Preferences.designEnabled {
        didSet { Preferences.designEnabled = designEnabled }
    }

    var mobileAccessEnabled = Preferences.mobileAccessEnabled {
        didSet { Preferences.mobileAccessEnabled = mobileAccessEnabled }
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
        sidebarSessionLimit = Preferences.sidebarSessionLimit(in: preferences)
        let storedIconSet = Preferences.sidebarIconSet(in: preferences)
        sidebarIconSet = storedIconSet
        let storedIconMotion = Preferences.sidebarIconMotion(in: preferences)
        let resolvedIconMotion = storedIconSet == .monograms ? .still : storedIconMotion
        sidebarIconMotion = resolvedIconMotion
        let storedAvatarStyle = Preferences.diceBearAvatarStyle(in: preferences)
        let resolvedAvatarStyle = resolvedIconMotion == .animated && !storedAvatarStyle.supportsAnimation
            ? .squircles : storedAvatarStyle
        diceBearAvatarStyle = resolvedAvatarStyle
        if resolvedIconMotion != storedIconMotion {
            Preferences.setSidebarIconMotion(resolvedIconMotion, in: preferences)
        }
        if resolvedAvatarStyle != storedAvatarStyle {
            Preferences.setDiceBearAvatarStyle(resolvedAvatarStyle, in: preferences)
        }
        hasCompletedOnboarding = Preferences.hasCompletedOnboarding(in: preferences)
        costShown = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map {
            ($0, Preferences.showCost(for: $0))
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
        sidebarIconMotion = .still
        diceBearAvatarStyle = .waves
        sidebarIconSet = .diceBear
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
        Preferences.setShowCost(shown, for: agent)
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
    @State private var tab = SettingsTab.appearance
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
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))

            Button { searchFocused = true } label: { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 8) {
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

                Spacer(minLength: 0)

                if tab == .appearance {
                    Button(action: settings.resetAppearance) {
                        Text("Reset Appearance")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button { dismiss() } label: {
                    Text("Done")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.88)))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.card)
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .general:
            VStack(alignment: .leading, spacing: 20) {
                sidebar.id(SettingsSearchTarget.generalSidebar.id)
                oldSessions.id(SettingsSearchTarget.generalOldSessions.id)
                skillRefresh.id(SettingsSearchTarget.generalSkills.id)
                system.id(SettingsSearchTarget.generalSystem.id)
            }
            .transition(.fadeIn)
        case .appearance:
            VStack(alignment: .leading, spacing: 20) {
                appearance.id(SettingsSearchTarget.appearanceTheme.id)
                sidebarIcons.id(SettingsSearchTarget.appearanceSidebarIcons.id)
                botImage.id(SettingsSearchTarget.appearanceDefaultBot.id)
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
                    HStack(spacing: 8) {
                        Text("\(settings.sidebarSessionLimit)")
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
                    .contentShape(Rectangle())
                    .appMenu(matchWidth: true) {
                        SidebarSessionVisibility.limitRange.map { limit in
                            .item("\(limit)", checked: settings.sidebarSessionLimit == limit) {
                                settings.sidebarSessionLimit = limit
                            }
                        }
                    }
                    .accessibilityLabel("Sessions shown per sidebar list: \(settings.sidebarSessionLimit)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }
        }
    }

    // The threshold decides what gets offered up for review, and, if the sweep below is
    // on, what gets cleared on its own. Even then the sweep only touches what git has
    // said is empty, so the number can be moved without wondering what it will take.
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

                Toggle(isOn: $settings.autoDeleteOldSessions) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete them without asking")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Only where nothing is lost: no Design files, and no worktree left or one Git says holds no changes. Once a session appears for review, it waits at least one hour before automatic deletion. A session with Design files or uncommitted work is never taken this way.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.appSwitch)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)

                SettingsRowDivider()

                HStack(spacing: 10) {
                    Text(stale == 0
                         ? "Nothing is older than that right now."
                         : "\(stale) session\(stale == 1 ? " is" : "s are") older than that right now.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Review them…") { reviewingOldSessions = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .disabled(stale == 0)
                        .opacity(stale == 0 ? 0.4 : 1)
                }
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
                    HStack(spacing: 8) {
                        Text(settings.skillsRefreshInterval.title)
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
                    .contentShape(Rectangle())
                    .appMenu(matchWidth: true) {
                        SkillsRefreshInterval.allCases.map { interval in
                            .item(interval.title,
                                  checked: settings.skillsRefreshInterval == interval) {
                                settings.skillsRefreshInterval = interval
                            }
                        }
                    }
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

                    HStack(spacing: 4) {
                        ForEach(TextSize.allCases) { size in
                            ChoicePill(title: size.label, selected: settings.textSize == size) {
                                settings.textSize = size
                            }
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Session text size: \(size.label)")
                            .accessibilityValue(settings.textSize == size ? "Selected" : "Not selected")
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private var sidebarIcons: some View {
        ChoiceBlock("SIDEBAR ICONS") {
            SettingsCard {
                HStack(alignment: .center, spacing: 20) {
                    settingCopy(
                        title: "Sidebar icons",
                        detail: "Give projects a distinct, recognisable look.")
                        .frame(width: 160, alignment: .leading)

                    HStack(spacing: 12) {
                        sidebarIconPreview
                            .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 9) {
                                Text("Style")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .leading)

                                HStack(spacing: 8) {
                                    Text(sidebarIconStyleLabel)
                                        .font(.system(size: 12, weight: .semibold))
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
                                .contentShape(Rectangle())
                                .appMenu(matchWidth: true) {
                                    sidebarIconStyleMenu
                                }
                                .accessibilityLabel("Sidebar icon style: \(sidebarIconStyleLabel)")
                            }

                            HStack(spacing: 9) {
                                Text("Motion")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .leading)

                                HStack(spacing: 4) {
                                    ForEach(SidebarIconMotion.allCases) { motion in
                                        let supportsMotion = settings.sidebarIconSet == .diceBear
                                            && settings.diceBearAvatarStyle.supportsAnimation
                                        let enabled = motion == .still || supportsMotion
                                        ChoicePill(title: motion.label,
                                                   selected: settings.sidebarIconMotion == motion) {
                                            settings.sidebarIconMotion = motion
                                        }
                                        .frame(maxWidth: .infinity)
                                        .disabled(!enabled)
                                        .opacity(enabled ? 1 : 0.4)
                                        .accessibilityLabel("Sidebar icon motion: \(motion.label)")
                                        .accessibilityValue(
                                            settings.sidebarIconMotion == motion
                                                ? "Selected" : "Not selected")
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(14)
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
            .item("Monogram", checked: settings.sidebarIconSet == .monograms) {
                settings.sidebarIconSet = .monograms
            },
        ]
        entries.append(contentsOf:
            DiceBearAvatarStyle.available(for: settings.sidebarIconMotion).map { style in
                .item(style.label,
                      checked: settings.sidebarIconSet == .diceBear
                        && settings.diceBearAvatarStyle == style) {
                    settings.diceBearAvatarStyle = style
                    settings.sidebarIconSet = .diceBear
                }
            })
        return entries
    }

    @ViewBuilder private var sidebarIconPreview: some View {
        switch settings.sidebarIconSet {
        case .monograms:
            ProjectTileView(
                name: "Project",
                tint: Theme.projectTint(for: "Project"),
                side: 42)
        case .diceBear:
            DiceBearAvatarView(
                avatar: .preview,
                style: settings.diceBearAvatarStyle,
                motion: settings.sidebarIconMotion,
                side: 42) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
            }
        }
    }

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
            HStack(spacing: 7) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(SystemTerminal.name(of: app))
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
            .contentShape(Rectangle())
            .appMenu(matchWidth: true) { terminalMenu }
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        panel.message = "Pick the terminal to open a shell in."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let id = SystemTerminal.bundleID(of: url) else {
            dialogs.show(Dialog(
                title: "Could not use that app",
                message: "\(SystemTerminal.name(of: url)) does not look like an application macOS can open.",
                actions: [.init(label: "OK", kind: .cancel)]))
            return
        }
        settings.terminalBundleID = id
    }

    private var startAtLogin: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { loginItem.isEnabled },
                                 set: { loginItem.set($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start at login")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Opens Teya Code Station when you log in, so sessions are there waiting.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.appSwitch)

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
                Toggle(isOn: $settings.designEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Design")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Offers Design mode when creating a session for visual ideas and prototypes.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.appSwitch)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)

                SettingsRowDivider()

                Toggle(isOn: $settings.mobileAccessEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mobile access")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Puts a QR code on Home, on every project and on every session. A phone on the same trusted Wi-Fi can read and run whatever the code it scanned covers.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.appSwitch)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var botImage: some View {
        ChoiceBlock("DEFAULT BOT") {
            SettingsCard {
                HStack(alignment: .center, spacing: 20) {
                    settingCopy(
                        title: "Default bot",
                        detail: "Used when a new session begins.")
                        .frame(width: 160, alignment: .leading)

                    HStack(spacing: 10) {
                        AgentAvatarView(image: defaultBot.displayImage(for: nil), size: 42)
                        defaultBotPicker

                        if settings.agentAvatars.count < AgentAvatarFile.maxCount {
                            Button(action: startBotDraft) {
                                Text("Add bot…")
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 13)
                                    .frame(height: 30)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(14)

                if !settings.agentAvatars.isEmpty {
                    SettingsRowDivider()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(settings.agentAvatars) { avatar in
                                botImageThumbnail(avatar)
                            }
                        }
                        .padding(.top, 4)
                        .padding(.trailing, 4)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }

                SettingsRowDivider()
                Text(botImageDescription)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }
        }
    }

    private var botImageDescription: String {
        let count = settings.agentAvatars.count
        guard count > 0 else {
            return "The built-in Default bot is used for new sessions. Add up to \(AgentAvatarFile.maxCount) custom bots with their own personality and optional photo."
        }
        let maximum = count == AgentAvatarFile.maxCount ? ", the maximum" : ""
        return "\(count) custom bot\(count == 1 ? "" : "s") configured\(maximum). Choose the default for new sessions or use the built-in Default bot."
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
        HStack(spacing: 7) {
            Text(defaultBotTitle)
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
        .contentShape(Rectangle())
        .appMenu(matchWidth: true) { defaultBotMenu }
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

    private func botImageThumbnail(_ avatar: AgentAvatar) -> some View {
        VStack(spacing: 5) {
            AgentAvatarView(image: avatar.displayImage(for: nil), size: 40)
            HStack(spacing: 4) {
                Text(avatar.personality.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            .contentShape(Rectangle())
            .accessibilityLabel("Personality: \(avatar.personality.title)")
            .accessibilityAddTraits(.isButton)
            .appMenu(matchWidth: true) { personalityMenu(for: avatar) }
        }
        .overlay(alignment: .topTrailing) {
            Button { removeBotImage(avatar) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Theme.deletion))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
            .accessibilityLabel("Remove bot")
        }
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"
        panel.message = "Pick a photo for this bot."
        guard panel.runModal() == .OK, let url = panel.url else { return }

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
        dialogs.show(Dialog(
            title: "Could not update the bots",
            message: error.localizedDescription,
            actions: [.init(label: "OK", kind: .cancel)]))
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
            Button("Open") { showingLog = true }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Button("Reveal") { SessionLog.revealInFinder() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
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
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Theme.card : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(selected ? Theme.border : .clear))
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
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(dark
                      ? Color(red: 0.125, green: 0.122, blue: 0.114)
                      : Color(red: 1, green: 0.992, blue: 0.965)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1)))
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

                Button(action: chooseImage) {
                    HStack(spacing: 7) {
                        Text(draft.image == nil ? "Add a photo…" : "Change photo…")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(selection == personality ? Theme.field : Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(selection == personality
                                ? Theme.accent.opacity(0.55) : Theme.border))
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
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
    }
}

enum SettingsSearchTarget: String, Hashable {
    case generalSidebar
    case generalOldSessions
    case generalSkills
    case generalSystem
    case appearanceTheme
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
        result("Old sessions", .general, .generalOldSessions,
               "count old after days delete automatically review clear stale"),
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
               "json environments api access starter requests mcp presets skills marketplace shortcuts"),
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

// The permission modes the CLI takes, minus the ones that have no place in a desktop app:
// nothing here can turn every check off.
enum PermissionMode {
    static let all: [(mode: String, title: String, short: String, detail: String)] = [
        ("acceptEdits", "Accept edits, ask about the rest", "Accept edits",
         "Edits to files go through on their own. Commands and anything else are asked about."),
        ("manual", "Ask about everything", "Ask everything",
         "Every edit and every command waits for an answer. The slowest, and the one that shows the most."),
        ("auto", "Ask only about risky things", "Ask risky only",
         "Claude Code judges each step and only asks about the ones that can do damage."),
    ]

    static func title(of mode: String?) -> String {
        all.first { $0.mode == mode }?.title ?? mode ?? "Accept edits, ask about the rest"
    }

    // What the mode is called where a sentence does not fit, like the composer bar.
    static func shortTitle(of mode: String?) -> String {
        all.first { $0.mode == mode }?.short ?? mode ?? "Accept edits"
    }
}
