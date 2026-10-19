import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): an open session's header
// carries what the GUI's top bar shows over a session. Besides the title and state, that
// is the container it sits in, whether it is a troubleshooting session, the model it runs
// on, what it has spent where the agent shows that, the pull requests it opened, how many
// files it changed and how many of its agents are running or failed.
@MainActor
struct StationSessionHeaderTests {

    @Test(arguments: StationImplementation.allCases)
    func theHeaderCarriesModelCostPullRequestsAndAgents(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-header")
        let index = scratch.path("projects.json")
        let preferences = try #require(UserDefaults(suiteName: "station-header-\(UUID().uuidString)"))
        let sessionID: UUID
        do {
            let seed = ProjectStore(storeURL: index)
            let alpha = try project(named: "alpha", in: seed, under: scratch)
            let session = try seed.insertSession(in: alpha.id, seed: .init(agent: .claudeCode,
                                                                           isTroubleshooting: true)).get()
            sessionID = session.id
            seed.renameSession(session.id, to: "Why is login slow")
            seed.append(ChatMessage(role: .user, text: "Look into it", date: Date(timeIntervalSinceNow: -60)),
                        to: session.id)
            let reviewer = ToolUse(id: "reviewer", name: "Task",
                                   input: #"{"subagent_type":"reviewer","description":"review the diff"}"#,
                                   result: "it broke", isError: true, startedAt: Date())
            seed.append(ChatMessage(role: .assistant, tools: [reviewer]), to: session.id)
            seed.recordUsage(TurnUsage(costUSD: 0.42, contextWindow: 200_000, model: "opus"),
                             from: .claudeCode, for: session.id)
            seed.recordContext(50_000, contextWindow: 200_000, model: "opus", from: .claudeCode, for: session.id)
            seed.notePullRequest(PullRequest(number: 12, url: "https://github.com/teya/alpha/pull/12"),
                                 for: session.id)
            #expect(seed.save())
        }

        let station = StationCommands.start(host: RecordingHost(), storeURL: index, preferences: preferences)
        let commands = kind.connect(to: station)
        let header = try #require(try await commands.openSession(sessionID.uuidString)).snapshot.header

        #expect(header.title == "Why is login slow")
        #expect(header.container == "alpha")
        #expect(header.containerKind == .project)
        #expect(header.isTroubleshooting == true)
        #expect(header.model == "Opus")
        #expect(header.cost == 0.42)
        #expect(header.context == 0.25)
        #expect(header.pullRequests == [PullRequest(number: 12, url: "https://github.com/teya/alpha/pull/12")])
        #expect(header.agentsRunning == 0)
        #expect(header.agentsFailed == 1)

        // Cost turned off for the agent in the shared settings leaves it off the header.
        Preferences.setShowCost(false, for: .claudeCode, in: preferences)
        await commands.closeSession(sessionID.uuidString)
        let hidden = try #require(try await commands.openSession(sessionID.uuidString)).snapshot.header
        #expect(hidden.cost == nil)
        #expect(hidden.model == "Opus")
    }

    // A workspace session names its workspace, and an agent that reports no cost has none.
    @Test(arguments: StationImplementation.allCases)
    func aWorkspaceSessionNamesItsWorkspaceAndCodexShowsNoCost(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-header")
        let index = scratch.path("projects.json")
        let preferences = try #require(UserDefaults(suiteName: "station-header-\(UUID().uuidString)"))
        let sessionID: UUID
        do {
            let seed = ProjectStore(storeURL: index)
            let alpha = try project(named: "alpha", in: seed, under: scratch)
            let beta = try project(named: "beta", in: seed, under: scratch)
            let both = try #require(seed.addWorkspace(name: "both", projectIDs: [alpha.id, beta.id],
                                                      leadProjectID: alpha.id))
            let session = try seed.insertSession(in: both.id, projects: [SessionProject(projectID: alpha.id),
                                                                        SessionProject(projectID: beta.id)],
                                                 seed: .init(agent: .codex)).get()
            sessionID = session.id
            seed.recordUsage(TurnUsage(costUSD: 0), from: .codex, for: session.id)
            #expect(seed.save())
        }

        let station = StationCommands.start(host: RecordingHost(), storeURL: index, preferences: preferences)
        let header = try #require(try await kind.connect(to: station).openSession(sessionID.uuidString))
            .snapshot.header

        #expect(header.container == "both")
        #expect(header.containerKind == .workspace)
        #expect(header.isTroubleshooting == false)
        #expect(header.cost == nil)
        #expect(header.pullRequests == [])
        #expect(header.agentsRunning == 0)
        #expect(header.agentsFailed == 0)
    }

    private func project(named name: String, in store: ProjectStore,
                         under scratch: ScratchDirectory) throws -> Project {
        let folder = scratch.path(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try #require(store.addProject(at: folder))
    }
}
