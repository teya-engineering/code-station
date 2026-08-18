import Foundation
import Testing
@testable import MenuBarApp

struct TroubleshootTests {
    @Test func promptCarriesTheProblemAndSelectedContext() {
        let request = TroubleshootRequest(
            problem: "Payments return 503 after deployment",
            environment: .prod,
            projects: ["payments-api", "merchant-web"],
            mcpServersEnabled: true,
            mcpServerNames: ["grafana-shared-shared", "grafana-platform-prd"])

        #expect(request.userInput == "Payments return 503 after deployment")
        #expect(!request.customInstructions.contains(request.userInput))
        #expect(request.customInstructions.contains("production (prod)"))
        #expect(request.customInstructions.contains("payments-api, merchant-web"))
        #expect(request.customInstructions.contains(
            "follow the `grafana-mcp` skill from the `grafana-specialist` plugin"))
        #expect(request.customInstructions.contains("whatever the agent calls skills"))
        #expect(request.customInstructions.contains("MCP servers are enabled"))
        #expect(request.customInstructions.contains("grafana-platform-prd, grafana-shared-shared"))
        #expect(request.customInstructions.contains("Search the available tool catalogue"))
        #expect(request.customInstructions.contains("before concluding that a server or tool is unavailable"))
        #expect(request.customInstructions.contains("do not mutate data, configuration, deployments, or running services"))
        #expect(request.customInstructions.contains("wait for a follow-up before applying it"))
    }

    @Test func attachmentOnlyDiagnosisStillHasAnInstruction() {
        let request = TroubleshootRequest(
            problem: "  \n",
            environment: .dev,
            projects: ["api"],
            mcpServersEnabled: false)

        #expect(request.userInput == "Troubleshoot the problem shown in the attached files.")
        #expect(request.customInstructions.contains("MCP servers are disabled for this diagnosis"))
    }

    @Test func queuedDiagnosisSeparatesTheTranscriptAndKeepsTheAgentPromptTogether() {
        let queued = SessionRunner.QueuedPrompt(
            text: "Payments return 503",
            attachments: [],
            customInstructions: "Use read-only checks first.")

        #expect(queued.prompt == "Payments return 503\n\nUse read-only checks first.")
        #expect(queued.transcriptMessages.map(\.role) == [.user, .instructions])
        #expect(queued.transcriptMessages.map(\.text) == [
            "Payments return 503",
            "Use read-only checks first.",
        ])
    }

    @Test func claudeRunsWithOnlyAnEmptyMCPConfigurationWhenDisabled() {
        let arguments = SessionRunner.arguments(
            settings: SessionSettings(mcpServersEnabled: false),
            defaults: SessionSettings(permissionMode: "acceptEdits"))

        #expect(pair(arguments, after: "--mcp-config") == #"{"mcpServers":{}}"#)
        #expect(arguments.contains("--strict-mcp-config"))
    }

    @Test func codexDisablesEveryServerInTheDiagnosisSnapshot() {
        let settings = SessionSettings(
            mcpServersEnabled: false,
            disabledMCPServerNames: ["grafana-platform-dev", "node_repl"])
        let arguments = SessionRunner.arguments(
            agent: .codex,
            settings: settings,
            defaults: SessionSettings())

        #expect(arguments.contains("mcp_servers.grafana-platform-dev.enabled=false"))
        #expect(arguments.contains("mcp_servers.node_repl.enabled=false"))
    }

    @Test func environmentKeepsSharedAndUnscopedServers() {
        let defaults = SiteDefaults(grafana: .init(presets: [
            .init(scope: "platform", environment: "dev",
                  url: "https://grafana.example", serves: ["dev"]),
            .init(scope: "platform", environment: "prd",
                  url: "https://grafana.example", serves: ["prod"]),
            .init(scope: "shared", environment: "shared",
                  url: "https://grafana.example", serves: ["dev", "prod"]),
        ]))
        let servers = [
            server("grafana-platform-dev"),
            server("grafana-platform-prd"),
            server("grafana-shared-shared"),
            server("node_repl"),
        ]

        #expect(servers.filter { TroubleshootEnvironment.dev.includes($0, in: defaults) }
            .map(\.name) == [
                "grafana-platform-dev", "grafana-shared-shared", "node_repl",
            ])
        #expect(servers.filter { TroubleshootEnvironment.prod.includes($0, in: defaults) }
            .map(\.name) == [
                "grafana-platform-prd", "grafana-shared-shared", "node_repl",
            ])
    }

    // With no site file there is nothing saying which environment a server belongs to,
    // so filtering must not quietly drop every one of them.
    @Test func everyServerSurvivesWithoutASiteFile() {
        let servers = [server("grafana-platform-dev"), server("node_repl")]

        #expect(servers.filter { TroubleshootEnvironment.prod.includes($0, in: SiteDefaults()) }
            .map(\.name) == ["grafana-platform-dev", "node_repl"])
    }

    @Test func claudeUsesTheFilteredMCPConfiguration() {
        let arguments = SessionRunner.arguments(
            settings: SessionSettings(
                mcpServersEnabled: true,
                allowedMCPServerNames: ["grafana-platform-dev", "grafana-shared-shared"]),
            defaults: SessionSettings(permissionMode: "acceptEdits"),
            mcpConfigPath: "/tmp/filtered-mcp.json")

        #expect(pair(arguments, after: "--mcp-config") == "/tmp/filtered-mcp.json")
        #expect(arguments.contains("--strict-mcp-config"))
    }

    @Test func filteredMCPConfigurationContainsOnlyAllowedServers() throws {
        let servers = [
            server("grafana-platform-dev"),
            server("grafana-platform-prd"),
            server("grafana-shared-shared"),
        ]
        let data = try #require(ConfigStore.mcpConfigurationData(
            from: servers,
            allowing: ["grafana-platform-dev", "grafana-shared-shared"]))
        let configuration = try JSONDecoder().decode(ConfigFile.self, from: data)

        #expect(Set(configuration.mcpServers.keys) == [
            "grafana-platform-dev", "grafana-shared-shared",
        ])
    }

    @Test func codexDisablesServersOutsideTheSelectedEnvironment() {
        let arguments = SessionRunner.arguments(
            agent: .codex,
            settings: SessionSettings(
                mcpServersEnabled: true,
                allowedMCPServerNames: ["grafana-platform-dev", "grafana-shared-shared"],
                disabledMCPServerNames: ["grafana-platform-prd"]),
            defaults: SessionSettings())

        #expect(arguments.contains("mcp_servers.grafana-platform-prd.enabled=false"))
        #expect(!arguments.contains("mcp_servers.grafana-platform-dev.enabled=false"))
    }

    @Test func managedServersMustBeEnabledInTheSelectedClient() {
        let configuration = TroubleshootMCPConfiguration(
            requiredNames: [
                "grafana-platform-dev",
                "grafana-shared-shared",
                "node_repl",
            ],
            registeredNames: [
                "grafana-platform-dev",
                "grafana-shared-shared",
            ],
            disabledNames: [
                "grafana-shared-shared",
            ])

        #expect(configuration.missing == ["node_repl"])
        #expect(configuration.disabled == ["grafana-shared-shared"])
        #expect(!configuration.isAvailable)
    }

    private func server(_ name: String) -> Server {
        Server(name: name, command: "mcp", args: [], url: nil, type: nil,
               env: [], headers: [], disabled: false)
    }

    private func pair(_ arguments: [String], after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}

