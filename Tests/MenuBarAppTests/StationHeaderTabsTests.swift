import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): what the top bar shows
// besides the identity row. The header names the tabs that apply, in the GUI's order,
// the warnings the GUI's strip would show (a missing folder, a lost checkout, an agent
// that is not installed), and the agent the indicator jumps to.
@MainActor
struct StationHeaderTabsTests {

    // A plain session has every tab, Chat first, and nothing to warn about.
    @Test(arguments: StationImplementation.allCases)
    func aPlainSessionHasEveryTabAndNoWarnings(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }

        let header = try await Followed(fixture, kind).log.mirror?.header

        #expect(header?.tabs?.map(\.kind) == [.chat, .design, .troubleshoot, .changes, .explorer])
        #expect(header?.tabs?.map(\.title) == ["Chat", "Design", "Troubleshoot", "Changes", "Explorer"])
        #expect(header?.warnings == [])
        #expect(header?.agentToolID == nil)
    }

    // The agents indicator points at the agent's call in the transcript: a running one
    // first, otherwise the failed one.
    @Test(arguments: StationImplementation.allCases)
    func theHeaderPointsAtTheAgentTheIndicatorCounts(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        fixture.store.append(ChatMessage(role: .user, text: "Review it", date: Date(timeIntervalSinceNow: -60)),
                             to: fixture.session.id)
        let reviewer = ToolUse(id: "reviewer", name: "Task",
                               input: #"{"subagent_type":"reviewer","description":"review the diff"}"#,
                               result: "it broke", isError: true, startedAt: Date())
        fixture.store.append(ChatMessage(role: .assistant, tools: [reviewer]), to: fixture.session.id)

        let header = try await Followed(fixture, kind).log.mirror?.header

        #expect(header?.agentsFailed == 1)
        #expect(header?.agentToolID == "reviewer")
    }

    // A project folder that has gone is the first thing the strip says.
    @Test(arguments: StationImplementation.allCases)
    func aMissingProjectFolderIsWarnedAbout(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        try FileManager.default.removeItem(at: fixture.projectURL)

        let warnings = try await Followed(fixture, kind).log.mirror?.header.warnings

        #expect(warnings?.count == 1)
        #expect(warnings?.first?.kind == .missingFolder)
        #expect(warnings?.first?.message.hasPrefix("Folder not found at ") == true)
        #expect(warnings?.first?.canRebuild == false)
    }

    // A worktree removed outside the app can be rebuilt, and the warning says so.
    @Test(arguments: StationImplementation.allCases)
    func aLostWorktreeCanBeRebuilt(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let lost = fixture.store.newSession(in: fixture.session.projectID,
                                            worktreePath: fixture.scratch.path("gone-worktree").path,
                                            worktreeBranch: "feature")

        let warnings = try await Followed(fixture, kind, sessionID: lost.id).log.mirror?.header.warnings

        #expect(warnings?.count == 1)
        #expect(warnings?.first?.kind == .missingCheckout)
        #expect(warnings?.first?.message.hasPrefix("Worktree not found at ") == true)
        #expect(warnings?.first?.canRebuild == true)
    }

    // A session whose agent is not installed cannot run, and the strip says why.
    @Test(arguments: StationImplementation.allCases)
    func anAgentThatIsNotInstalledIsWarnedAbout(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .codex, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let claude = try fixture.store.insertSession(in: fixture.session.projectID,
                                                     seed: .init(agent: .claudeCode)).get()

        let warnings = try await Followed(fixture, kind, sessionID: claude.id).log.mirror?.header.warnings

        #expect(warnings?.map(\.kind) == [.agentMissing])
        #expect(warnings?.first?.message == "Claude Code CLI not found on PATH. Sessions cannot run until it is installed.")
    }
}
