import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): what the rest of the GUI's
// sidebar reads comes with the directory. Each session row says why it belongs in the
// Needs you stack, in the GUI's words; a workspace names its member projects, which the
// filter matches; the cleanup strips at the foot get their counts and countdowns; and a
// host handing the station over says to whom.
@MainActor
struct StationSidebarExtrasTests {

    private static let writeRequest = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/tmp/p/hello.txt","content":"hi"},"tool_use_id":"toolu_1"}}"#

    // A tool waiting for permission and a turn that finished unseen each carry their
    // notice and the reason the GUI's stack card gives; a quiet session carries none.
    @Test(arguments: StationImplementation.allCases)
    func sessionRowsCarryTheirNoticeAndReason(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '\(Self.writeRequest)'
        IFS= read -r answer
        """)
        defer { fixture.tearDown() }
        let project = try #require(fixture.store.project(fixture.session.projectID))
        let finished = try fixture.store.insertSession(in: project.id, seed: .init(agent: .claudeCode)).get()
        fixture.store.renameSession(finished.id, to: "Finished")
        let quiet = try fixture.store.insertSession(in: project.id, seed: .init(agent: .claudeCode)).get()
        fixture.store.renameSession(quiet.id, to: "Quiet")
        fixture.store.noteTurnEnded(for: finished.id)
        let station = StationCommands(store: fixture.store, runner: fixture.runner,
                                      refreshInterval: .milliseconds(50))
        let commands = kind.connect(to: station)

        fixture.runner.send("Write hello", sessionID: fixture.session.id, store: fixture.store)

        func row(_ id: UUID) async throws -> RemoteSessionRow? {
            try await commands.listDirectory().containers?.flatMap(\.sessions).first { $0.id == id.uuidString }
        }
        #expect(await eventually { try await row(fixture.session.id)?.notice?.kind == .needsInput })
        #expect(try await row(fixture.session.id)?.notice?.reason == "permission · write")
        #expect(try await row(finished.id)?.notice == RemoteNotice(kind: .finished, reason: "finished while away"))
        #expect(try await row(quiet.id)?.notice == nil)
        fixture.runner.stopAll()
    }

    // The old-sessions strip counts the sessions past the shared age that are not busy
    // or snoozed, with the age it counts from and the cohort the sweep will take; the orphaned-worktrees strip counts what
    // the host's upkeep found and their size, with the pruning countdown while automatic
    // pruning is on. A workspace names its member projects.
    @Test(arguments: StationImplementation.allCases)
    func theDirectoryCarriesTheCleanupStripCountsAndWorkspaceMembers(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-extras")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let alphaFolder = scratch.path("alpha")
        let betaFolder = scratch.path("beta")
        try FileManager.default.createDirectory(at: alphaFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaFolder, withIntermediateDirectories: true)
        let alpha = try #require(store.addProject(at: alphaFolder))
        let beta = try #require(store.addProject(at: betaFolder))
        _ = try #require(store.addWorkspace(name: "both", projectIDs: [alpha.id, beta.id], leadProjectID: alpha.id))
        for title in ["Old one", "Old two"] {
            let session = try store.insertSession(in: alpha.id, seed: .init(agent: .claudeCode)).get()
            store.renameSession(session.id, to: title)
            store.append(ChatMessage(role: .assistant, text: "Done", date: Date().addingTimeInterval(-10 * 86_400)),
                         to: session.id)
        }
        let fresh = try store.insertSession(in: beta.id, seed: .init(agent: .claudeCode)).get()
        store.append(ChatMessage(role: .assistant, text: "Done", date: Date()), to: fresh.id)

        let preferences = try #require(UserDefaults(suiteName: "station-extras-\(UUID().uuidString)"))
        Preferences.setOldSessionDays(7, in: preferences)
        Preferences.setAutoPruneOrphanedWorktrees(true, in: preferences)
        let monitor = OrphanedWorktreeMonitor(discover: { projectPath, _ in
            guard projectPath.hasSuffix("/alpha") else { return [] }
            return [GitWorktree.Orphaned(path: "/worktrees/stray", branch: "code-station/stray", allocatedBytes: 2_048)]
        })
        let station = StationCommands(store: store, runner: StationNewSessionTests.runner(),
                                      refreshInterval: .milliseconds(50), preferences: preferences)
        let upkeep = StationUpkeep(station: station, orphanedWorktrees: monitor,
                                   preferences: preferences, pace: .test)
        upkeep.start()
        defer { upkeep.stop() }
        let commands = kind.connect(to: station)

        #expect(await eventually { try await commands.listDirectory().cleanup?.orphanedWorktrees == 1 })
        let directory = try await commands.listDirectory()
        let cleanup = try #require(directory.cleanup)
        #expect(cleanup.oldSessions == 2)
        #expect(cleanup.oldSessionDays == 7)
        // The sweep, on by default, has settled on both and counts down to them.
        #expect(cleanup.oldSessionsDeleting == 2)
        #expect(cleanup.oldSessionsDeletingAt != nil)
        #expect(cleanup.orphanedBytes == 2_048)
        #expect(cleanup.orphansPruneAt != nil)
        #expect(directory.containers?.first { $0.name == "both" }?.members == ["alpha", "beta"])
        #expect(directory.containers?.first { $0.name == "alpha" }?.members == nil)
        #expect(directory.handingOverTo == nil)

        // With automatic pruning off there is no countdown.
        Preferences.setAutoPruneOrphanedWorktrees(false, in: preferences)
        #expect(await eventually { try await commands.listDirectory().cleanup?.orphansPruneAt == nil })
    }

    // A host handing the station over says who to in every list it sends from then on,
    // so a front end can say so until it is listing from the next host.
    @Test(arguments: StationImplementation.allCases)
    func aHostHandingOverSaysWhoToInTheDirectory(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-extras")
        let station = StationCommands(store: ProjectStore(storeURL: scratch.path("projects.json")),
                                      runner: StationNewSessionTests.runner())
        station.letGo = {}
        let commands = kind.connect(to: station)
        #expect(try await commands.listDirectory().handingOverTo == nil)

        _ = try await commands.handOver(to: "the Code Station app")

        #expect(try await commands.listDirectory().handingOverTo == "the Code Station app")
    }
}
