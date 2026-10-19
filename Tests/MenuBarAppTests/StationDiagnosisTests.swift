import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): troubleshooting as the GUI's
// Troubleshoot sheet and tab start it. The choices a diagnosis offers (the site file's
// environments, the MCP servers each reaches, the agent's skills), and starting one from
// a brief: in the session's own tab, or in a new session in a project.
@MainActor
struct StationDiagnosisTests {

    private static let site = """
    {"environments": [{"name": "dev", "title": "Dev"}, {"name": "prd", "title": "Prod", "danger": true}]}
    """

    private static let mcp = """
    {"mcpServers": {
      "grafana-dev": {"command": "mcp-grafana", "environment": "dev"},
      "grafana-prd": {"command": "mcp-grafana", "environment": "prd"},
      "notes": {"command": "notes-mcp"}
    }}
    """

    // A host reading the site file and the shared MCP file, as the daemon does, and an
    // agent whose installed skills and switched-on servers are given.
    private func station(_ fixture: RunnerHarness, skills: [String] = [],
                         enabled: [DisabledMCPServer] = []) throws -> StationCommands {
        let siteFile = fixture.scratch.path("site-defaults.json")
        try Self.site.write(to: siteFile, atomically: true, encoding: .utf8)
        let mcpFile = fixture.scratch.path("mcp.json")
        try Self.mcp.write(to: mcpFile, atomically: true, encoding: .utf8)
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        var support = DiagnosisSupport.live(mcpConfigURL: mcpFile, siteFiles: [siteFile])
        support.skills = { _ in skills }
        support.enabledServers = { _, _ in enabled }
        station.diagnosis = support
        return station
    }

    // The tab offers the site's environments, the servers each one reaches (an untagged
    // server reaches all of them), the agent's skills, and the session's own projects.
    @Test(arguments: StationImplementation.allCases)
    func theOptionsComeFromTheSiteFileAndTheMCPFile(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let commands = kind.connect(to: try station(fixture, skills: ["grafana-mcp"]))

        let options = try await commands.diagnosisOptions(sessionID: fixture.session.id.uuidString, agent: nil)

        #expect(options.environments.map(\.name) == ["dev", "prd"])
        #expect(options.environments.map(\.title) == ["Dev", "Prod"])
        #expect(options.environments.map(\.isDangerous) == [false, true])
        #expect(options.servers(in: options.environments[0]) == ["grafana-dev", "notes"])
        #expect(options.servers(in: options.environments[1]) == ["grafana-prd", "notes"])
        #expect(options.skills == ["grafana-mcp"])
        #expect(options.agent == .claudeCode)
        #expect(options.projects == ["project"])

        // A site file that names no environment, or none at all, leaves the app's own two.
        #expect(TroubleshootEnvironment.site(from: [fixture.scratch.path("missing.json")]).map(\.name)
                == ["staging", "production"])
        await #expect(throws: StationRefusal.self) {
            try await commands.diagnosisOptions(sessionID: UUID().uuidString, agent: nil)
        }
    }

    // The brief goes to the session as its next prompt, with the evidence attached and
    // the troubleshooting context as instructions beside it. The session is marked as
    // troubleshooting and keeps to the servers the chosen environment reaches.
    @Test(arguments: StationImplementation.allCases)
    func aDiagnosisSendsTheBriefToTheSession(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        case "$input" in *'Troubleshooting context:'*'Environment: dev'*) ;; *) exit 7 ;; esac
        case "$input" in *'Incident time window (as supplied): 14:00 UTC'*) ;; *) exit 8 ;; esac
        case "$input" in *'`grafana-mcp`'*) ;; *) exit 9 ;; esac
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Looking."}]}}'
        """, mcpConfiguration: { _ in Data(#"{"mcpServers":{}}"#.utf8) }, host: RecordingHost())
        defer { fixture.tearDown() }
        let host = try station(fixture)
        let session = try await Followed(fixture, kind, station: host)
        let log = fixture.scratch.path("error.log")
        try "boom".write(to: log, atomically: true, encoding: .utf8)

        await #expect(throws: StationRefusal.self) {
            try await session.commands.startDiagnosis(RemoteDiagnosis(
                target: .session(session.id), problem: "  ", environment: "dev"))
        }
        await #expect(throws: StationRefusal.self) {
            try await session.commands.startDiagnosis(RemoteDiagnosis(
                target: .session(session.id), problem: "Slow", environment: "qa"))
        }
        await #expect(throws: StationRefusal.self) {
            try await session.commands.startDiagnosis(RemoteDiagnosis(
                target: .session(session.id), problem: "Slow", environment: "dev",
                attachments: [fixture.scratch.path("missing.log").path]))
        }

        let started = try await session.commands.startDiagnosis(RemoteDiagnosis(
            target: .session(session.id), problem: "Checkout is slow", environment: "dev",
            incidentTime: "14:00 UTC", attachments: [log.path], skills: ["grafana-mcp"]))

        #expect(started == session.id)
        #expect(await waitUntil {
            session.log.mirror?.header.isBusy == false
                && session.log.mirror?.messages.last?.text.hasSuffix("Looking.") == true
        }, "\(session.log.mirror?.messages.map(\.text) ?? [])")
        let prompt = try #require(session.log.mirror?.messages.first { $0.role == "user" })
        #expect(prompt.text.hasPrefix("Checkout is slow"))
        #expect(prompt.attachments == ["error.log"])
        let stored = try #require(fixture.store.session(fixture.session.id))
        #expect(stored.isTroubleshooting)
        #expect(stored.settings?.mcpServersEnabled == true)
        #expect(stored.settings?.allowedMCPServerNames == ["grafana-dev", "notes"])
    }

    // A diagnosis from scratch starts a new troubleshooting session in the project, on
    // the agent asked for. Codex is told to switch off the servers it has on that the
    // environment does not reach; with MCP off, all of them.
    @Test(arguments: StationImplementation.allCases)
    func aNewDiagnosisStartsATroubleshootingSession(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .codex, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let enabled = [DisabledMCPServer(name: "grafana-dev", transport: .stdio),
                       DisabledMCPServer(name: "grafana-prd", transport: .stdio)]
        let commands = kind.connect(to: try station(fixture, enabled: enabled))
        let projectID = fixture.session.projectID.uuidString

        let id = try await commands.startDiagnosis(RemoteDiagnosis(
            target: .project(projectID), agent: .codex, problem: "Errors spike", environment: "dev"))

        let session = try #require(UUID(uuidString: id).flatMap(fixture.store.session))
        #expect(session.id != fixture.session.id)
        #expect(session.projectID == fixture.session.projectID)
        #expect(session.agent == .codex)
        #expect(session.isTroubleshooting)
        #expect(session.settings?.disabledMCPServers?.map(\.name) == ["grafana-prd"])

        let off = try await commands.startDiagnosis(RemoteDiagnosis(
            target: .project(projectID), agent: .codex, problem: "Errors spike", environment: "prd",
            mcpServersEnabled: false))
        let quiet = try #require(UUID(uuidString: off).flatMap(fixture.store.session))
        #expect(quiet.settings?.mcpServersEnabled == false)
        #expect(quiet.settings?.disabledMCPServers?.map(\.name) == ["grafana-dev", "grafana-prd"])
        #expect(quiet.settings?.allowedMCPServerNames == nil)

        await #expect(throws: StationRefusal.self) {
            try await commands.startDiagnosis(RemoteDiagnosis(
                target: .project(UUID().uuidString), problem: "x", environment: "dev"))
        }
    }
}
