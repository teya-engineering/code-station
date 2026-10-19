import Foundation

// What `codex mcp list --json` prints, read down to the servers that are switched on. A
// run that turns MCP off has to name each of them, with the transport it uses, and the
// CLI is the source of truth for that rather than its TOML file. Nil when a server has no
// transport the run could name, so the caller refuses instead of leaving one running.
public enum CodexMCPListing {
    private struct ListedServer: Decodable {
        struct Transport: Decodable {
            let command: String?
            let url: String?
        }

        let name: String
        let enabled: Bool
        let transport: Transport?

        var disabledSnapshot: DisabledMCPServer? {
            if transport?.command != nil {
                return DisabledMCPServer(name: name, transport: .stdio)
            }
            if transport?.url != nil {
                return DisabledMCPServer(name: name, transport: .streamableHTTP)
            }
            return nil
        }
    }

    public static func enabledServers(in data: Data) -> [DisabledMCPServer]? {
        guard let servers = try? JSONDecoder().decode([ListedServer].self, from: data) else {
            return nil
        }
        let enabled = servers.filter(\.enabled)
        let snapshots = enabled.compactMap(\.disabledSnapshot)
        guard snapshots.count == enabled.count else { return nil }
        return snapshots.sorted { $0.name < $1.name }
    }
}
