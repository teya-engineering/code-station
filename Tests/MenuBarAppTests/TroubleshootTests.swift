import Foundation
import Testing
@testable import MenuBarApp

struct TroubleshootTests {
    private static let site = SiteDefaults(environments: [
        .init(name: "dev", title: "Dev"),
        .init(name: "prd", title: "Prod", danger: true),
        .init(name: "shared", title: "Shared"),
    ])
    private static let dev = TroubleshootEnvironment(name: "dev", title: "Dev")
    private static let prod = TroubleshootEnvironment(name: "prd", title: "Prod",
                                                      isDangerous: true)
    private static let shared = TroubleshootEnvironment(name: "shared", title: "Shared")

    @Test func promptCarriesTheProblemAndSelectedContext() {
        let request = TroubleshootRequest(
            problem: "Payments return 503 after deployment",
            environment: Self.prod,
            projects: ["payments-api", "merchant-web"],
            skills: ["postgres-specialist", "grafana-specialist"],
            mcpServersEnabled: true,
            mcpServerNames: ["grafana-shared-shared", "grafana-platform-prd"],
            agent: .claudeCode)

        #expect(request.userInput == "Payments return 503 after deployment")
        #expect(!request.customInstructions.contains(request.userInput))
        #expect(request.customInstructions.contains("Prod (prd)"))
        #expect(request.customInstructions.contains("payments-api, merchant-web"))
        #expect(request.customInstructions.contains(
            "Skills to use: `grafana-specialist`, `postgres-specialist`"))
        #expect(request.customInstructions.contains("whatever the agent calls skills"))
        #expect(request.customInstructions.contains("MCP servers are enabled"))
        #expect(request.customInstructions.contains("grafana-platform-prd, grafana-shared-shared"))
        #expect(request.customInstructions.contains("Search the available tool catalogue"))
        #expect(request.customInstructions.contains("before concluding that a server or tool is unavailable"))
        #expect(request.customInstructions.contains("Treat this environment as live"))
        #expect(request.customInstructions.contains("do not mutate data, configuration, deployments, or running services"))
        #expect(request.customInstructions.contains("wait for a follow-up before applying it"))
        #expect(request.customInstructions.contains("Chart the measurements"))
    }

    // Claude reads the chart shape in its system prompt, so repeating it in the brief
    // would spend the same tokens on every diagnosis for nothing. The agents with no
    // system prompt to put it in get it here or not at all.
    @Test func onlyTheAgentsWithoutASystemPromptCarryTheChartShape() {
        func brief(_ agent: AgentKind) -> String {
            TroubleshootRequest(problem: "Latency doubled", environment: Self.dev,
                                projects: ["api"], mcpServersEnabled: false,
                                agent: agent).customInstructions
        }

        #expect(!brief(.claudeCode).contains(TranscriptChartSpec.agentInstructions))
        #expect(brief(.codex).contains(TranscriptChartSpec.agentInstructions))
        #expect(brief(.copilot).contains(TranscriptChartSpec.agentInstructions))
    }

    @Test func attachmentOnlyDiagnosisStillHasAnInstruction() {
        let request = TroubleshootRequest(
            problem: "  \n",
            environment: Self.dev,
            projects: ["api"],
            mcpServersEnabled: false,
            agent: .claudeCode)

        #expect(request.userInput == "Troubleshoot the problem shown in the attached files.")
        #expect(request.customInstructions.contains("MCP servers are disabled for this diagnosis"))
        #expect(request.customInstructions.contains("No skills were picked for this diagnosis"))
    }

    @Test func chosenSkillsSurviveTheAppBeingClosed() {
        let suite = "troubleshoot-skills-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }

        Preferences.setTroubleshootSkills(["grafana-specialist", "java-specialist"], in: store)
        #expect(Preferences.troubleshootSkills(in: store) == [
            "grafana-specialist", "java-specialist",
        ])

        Preferences.setTroubleshootSkills([], in: store)
        #expect(Preferences.troubleshootSkills(in: store).isEmpty)
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
            disabledMCPServers: [
                DisabledMCPServer(name: "grafana-platform-dev", transport: .stdio),
                DisabledMCPServer(name: "remote", transport: .streamableHTTP),
            ])
        let arguments = SessionRunner.arguments(
            agent: .codex,
            settings: settings,
            defaults: SessionSettings())

        #expect(arguments.contains(
            #"mcp_servers={"grafana-platform-dev"={enabled=false,command="/usr/bin/false"},"remote"={enabled=false,url="https://disabled.invalid"}}"#))
    }

    @Test func codexDoesNotCreateInvalidOverridesFromLegacyNames() {
        let settings = SessionSettings(
            mcpServersEnabled: false,
            disabledMCPServerNames: ["cua_repl"])
        let arguments = SessionRunner.arguments(
            agent: .codex,
            settings: settings,
            defaults: SessionSettings())

        #expect(!arguments.contains { $0.contains("mcp_servers") })
    }

    @Test func anEnvironmentOffersOnlyTheServersTaggedForIt() {
        let servers = [
            server("grafana-platform-dev", tag: "dev"),
            server("grafana-platform-prd", tag: "prd"),
            server("grafana-shared-shared", tag: "shared"),
            server("node_repl"),
        ]

        #expect(servers.filter { Self.dev.includes($0, in: Self.site) }.map(\.name)
            == ["grafana-platform-dev", "node_repl"])
        #expect(servers.filter { Self.prod.includes($0, in: Self.site) }.map(\.name)
            == ["grafana-platform-prd", "node_repl"])
        #expect(servers.filter { Self.shared.includes($0, in: Self.site) }.map(\.name)
            == ["grafana-shared-shared", "node_repl"])
    }

    // A tag the file no longer names says nothing about where the server belongs, so
    // hiding it everywhere would lose it without telling anybody.
    @Test func aTagNothingNamesLeavesTheServerInEveryEnvironment() {
        let servers = [server("grafana-sandbox-sbx", tag: "sbx"), server("node_repl")]

        #expect(servers.filter { Self.dev.includes($0, in: Self.site) }.map(\.name)
            == ["grafana-sandbox-sbx", "node_repl"])
        #expect(servers.filter { Self.prod.includes($0, in: Self.site) }.map(\.name)
            == ["grafana-sandbox-sbx", "node_repl"])
    }

    // With no site file there is nothing saying which environment a server belongs to,
    // so filtering must not quietly drop every one of them.
    @Test func everyServerSurvivesWithoutASiteFile() {
        let servers = [server("grafana-platform-dev", tag: "dev"), server("node_repl")]
        let environment = TroubleshootEnvironment.first(in: SiteDefaults())

        #expect(environment.name == "staging")
        #expect(servers.filter { environment.includes($0, in: SiteDefaults()) }.map(\.name)
            == ["grafana-platform-dev", "node_repl"])
    }

    // The pills come from the file, and the prompt names the deployment the way the
    // agent will meet it rather than only the way it reads on screen.
    @Test func thePickerAndThePromptFollowTheSiteFile() {
        #expect(TroubleshootEnvironment.all(in: Self.site).map(\.title)
            == ["Dev", "Prod", "Shared"])
        #expect(TroubleshootEnvironment.first(in: Self.site) == Self.dev)
        #expect(Self.prod.promptTitle == "Prod (prd)")
        #expect(Self.dev.promptTitle == "dev")
        #expect(!Self.shared.isDangerous)
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
                disabledMCPServers: [
                    DisabledMCPServer(name: "grafana-platform-prd", transport: .stdio),
                ]),
            defaults: SessionSettings())

        let override = #"mcp_servers={"grafana-platform-prd"={enabled=false,command="/usr/bin/false"}}"#
        #expect(arguments.contains(override))
        #expect(!arguments.contains { $0.contains("grafana-platform-dev") })
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

    // Nothing to check means nothing to wait for: a diagnosis that is not using managed
    // servers must not sit behind a registry read it does not need.
    @Test func nothingToCheckIsReadyAtOnce() {
        #expect(TroubleshootMCPState.resolve(
            enabled: false, servers: [server("grafana-platform-dev")],
            hasStartedCheck: false, isRefreshing: false,
            registeredNames: [], disabledNames: []) == .ready)
        #expect(TroubleshootMCPState.resolve(
            enabled: true, servers: [], hasStartedCheck: false, isRefreshing: false,
            registeredNames: [], disabledNames: []) == .ready)
    }

    // An unasked question and an unfinished one both read as still running, so a start
    // cannot slip through the gap before the first answer.
    @Test func theCheckHoldsUntilTheRegistryHasBeenRead() {
        let servers = [server("grafana-platform-dev")]

        #expect(TroubleshootMCPState.resolve(
            enabled: true, servers: servers, hasStartedCheck: false, isRefreshing: false,
            registeredNames: ["grafana-platform-dev"], disabledNames: []) == .checking)
        #expect(TroubleshootMCPState.resolve(
            enabled: true, servers: servers, hasStartedCheck: true, isRefreshing: true,
            registeredNames: ["grafana-platform-dev"], disabledNames: []) == .checking)
        #expect(TroubleshootMCPState.resolve(
            enabled: true, servers: servers, hasStartedCheck: true, isRefreshing: false,
            registeredNames: ["grafana-platform-dev"], disabledNames: []) == .ready)
    }

    @Test func anUnreachableServerNamesBothWhatIsMissingAndWhatIsOff() {
        let state = TroubleshootMCPState.resolve(
            enabled: true,
            servers: [server("grafana-platform-dev"), server("node_repl")],
            hasStartedCheck: true, isRefreshing: false,
            registeredNames: ["grafana-platform-dev"],
            disabledNames: ["grafana-platform-dev"])

        let message = state.message(for: .codex) ?? ""
        #expect(message.contains("Not configured for Codex: node_repl."))
        #expect(message.contains("Disabled in Codex: grafana-platform-dev."))
        #expect(message.contains("Sync the listed servers in MCP Servers"))
        #expect(TroubleshootMCPState.ready.message(for: .codex) == nil)
    }

    private func server(_ name: String, tag: String = "") -> Server {
        Server(name: name, environmentTag: tag, command: "mcp", args: [], url: nil,
               type: nil, env: [], headers: [], disabled: false)
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

    @Test func matchingProjectsReuseTheExistingWorkspace() {
        let firstID = UUID()
        let secondID = UUID()
        let workspace = ProjectWorkspace(name: "Payments",
                                         projectIDs: [firstID, secondID],
                                         leadProjectID: firstID)

        #expect(TroubleshootView.workspaceSessionTarget(
            workspace, selectedProjectIDs: [firstID, secondID]) == workspace)
        #expect(TroubleshootView.workspaceSessionTarget(
            workspace, selectedProjectIDs: [firstID]) == nil)
        #expect(TroubleshootView.workspaceSessionTarget(
            nil, selectedProjectIDs: [firstID, secondID]) == nil)
    }

    // The Troubleshoot tab is on every session, so a session only becomes a diagnosis
    // once a brief is actually sent from it. The sidebar filter and the header chip both
    // read the marker, so it has to survive the turn that set it.
    @Test func sendingABriefFromTheTabMarksTheSession() throws {
        let (store, scratch) = TestStore.make()
        defer { withExtendedLifetime(scratch) {} }
        let project = try TestStore.project(in: store, named: "payments-api")
        let session = store.newSession(in: project.id)

        #expect(store.session(session.id)?.isTroubleshooting == false)

        store.markTroubleshooting(session.id)
        #expect(store.session(session.id)?.isTroubleshooting == true)

        // Running it again appends to the same conversation rather than re-marking it.
        store.markTroubleshooting(session.id)
        #expect(store.session(session.id)?.isTroubleshooting == true)
    }

    @Test func multiProjectDiagnosisStartsInANewWorkspace() throws {
        let (store, scratch) = TestStore.make()
        defer { withExtendedLifetime(scratch) {} }
        let first = try TestStore.project(in: store, named: "payments-api")
        let second = try TestStore.project(in: store, named: "merchant-web")

        let workspace = try #require(store.addWorkspace(
            name: "Checkout diagnosis",
            projectIDs: [first.id, second.id],
            leadProjectID: first.id))
        let session = try #require(store.newSession(in: workspace.id, projects: [
                SessionProject(projectID: first.id, worktreePath: nil, worktreeBranch: nil),
                SessionProject(projectID: second.id, worktreePath: nil, worktreeBranch: nil),
            ], seed: .init(isTroubleshooting: true)))

        #expect(session.projectID == first.id)
        #expect(session.workspaceID == workspace.id)
        #expect(session.isTroubleshooting)
        #expect(store.workspaces == [workspace])
        #expect(store.workingDirectories(for: session) == [first.path, second.path])
        #expect(store.selection == .session(session.id))
    }
}

