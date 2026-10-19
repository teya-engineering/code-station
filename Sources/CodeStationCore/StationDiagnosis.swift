import Foundation

// Troubleshooting, as the GUI's Troubleshoot sheet and tab start it, for a client: the
// choices a diagnosis offers (the deployments the site file names, the MCP servers each
// one reaches, the skills the agent can load), and starting a diagnosis from a brief in
// a session that already exists or in a new one in a project or workspace.
//
// Commands:
// - diagnosis options: the choices above, for a session or a new diagnosis on an agent.
// - start diagnosis: marks the session as troubleshooting, keeps it to the servers the
//   chosen environment reaches, and sends the brief (`TroubleshootRequest`) as its next
//   prompt, with the evidence attached by path. Answers with the session's id.

public struct RemoteDiagnosisOptions: Codable, Equatable, Sendable {
    public var environments: [TroubleshootEnvironment]
    // The MCP servers set up on the host, each with the environment it is tagged with.
    public var servers: [MCPConfigFile.Server]
    // The skills the agent has installed, as far as the host can tell.
    public var skills: [String]
    // The agent the diagnosis runs on, and the projects it looks at (a session's own).
    public var agent: AgentKind
    public var projects: [String]

    public init(environments: [TroubleshootEnvironment], servers: [MCPConfigFile.Server],
                skills: [String], agent: AgentKind, projects: [String]) {
        self.environments = environments
        self.servers = servers
        self.skills = skills
        self.agent = agent
        self.projects = projects
    }

    // The servers a diagnosis in `environment` is offered, by name.
    public func servers(in environment: TroubleshootEnvironment) -> [String] {
        servers.filter { environment.includes(tag: $0.environment, among: environments) }.map(\.name)
    }
}

public struct RemoteDiagnosis: Codable, Equatable, Sendable {
    public enum Target: Codable, Equatable, Sendable {
        // The session's own Troubleshoot tab.
        case session(String)
        // A new session in the project's folder, or across a workspace's projects.
        case project(String)
        case workspace(String)
    }

    public var target: Target
    // The agent a new session runs on; nil for the app's default. A session keeps its own.
    public var agent: AgentKind?
    public var problem: String
    // The environment's name, as the options list it.
    public var environment: String
    public var incidentTime: String
    // Evidence, by path on the host.
    public var attachments: [String]
    public var skills: [String]
    public var mcpServersEnabled: Bool

    public init(target: Target, agent: AgentKind? = nil, problem: String, environment: String,
                incidentTime: String = "", attachments: [String] = [], skills: [String] = [],
                mcpServersEnabled: Bool = true) {
        self.target = target
        self.agent = agent
        self.problem = problem
        self.environment = environment
        self.incidentTime = incidentTime
        self.attachments = attachments
        self.skills = skills
        self.mcpServersEnabled = mcpServersEnabled
    }
}

// Where a station finds what a diagnosis offers. The GUI hands over its own site
// defaults, MCP settings and skills; a host without them reads the site file and the
// shared MCP file, and asks Codex and Copilot which servers they have switched on.
public struct DiagnosisSupport {
    public var environments: @MainActor () -> [TroubleshootEnvironment]
    public var servers: @MainActor () -> [MCPConfigFile.Server]
    public var skills: @MainActor (AgentKind) async -> [String]
    // The servers the agent has switched on in a folder (Codex and Copilot only).
    public var enabledServers: @MainActor (AgentKind, String) async throws -> [DisabledMCPServer]

    public init(environments: @escaping @MainActor () -> [TroubleshootEnvironment],
                servers: @escaping @MainActor () -> [MCPConfigFile.Server],
                skills: @escaping @MainActor (AgentKind) async -> [String],
                enabledServers: @escaping @MainActor (AgentKind, String) async throws -> [DisabledMCPServer]) {
        self.environments = environments
        self.servers = servers
        self.skills = skills
        self.enabledServers = enabledServers
    }

    public static func live(mcpConfigURL: URL = MCPConfigFile.standardURL,
                            siteFiles: [URL] = TroubleshootEnvironment.siteSearchPaths()) -> DiagnosisSupport {
        DiagnosisSupport(
            environments: { TroubleshootEnvironment.site(from: siteFiles) },
            servers: { MCPConfigFile.servers(at: mcpConfigURL) },
            skills: { _ in [] },
            enabledServers: { agent, directory in try await AgentMCPServers.enabled(for: agent, in: directory) })
    }
}

extension StationCommands {
    // For a session's Troubleshoot tab (its agent and projects), or for a new diagnosis
    // on `agent` (the app's default when nil).
    public func diagnosisOptions(sessionID: String?, agent: AgentKind?) async throws(StationRefusal) -> RemoteDiagnosisOptions {
        followSharedDefaults()
        var chosen = agent ?? runner.agent
        var projects: [String] = []
        if let sessionID {
            guard let id = UUID(uuidString: sessionID), let session = store.session(id) else { throw .noSession }
            chosen = session.agent
            projects = store.checkoutProjects(for: session).compactMap { store.project($0.projectID)?.name }
        }
        return RemoteDiagnosisOptions(environments: diagnosis.environments(), servers: diagnosis.servers(),
                                      skills: await diagnosis.skills(chosen), agent: chosen, projects: projects)
    }

