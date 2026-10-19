import Foundation

// The MCP servers Codex or Copilot has switched on for a folder, read from the CLI's own
// list, so a diagnosis can switch off the ones it must not see. Claude Code is handed a
// filtered configuration instead and is never asked. (The GUI's MCP managers read the
// same lists for their own screens.)
public enum AgentMCPServers {
    public struct Failure: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func enabled(for agent: AgentKind, in directory: String) async throws -> [DisabledMCPServer] {
        let command: String
        switch agent {
        case .claudeCode: return []
        case .codex: command = "codex"
        case .copilot: command = "copilot"
        }
        guard let path = ExecutableSearch.resolve(command) else {
            throw Failure(message: "\(agent.title) CLI not found on PATH.")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ExecutableSearch.searchPath
        let result: CommandRunner.Output
        do {
            result = try await CommandRunner.run(executable: path, arguments: ["mcp", "list", "--json"],
                                                 currentDirectory: URL(fileURLWithPath: directory),
                                                 environment: environment, timeout: .seconds(30))
        } catch {
            throw Failure(message: "Could not run \(agent.title): \(error.localizedDescription)")
        }
        guard result.succeeded else {
            let message = result.errorOutput.trimmed
            throw Failure(message: message.isEmpty ? "\(agent.title) could not list its MCP servers." : message)
        }
        let data = Data(result.output.utf8)
        guard let servers = agent == .codex ? codexEnabled(in: data) : copilotEnabled(in: data) else {
            throw Failure(message: "\(agent.title) returned an MCP server list the app could not read.")
        }
        return servers
    }

    // `codex mcp list --json`: an array of servers, each enabled or not, with a command
    // or a URL. A server with neither cannot be switched off by name, so the list is
    // refused rather than read short.
    public static func codexEnabled(in data: Data) -> [DisabledMCPServer]? {
        struct Listed: Decodable {
            struct Transport: Decodable { let command: String?; let url: String? }
            let name: String
            let enabled: Bool
            let transport: Transport?
        }
        guard let servers = try? JSONDecoder().decode([Listed].self, from: data) else { return nil }
        let enabled = servers.filter(\.enabled)
        let snapshots = enabled.compactMap { server -> DisabledMCPServer? in
            if server.transport?.command != nil { return DisabledMCPServer(name: server.name, transport: .stdio) }
            if server.transport?.url != nil { return DisabledMCPServer(name: server.name, transport: .streamableHTTP) }
            return nil
        }
        guard snapshots.count == enabled.count else { return nil }
        return snapshots.sorted { $0.name < $1.name }
    }

    // `copilot mcp list --json`: servers by name under `mcpServers`, local ones with a
    // command, each enabled unless it says otherwise.
    public static func copilotEnabled(in data: Data) -> [DisabledMCPServer]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return nil }
        return servers.compactMap { name, value -> DisabledMCPServer? in
            guard let raw = value as? [String: Any], raw["enabled"] as? Bool ?? true else { return nil }
            return DisabledMCPServer(name: name, transport: raw["command"] is String ? .stdio : .streamableHTTP)
        }.sorted { $0.name < $1.name }
    }
}