@MainActor
struct TroubleshootProjectTests {
    @Test func troubleshootingMarkerSurvivesSessionPersistence() throws {
        var session = ChatSession(projectID: UUID())
        session.isTroubleshooting = true

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(ChatSession.self, from: data)

        #expect(decoded.isTroubleshooting)
    }

    @Test func sessionsWrittenBeforeTroubleshootingDefaultToRegular() throws {
        let id = UUID()
        let projectID = UUID()
        let data = Data("""
            {
              "id": "\(id.uuidString)",
              "projectID": "\(projectID.uuidString)"
            }
            """.utf8)

        let session = try JSONDecoder().decode(ChatSession.self, from: data)

        #expect(!session.isTroubleshooting)
    }

    @Test func filtersProjectsByNameOrPathIgnoringCase() {
        let api = Project(name: "Payments API", path: "/Development/services/payments-api")
        let web = Project(name: "Merchant Web", path: "/Development/frontends/merchant-web")

        #expect(TroubleshootView.projects([api, web], matching: "PAYMENTS") == [api])
        #expect(TroubleshootView.projects([api, web], matching: "frontends") == [web])
        #expect(TroubleshootView.projects([api, web], matching: "  ") == [api, web])
    }

    @Test func onlyOneProjectStartsADirectProjectSession() {
        let first = Project(name: "Payments API", path: "/payments-api")
        let second = Project(name: "Merchant Web", path: "/merchant-web")

        #expect(TroubleshootView.projectSessionTarget([]) == nil)
        #expect(TroubleshootView.projectSessionTarget([first]) == first)
        #expect(TroubleshootView.projectSessionTarget([first, second]) == nil)
    }

    @Test func multiProjectDiagnosisStartsInANewWorkspace() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-station-troubleshoot-tests-\(UUID().uuidString).json")
        setenv("CODE_STATION_STORE", storeURL.path, 1)
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(
                at: storeURL.deletingLastPathComponent()
                    .appendingPathComponent(storeURL.deletingPathExtension().lastPathComponent
                        + "-transcripts"))
        }

        let store = ProjectStore()
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("payments-api-\(UUID().uuidString)")
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("merchant-web-\(UUID().uuidString)")
        let first = try #require(store.addProject(at: firstURL))
        let second = try #require(store.addProject(at: secondURL))

        let workspace = try #require(store.addWorkspace(
            name: "Checkout diagnosis",
            projectIDs: [first.id, second.id],
            leadProjectID: first.id))
        let session = try #require(store.newSession(
            in: workspace.id,
            projects: [
                SessionProject(projectID: first.id, worktreePath: nil, worktreeBranch: nil),
                SessionProject(projectID: second.id, worktreePath: nil, worktreeBranch: nil),
            ],
            isTroubleshooting: true))

        #expect(session.projectID == first.id)
        #expect(session.workspaceID == workspace.id)
        #expect(session.isTroubleshooting)
        #expect(store.workspaces == [workspace])
        #expect(store.workingDirectories(for: session) == [first.path, second.path])
        #expect(store.selection == .session(session.id))
    }
}
