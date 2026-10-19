import Foundation

// The brief a diagnosis starts from: what the person says is wrong, as the agent's first
// message, and the troubleshooting context as custom instructions beside it. The GUI's
// Troubleshoot sheet and tab and a client's diagnosis command all write it here.
public struct TroubleshootRequest: Equatable, Sendable {
    public let problem: String
    public let incidentTime: String
    public let environment: TroubleshootEnvironment
    public let projects: [String]
    public let skills: [String]
    public let mcpServersEnabled: Bool
    public let mcpServerNames: [String]
    public let agent: AgentKind

    public init(problem: String, incidentTime: String = "", environment: TroubleshootEnvironment, projects: [String],
         skills: [String] = [], mcpServersEnabled: Bool, mcpServerNames: [String] = [],
         agent: AgentKind) {
        self.problem = problem
        self.incidentTime = incidentTime
        self.environment = environment
        self.projects = projects
        self.skills = skills
        self.mcpServersEnabled = mcpServersEnabled
        self.mcpServerNames = mcpServerNames
        self.agent = agent
    }

    public var userInput: String {
        let description = problem.isBlank
            ? "Troubleshoot the problem shown in the attached files."
            : problem.trimmed
        guard !incidentTime.isBlank else { return description }
        return description + "\n\nIncident time window (as supplied): " + incidentTime.trimmed
    }

    public var customInstructions: String {
        let projectText = projects.joined(separator: ", ")
        let mcpText: String
        if !mcpServersEnabled {
            mcpText = "MCP servers are disabled for this diagnosis."
        } else if mcpServerNames.isEmpty {
            mcpText = "MCP servers are enabled. Use them when they provide relevant logs, metrics, or service context."
        } else {
            let names = mcpServerNames.sorted().joined(separator: ", ")
            mcpText = """
            MCP servers are enabled: \(names). Their tools may be deferred from the initial tool list. Search the available tool catalogue for these server names before concluding that a server or tool is unavailable.
            """
        }
        let skillText: String
        if skills.isEmpty {
            skillText = "No skills were picked for this diagnosis."
        } else {
            let names = skills.sorted().map { "`\($0)`" }.joined(separator: ", ")
            skillText = """
            Skills to use: \(names). Load each one before the first step it covers, whatever the agent calls skills.
            """
        }
        // Claude is told how to draw a chart in its system prompt. The others have no
        // such channel, and a diagnosis is where a chart earns its place most often, so
        // the shape travels with the brief instead.
        let chartText = agent == .claudeCode
            ? ""
            : "\n\n\(TranscriptChartSpec.agentInstructions)"
        let dangerText = environment.isDangerous
            ? " Treat this environment as live: do not mutate data, configuration, deployments, or running services."
            : ""

        return """
        Troubleshooting context:
        - Environment: \(environment.promptTitle)
        - Projects: \(projectText)
        - \(skillText)
        - \(mcpText)

        Investigate the problem and use read-only checks first. Do not change code or configuration.\(dangerText) Explain the likely root cause, cite the evidence you found, and give concrete next steps. If a fix is needed, propose it and wait for a follow-up before applying it. Chart the measurements the root cause rests on.\(chartText)
        """
    }
}
