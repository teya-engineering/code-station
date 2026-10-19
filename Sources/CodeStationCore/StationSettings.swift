import Foundation

// The settings that matter outside the GUI, as the station hands them to a client: agent
// defaults, the old-session policy, the memory limit, the session sound and the sidebar's
// arrangement. They are read from and written to the shared station preferences, the
// same ones the GUI's Settings window reads, so a change in one shows in the other.
//
// Every setting is one choice among values the station lists, so a client draws each as
// a row and cycles through its choices without knowing what any of them means. Along with
// them come each agent's readiness (installed, signed in, and the command that fixes it)
// and whether an update to the app is waiting.

public struct RemoteSettings: Codable, Equatable, Sendable {
    public var sections: [RemoteSettingSection]
    public var agents: [RemoteAgentReadiness]
    // A newer release than the one installed, when the GUI has found one.
    public var update: RemoteAppUpdate?

    public init(sections: [RemoteSettingSection], agents: [RemoteAgentReadiness], update: RemoteAppUpdate?) {
        self.sections = sections
        self.agents = agents
        self.update = update
    }

    public func setting(_ id: String) -> RemoteSetting? {
        sections.lazy.flatMap(\.settings).first { $0.id == id }
    }

    public func readiness(of agent: AgentKind) -> RemoteAgentReadiness? {
        agents.first { $0.agent == agent }
    }
}

public struct RemoteSettingSection: Codable, Equatable, Sendable {
    public var title: String
    // The agent a section of agent defaults belongs to, so its readiness can sit under it.
    public var agent: AgentKind?
    public var settings: [RemoteSetting]

    public init(title: String, agent: AgentKind? = nil, settings: [RemoteSetting]) {
        self.title = title
        self.agent = agent
        self.settings = settings
    }
}

public struct RemoteSetting: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String?
    // One of the choices' values. An empty value is "Default" where a setting has one.
    public var value: String
    public var choices: [RemoteSettingChoice]

    public init(id: String, title: String, detail: String? = nil, value: String, choices: [RemoteSettingChoice]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.value = value
        self.choices = choices
    }

    public var valueTitle: String {
        choices.first { $0.value == value }?.title ?? value
    }
}

public struct RemoteSettingChoice: Codable, Equatable, Sendable {
    public var value: String
    public var title: String

    public init(value: String, title: String) {
        self.value = value
        self.title = title
    }
}

// Whether an agent can run a session, and if not, what to type to fix it.
public struct RemoteAgentReadiness: Codable, Equatable, Sendable {
    public var agent: AgentKind
    public var title: String
    public var installed: Bool
    // Nil while it is not known: not installed, or a sign-in the CLI has yet to answer
    // about.
    public var signedIn: Bool?
    // Who it is signed in as, worded as the GUI's Agents pane words it.
    public var account: String?
    public var installCommand: String
    public var loginCommand: String

    public init(agent: AgentKind, installed: Bool, signedIn: Bool?, account: String?) {
        self.agent = agent
        title = agent.title
        self.installed = installed
        self.signedIn = signedIn
        self.account = account
        installCommand = agent.installHint
        loginCommand = agent.loginCommand
    }

    // What stands in the way, or nil when nothing known does.
    public var problem: String? {
        if !installed { return "\(title) is not installed." }
        if signedIn == false { return "\(title) is not signed in." }
        return nil
    }

    // The command that clears the problem.
    public var fix: String? {
        if !installed { return installCommand }
        if signedIn == false { return loginCommand }
        return nil
    }
}

public struct RemoteAppUpdate: Codable, Equatable, Sendable {
    public var version: String
    public var installed: String
    // The release page, where the update can be read about and taken by hand.
    public var page: String?

    public init(version: String, installed: String, page: String?) {
        self.version = version
        self.installed = installed
        self.page = page
    }
}

// A session's own lines from the session log, oldest first.
public struct RemoteSessionLog: Codable, Equatable, Sendable {
    public var sessionID: String
    public var text: String

    public init(sessionID: String, text: String) {
        self.sessionID = sessionID
        self.text = text
    }
}

// Who each agent's CLI is signed in as. Claude Code and Codex keep it in a file in the
// home folder; Copilot keeps it in the keychain, so only its CLI can say, which takes a
// while and can stop on a keychain prompt.
public struct AgentSignIn: Sendable {
    public var home: URL
    // True or false once Copilot has answered, nil when it could not.
    public var copilot: @Sendable () async -> Bool?

