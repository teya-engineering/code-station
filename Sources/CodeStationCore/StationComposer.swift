import Foundation

// The composer as the GUI's offers it, for a client: the run settings of a session's next
// turn, prompts with files and custom instructions, and the slash commands a session can
// be sent. (Granting a folder outside the session's is an answer to a permission request;
// see `answerPermission`.)
//
// Run settings come as the same generic rows the settings screen reads (`RemoteSettings`),
// so a client draws each as a row and cycles through its choices. Their ids:
// - agent: the agent the session runs on, fixed for its life (one choice, never changed);
// - model, effort: "" follows the app's default;
// - permissionMode (Claude Code), codexSandbox (Codex), copilotAccess (Copilot): how much
//   the agent asks first, or what it may reach; "" follows the app's default;
// - designAmbition (a Design conversation only): how far the look is pushed; "" follows
//   the app's Design default.

// A prompt as a client's composer sends it: the text, files to go with it by their path on
// the host's machine, and instructions for this prompt alone.
public struct RemotePrompt: Codable, Equatable, Sendable {
    public var text: String
    public var attachments: [String]
    public var customInstructions: String?

    public init(text: String, attachments: [String] = [], customInstructions: String? = nil) {
        self.text = text
        self.attachments = attachments
        self.customInstructions = customInstructions
    }
}

// One slash command a session can be sent, as the GUI's command menu lists it.
public struct RemoteSlashCommand: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, Sendable {
        // The app answers it (clear, compact, plan).
        case app
        // The CLI answers it.
        case builtIn
        // A file in the person's own folder.
        case user
        // A file in the session's checkout.
        case project
    }

    public var name: String
    public var summary: String
    public var scope: Scope

    public init(name: String, summary: String, scope: Scope) {
        self.name = name
        self.summary = summary
        self.scope = scope
    }

    // What goes in the prompt: the name after its slash.
    public var typed: String { "/\(name)" }
}

extension StationCommands {
    // MARK: - Sending a composed prompt

