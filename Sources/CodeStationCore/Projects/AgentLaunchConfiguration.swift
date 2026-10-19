import Foundation

public struct AgentLaunchConfiguration: Sendable {
    public let agent: AgentKind
    public let model: String?
    public let effort: String?
    public let codexSandbox: CodexSandboxMode
    public let copilotAccess: CopilotAccessMode
    public let permissionMode: String
    public let settings: SessionSettings
    public let addDirectories: [String]
    public let writableRoots: [String]
    public let resume: String?
    public let newSessionID: String?
    public let prompt: String?
    public let mcpConfigPath: String?
    public let additionalSystemPrompt: String?
    public let suggestsPrompts: Bool

    public init(agent: AgentKind = .claudeCode,
         settings: SessionSettings, defaults: SessionSettings,
         addDirectories: [String] = [], writableRoots: [String] = [],
         resume: String? = nil, newSessionID: String? = nil, prompt: String? = nil,
         mcpConfigPath: String? = nil, additionalSystemPrompt: String? = nil,
         suggestsPrompts: Bool = false, discovered: [ModelChoice.Option]? = nil) {
        self.agent = agent
        self.settings = settings
        // A session keeps its model until the user changes it, even if the app default changes.
        model = ModelChoice.valid(settings.model, for: agent, discovered: discovered)
        effort = EffortChoice.valid(settings.effort ?? defaults.effort, for: agent,
                                    model: model, discovered: discovered)
        codexSandbox = (settings.codexSandboxMode ?? defaults.codexSandboxMode ?? .workspaceWrite)
        copilotAccess = (settings.copilotAccessMode ?? defaults.copilotAccessMode ?? .workspace)
        permissionMode = (settings.permissionMode ?? defaults.permissionMode ?? .fallback).rawValue
        self.addDirectories = addDirectories
        self.writableRoots = writableRoots
        self.resume = resume.flatMap { $0.isEmpty ? nil : $0 }
        self.newSessionID = newSessionID.flatMap { $0.isEmpty ? nil : $0 }
        self.prompt = prompt
        self.mcpConfigPath = mcpConfigPath
        self.additionalSystemPrompt = additionalSystemPrompt
        self.suggestsPrompts = suggestsPrompts
    }

    public var copilotPrompt: String {
        [additionalSystemPrompt, prompt].compactMap { $0 }.joined(separator: "\n\n")
    }

    public var arguments: [String] {
        switch agent {
        case .claudeCode:
            let systemPrompt = [AgentInstructions.appendedSystemPrompt, additionalSystemPrompt]
                .compactMap { $0 }.joined(separator: "\n\n")
            // Streaming input lets the app answer permission and user-input requests.
            var arguments = ["-p", "--output-format", "stream-json", "--input-format", "stream-json",
                             "--permission-prompt-tool", "stdio", "--verbose",
                             "--permission-mode", permissionMode,
                             "--append-system-prompt", systemPrompt]
            if let model { arguments += ["--model", model] }
            if let effort { arguments += ["--effort", effort] }
            if suggestsPrompts { arguments += ["--prompt-suggestions", "true"] }
            if settings.mcpServersEnabled == false {
                arguments += ["--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
            } else if let mcpConfigPath {
                arguments += ["--strict-mcp-config", "--mcp-config", mcpConfigPath]
            }
            if !addDirectories.isEmpty { arguments += ["--add-dir"] + addDirectories }
            // Forking keeps each checkpoint's conversation intact for rewinding.
            if let resume { arguments += ["--resume", resume, "--fork-session"] }
            return arguments
        case .codex:
            var arguments = ["exec"]
            if let resume { arguments += ["resume", resume] }
            arguments += ["--json", "--skip-git-repo-check"] + codexOverrides
            switch codexSandbox {
            case .workspaceWrite: break
            case .approveForMe:
                arguments += resume == nil ? ["--approve-for-me"] : Self.codexAutoReview
            case .fullAccess:
                arguments.append("--dangerously-bypass-approvals-and-sandbox")
            }
            if let model { arguments += ["--model", model] }
            // The resume subcommand accepts writable_roots but not --add-dir.
            if resume == nil {
                for directory in addDirectories { arguments += ["--add-dir", directory] }
            }
            // Stdin keeps prompts beginning with a dash from being read as flags.
            arguments.append("-")
            return arguments
        case .copilot:
            var arguments = ["-p", copilotPrompt, "--output-format", "json",
                             "--no-auto-update", "--no-color", "--no-ask-user"]
            if let resume { arguments += ["--resume", resume] }
            else if let newSessionID { arguments += ["--session-id", newSessionID] }
            arguments += copilotPermissions
            if let model { arguments += ["--model", model] }
            if let effort { arguments += ["--effort", effort] }
            for directory in addDirectories { arguments += ["--add-dir", directory] }
            return arguments
        }
    }

    public var codexOverrides: [String] {
        var arguments = ["-c", "model_reasoning_summary=\"detailed\""]
        if let additionalSystemPrompt {
            arguments += ["-c", "developer_instructions=\(Self.tomlQuoted(additionalSystemPrompt))"]
        }
        if codexSandbox != .fullAccess {
            arguments += ["-c", "sandbox_mode=\"workspace-write\""]
            // Worktrees keep their Git metadata outside the working directory.
            if !writableRoots.isEmpty {
                let roots = writableRoots.map(Self.tomlQuoted).joined(separator: ",")
                arguments += ["-c", "sandbox_workspace_write.writable_roots=[\(roots)]"]
            }
        }
        if let effort { arguments += ["-c", "model_reasoning_effort=\(Self.tomlQuoted(effort))"] }
        if let override = Self.disabledMCPServersOverride(settings.disabledMCPServers ?? []) {
            arguments += ["-c", override]
        }
        return arguments
    }

    public static let codexAutoReview = ["-c", "approval_policy=\"on-failure\"",
                                 "-c", "approvals_reviewer=\"auto_review\""]

    public var copilotPermissions: [String] {
        var arguments = [copilotAccess == .fullAccess ? "--allow-all" : "--allow-all-tools"]
        if settings.mcpServersEnabled == false { arguments.append("--disable-builtin-mcps") }
        for server in settings.disabledMCPServers ?? [] where !server.name.isEmpty {
            arguments += ["--disable-mcp-server", server.name]
        }
        return arguments
    }

    private static func tomlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    // A plugin-provided server may appear in `codex mcp list` without existing in
    // config.toml. Supplying only `enabled=false` creates a transport-less table that
    // Codex rejects before startup. One inline table preserves every disabled entry and
    // gives it an inert transport, which also prevents a plugin from adding it back.
    static func disabledMCPServersOverride(
        _ servers: [DisabledMCPServer]
    ) -> String? {
        let entries = servers
            .filter { !$0.name.isEmpty }
            .sorted { $0.name < $1.name }
            .map { server in
                let transport = switch server.transport {
                case .stdio:
                    "command=\"/usr/bin/false\""
                case .streamableHTTP:
                    "url=\"https://disabled.invalid\""
                }
                return "\(tomlQuoted(server.name))={enabled=false,\(transport)}"
            }
        guard !entries.isEmpty else { return nil }
        return "mcp_servers={\(entries.joined(separator: ","))}"
    }

}