// The tab is thrown away and rebuilt every time the pane shows another one, so a brief
// held there would go with a single look at Chat. These pin it to the runner instead.
@MainActor
struct TroubleshootBriefTests {

    @Test func whatWasTypedOutlivesTheTabBeingRebuilt() {
        let runner = SessionRunner()
        let sessionID = UUID()
        let evidence = Attachment(url: URL(fileURLWithPath: "/tmp/payments.log"))

        runner.editBrief(sessionID) {
            $0.problem = "Payments return 503 after deployment"
            $0.attachments = [evidence]
            $0.mcpServersEnabled = false
        }

        #expect(runner.brief(sessionID).problem == "Payments return 503 after deployment")
        #expect(runner.brief(sessionID).attachments == [evidence])
        #expect(runner.brief(sessionID).mcpServersEnabled == false)
    }

    @Test func eachSessionKeepsItsOwnBrief() {
        let runner = SessionRunner()
        let first = UUID()
        let second = UUID()

        runner.editBrief(first) { $0.problem = "checkout times out" }
        runner.editBrief(second) { $0.problem = "webhooks arrive twice" }

        #expect(runner.brief(first).problem == "checkout times out")
        #expect(runner.brief(second).problem == "webhooks arrive twice")
    }

    @Test func aSessionWithoutABriefStartsOnTheDefaults() {
        let runner = SessionRunner()

        let brief = runner.brief(UUID())

        #expect(brief.problem.isEmpty)
        #expect(brief.attachments.isEmpty)
        #expect(brief.mcpServersEnabled)
    }

    // A sent brief is in the transcript, so the form it came from starts again empty.
    @Test func sendingLeavesTheFormEmpty() {
        let runner = SessionRunner()
        let sessionID = UUID()

        runner.editBrief(sessionID) { $0.problem = "queue is stuck" }
        runner.clearBrief(sessionID)

        #expect(runner.brief(sessionID).problem.isEmpty)
    }
}
