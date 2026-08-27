import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct AgentConfiguredServerTests {
    @Test func keepsOnlyServersOutsideCodeStationAndCombinesTheirSources() {
        let managed = Server(name: "managed", command: "managed-mcp", args: [],
                             url: nil, type: nil, env: [], headers: [], disabled: false)
        let claude = [
            "managed": ClaudeCodeManager.Entry(command: "managed-mcp"),
            "shared": ClaudeCodeManager.Entry(command: "shared-mcp", args: ["serve"]),
            "claude-only": ClaudeCodeManager.Entry(
                url: "https://mcp.example/claude", type: "http")
        ]
        let codex = [
            "shared": CodexCodeManager.Entry(command: "shared-mcp", args: ["serve"]),
            "codex-only": CodexCodeManager.Entry(
                command: "codex-mcp", enabled: false)
        ]

        let servers = AgentConfiguredServer.outsideCodeStation(
            managedServers: [managed], claudeEntries: claude, codexEntries: codex)

        #expect(servers.map(\.name) == ["claude-only", "codex-only", "shared"])
        #expect(servers[0].registrations.map(\.source) == [.claudeCode])
        #expect(servers[1].registrations.map(\.source) == [.codex])
        #expect(!servers[1].registrations[0].enabled)
        #expect(servers[2].registrations.map(\.source) == [.claudeCode, .codex])
        #expect(!servers[2].hasDifferentConfigurations)
    }

    @Test func noticesWhenAgentsUseDifferentDefinitionsForTheSameName() {
        let servers = AgentConfiguredServer.outsideCodeStation(
            managedServers: [],
            claudeEntries: [
                "shared": ClaudeCodeManager.Entry(command: "shared-mcp", args: ["serve"])
            ],
            codexEntries: [
                "shared": CodexCodeManager.Entry(command: "shared-mcp", args: ["inspect"])
            ])

        #expect(servers.first?.hasDifferentConfigurations == true)
    }

    @Test func readsRemoteClaudeConfigurationsForDiscovery() throws {
        let data = Data("""
            {
              "mcpServers": {
                "remote": {
                  "type": "http",
                  "url": "https://mcp.example/api",
                  "headers": { "Authorization": "Bearer secret" }
                }
              }
            }
            """.utf8)

        let entries = try #require(ClaudeCodeManager.configurationEntries(in: data))

        #expect(entries["remote"]?.url == "https://mcp.example/api")
        #expect(entries["remote"]?.type == "http")
        #expect(entries["remote"]?.headers.keys.sorted() == ["Authorization"])
    }
}
