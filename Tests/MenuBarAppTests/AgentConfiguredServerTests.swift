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

    @Test func listsCopilotRegistrationsWithTheirHeaders() throws {
        let servers = AgentConfiguredServer.outsideCodeStation(
            managedServers: [],
            claudeEntries: [:],
            codexEntries: [:],
            copilotEntries: [
                "remote": CopilotCodeManager.Entry(url: "https://mcp.example/mcp", type: "http",
                                                   headers: ["Authorization": "Bearer x"],
                                                   enabled: false)
            ])

        let registration = try #require(servers.first?.registrations.first)
        #expect(registration.source == .copilot)
        #expect(registration.transport == "http")
        #expect(registration.headers == ["Authorization": "Bearer x"])
        #expect(!registration.enabled)
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

    // MARK: - Status

    private func registration(_ source: AgentConfiguredServer.Source,
                              url: String? = "https://mcp.example/mcp",
                              enabled: Bool = true,
                              auth: AgentConfiguredServer.Auth = .none,
                              health: AgentConfiguredServer.Health? = nil,
                              work: AgentConfiguredServer.Work? = nil)
        -> AgentConfiguredServer.Registration {
        AgentConfiguredServer.Registration(
            source: source, command: url == nil ? "mcp" : nil, args: [], env: [:], url: url,
            type: url == nil ? nil : "http", headers: [:], enabled: enabled,
            auth: auth, health: health, work: work)
    }

    @Test func readsEachStatusTheWayTheDesignNamesIt() {
        #expect(registration(.claudeCode, health: .connected).status == .connected)
        #expect(registration(.claudeCode, health: .needsSignIn).status == .needsSignIn)
        #expect(registration(.claudeCode, health: .failed).status == .cantConnect)
        #expect(registration(.claudeCode).status == .on)
        #expect(registration(.codex, auth: .signedOut).status == .needsSignIn)
        #expect(registration(.codex, auth: .signedIn).status == .on)
        #expect(registration(.copilot, enabled: false).status == .off)
        #expect(registration(.codex, enabled: false, auth: .signedOut).status == .off)
        #expect(registration(.codex, enabled: false, work: .turningOn).status
                == .working(.turningOn))
        #expect(AgentConfiguredServer.Status.working(.turningOff).word == "turning off…")
    }

    @Test func headerShowsTheWorstStatusAcrossAgents() {
        let worst = AgentConfiguredServer.Status.worst([.connected, .off, .needsSignIn, .on])
        #expect(worst == .needsSignIn)
        #expect(AgentConfiguredServer.Status.worst([.needsSignIn, .cantConnect]) == .cantConnect)
        #expect(AgentConfiguredServer.Status.worst([.off, .on]) == .on)
    }

    @Test func offersSignInOnlyWhereTheAgentCanDoIt() {
        #expect(registration(.claudeCode).offersSignIn)
        #expect(!registration(.claudeCode, url: nil).offersSignIn)
        #expect(registration(.codex, auth: .signedOut).offersSignIn)
        #expect(!registration(.codex, auth: .none).offersSignIn)
        #expect(!registration(.copilot).offersSignIn)
        #expect(!AgentConfiguredServer.Source.claudeCode.canSwitch)
        #expect(AgentConfiguredServer.Source.codex.canSwitch)
        #expect(AgentConfiguredServer.Source.copilot.canSwitch)
    }

    @Test func carriesEachAgentsOwnHealthAuthAndWork() throws {
        let servers = AgentConfiguredServer.outsideCodeStation(
            managedServers: [],
            claudeEntries: ["linear": ClaudeCodeManager.Entry(url: "https://mcp.linear.app/mcp",
                                                              type: "http")],
            codexEntries: ["linear": CodexCodeManager.Entry(url: "https://mcp.linear.app/mcp",
                                                            authStatus: "not_logged_in")],
            claudeHealth: ["linear": .connected],
            work: { source, _ in source == .codex ? .signingIn : nil })

        let server = try #require(servers.first)
        #expect(server.registration(from: .claudeCode)?.status == .connected)
        #expect(server.registration(from: .codex)?.auth == .signedOut)
        #expect(server.registration(from: .codex)?.status == .working(.signingIn))
        #expect(server.worstStatus == .working(.signingIn))
    }

    // MARK: - Claude Code health

    @Test func readsHealthFromClaudeMcpList() {
        let output = """
            Checking MCP server health…

            snowflake: https://data.example/snowflake-mcp (HTTP) - ✔ Connected
            sentry: https://mcp.sentry.dev/mcp (HTTP) - ✗ Failed to connect
            linear: https://mcp.linear.app/mcp (HTTP) - △ Needs authentication
            grafana: /usr/local/bin/mcp-grafana --flag a - b - ✔ Connected
            project: npx thing - ⏸ Pending approval
            """

        let health = ClaudeCodeManager.health(inList: output)

        #expect(health == ["snowflake": .connected, "sentry": .failed,
                           "linear": .needsSignIn, "grafana": .connected])
    }

    @Test func readsHealthFromClaudeMcpGet() {
        let output = """
            snowflake:
              Scope: User config (available in all your projects)
              Status: ✔ Connected
              Type: http
            """
        #expect(ClaudeCodeManager.health(inGet: output) == .connected)
        #expect(ClaudeCodeManager.health(inGet: "x:\n  Status: ⚠ Needs authentication") == .needsSignIn)
        #expect(ClaudeCodeManager.health(inGet: "nothing here") == nil)
    }

    // MARK: - Codex

    @Test func readsCodexSignInStateFromItsList() throws {
        let data = Data("""
            [
              {"name": "linear", "enabled": true, "auth_status": "not_logged_in",
               "transport": {"type": "streamable_http", "url": "https://mcp.linear.app/mcp"}},
              {"name": "node_repl", "enabled": false, "auth_status": "unsupported",
               "transport": {"type": "stdio", "command": "node_repl"}}
            ]
            """.utf8)

        let states = try #require(CodexCodeManager.listedStates(in: data))

        #expect(states["linear"]?.authStatus == "not_logged_in")
        #expect(states["node_repl"]?.enabled == false)
        #expect(CodexCodeManager.auth(fromStatus: "not_logged_in") == .signedOut)
        #expect(CodexCodeManager.auth(fromStatus: "o_auth") == .signedIn)
        #expect(CodexCodeManager.auth(fromStatus: "bearer_token") == AgentConfiguredServer.Auth.none)
        #expect(CodexCodeManager.auth(fromStatus: "unsupported") == AgentConfiguredServer.Auth.none)
        #expect(CodexCodeManager.auth(fromStatus: nil) == AgentConfiguredServer.Auth.none)
    }

    @Test func turnsACodexServerOffInsideItsOwnTableOnly() throws {
        let toml = """
            model = "gpt-5"

            [mcp_servers.linear]
            url = "https://mcp.linear.app/mcp"

            [mcp_servers.linear.env]
            enabled = "not this one"

            [mcp_servers.other]
            command = "other"
            """

        let off = try #require(CodexCodeManager.settingEnabled(false, forServer: "linear", in: toml))

        #expect(off == """
            model = "gpt-5"

            [mcp_servers.linear]
            enabled = false
            url = "https://mcp.linear.app/mcp"

            [mcp_servers.linear.env]
            enabled = "not this one"

            [mcp_servers.other]
            command = "other"
            """)
        #expect(CodexCodeManager.settingEnabled(true, forServer: "linear", in: off) == toml)
    }

    @Test func updatesAnExistingEnabledKeyAndQuotedTableNames() throws {
        let toml = """
            [mcp_servers."my-server"]
            command = "x"
            enabled   = true
            """

        let off = try #require(CodexCodeManager.settingEnabled(false, forServer: "my-server", in: toml))

        #expect(off.contains("enabled = false"))
        #expect(!off.contains("enabled   = true"))
        #expect(CodexCodeManager.settingEnabled(true, forServer: "my-server", in: toml)?
            .contains("enabled") == false)
    }

    @Test func refusesToSwitchACodexServerItHasNoTableFor() {
        let toml = """
            [mcp_servers.linear]
            url = "https://mcp.linear.app/mcp"
            """
        #expect(CodexCodeManager.settingEnabled(false, forServer: "code-review", in: toml) == nil)
        #expect(CodexCodeManager.settingEnabled(false, forServer: "line", in: toml) == nil)
    }

    // MARK: - Copilot

    @Test func switchesCopilotServersWithItsOwnCommands() {
        #expect(CopilotCodeManager.switchArguments(false, for: "playwright")
                == ["mcp", "disable", "playwright"])
        #expect(CopilotCodeManager.switchArguments(true, for: "playwright")
                == ["mcp", "enable", "playwright"])
    }

    @Test func takesTerminalCodesOutOfASignInFailure() {
        let said = "^DStarting authentication…\r\n"
            + "Visit:\r\n  \u{1B}]8;;https://auth.example/a\u{07}https://auth.example/a\u{1B}]8;;\u{07}\r\n"
            + "\u{1B}[1G\u{1B}[0JOr paste the redirect URL here: \u{1B}[33G"
        #expect(AgentServerWork.withoutTerminalCodes(said)
                == "Starting authentication…\nVisit:\n  https://auth.example/a\nOr paste the redirect URL here:")
    }

    // MARK: - Detail

    @Test func saysHowLongAgoTheServerWasChecked() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        func phrase(_ seconds: TimeInterval) -> String {
            AgentConfiguredServerDetailView.checkedPhrase(since: now.addingTimeInterval(-seconds), now: now)
        }
        #expect(phrase(2) == "just now")
        #expect(phrase(22) == "22 seconds ago")
        #expect(phrase(70) == "a minute ago")
        #expect(phrase(300) == "5 minutes ago")
    }
}