    // Hands the prompt to the session's runner as the GUI's composer does: the text, the
    // files by their path on this machine, and instructions for this prompt alone. Each
    // file must be there now; a prompt with files or instructions needs no text.
    public func sendPrompt(_ sessionID: String, _ prompt: RemotePrompt) throws(StationRefusal) {
        guard let id = UUID(uuidString: sessionID), store.session(id) != nil else { throw .noSession }
        let text = prompt.text.trimmed
        let instructions = prompt.customInstructions?.trimmed ?? ""
        var attachments: [Attachment] = []
        for path in prompt.attachments {
            let expanded = (path.trimmed as NSString).expandingTildeInPath
            var isFolder: ObjCBool = false
            guard expanded.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: expanded, isDirectory: &isFolder) else {
                throw StationRefusal("There is no file at \(path).")
            }
            attachments.append(Attachment(url: URL(fileURLWithPath: expanded, isDirectory: isFolder.boolValue)))
        }
        guard !text.isEmpty || !attachments.isEmpty || !instructions.isEmpty else { throw .emptyPrompt }
        guard text.count <= 100_000, instructions.count <= 100_000 else { throw .longPrompt }
        try admitTurn()
        runner.send(text, attachments: attachments, customInstructions: instructions.isEmpty ? nil : instructions,
                    sessionID: id, store: store)
        runner.composer.clearDraft(id)
    }

    // MARK: - Slash commands

    // What the session's agent can be sent after a slash, nearest first, as the GUI's
    // command menu lists them: what the app answers, the checkouts' own files, the
    // person's, then what the CLI ships.
    public func listCommands(_ sessionID: String) throws(StationRefusal) -> [RemoteSlashCommand] {
        let session = try runSession(sessionID)
        return AgentCommands.all(for: session.agent, workingDirectories: store.workingDirectories(for: session),
                                 home: agentCommandsHome, environment: agentCommandsEnvironment)
            .map { command in
                let scope: RemoteSlashCommand.Scope = switch command.scope {
                case .app: .app
                case .builtIn: .builtIn
                case .user: .user
                case .project: .project
                }
                return RemoteSlashCommand(name: command.name, summary: command.summary, scope: scope)
            }
    }

    // MARK: - Run settings

    // What the session's next turn runs with, as the GUI's bar under the composer shows
    // it. Nil-free: a setting that follows the app's default reads "".
    public func readRunSettings(_ sessionID: String) throws(StationRefusal) -> RemoteSettings {
        let session = try runSession(sessionID)
        return runSettings(of: session)
    }

    // Changes one run setting from the next turn on, and answers with them all as they
    // now stand. A model the effort chosen does not go with drops the effort back to the
    // default, as the GUI does.
    public func changeRunSetting(_ sessionID: String, _ id: String,
                                 to value: String) throws(StationRefusal) -> RemoteSettings {
        let session = try runSession(sessionID)
        let agent = session.agent
        guard id != "agent" else {
            throw StationRefusal("This session always runs on \(agent.title).")
        }
        guard let setting = runSettings(of: session).setting(id) else {
            throw StationRefusal("This session has no setting called \(id).")
        }
        guard setting.choices.contains(where: { $0.value == value }) else {
            throw StationRefusal("That is not one of the choices for \(setting.title.lowercased()).")
        }
        let chosen = value.isEmpty ? nil : value
        var settings = session.settings ?? SessionSettings()
        switch id {
        case "model":
            settings.model = chosen
            if let effort = settings.effort, runner.validEffort(effort, for: agent, model: chosen) == nil {
                settings.effort = nil
            }
        case "effort": settings.effort = chosen
        case "permissionMode": settings.permissionMode = chosen.flatMap(PermissionMode.init(rawValue:))
        case "codexSandbox": settings.codexSandboxMode = chosen.flatMap(CodexSandboxMode.init(rawValue:))
        case "copilotAccess": settings.copilotAccessMode = chosen.flatMap(CopilotAccessMode.init(rawValue:))
        case "designAmbition": settings.designAmbition = chosen.flatMap(DesignAmbition.init(rawValue:))
        default: break
        }
        store.setSettings(settings, for: session.id)
        return runSettings(of: store.session(session.id) ?? session)
    }

    private func runSession(_ sessionID: String) throws(StationRefusal) -> ChatSession {
        guard let id = UUID(uuidString: sessionID), let session = store.session(id) else { throw .noSession }
        return session
    }

    private func runSettings(of session: ChatSession) -> RemoteSettings {
        let agent = session.agent
        let settings = session.settings ?? SessionSettings()
        let defaults = runner.defaults(for: agent)
        var rows = [RemoteSetting(id: "agent", title: "Agent",
                                  detail: "This session always runs on \(agent.title).",
                                  value: agent.rawValue,
                                  choices: [RemoteSettingChoice(value: agent.rawValue, title: agent.title)])]

        let model = runner.validModel(settings.model, for: agent)
        let lastRan = session.usage?.model(for: agent).map { ModelChoice.shortName(of: $0) }
        let modelDefault = lastRan.map { "\(agent.title) default (\($0))" } ?? "\(agent.title) default"
        rows.append(RemoteSetting(
            id: "model", title: "Model",
            detail: session.hasAgentConversation
                ? "From the next turn. Cached context may not carry over to another model."
                : "The model the next turn uses.",
            value: model ?? "",
            choices: [RemoteSettingChoice(value: "", title: modelDefault)]
                + runner.modelOptions(for: agent).compactMap { option in
                    option.id.map { RemoteSettingChoice(value: $0, title: option.title) }
                }))

        let levels = runner.effortOptions(for: agent, model: model).compactMap(\.id)
        let effortDefault = runner.validEffort(defaults.effort, for: agent, model: model)
            .map { runner.effortTitle($0, for: agent, model: model) } ?? "\(agent.title) settings"
        rows.append(RemoteSetting(
            id: "effort", title: "Effort", detail: "How long the model thinks before it answers.",
            value: runner.validEffort(settings.effort, for: agent, model: model) ?? "",
            choices: [RemoteSettingChoice(value: "", title: "Code Station default (\(effortDefault))")]
                + levels.map { RemoteSettingChoice(value: $0, title: runner.effortTitle($0, for: agent, model: model)) }))

        switch agent {
        case .claudeCode:
            let appDefault = defaults.permissionMode ?? .fallback
            rows.append(RemoteSetting(
                id: "permissionMode", title: "Asks before",
                detail: (settings.permissionMode ?? appDefault).detail,
                value: settings.permissionMode?.rawValue ?? "",
                choices: [RemoteSettingChoice(value: "", title: "Default (\(appDefault.shortTitle))")]
                    + PermissionMode.allCases.map { RemoteSettingChoice(value: $0.rawValue, title: $0.shortTitle) }))
        case .codex:
            let appDefault = defaults.codexSandboxMode ?? .workspaceWrite
            let override = settings.codexSandboxMode
            rows.append(RemoteSetting(
                id: "codexSandbox", title: "Access", detail: (override ?? appDefault).detail,
                value: override?.rawValue ?? "",
                choices: [RemoteSettingChoice(value: "", title: "Default (\(appDefault.title))")]
                    + CodexSandboxMode.allCases.map { RemoteSettingChoice(value: $0.rawValue, title: $0.title) }))
        case .copilot:
            let appDefault = defaults.copilotAccessMode ?? .workspace
            let override = settings.copilotAccessMode
            rows.append(RemoteSetting(
                id: "copilotAccess", title: "Access", detail: (override ?? appDefault).detail,
                value: override?.rawValue ?? "",
                choices: [RemoteSettingChoice(value: "", title: "Default (\(appDefault.title))")]
                    + CopilotAccessMode.allCases.map { RemoteSettingChoice(value: $0.rawValue, title: $0.title) }))
        }

        if session.mode == .design {
            let appDefault = Preferences.designAmbition(in: preferences)
            let override = settings.designAmbition
            rows.append(RemoteSetting(
                id: "designAmbition", title: "Design ambition", detail: (override ?? appDefault).detail,
                value: override?.rawValue ?? "",
                choices: [RemoteSettingChoice(value: "", title: "Code Station default (\(appDefault.title))")]
                    + DesignAmbition.allCases.map { RemoteSettingChoice(value: $0.rawValue, title: $0.title) }))
        }

        return RemoteSettings(sections: [RemoteSettingSection(title: "Next turn", settings: rows)],
                              agents: [], update: nil)
    }
}

