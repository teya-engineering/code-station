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
    private var hasExplicitNonBotDefault: Bool

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

    // Whether the money a session has spent is on screen, one answer per agent. The
    // choice sits with the agent because only some CLIs report a cost at all.
    private var costShown: [AgentKind: Bool]

    private(set) var agentAvatars: [AgentAvatar]
    private(set) var defaultAgentAvatarName: String

    init(agentAvatarURL: URL = AppPaths.supportFile("agent-avatar.png"),
         preferences: UserDefaults = .standard) {
        self.agentAvatarURL = agentAvatarURL
        self.preferences = preferences
        costShown = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map {
            ($0, Preferences.showCost(for: $0))
        })
        let avatars = AgentAvatarFile.loadAll(from: agentAvatarURL)
        let preferredName = Preferences.defaultAgentAvatarName(in: preferences)
        agentAvatars = avatars
        defaultAgentAvatarName = AgentAvatarSelection.defaultName(
            preferredName: preferredName,
            availableNames: avatars.map { $0.url.lastPathComponent })
        hasExplicitNonBotDefault = preferredName == AgentAvatarSelection.nonBotName
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
        let hadAvatars = !agentAvatars.isEmpty
        agentAvatars.append(contentsOf: avatars)
        if !hadAvatars, !hasExplicitNonBotDefault, let first = agentAvatars.first {
            setDefaultAgentAvatarName(first.url.lastPathComponent)
        }
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
    // are read back together and the default falls to whatever is still there.
    private func reloadAgentAvatars() {
        agentAvatars = AgentAvatarFile.loadAll(from: agentAvatarURL)
        let resolvedDefault = AgentAvatarSelection.defaultName(
            preferredName: defaultAgentAvatarName,
            availableNames: agentAvatars.map { $0.url.lastPathComponent })
        if resolvedDefault != defaultAgentAvatarName {
            setDefaultAgentAvatarName(resolvedDefault)
        }
    }

    func setDefaultAgentAvatarName(_ name: String) {
        guard name == AgentAvatarSelection.nonBotName
                || agentAvatars.contains(where: { $0.url.lastPathComponent == name }) else {
            return
        }
        defaultAgentAvatarName = name
        hasExplicitNonBotDefault = name == AgentAvatarSelection.nonBotName
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

    @State private var reviewingOldSessions = false
    @State private var showingLog = false
    @State private var tab = SettingsTab.general
    @State private var botDraft = BotDraft()

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch tab {
                    case .general:
                        oldSessions
                        skillRefresh
                        defaultAgent
                        botImage
                        terminal
                        appearance
                        startAtLogin
                        log
                    case .agents:
                        AgentSettingsView()
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 560)
            SheetFooter { dismiss() }
        }
        .frame(width: 520)
        .background(Theme.background)
        .onAppear { loginItem.refresh() }
        .sheet(isPresented: $reviewingOldSessions) { OldSessionsView().appOverlays() }
        .sheet(isPresented: $showingLog) { LogView().appOverlays() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Settings").font(.serif(16))
            Text(tab.note)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .headerBand()
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

    // MARK: - The app itself

    // The threshold decides what gets offered up for review, and, if the sweep below is
    // on, what gets cleared on its own. Even then the sweep only touches what git has
    // said is empty, so the number can be moved without wondering what it will take.
    private var oldSessions: some View {
        @Bindable var settings = settings
        let days = settings.oldSessionDays
        let stale = OldSessions.olderThan(days, in: store.sessions).count

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
                        Text("Only where nothing is lost: no worktree left, or one git says holds no changes. A session with uncommitted work is never taken this way, and waits for you in the review.")
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
                    Text("Opens Teya Conductor when you log in, so sessions are there waiting.")
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

    private var defaultAgent: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Default agent")
                    .font(.system(size: 13, weight: .semibold))
                Text("New sessions use this agent unless you choose a different one when creating them.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text(runner.agent.title)
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
                AgentKind.allCases.map { agent in
                    .item(agent.title,
                          checked: runner.agent == agent,
                          subtitle: agent == .codex
                              ? "OpenAI's coding agent."
                              : "Anthropic's coding agent.") {
                        runner.agent = agent
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            return "Add bots and give each one a personality for its working words. A bot with no photo gets the picture that comes with its personality. Up to \(AgentAvatarFile.maxCount) bots."
        }
        let maximum = count == AgentAvatarFile.maxCount ? ", the maximum" : ""
        return "\(count) bot\(count == 1 ? "" : "s") configured\(maximum). Choose the default for new sessions or override it when creating one."
    }

    private var defaultBot: AgentAvatar? {
        settings.agentAvatars.first {
            $0.url.lastPathComponent == settings.defaultAgentAvatarName
        }
    }

    // Non-bot is what the app falls back to with nothing to choose from, so until there is a
    // bot the picker says so rather than naming a choice nobody made.
    private var defaultBotTitle: String {
        if let defaultBot { return defaultBot.personality.title }
        return settings.agentAvatars.isEmpty ? "none yet" : "Non-bot"
    }

    private var defaultBotPicker: some View {
        HStack(spacing: 7) {
            if let defaultBot {
                AgentAvatarView(image: defaultBot.image, size: 18)
            } else {
                Image(systemName: "person.slash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
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
            .item("Non-bot",
                  icon: "person.slash",
                  checked: settings.defaultAgentAvatarName == AgentAvatarSelection.nonBotName,
                  subtitle: "Use the standard working indicator and voice.") {
                settings.setDefaultAgentAvatarName(AgentAvatarSelection.nonBotName)
            }
        ]
        if !settings.agentAvatars.isEmpty {
            entries.append(.separator)
        }
        entries.append(contentsOf: settings.agentAvatars.map { avatar in
            .item(avatar.personality.title,
                  image: avatar.image,
                  checked: settings.defaultAgentAvatarName == avatar.url.lastPathComponent,
                  subtitle: avatar.personality.detail) {
                settings.setDefaultAgentAvatarName(avatar.url.lastPathComponent)
            }
        })
        return entries
    }

    private func botImageThumbnail(_ avatar: AgentAvatar) -> some View {
        VStack(spacing: 5) {
            AgentAvatarView(image: avatar.image, size: 40)
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
    case agents

    var title: String {
        switch self {
        case .general: "General"
        case .agents: "Agents"
        }
    }

    var note: String {
        switch self {
        case .general: "Settings for Teya Conductor."
        case .agents: "Choose an agent and set how it runs."
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
