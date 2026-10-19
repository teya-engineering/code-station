import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): command shortcuts, saved
// shell commands the station runs for any front end. A project offers its own and the
// shared ones, run in its folder; a session offers those of each project it works in, run
// in its checkout; the Mac's own list (the Tools entry) runs from the home folder. A
// client lists them, runs and stops one, reads what it printed, and adds and edits them,
// all saved to the file the GUI reads.
@MainActor
struct StationShortcutsTests {

    @Test(arguments: StationImplementation.allCases)
    func aProjectListsItsOwnAndTheSharedShortcuts(_ kind: StationImplementation) async throws {
        let fixture = try Fixture()
        let alpha = try fixture.project("alpha")
        let beta = try fixture.project("beta")
        let tests = try #require(fixture.shortcuts.add(name: "Tests", text: "swift test", projectID: alpha.id))
        _ = fixture.shortcuts.add(name: "Lint", text: "swiftlint", projectID: beta.id)
        let shared = try #require(fixture.shortcuts.add(name: "Prune", text: "git prune", availableInAllProjects: true))
        _ = fixture.shortcuts.add(name: "Docker", text: "docker ps")
        let commands = kind.connect(to: fixture.station)

        let listed = try await commands.listShortcuts(in: alpha.id.uuidString)

        #expect(listed.title == "alpha")
        #expect(listed.projectID == alpha.id.uuidString)
        #expect(listed.shortcuts.map(\.name) == ["Tests", "Prune"])
        let first = try #require(listed.shortcuts.first)
        #expect(first.id == tests.uuidString)
        #expect(first.command == "swift test")
        #expect(first.directory == alpha.path)
        #expect(first.run.outcome == .never)
        #expect(listed.shortcuts.last?.id == shared.uuidString)
        #expect(listed.shortcuts.last?.availableInAllProjects == true)
    }

    @Test(arguments: StationImplementation.allCases)
    func theMacsOwnListRunsFromHome(_ kind: StationImplementation) async throws {
        let fixture = try Fixture()
        let alpha = try fixture.project("alpha")
        _ = fixture.shortcuts.add(name: "Tests", text: "swift test", projectID: alpha.id)
        _ = fixture.shortcuts.add(name: "Docker", text: "docker ps")
        let commands = kind.connect(to: fixture.station)

        let listed = try await commands.listShortcuts(in: nil)

        #expect(listed.shortcuts.map(\.name) == ["Docker"])
        #expect(listed.shortcuts.first?.directory == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(listed.projectID == nil)
    }

    @Test(arguments: StationImplementation.allCases)
    func aSessionRunsItsProjectsShortcutsInItsCheckout(_ kind: StationImplementation) async throws {
        let fixture = try Fixture()
        let alpha = try fixture.project("alpha")
        _ = fixture.shortcuts.add(name: "Tests", text: "swift test", projectID: alpha.id)
        let session = try fixture.store.insertSession(in: alpha.id, seed: .init(agent: .claudeCode)).get()
        fixture.store.renameSession(session.id, to: "Fix the login bug")
        let commands = kind.connect(to: fixture.station)

        let listed = try await commands.listShortcuts(in: session.id.uuidString)

        #expect(listed.title == "Fix the login bug")
        #expect(listed.projectID == alpha.id.uuidString)
        #expect(listed.shortcuts.map(\.name) == ["Tests"])
        #expect(listed.shortcuts.first?.directory == alpha.path)
    }

