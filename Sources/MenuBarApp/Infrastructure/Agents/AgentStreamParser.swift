import Foundation

// Reads one line of an agent's output as the events every agent shares. Copilot reports
// usage and errors across several lines, so one parser has to see a whole run.
struct AgentStreamParser: Sendable {
    private let agent: AgentKind
    private let projectPath: String
    private let copilot = CopilotStream()

    init(agent: AgentKind, projectPath: String = "") {
        self.agent = agent
        self.projectPath = projectPath
    }

    func parse(_ line: String) -> [StreamEvent] {
        switch agent {
        case .claudeCode: StreamEvent.parse(line, projectPath: projectPath)
        case .codex: StreamEvent.parseCodex(line)
        case .copilot: copilot.parse(line)
        }
    }
}
