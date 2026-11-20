import Foundation

struct AgentServerLaunch: Sendable {
    enum LaunchError: Error { case unsupportedAgent }

    let agent: AgentKind
    let arguments: [String]
    let sessionParameters: Data
    let resume: Bool
    let fullAccess: Bool
    let directories: [String]
    // The folder the agent runs in, which Kiro's edits are measured against when the
    // session's access mode lets edits through without asking.
    let directory: String
    let permissionMode: PermissionMode
    // The model to switch to once the session is open. Kiro takes it as a session
    // option rather than with the session's own parameters.
    let model: String?

    init(configuration: AgentLaunchConfiguration, directory: String) throws {
        agent = configuration.agent
        resume = configuration.resume != nil
        directories = configuration.addDirectories
        self.directory = directory
        permissionMode = PermissionMode(stored: configuration.permissionMode)
        model = configuration.model
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
        case .kiro:
            // Pinned to the V3 engine: the one the protocol here was written against, and
            // Kiro's default. V2 frames its requests and extensions differently.
            fullAccess = false
            arguments = ["acp", "--agent-engine", "v3"]
            parameters = ["cwd": directory, "mcpServers": [[String: Any]]()]
            if let resumeID = configuration.resume { parameters["sessionId"] = resumeID }
            if configuration.prompt != nil || configuration.additionalSystemPrompt != nil {
                parameters["initialPrompt"] = configuration.copilotPrompt
            }
        case .claudeCode:
            throw LaunchError.unsupportedAgent
        }
        sessionParameters = try JSONSerialization.data(withJSONObject: parameters)
    }
}
