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
            liveEnvironments: [Self.prod],
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
        #expect(request.customInstructions.contains("Treat the environment Prod (prd) as live"))
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

    private static let traceID = "0af7651916cd43dd8448eb211c80319c"

    private func traced(_ problem: String, agent: AgentKind = .claudeCode) -> TroubleshootRequest {
        TroubleshootRequest(problem: problem, environment: Self.dev,
                            projects: ["api"], mcpServersEnabled: true, agent: agent)
    }

    @Test func aTraceIdInTheProblemIsWhereTheDiagnosisStarts() {
        let request = traced("Checkout fails for \(Self.traceID.uppercased()), see logs")

        #expect(request.traceIDs == [Self.traceID])
        #expect(request.userInput == "Checkout fails for \(Self.traceID.uppercased()), see logs")
        #expect(request.customInstructions.contains("Start from trace `\(Self.traceID)`."))
        #expect(request.customInstructions.contains("follow a skill's guidance on which Grafana holds traces"))
        #expect(request.customInstructions.contains("```trace block before going further"))
    }

    // The link stays in the problem as written, since it says which Grafana the trace was
    // seen in and when, which the id alone does not.
    @Test func aPastedLinkStaysInTheProblem() {
        let link = "https://grafana.edge-dev.example.com/explore?trace=\(Self.traceID)"
        let request = traced(link)

        #expect(request.userInput == link)
        #expect(request.traceIDs == [Self.traceID])
    }

    @Test func everyTraceNamedIsFollowed() {
        let other = "4bf92f3577b34da6a3ce929d0e0e4736"
        let request = traced("Both \(Self.traceID) and \(other) time out")

        #expect(request.customInstructions.contains("Start from traces `\(Self.traceID)`, `\(other)`."))
    }

    @Test func aProblemWithoutATraceIdAsksForNoTrace() {
        let request = traced("Checkout fails since this morning")

        #expect(request.traceIDs.isEmpty)
        #expect(!request.customInstructions.contains("Start from trace"))
    }

    // Every agent is told how to draw evidence, since the brief is its only channel for it
    // and the Evidence tab is built from what it draws.
    @Test func everyAgentIsToldHowToDrawEvidence() {
        for agent in AgentKind.allCases {
            #expect(traced("Checkout fails", agent: agent).customInstructions
                .contains(TranscriptEvidenceBlocks.agentInstructions))
        }
    }

    @Test func incidentTimeIsSentVerbatimWithoutAnInferredTimezone() {
        let request = TroubleshootRequest(
            problem: "Latency doubled", incidentTime: "Yesterday around 14:00",
            environment: Self.dev, projects: ["api"], mcpServersEnabled: false,
            agent: .codex)
        #expect(request.userInput == "Latency doubled\n\nIncident time window (as supplied): Yesterday around 14:00")
        let blank = TroubleshootRequest(
            problem: "Latency doubled", incidentTime: "  \n ",
            environment: Self.dev, projects: ["api"], mcpServersEnabled: false,
            agent: .codex)
        #expect(blank.userInput == "Latency doubled")
        let evidenceOnly = TroubleshootRequest(
            problem: "", incidentTime: "last 30 minutes",
            environment: Self.dev, projects: ["api"], mcpServersEnabled: false,
            agent: .codex)
        #expect(evidenceOnly.userInput == "Troubleshoot the problem shown in the attached files.\n\nIncident time window (as supplied): last 30 minutes")
    }

    @Test func eachServerShowsItsOwnConfigurationState() {
        let state = TroubleshootMCPState.unavailable(TroubleshootMCPConfiguration(
            requiredNames: ["ready", "missing", "disabled"],
            registeredNames: ["ready", "disabled"], disabledNames: ["disabled"]))
        #expect(state.configurationLabel(for: "ready") == "Configured")
        #expect(state.configurationLabel(for: "missing") == "Not configured")
        #expect(state.configurationLabel(for: "disabled") == "Disabled")
        #expect(TroubleshootMCPState.checking.configurationLabel(for: "ready") == "Checking")
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
        let arguments = AgentLaunchConfiguration(
            settings: SessionSettings(mcpServersEnabled: false),
            defaults: SessionSettings(permissionMode: .acceptEdits)).arguments

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
        let arguments = AgentLaunchConfiguration(
            agent: .codex,
            settings: settings,
            defaults: SessionSettings()).arguments

        #expect(arguments.contains(
            #"mcp_servers={"grafana-platform-dev"={enabled=false,command="/usr/bin/false"},"remote"={enabled=false,url="https://disabled.invalid"}}"#))
    }

    @Test func codexDoesNotCreateInvalidOverridesFromLegacyNames() {
        let settings = SessionSettings(
            mcpServersEnabled: false,
            disabledMCPServerNames: ["cua_repl"])
        let arguments = AgentLaunchConfiguration(
            agent: .codex,
            settings: settings,
            defaults: SessionSettings()).arguments

        #expect(!arguments.contains { $0.contains("mcp_servers") })
    }

    // The environment only says where to look first, so the agent is told it may follow
    // the evidence elsewhere, and is told to work it out when none was picked.
    @Test func theEnvironmentIsAHintNotALimit() {
        let picked = TroubleshootRequest(problem: "Latency doubled", environment: Self.dev,
                                         liveEnvironments: [], projects: ["api"],
                                         mcpServersEnabled: true, agent: .claudeCode)
        #expect(picked.customInstructions.contains("Environment: dev. Look there first"))
        #expect(picked.customInstructions.contains("follow the evidence if it leads to another environment"))

        let none = TroubleshootRequest(problem: "Latency doubled", liveEnvironments: [],
                                       projects: ["api"], mcpServersEnabled: true,
                                       agent: .claudeCode)
        #expect(none.customInstructions.contains("Environment: not given."))
        #expect(!none.customInstructions.contains("as live"))
    }

    // Servers for every environment reach every diagnosis, so the live ones stay
    // read-only even when the brief points somewhere else or nowhere at all.
    @Test func liveEnvironmentsStayReadOnlyWhicheverEnvironmentIsPicked() {
        for environment in [nil, Self.dev, Self.shared] {
            let request = TroubleshootRequest(problem: "Latency doubled", environment: environment,
                                              liveEnvironments: TroubleshootEnvironment.live(in: Self.site),
                                              projects: ["api"], mcpServersEnabled: true,
                                              agent: .claudeCode)
            #expect(request.customInstructions.contains(
                "Treat the environment Prod (prd) as live: do not mutate data, configuration, deployments, or running services there."))
        }
    }

    // The pills come from the file, and the prompt names the deployment the way the
    // agent will meet it rather than only the way it reads on screen.
    @Test func thePickerAndThePromptFollowTheSiteFile() {
        #expect(TroubleshootEnvironment.all(in: Self.site).map(\.title)
            == ["Dev", "Prod", "Shared"])
        #expect(Self.prod.promptTitle == "Prod (prd)")
        #expect(Self.dev.promptTitle == "dev")
        #expect(!Self.shared.isDangerous)
    }

    @Test func claudeUsesTheFilteredMCPConfiguration() {
        let arguments = AgentLaunchConfiguration(
            settings: SessionSettings(
                mcpServersEnabled: true,
                allowedMCPServerNames: ["grafana-platform-dev", "grafana-shared-shared"]),
            defaults: SessionSettings(permissionMode: .acceptEdits),
            mcpConfigPath: "/tmp/filtered-mcp.json").arguments

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

    // A server added to Claude Code by hand has no environment, so a diagnosis keeps it
    // whole, while one the app manages stays behind the environment filter.
    @Test func filteredMCPConfigurationKeepsServersAddedToClaudeByHand() throws {
        let servers = [server("grafana-platform-dev"), server("grafana-platform-prd")]
        let managed = try #require(ConfigStore.mcpConfigurationData(
            from: servers, allowing: ["grafana-platform-dev"]))
        let claudeConfig = Data("""
        {"mcpServers": {
          "snowflake": {"type": "http", "url": "https://example.test/mcp",
                        "oauth": {"clientId": "abc"}},
          "grafana-platform-prd": {"command": "grafana"}
        }}
        """.utf8)

        let data = try #require(ClaudeCodeManager.addingOwnServers(
            to: managed, from: claudeConfig, managedNames: Set(servers.map(\.name))))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try #require(object["mcpServers"] as? [String: [String: Any]])

        #expect(Set(result.keys) == ["grafana-platform-dev", "snowflake"])
        #expect((result["snowflake"]?["oauth"] as? [String: String]) == ["clientId": "abc"])
    }

    @Test func filteredMCPConfigurationSurvivesAMissingClaudeConfig() throws {
        let managed = try #require(ConfigStore.mcpConfigurationData(
            from: [server("grafana-platform-dev")], allowing: ["grafana-platform-dev"]))

        let data = try #require(ClaudeCodeManager.addingOwnServers(
            to: managed, from: nil, managedNames: ["grafana-platform-dev"]))
        let configuration = try JSONDecoder().decode(ConfigFile.self, from: data)

        #expect(Set(configuration.mcpServers.keys) == ["grafana-platform-dev"])
    }

    @Test func codexDisablesOnlyTheServersTheSessionTurnsOff() {
        let arguments = AgentLaunchConfiguration(
            agent: .codex,
            settings: SessionSettings(
                mcpServersEnabled: true,
                allowedMCPServerNames: ["grafana-platform-dev", "grafana-shared-shared"],
                disabledMCPServers: [
                    DisabledMCPServer(name: "grafana-platform-prd", transport: .stdio),
                ]),
            defaults: SessionSettings()).arguments

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
    private let testPreferences = TestPreferences()
    @Test func troubleshootingMarkerSurvivesSessionPersistence() throws {
        var session = ChatSession(projectID: UUID())
        session.isTroubleshooting = true
        session.troubleshootEnvironment = "prd"
        session.troubleshootTimeWindow = "Since 14:05 UTC"

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(ChatSession.self, from: data)

        #expect(decoded.isTroubleshooting)
        #expect(decoded.troubleshootEnvironment == "prd")
        #expect(decoded.troubleshootTimeWindow == "Since 14:05 UTC")
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

    // The Troubleshoot tab is on every session, so a session only becomes a diagnosis
    // once a brief is actually sent from it. The sidebar filter and the header chip both
    // read the marker, so it has to survive the turn that set it.
    @Test func sendingABriefFromTheTabMarksTheSession() throws {
        let (store, scratch) = TestStore.make()
        defer { withExtendedLifetime(scratch) {} }
        let project = try TestStore.project(in: store, named: "payments-api")
        let session = store.newSession(in: project.id)

        #expect(store.session(session.id)?.isTroubleshooting == false)

        store.markTroubleshooting(session.id, environment: "prd", timeWindow: "Last 2 hours")
        #expect(store.session(session.id)?.isTroubleshooting == true)
        #expect(store.session(session.id)?.troubleshootEnvironment == "prd")
        #expect(store.session(session.id)?.troubleshootTimeWindow == "Last 2 hours")

        // Running it again appends to the same conversation rather than re-marking it,
        // so the strip keeps describing the brief that made it a diagnosis.
        store.markTroubleshooting(session.id, environment: "dev", timeWindow: "")
        #expect(store.session(session.id)?.isTroubleshooting == true)
        #expect(store.session(session.id)?.troubleshootEnvironment == "prd")
        #expect(store.session(session.id)?.troubleshootTimeWindow == "Last 2 hours")
    }

    // The strip shows the window only when one was given, so blanks are not kept.
    @Test func aBlankTimeWindowIsNotKeptOnTheSession() throws {
        let (store, scratch) = TestStore.make()
        defer { withExtendedLifetime(scratch) {} }
        let project = try TestStore.project(in: store, named: "payments-api")
        let session = store.newSession(in: project.id)

        store.markTroubleshooting(session.id, environment: "dev", timeWindow: "  \n")

        #expect(store.session(session.id)?.troubleshootEnvironment == "dev")
        #expect(store.session(session.id)?.troubleshootTimeWindow == nil)
    }

    @Test func aSheetDiagnosisRemembersItsEnvironment() throws {
        let (store, scratch) = TestStore.make()
        defer { withExtendedLifetime(scratch) {} }
        let project = try TestStore.project(in: store, named: "payments-api")

        let session = store.newSession(in: project.id, seed: .init(isTroubleshooting: true,
                                                                   troubleshootEnvironment: "prd"))
        let regular = store.newSession(in: project.id, seed: .init(troubleshootEnvironment: "prd"))

        #expect(session.troubleshootEnvironment == "prd")
        #expect(regular.troubleshootEnvironment == nil)
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
            ], seed: .init(agentAvatarName: "agent-avatar-2.png", isTroubleshooting: true)))

        #expect(session.projectID == first.id)
        #expect(session.workspaceID == workspace.id)
        #expect(session.agentAvatarName == "agent-avatar-2.png")
        let restored = try #require(ProjectStore(preferences: testPreferences.store, storeURL: store.storeURL).session(session.id))
        #expect(restored.agentAvatarName == "agent-avatar-2.png")
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
    private let testPreferences = TestPreferences()

    @Test func whatWasTypedOutlivesTheTabBeingRebuilt() {
        let runner = SessionRunner(store: TestStore.make().store, preferences: testPreferences.store)
        let sessionID = UUID()
        let evidence = Attachment(url: URL(fileURLWithPath: "/tmp/payments.log"))

        runner.composer.editBrief(sessionID) {
            $0.problem = "Payments return 503 after deployment"
            $0.incidentTime = "14:00 UTC"
            $0.attachments = [evidence]
            $0.mcpServersEnabled = false
        }

        #expect(runner.composer.brief(sessionID).problem == "Payments return 503 after deployment")
        #expect(runner.composer.brief(sessionID).incidentTime == "14:00 UTC")
        #expect(runner.composer.brief(sessionID).attachments == [evidence])
        #expect(runner.composer.brief(sessionID).mcpServersEnabled == false)
    }

    @Test func eachSessionKeepsItsOwnBrief() {
        let runner = SessionRunner(store: TestStore.make().store, preferences: testPreferences.store)
        let first = UUID()
        let second = UUID()

        runner.composer.editBrief(first) { $0.problem = "checkout times out" }
        runner.composer.editBrief(second) { $0.problem = "webhooks arrive twice" }

        #expect(runner.composer.brief(first).problem == "checkout times out")
        #expect(runner.composer.brief(second).problem == "webhooks arrive twice")
    }

    @Test func aSessionWithoutABriefStartsOnTheDefaults() {
        let runner = SessionRunner(store: TestStore.make().store, preferences: testPreferences.store)

        let brief = runner.composer.brief(UUID())

        #expect(brief.problem.isEmpty)
        #expect(brief.incidentTime.isEmpty)
        #expect(brief.attachments.isEmpty)
        #expect(brief.environment == nil)
        #expect(brief.mcpServersEnabled)
    }

    // A sent brief is in the transcript, so the form it came from starts again empty.
    @Test func sendingLeavesTheFormEmpty() {
        let runner = SessionRunner(store: TestStore.make().store, preferences: testPreferences.store)
        let sessionID = UUID()

        runner.composer.editBrief(sessionID) {
            $0.problem = "queue is stuck"
            $0.incidentTime = "last hour"
        }
        runner.composer.clearBrief(sessionID)

        #expect(runner.composer.brief(sessionID).problem.isEmpty)
        #expect(runner.composer.brief(sessionID).incidentTime.isEmpty)
    }
}