// MARK: - The in-process client

extension StationConnection {
    public func sendPrompt(_ sessionID: String, _ prompt: RemotePrompt) throws(StationRefusal) {
        try host.sendPrompt(sessionID, prompt)
    }

    public func listCommands(_ sessionID: String) throws(StationRefusal) -> [RemoteSlashCommand] {
        try host.listCommands(sessionID)
    }

    public func readRunSettings(_ sessionID: String) throws(StationRefusal) -> RemoteSettings {
        try host.readRunSettings(sessionID)
    }

    public func changeRunSetting(_ sessionID: String, _ id: String,
                                 to value: String) throws(StationRefusal) -> RemoteSettings {
        try host.changeRunSetting(sessionID, id, to: value)
    }
}

// MARK: - The socket client

extension StationSocketClient {
    public func sendPrompt(_ sessionID: String, _ prompt: RemotePrompt) async throws(StationRefusal) {
        _ = try await call(.sendComposedPrompt(sessionID: sessionID, prompt: prompt), as: StationWire.Nothing.self)
    }

    public func listCommands(_ sessionID: String) async throws(StationRefusal) -> [RemoteSlashCommand] {
        try await call(.listCommands(sessionID: sessionID), as: [RemoteSlashCommand].self)
    }

    public func readRunSettings(_ sessionID: String) async throws(StationRefusal) -> RemoteSettings {
        try await call(.readRunSettings(sessionID: sessionID), as: RemoteSettings.self)
    }

    public func changeRunSetting(_ sessionID: String, _ id: String,
                                 to value: String) async throws(StationRefusal) -> RemoteSettings {
        try await call(.changeRunSetting(sessionID: sessionID, id: id, value: value), as: RemoteSettings.self)
    }
}

// MARK: - The command menu

extension Array where Element == RemoteSlashCommand {
    // The commands a word typed after a slash points at, nearest first, matched as the
    // GUI's menu matches them (`SlashQuery.matches`).
    public func matching(_ query: String) -> [RemoteSlashCommand] {
        let byName = Dictionary(map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let commands = map { AgentCommand(name: $0.name, summary: $0.summary, scope: .app) }
        return SlashQuery.matches(query, in: commands).compactMap { byName[$0.name] }
    }
}
