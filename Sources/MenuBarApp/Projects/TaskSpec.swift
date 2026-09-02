import Foundation

// What a task does when it is run: the prompt handed to a fresh session, and the run
// choices that session starts with. Nil choices follow the app defaults at run time.
// Only ad-hoc projects carry one.
//
// A prompt can leave holes for the run to fill - see TaskTemplate. `inputs` says how each
// hole is asked for, and `lastValues` is what the last run put in them, so running the
// same thing again is a confirmation rather than a retype.
struct TaskSpec: Codable, Equatable, Sendable {
    var prompt: String
    var agent: AgentKind?
    var agentAvatarName: String?
    var model: String?
    var effort: String?
    var permissionMode: String?
    var codexSandboxMode: String?
    var inputs: [TaskInput] = []
    var lastValues: [String: String] = [:]
    var schedule: TaskSchedule?

    init(prompt: String, agent: AgentKind? = nil, agentAvatarName: String? = nil,
         model: String? = nil, effort: String? = nil, permissionMode: String? = nil,
         codexSandboxMode: String? = nil, inputs: [TaskInput] = [],
         lastValues: [String: String] = [:], schedule: TaskSchedule? = nil) {
        self.prompt = prompt
        self.agent = agent
        self.agentAvatarName = agentAvatarName
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.codexSandboxMode = codexSandboxMode
        self.inputs = inputs
        self.lastValues = lastValues
        self.schedule = schedule
    }

    // Tasks saved before a prompt could ask for anything hold neither list.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decode(String.self, forKey: .prompt)
        agent = try container.decodeIfPresent(AgentKind.self, forKey: .agent)
        agentAvatarName = try container.decodeIfPresent(String.self, forKey: .agentAvatarName)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        codexSandboxMode = try container.decodeIfPresent(String.self, forKey: .codexSandboxMode)
        inputs = try container.decodeIfPresent([TaskInput].self, forKey: .inputs) ?? []
        lastValues = try container.decodeIfPresent([String: String].self, forKey: .lastValues)
            ?? [:]
        schedule = try container.decodeIfPresent(TaskSchedule.self, forKey: .schedule)
    }
}
