import Foundation

public struct AgentServerLaunch: Sendable {
    public enum LaunchError: Error { case unsupportedAgent }

    public let agent: AgentKind
    public let arguments: [String]
    public let sessionParameters: Data
    public let resume: Bool
    public let fullAccess: Bool
    public let directories: [String]

    public init(configuration: AgentLaunchConfiguration, directory: String) throws {
        agent = configuration.agent
        resume = configuration.resume != nil
        directories = configuration.addDirectories
        var parameters: [String: Any] = [:]
        if let model = configuration.model { parameters["model"] = model }

        switch agent {
        case .codex:
            fullAccess = configuration.codexSandbox == .fullAccess
            arguments = ["app-server"] + configuration.codexOverrides
                + (configuration.codexSandbox == .approveForMe ? AgentLaunchConfiguration.codexAutoReview : [])
            parameters["cwd"] = directory
            if fullAccess { parameters["sandbox"] = "danger-full-access" }
            if configuration.codexSandbox != .approveForMe { parameters["approvalPolicy"] = "never" }
            parameters["runtimeWorkspaceRoots"] = [directory] + directories
            if let resumeID = configuration.resume { parameters["threadId"] = resumeID }
            else { parameters["experimentalRawEvents"] = false }
        case .copilot:
            fullAccess = configuration.copilotAccess == .fullAccess
            arguments = ["--headless", "--stdio", "--no-auto-update", "--log-level", "none"]
                + configuration.copilotPermissions
            parameters["workingDirectory"] = directory
            parameters["streaming"] = false
            parameters["requestPermission"] = true
            parameters["requestUserInput"] = true
            if configuration.prompt != nil || configuration.additionalSystemPrompt != nil {
                parameters["initialPrompt"] = configuration.copilotPrompt
            }
            parameters["additionalDirectories"] = directories
            parameters["sessionId"] = configuration.resume ?? configuration.newSessionID
            parameters["reasoningEffort"] = configuration.effort
        case .claudeCode:
            throw LaunchError.unsupportedAgent
        }
        sessionParameters = try JSONSerialization.data(withJSONObject: parameters)
    }
}