    public func startDiagnosis(_ request: RemoteDiagnosis) async throws(StationRefusal) -> String {
        try admitTurn()
        followSharedDefaults()
        let environments = diagnosis.environments()
        guard let environment = environments.first(where: { $0.name == request.environment }) else {
            throw StationRefusal("The site names no environment called \(request.environment).")
        }
        let attachments = try Self.evidence(request.attachments)
        guard !request.problem.isBlank || !attachments.isEmpty else {
            throw StationRefusal("Describe the problem or attach evidence to continue.")
        }

        // Where it runs: the session named, or the folders a new one will work in.
        let existing: ChatSession?
        let agent: AgentKind
        let projects: [Project]
        switch request.target {
        case .session(let sessionID):
            guard let id = UUID(uuidString: sessionID), let session = store.session(id) else { throw .noSession }
            existing = session
            agent = session.agent
            projects = store.checkoutProjects(for: session).compactMap { store.project($0.projectID) }
        case .project(let projectID):
            guard let id = UUID(uuidString: projectID), let project = store.project(id) else {
                throw StationRefusal("That project is no longer in the app.")
            }
            existing = nil
            agent = request.agent ?? runner.agent
            projects = [project]
        case .workspace(let workspaceID):
            guard let id = UUID(uuidString: workspaceID), let workspace = store.workspace(id) else {
                throw StationRefusal("That workspace is no longer in the app.")
            }
            let members = workspace.projectIDs.compactMap(store.project)
            guard members.count == workspace.projectIDs.count else {
                throw StationRefusal("One of the workspace projects is no longer available.")
            }
            existing = nil
            agent = request.agent ?? runner.agent
            projects = members
        }
        guard runner.isAvailable(agent) else { throw StationRefusal("\(agent.title) CLI was not found on PATH.") }
        guard let lead = projects.first else { throw StationRefusal("The diagnosis has no project to look at.") }

        // The servers the agent must not see, worked out before anything is made, so a
        // failure here leaves nothing half done.
        let managed = diagnosis.servers()
        let selected = managed.filter { environment.includes(tag: $0.environment, among: environments) }.map(\.name)
        var disabled: [DisabledMCPServer] = []
        if agent != .claudeCode, !request.mcpServersEnabled || !managed.isEmpty {
            let directory = existing.flatMap { store.workingDirectories(for: $0).first } ?? lead.path
            do {
                let enabled = try await diagnosis.enabledServers(agent, directory)
                disabled = request.mcpServersEnabled ? enabled.filter { !selected.contains($0.name) } : enabled
            } catch {
                throw StationRefusal("Could not filter MCP servers: \(error.localizedDescription)")
            }
        }

        let session: ChatSession
        if let existing {
            session = existing
        } else {
            let seed = ProjectStore.SessionSeed(agent: agent, model: runner.defaults(for: agent).model,
                                                isTroubleshooting: true)
            let made: Result<ChatSession, PersistenceFailure>
            if case .workspace(let workspaceID) = request.target, let id = UUID(uuidString: workspaceID) {
                made = store.insertSession(in: id, projects: projects.map {
                    SessionProject(projectID: $0.id, worktreePath: nil, worktreeBranch: nil)
                }, seed: seed)
            } else {
                made = store.insertSession(in: lead.id, seed: seed)
            }
            switch made {
            case .success(let created): session = created
            case .failure(let failure): throw StationRefusal(failure.message)
            }
        }

        var settings = store.session(session.id)?.settings ?? SessionSettings()
        settings.mcpServersEnabled = request.mcpServersEnabled
        settings.allowedMCPServerNames = request.mcpServersEnabled && !managed.isEmpty ? selected : nil
        settings.disabledMCPServers = disabled.isEmpty ? nil : disabled
        settings.disabledMCPServerNames = nil
        store.setSettings(settings, for: session.id)
        store.markTroubleshooting(session.id)

        let brief = TroubleshootRequest(
            problem: request.problem, incidentTime: request.incidentTime, environment: environment,
            projects: projects.map(\.name),
            skills: request.skills.map(\.trimmed).filter { !$0.isEmpty },
            mcpServersEnabled: request.mcpServersEnabled,
            mcpServerNames: request.mcpServersEnabled ? selected : [], agent: agent)
        runner.send(brief.userInput, attachments: attachments, customInstructions: brief.customInstructions,
                    sessionID: session.id, store: store)
        return session.id.uuidString
    }

    // Files named by their path on this machine, `~` expanded; each must be there now.
    static func evidence(_ paths: [String]) throws(StationRefusal) -> [Attachment] {
        var attachments: [Attachment] = []
        for path in paths where !path.isBlank {
            let expanded = (path.trimmed as NSString).expandingTildeInPath
            var isFolder: ObjCBool = false
            guard expanded.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: expanded, isDirectory: &isFolder) else {
                throw StationRefusal("There is no file at \(path).")
            }
            attachments.append(Attachment(url: URL(fileURLWithPath: expanded, isDirectory: isFolder.boolValue)))
        }
        return attachments
    }
}

// MARK: - The in-process client

extension StationConnection {
    public func diagnosisOptions(sessionID: String?, agent: AgentKind?) async throws(StationRefusal) -> RemoteDiagnosisOptions {
        try await host.diagnosisOptions(sessionID: sessionID, agent: agent)
    }

    public func startDiagnosis(_ request: RemoteDiagnosis) async throws(StationRefusal) -> String {
        try await host.startDiagnosis(request)
    }
}

// MARK: - The socket client

extension StationSocketClient {
    public func diagnosisOptions(sessionID: String?, agent: AgentKind?) async throws(StationRefusal) -> RemoteDiagnosisOptions {
        try await call(.diagnosisOptions(sessionID: sessionID, agent: agent), as: RemoteDiagnosisOptions.self)
    }

    public func startDiagnosis(_ request: RemoteDiagnosis) async throws(StationRefusal) -> String {
        try await call(.startDiagnosis(request: request), as: String.self)
    }
}