    public init(home: URL, copilot: @escaping @Sendable () async -> Bool?) {
        self.home = home
        self.copilot = copilot
    }

    public static let live = AgentSignIn(home: FileManager.default.homeDirectoryForCurrentUser) {
        guard let path = ExecutableSearch.resolve(AgentKind.copilot.command) else { return nil }
        return await CopilotServer.authStatus(at: path, searchPath: ExecutableSearch.searchPath)?.isAuthenticated
    }

    // The account read from the CLI's own file: nil when it is not signed in.
    func account(of agent: AgentKind) -> String? {
        switch agent {
        case .claudeCode:
            guard let object = json(".claude.json"),
                  let oauth = object["oauthAccount"] as? [String: Any],
                  let email = oauth["emailAddress"] as? String else { return nil }
            return (oauth["displayName"] as? String).map { "\($0) · \(email)" } ?? email
        case .codex:
            guard let object = json(".codex/auth.json") else { return nil }
            if let tokens = object["tokens"] as? [String: Any], tokens["id_token"] is String {
                return "ChatGPT login"
            }
            if let key = object["OPENAI_API_KEY"] as? String, !key.isEmpty { return "API key" }
            return nil
        case .copilot:
            return nil
        }
    }

    private func json(_ name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(name)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

extension StationCommands {
    // MARK: - Settings

    // The settings as the shared preferences hold them now, with each agent's readiness
    // and any update waiting. Copilot's sign-in is asked for in the background, the first
    // time only, and reads as unknown until it answers.
    public func readSettings() -> RemoteSettings {
        RemoteSettings(sections: settingSections(), agents: AgentKind.allCases.map(readiness),
                       update: availableUpdate())
    }

    // Writes one setting to the shared preferences and answers with the settings as they
    // now stand. A setting that does not exist, or a value it does not offer, is refused.
    public func changeSetting(_ id: String, to value: String) throws(StationRefusal) -> RemoteSettings {
        guard let setting = readSettings().setting(id) else {
            throw StationRefusal("There is no setting called \(id).")
        }
        let offered = setting.choices.contains { $0.value == value }
        switch id {
        case "agent":
            guard offered, let agent = AgentKind(rawValue: value) else { throw refusal(value, setting) }
            Preferences.setAgent(agent, in: preferences)
            runner.adoptDefaults(from: preferences)
        case "sound":
            guard offered, let sound = SessionSound(rawValue: value) else { throw refusal(value, setting) }
            Preferences.setSessionFinishedSound(sound, in: preferences)
        case "memoryLimit":
            guard offered, let limit = Int(value).flatMap(SessionMemoryLimit.init(rawValue:)) else {
                throw refusal(value, setting)
            }
            Preferences.setSessionMemoryLimit(limit, in: preferences)
        case "oldSessions.days":
            // Any number of days the GUI's field takes, not only the ones listed.
            guard let days = Int(value), OldSessions.resolvedDays(days) == days else { throw refusal(value, setting) }
            Preferences.setOldSessionDays(days, in: preferences)
        case "oldSessions.policy":
            guard offered, let policy = OldSessionCleanupPolicy(rawValue: value) else { throw refusal(value, setting) }
            Preferences.setOldSessionCleanupPolicy(policy, in: preferences)
        case "sidebar.sessionsShown":
            guard offered, let limit = Int(value) else { throw refusal(value, setting) }
            Preferences.setSidebarSessionLimit(limit, in: preferences)
        case "sidebar.sort":
            guard offered, let sort = ProjectSort(rawValue: value) else { throw refusal(value, setting) }
            Preferences.setProjectSort(sort, in: preferences)
        case "sidebar.grouping":
            guard offered, let grouping = ProjectGrouping(rawValue: value) else { throw refusal(value, setting) }
            Preferences.setProjectGrouping(grouping, in: preferences)
        default:
            guard offered else { throw refusal(value, setting) }
            try changeAgentDefault(id, to: value)
        }
        return readSettings()
    }

    private func refusal(_ value: String, _ setting: RemoteSetting) -> StationRefusal {
        StationRefusal("\(setting.title) cannot be set to \(value.isEmpty ? "that" : value).")
    }

    // `<agent>.<field>`: one of an agent's defaults for new sessions. The runner takes the
    // new defaults at once, so the next session starts on them.
    private func changeAgentDefault(_ id: String, to value: String) throws(StationRefusal) {
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let agent = AgentKind(rawValue: parts[0]) else {
            throw StationRefusal("There is no setting called \(id).")
        }
        var defaults = Preferences.sessionDefaults(for: agent, in: preferences)
        let chosen = value.isEmpty ? nil : value
        switch parts[1] {
        case "model": defaults.model = chosen
        case "effort": defaults.effort = chosen
        case "permissionMode": defaults.permissionMode = chosen.flatMap(PermissionMode.init(rawValue:))
        case "sandbox": defaults.codexSandboxMode = chosen.flatMap(CodexSandboxMode.init(rawValue:))
        case "access": defaults.copilotAccessMode = chosen.flatMap(CopilotAccessMode.init(rawValue:))
        default: throw StationRefusal("There is no setting called \(id).")
        }
        Preferences.setSessionDefaults(defaults, for: agent, in: preferences)
        runner.adoptDefaults(from: preferences)
    }

    private func settingSections() -> [RemoteSettingSection] {
        let agentChoices = AgentKind.allCases.map { agent in
            RemoteSettingChoice(value: agent.rawValue,
                                title: runner.isAvailable(agent) ? agent.title : "\(agent.title) (not installed)")
        }
        var sections = [RemoteSettingSection(title: "New sessions", settings: [
            RemoteSetting(id: "agent", title: "Agent", detail: "The agent a new session starts on.",
                          value: Preferences.agent(in: preferences).rawValue, choices: agentChoices),
        ])]
        sections += AgentKind.allCases.map(agentSection)

        let days = Preferences.oldSessionDays(in: preferences)
        let dayChoices = Set([1, 2, 3, 5, 7, 14, 30, 60, 90, 180, 365, days]).sorted().map {
            RemoteSettingChoice(value: "\($0)", title: $0 == 1 ? "1 day" : "\($0) days")
        }
        let sessionLimit = Preferences.sidebarSessionLimit(in: preferences)
        sections += [
            RemoteSettingSection(title: "Sessions", settings: [
                RemoteSetting(id: "sound", title: "Sound when a session finishes",
                              value: Preferences.sessionFinishedSound(in: preferences).rawValue,
                              choices: SessionSound.allCases.map { RemoteSettingChoice(value: $0.rawValue, title: $0.title) }),
                RemoteSetting(id: "memoryLimit", title: "Stop a turn after it uses",
                              detail: "Counted across the agent and everything it starts.",
                              value: "\(Preferences.sessionMemoryLimit(in: preferences).rawValue)",
                              choices: SessionMemoryLimit.choices().map {
                                  RemoteSettingChoice(value: "\($0.rawValue)", title: $0.title)
                              }),
            ]),
            RemoteSettingSection(title: "Old sessions", settings: [
                RemoteSetting(id: "oldSessions.days", title: "Count a session as old after",
                              detail: "Counted from its last turn.", value: "\(days)", choices: dayChoices),
                RemoteSetting(id: "oldSessions.policy", title: "Then",
                              value: Preferences.oldSessionCleanupPolicy(in: preferences).rawValue,
                              choices: [
                                  RemoteSettingChoice(value: OldSessionCleanupPolicy.review.rawValue,
                                                      title: "Review before deleting"),
                                  RemoteSettingChoice(value: OldSessionCleanupPolicy.deleteSafe.rawValue,
                                                      title: "Delete when nothing would be lost"),
                                  RemoteSettingChoice(value: OldSessionCleanupPolicy.deleteAll.rawValue,
                                                      title: "Delete even when work would be lost"),
                              ]),
            ]),
            RemoteSettingSection(title: "Sidebar", settings: [
                RemoteSetting(id: "sidebar.sessionsShown", title: "Sessions shown",
                              detail: "How many recent sessions each project and workspace lists before See more.",
                              value: "\(sessionLimit)",
                              choices: SidebarSessionLimit.range.map { RemoteSettingChoice(value: "\($0)", title: "\($0)") }),
                RemoteSetting(id: "sidebar.sort", title: "Sort", value: Preferences.projectSort(in: preferences).rawValue,
                              choices: ProjectSort.allCases.map { RemoteSettingChoice(value: $0.rawValue, title: $0.label) }),
                RemoteSetting(id: "sidebar.grouping", title: "Group",
                              value: Preferences.projectGrouping(in: preferences).rawValue,
                              choices: ProjectGrouping.allCases.map {
                                  RemoteSettingChoice(value: $0.rawValue, title: $0.label)
                              }),
            ]),
        ]
        return sections
    }

    // One agent's defaults for new sessions: model, effort and how much it may do unasked.
    private func agentSection(_ agent: AgentKind) -> RemoteSettingSection {
        let defaults = Preferences.sessionDefaults(for: agent, in: preferences)
        let model = runner.validModel(defaults.model, for: agent)
        var models = runner.modelOptions(for: agent).map { RemoteSettingChoice(value: $0.id ?? "", title: $0.title) }
        if let model, !models.contains(where: { $0.value == model }) {
            models.append(RemoteSettingChoice(value: model, title: model))
        }
        let efforts = runner.effortOptions(for: agent, model: model).map {
            RemoteSettingChoice(value: $0.id ?? "", title: $0.title)
        }
        let effort = runner.validEffort(defaults.effort, for: agent, model: model) ?? ""
        let prefix = agent.rawValue
        var settings = [
            RemoteSetting(id: "\(prefix).model", title: "Model", value: model ?? "", choices: models),
            RemoteSetting(id: "\(prefix).effort", title: "Effort", value: effort, choices: efforts),
        ]
        switch agent {
        case .claudeCode:
            settings.append(RemoteSetting(
                id: "\(prefix).permissionMode", title: "Permissions",
                value: (defaults.permissionMode ?? .fallback).rawValue,
                choices: PermissionMode.defaultChoices.map { RemoteSettingChoice(value: $0.rawValue, title: $0.title) }))
        case .codex:
            settings.append(RemoteSetting(
                id: "\(prefix).sandbox", title: "Access",
                value: (defaults.codexSandboxMode ?? .workspaceWrite).rawValue,
                choices: CodexSandboxMode.allCases.map { RemoteSettingChoice(value: $0.rawValue, title: $0.title) }))
        case .copilot:
            settings.append(RemoteSetting(
                id: "\(prefix).access", title: "Access",
                value: (defaults.copilotAccessMode ?? .workspace).rawValue,
                choices: CopilotAccessMode.allCases.map { RemoteSettingChoice(value: $0.rawValue, title: $0.title) }))
        }
        return RemoteSettingSection(title: agent.title, agent: agent, settings: settings)
    }

    // MARK: - Readiness

    private func readiness(_ agent: AgentKind) -> RemoteAgentReadiness {
        guard runner.isAvailable(agent) else {
            return RemoteAgentReadiness(agent: agent, installed: false, signedIn: nil, account: nil)
        }
        guard agent == .copilot else {
            let account = signIn.account(of: agent)
            return RemoteAgentReadiness(agent: agent, installed: true, signedIn: account != nil, account: account)
        }
        if copilotSignIn.asked == false {
            copilotSignIn.asked = true
            let ask = signIn.copilot
            Task { @MainActor [weak self] in
                let answer = await ask()
                self?.copilotSignIn.answer = answer
            }
        }
        return RemoteAgentReadiness(agent: agent, installed: true, signedIn: copilotSignIn.answer, account: nil)
    }

    // MARK: - Updates

    // The release the GUI last found, when it is newer than the one installed. The GUI
    // does the asking, once a day; the station only reads what it cached.
    private func availableUpdate() -> RemoteAppUpdate? {
        guard let installedVersion, let installed = AppVersion(installedVersion),
              let data = preferences.data(forKey: "cachedAppUpdateRelease"),
              let release = try? JSONDecoder().decode(CachedRelease.self, from: data),
              let offered = AppVersion(release.version), offered > installed else { return nil }
        return RemoteAppUpdate(version: release.version, installed: installedVersion, page: release.pageURL)
    }

    // What the GUI's update checker caches, as far as the station reads it.
    private struct CachedRelease: Decodable {
        let version: String
        let pageURL: String?
    }

    // MARK: - Session log

    // The session's own lines from the end of the session log: every line it wrote is
    // tagged with the start of its id.
    public func readLog(_ sessionID: String) throws(StationRefusal) -> RemoteSessionLog {
        guard let id = UUID(uuidString: sessionID), let session = store.session(id) else { throw .noSession }
        let tag = "[\(session.id.uuidString.prefix(8))]"
        let lines = SessionLog.tail().split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.contains(tag) }
        return RemoteSessionLog(sessionID: sessionID, text: lines.joined(separator: "\n"))
    }
}

// Whether Copilot has been asked about its sign-in, and what it said.
@MainActor
final class CopilotSignInCheck {
    var asked = false
    var answer: Bool?
}