    @Test(arguments: StationImplementation.allCases)
    func runningAShortcutShowsWhatItPrintedAndHowItEnded(_ kind: StationImplementation) async throws {
        let fixture = try Fixture()
        let alpha = try fixture.project("alpha")
        let id = try #require(fixture.shortcuts.add(name: "Where", text: "echo here; pwd", projectID: alpha.id))
        let failing = try #require(fixture.shortcuts.add(name: "Fail", text: "echo nope; exit 3", projectID: alpha.id))
        let commands = kind.connect(to: fixture.station)
        let scope = alpha.id.uuidString

        let started = try await commands.runShortcut(id.uuidString, in: scope)
        #expect(started.name == "Where")
        #expect(started.directory == alpha.path)

        var output = started
        #expect(await eventually {
            output = try await commands.readShortcutOutput(id.uuidString, in: scope)
            return output.run.outcome == .passed
        }, "\(output)")
        #expect(output.text.contains("here"))
        #expect(output.text.contains("alpha"))
        #expect(output.run.exitStatus == 0)
        #expect(output.run.at != nil)

        _ = try await commands.runShortcut(failing.uuidString, in: scope)
        #expect(await eventually {
            try await commands.readShortcutOutput(failing.uuidString, in: scope).run.outcome == .failed
        })
        let failed = try await commands.readShortcutOutput(failing.uuidString, in: scope)
        #expect(failed.run.exitStatus == 3)
        #expect(failed.text.contains("nope"))

        let listed = try await commands.listShortcuts(in: scope)
        #expect(listed.shortcuts.map(\.run.outcome) == [.passed, .failed])
        #expect(listed.lastStartedID == failing.uuidString)
    }

    @Test(arguments: StationImplementation.allCases)
    func aRunningShortcutCanBeStopped(_ kind: StationImplementation) async throws {
        let fixture = try Fixture()
        let alpha = try fixture.project("alpha")
        let id = try #require(fixture.shortcuts.add(name: "Serve", text: "echo serving; sleep 30", projectID: alpha.id))
        let commands = kind.connect(to: fixture.station)
        let scope = alpha.id.uuidString

        let started = try await commands.runShortcut(id.uuidString, in: scope)
        #expect(started.run.outcome == .running)
        #expect(await eventually {
            try await commands.readShortcutOutput(id.uuidString, in: scope).text.contains("serving")
        })
        #expect(try await commands.listShortcuts(in: scope).shortcuts.first?.run.outcome == .running)

        let stopped = try await commands.stopShortcut(id.uuidString, in: scope)

        #expect(stopped.run.outcome == .stopped)
        #expect(stopped.text.contains("serving"))
        #expect(!fixture.shortcuts.isRunningAnywhere(id))
    }

    @Test(arguments: StationImplementation.allCases)
    func aShortcutIsAddedAndEditedAndSavedForTheGUI(_ kind: StationImplementation) async throws {
        let fixture = try Fixture()
        let alpha = try fixture.project("alpha")
        let commands = kind.connect(to: fixture.station)

        let id = try await commands.saveShortcut(RemoteShortcutDraft(
            name: "  Tests ", command: " swift test ", projectID: alpha.id.uuidString))

        let uuid = try #require(UUID(uuidString: id))
        let saved = try #require(fixture.shortcuts.shortcut(uuid))
        #expect(saved.name == "Tests")
        #expect(saved.text == "swift test")
        #expect(saved.projectID == alpha.id)
        #expect(try await commands.listShortcuts(in: alpha.id.uuidString).shortcuts.map(\.name) == ["Tests"])

        let edited = try await commands.saveShortcut(RemoteShortcutDraft(
            id: id, name: "All tests", command: "swift test --parallel", projectID: alpha.id.uuidString,
            availableInAllProjects: true))

        #expect(edited == id)
        let reread = ShortcutStore(storageURL: fixture.shortcuts.storageURL, startingShortcuts: [])
        let again = try #require(reread.shortcut(saved.id))
        #expect(again.name == "All tests")
        #expect(again.text == "swift test --parallel")
        #expect(again.availableInAllProjects)
        #expect(again.projectID == nil)
        #expect(try await commands.listShortcuts(in: nil).shortcuts.map(\.name) == ["All tests"])
    }

    @Test(arguments: StationImplementation.allCases)
    func aShortcutIsRemoved(_ kind: StationImplementation) async throws {
        let fixture = try Fixture()
        let alpha = try fixture.project("alpha")
        let id = try #require(fixture.shortcuts.add(name: "Tests", text: "swift test", projectID: alpha.id))
        let commands = kind.connect(to: fixture.station)

        try await commands.removeShortcut(id.uuidString)

        #expect(fixture.shortcuts.shortcut(id) == nil)
        #expect(try await commands.listShortcuts(in: alpha.id.uuidString).shortcuts.isEmpty)
    }

    @Test(arguments: StationImplementation.allCases)
    func whatCannotBeDoneIsRefused(_ kind: StationImplementation) async throws {
        let fixture = try Fixture()
        let alpha = try fixture.project("alpha")
        let beta = try fixture.project("beta")
        let workspace = try #require(fixture.store.addWorkspace(name: "both", projectIDs: [alpha.id, beta.id],
                                                                leadProjectID: alpha.id))
        let betaOnly = try #require(fixture.shortcuts.add(name: "Lint", text: "swiftlint", projectID: beta.id))
        let serve = try #require(fixture.shortcuts.add(name: "Serve", text: "sleep 30", projectID: alpha.id))
        let commands = kind.connect(to: fixture.station)

        // A workspace screen has no shortcuts of its own, as in the GUI.
        await #expect(throws: StationRefusal.self) { try await commands.listShortcuts(in: workspace.id.uuidString) }
        await #expect(throws: StationRefusal.self) { try await commands.listShortcuts(in: UUID().uuidString) }
        // A shortcut is only run where it is offered.
        await #expect(throws: StationRefusal.self) {
            try await commands.runShortcut(betaOnly.uuidString, in: alpha.id.uuidString)
        }
        await #expect(throws: StationRefusal.self) {
            try await commands.saveShortcut(RemoteShortcutDraft(name: " ", command: "make"))
        }
        await #expect(throws: StationRefusal.self) {
            try await commands.saveShortcut(RemoteShortcutDraft(id: UUID().uuidString, name: "Gone", command: "make"))
        }
        // A running command is stopped before it is edited.
        _ = try await commands.runShortcut(serve.uuidString, in: alpha.id.uuidString)
        await #expect(throws: StationRefusal.self) {
            try await commands.saveShortcut(RemoteShortcutDraft(id: serve.uuidString, name: "Serve",
                                                                command: "sleep 60",
                                                                projectID: alpha.id.uuidString))
        }
        _ = try await commands.stopShortcut(serve.uuidString, in: alpha.id.uuidString)
    }

    // A host and its shortcut store on a scratch folder. The store sits beside the index,
    // as the station's own does beside the real one.
    @MainActor
    private struct Fixture {
        let scratch = ScratchDirectory(prefix: "station-shortcuts")
        let store: ProjectStore
        let station: StationCommands
        var shortcuts: ShortcutStore { station.shortcuts }

        @MainActor
        init() throws {
            store = ProjectStore(storeURL: scratch.path("projects.json"))
            station = StationCommands(store: store, runner: SessionRunner(paths: [.claudeCode: "/usr/bin/true"],
                                                                          host: RecordingHost()))
        }

        @MainActor
        func project(_ name: String) throws -> Project {
            let folder = scratch.path(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try #require(store.addProject(at: folder))
        }
    }
}
