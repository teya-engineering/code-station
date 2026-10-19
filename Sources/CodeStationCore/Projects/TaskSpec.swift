import Foundation

// What a task does when it is run: the prompt handed to a fresh session, and the run
// choices that session starts with. Nil choices follow the app defaults at run time.
// Only ad-hoc projects carry one.
//
// A prompt can leave holes for the run to fill - see TaskTemplate. `inputs` says how each
// hole is asked for, and `lastValues` is what the last run put in them, so running the
// same thing again is a confirmation rather than a retype.
public struct TaskSpec: Codable, Equatable, Sendable {
    public var prompt: String
    public var agent: AgentKind?
    public var agentAvatarName: String?
    public var model: String?
    public var effort: String?
    public var permissionMode: PermissionMode?
    public var codexSandboxMode: CodexSandboxMode?
    public var copilotAccessMode: CopilotAccessMode?
    public var inputs: [TaskInput] = []
    public var lastValues: [String: String] = [:]
    public var schedule: TaskSchedule?

    public init(prompt: String, agent: AgentKind? = nil, agentAvatarName: String? = nil,
         model: String? = nil, effort: String? = nil, permissionMode: PermissionMode? = nil,
         codexSandboxMode: CodexSandboxMode? = nil, copilotAccessMode: CopilotAccessMode? = nil,
         inputs: [TaskInput] = [],
         lastValues: [String: String] = [:], schedule: TaskSchedule? = nil) {
        self.prompt = prompt
        self.agent = agent
        self.agentAvatarName = agentAvatarName
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.codexSandboxMode = codexSandboxMode
        self.copilotAccessMode = copilotAccessMode
        self.inputs = inputs
        self.lastValues = lastValues
        self.schedule = schedule
    }

    // Tasks saved before a prompt could ask for anything hold neither list.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decode(String.self, forKey: .prompt)
        agent = try container.decodeIfPresent(AgentKind.self, forKey: .agent)
        agentAvatarName = try container.decodeIfPresent(String.self, forKey: .agentAvatarName)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
            .map { PermissionMode(rawValue: $0) ?? .fallback }
        codexSandboxMode = try container.decodeIfPresent(String.self, forKey: .codexSandboxMode)
            .map { CodexSandboxMode(rawValue: $0) ?? .workspaceWrite }
        copilotAccessMode = try container.decodeIfPresent(String.self, forKey: .copilotAccessMode)
            .map { CopilotAccessMode(rawValue: $0) ?? .workspace }
        inputs = try container.decodeIfPresent([TaskInput].self, forKey: .inputs) ?? []
        lastValues = try container.decodeIfPresent([String: String].self, forKey: .lastValues)
            ?? [:]
        schedule = try container.decodeIfPresent(TaskSchedule.self, forKey: .schedule)
    }
}
