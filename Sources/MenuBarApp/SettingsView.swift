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
    @State private var tab = SettingsTab.general
    @State private var botDraft = BotDraft()

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            ScrollView {
                tabContent.padding(20)
            }
            .frame(maxHeight: 560)
            SheetFooter { dismiss() }
        }
        .smoothlyResizes(when: tab)
        .frame(width: 520)
        .background(Theme.background)
        .onAppear { loginItem.refresh() }
        .sheet(isPresented: $reviewingOldSessions) { OldSessionsView().appOverlays() }
        .sheet(isPresented: $showingLog) { LogView().appOverlays() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Settings").font(.serif(16))
            tabNote
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .general:
            VStack(alignment: .leading, spacing: 24) {
                sidebar
                oldSessions
                skillRefresh
                terminal
                startAtLogin
                log
            }
            .transition(.fadeIn)
        case .appearance:
            VStack(alignment: .leading, spacing: 24) {
                appearance
                textSize
                sidebarIcons
                botImage
            }
            .transition(.fadeIn)
        case .agents:
            VStack(alignment: .leading, spacing: 24) {
                AgentSettingsView(selectedAgent: runner.agent)
            }
            .transition(.fadeIn)
        case .advanced:
            VStack(alignment: .leading, spacing: 24) {
                SiteConfigurationSection(skills: skills)
            }
            .transition(.fadeIn)
        case .experimental:
            VStack(alignment: .leading, spacing: 24) {
                experimentalFeatures
            }
            .transition(.fadeIn)
        }
    }

    private var sidebar: some View {
        ChoiceBlock("SIDEBAR") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sessions shown")
                        .font(.system(size: 13, weight: .semibold))
                    Text("How many recent sessions each project and workspace lists before See more.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
        }
    }

    @ViewBuilder private var tabNote: some View {
        switch tab {
        case .general:
            Text(SettingsTab.general.note).transition(.fadeIn)
        case .appearance:
            Text(SettingsTab.appearance.note).transition(.fadeIn)
        case .agents:
            Text(SettingsTab.agents.note).transition(.fadeIn)
        case .advanced:
            Text(SettingsTab.advanced.note).transition(.fadeIn)
        case .experimental:
            Text(SettingsTab.experimental.note).transition(.fadeIn)
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { choice in
                ChoicePill(title: choice.title, selected: tab == choice) { tab = choice }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .headerBand(height: Theme.subHeaderHeight)
    }

    // The threshold decides what gets offered up for review, and, if the sweep below is
    // on, what gets cleared on its own. Even then the sweep only touches what git has
    // said is empty, so the number can be moved without wondering what it will take.
    private var oldSessions: some View {
        @Bindable var settings = settings
        let days = settings.oldSessionDays
        let stale = OldSessions.olderThan(days, in: store.userSessions).count

        return ChoiceBlock("OLD SESSIONS") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Count a session as old after")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Counted from its last turn. The sidebar offers to clear them.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    DayField(days: $settings.oldSessionDays)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))

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
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))

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
            }
        }
    }

    private var skillRefresh: some View {
        ChoiceBlock("SKILLS") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Refresh the skills list")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Checks the marketplace for new versions. You can still refresh it from Skills at any time.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
        }
    }

    private var appearance: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Appearance")
                    .font(.system(size: 13, weight: .semibold))
                Text("Follow the system or pin the app to light or dark.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(Appearance.allCases) { appearance in
                    ChoicePill(title: appearance.label,
                               selected: settings.appearance == appearance) {
                        settings.appearance = appearance
                    }
                }
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var textSize: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Text size")
                    .font(.system(size: 13, weight: .semibold))
                Text("How large a session reads: the transcript, tool output, diffs and the terminal. Cmd+ and Cmd- change it from anywhere.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(TextSize.allCases) { size in
                    ChoicePill(title: size.label, selected: settings.textSize == size) {
                        settings.textSize = size
                    }
                }
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidebarIcons: some View {
        ChoiceBlock(
            "SIDEBAR ICONS",
            note: "DiceBear avatars are bundled with the app and stay offline. Monogram and Stripes are available as still styles only."
        ) {
            HStack(spacing: 12) {
                sidebarIconPreview

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Motion")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                        HStack(spacing: 4) {
                            ForEach(availableSidebarIconMotions) { motion in
                                ChoicePill(title: motion.label,
                                           selected: settings.sidebarIconMotion == motion) {
                                    settings.sidebarIconMotion = motion
                                }
                            }
                        }
                    }

                    HStack {
                        Text("Style")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                        HStack(spacing: 8) {
                            Text(sidebarIconStyleLabel)
                                .font(.system(size: 12, weight: .semibold))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
                        .contentShape(Rectangle())
                        .appMenu(matchWidth: true) {
                            sidebarIconStyleMenu
                        }
                        .accessibilityLabel("Sidebar icon style: \(sidebarIconStyleLabel)")
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
        }
    }

    private var availableSidebarIconMotions: [SidebarIconMotion] {
        settings.sidebarIconSet == .monograms ? [.still] : SidebarIconMotion.allCases
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
                side: 48)
        case .diceBear:
            DiceBearAvatarView(
                avatar: .preview,
                style: settings.diceBearAvatarStyle,
                motion: settings.sidebarIconMotion,
                side: 48) {
                RoundedRectangle(cornerRadius: 13)
                    .fill(Theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.border))
            }
        }
    }

    // MARK: - Terminal

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
            VStack(alignment: .leading, spacing: 10) {
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
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))

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
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
            }
        }
    }

    private var botImage: some View {
        ChoiceBlock("BOTS") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bots")
                            .font(.system(size: 13, weight: .semibold))
                        Text(botImageDescription)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 10) {
                        defaultBotPicker

                        if settings.agentAvatars.count < AgentAvatarFile.maxCount {
                            Button(action: startBotDraft) {
                                Text("Add bot…")
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 12)
                                    .frame(height: 34)
                                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .fixedSize()
                }

                if !settings.agentAvatars.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(settings.agentAvatars) { avatar in
                                botImageThumbnail(avatar)
                            }
                        }
                        .padding(.top, 4)
                        .padding(.trailing, 4)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
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
            AgentAvatarView(image: defaultBot.displayImage(for: nil), size: 18)
            Text("Default: \(defaultBotTitle)")
                .font(.system(size: 12, weight: .semibold))
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
        .contentShape(Rectangle())
        .appMenu(matchWidth: true) { defaultBotMenu }
        .accessibilityLabel("Default bot: \(defaultBotTitle)")
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

enum SettingsTab: CaseIterable {
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

    var note: String {
        switch self {
        case .general: "Settings for Teya Code Station."
        case .appearance: "Choose how Teya Code Station looks and feels."
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
