import Foundation

// Starting a session, as the station commands façade hands it out: the choices a
// new-session form offers (the agents on this Mac, each with its models and the model it
// starts on), and the request a front end sends back. They are new kinds next to the
// phone remote's, written the same way: a fixed type and version on the wire, plain
// Codable values. The request reuses the phone's `createSession` words (`projectID`,
// `worktree`) and adds the agent and model the phone has no room to choose.

public struct RemoteSessionOptions: Codable, Equatable, Sendable {
    public let type = "sessionOptions"
    public let version = 1
    // Every agent the app knows, installed or not, in the app's order.
    public let agents: [RemoteAgentChoice]
    // The agent a new session starts on unless another is chosen: the app's own agent
    // when it is installed, otherwise the first one that is. Nil when none is.
    public let defaultAgent: AgentKind?

    public init(agents: [RemoteAgentChoice], defaultAgent: AgentKind?) {
        self.agents = agents
        self.defaultAgent = defaultAgent
    }

    private enum CodingKeys: String, CodingKey {
        case type, version, agents, defaultAgent
    }

    // The type and version are fixed for this struct, so they are written but not read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agents = try container.decode([RemoteAgentChoice].self, forKey: .agents)
        defaultAgent = try container.decodeIfPresent(AgentKind.self, forKey: .defaultAgent)
    }

    public func agent(_ kind: AgentKind) -> RemoteAgentChoice? {
        agents.first { $0.agent == kind }
    }
}

public struct RemoteAgentChoice: Codable, Equatable, Sendable {
    public let agent: AgentKind
    public let title: String
    public let installed: Bool
    // "Default" (no id: whatever the agent is set to use) first, then the agent's models.
    public let models: [RemoteModelChoice]
    // The model the app's settings start this agent's sessions on. Nil for "Default".
    public let defaultModel: String?

    public init(agent: AgentKind, title: String, installed: Bool,
                models: [RemoteModelChoice], defaultModel: String?) {
        self.agent = agent
        self.title = title
        self.installed = installed
        self.models = models
        self.defaultModel = defaultModel
    }
}

public struct RemoteModelChoice: Codable, Equatable, Sendable {
    public let id: String?
    public let title: String
    public let detail: String

    public init(id: String?, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

// What a front end asks for: a session in this project, on this agent and model, in a
// worktree of its own or in the project folder. A nil model is the agent's own default.
public struct RemoteNewSession: Codable, Equatable, Sendable {
    public let type = "createSession"
    public let version = 1
    public let projectID: String
    public let agent: AgentKind
    public let model: String?
    public let worktree: Bool

    public init(projectID: String, agent: AgentKind, model: String?, worktree: Bool) {
        self.projectID = projectID
        self.agent = agent
        self.model = model
        self.worktree = worktree
    }

    private enum CodingKeys: String, CodingKey {
        case type, version, projectID, agent, model, worktree
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(String.self, forKey: .projectID)
        agent = try container.decode(AgentKind.self, forKey: .agent)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        worktree = try container.decode(Bool.self, forKey: .worktree)
    }
}