// What the brief reads back under the editor as it is typed. These are the chips the
// person sees before sending, so each one has to come from the words they wrote.
struct TroubleshootRecognisedTests {
    private static let traceID = "4f9c2a7e1d3b4c5a6e7f8091a2b3c4d5"

    @Test func aPastedTraceIdShowsAsAShortenedChip() {
        let details = TroubleshootRecognised.details(in: "Failing trace \(Self.traceID) since 14:05")
        #expect(details.map(\.kind) == [.trace, .time])
        #expect(details[0].label == "Trace 4f9c2a7e…c4d5")
    }

    @Test func aGrafanaLinkIsReadForItsTraceId() {
        let link = "https://grafana.edge-prd.teya.io/explore?traceId=\(Self.traceID)"
        let details = TroubleshootRecognised.details(in: "One failing trace: \(link)")
        #expect(details.map(\.label) == ["Trace 4f9c2a7e…c4d5"])
    }

    @Test func theTimeKeepsItsLeadWordAndWrittenZone() {
        #expect(TroubleshootRecognised.timeWindow(in: "fails since about 14:05 UTC, still happening")
                == "Since 14:05 UTC")
        #expect(TroubleshootRecognised.timeWindow(in: "Errors started AT 9:30") == "At 9:30")
        #expect(TroubleshootRecognised.timeWindow(in: "rolled out 2.41.0 at 14:02 bst") == "At 14:02 BST")
        #expect(TroubleshootRecognised.timeWindow(in: "the ratio is 3:1 across hosts") == nil)
        #expect(TroubleshootRecognised.timeWindow(in: "nothing timed here") == nil)
    }

    @Test func namedProjectsAndAVersionAreRecognised() {
        let text = "Nothing shipped on payments-gateway today; Ledger-Service rolled out 2.41.0 at 14:02."
        let details = TroubleshootRecognised.details(
            in: text, projects: ["payments-gateway", "ledger-service", "fx-rates"])
        #expect(details.map(\.kind) == [.time, .projects, .version])
        #expect(details[1].label == "payments-gateway, ledger-service")
        #expect(details[2].label == "Version 2.41.0")
    }

    @Test func anIPAddressIsNotReadAsAVersion() {
        let details = TroubleshootRecognised.details(in: "pod 10.42.7.13 restarted twice")
        #expect(details.isEmpty)
        #expect(TroubleshootRecognised.details(in: "").isEmpty)
    }
}
