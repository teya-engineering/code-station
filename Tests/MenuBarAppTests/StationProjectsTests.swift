import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): what a front end does to a
// project from the sidebar. It adds one by its folder's path, renames, pins and unpins
// it, snoozes its cleanup and wakes it, and clears its idle sessions or removes it, each
// of those last two after reading what would go and what would stay, as the GUI's impact
// dialogs say it.
@MainActor
struct StationProjectsTests {

    private func station(_ scratch: ScratchDirectory) -> StationCommands {
        StationCommands(store: ProjectStore(storeURL: scratch.path("projects.json")),
                        runner: StationNewSessionTests.runner(), refreshInterval: .milliseconds(50))
    }

    private func folder(_ name: String, in scratch: ScratchDirectory) throws -> URL {
        let url = scratch.path(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func container(_ id: String, in commands: any StationInterface) async throws -> RemoteContainer? {
        try await commands.listDirectory().containers?.first { $0.id == id }
    }

    // A folder's path adds it as a project, answered with its id; the list then has it,
    // with the folder in full. The same folder again answers with the project it already
    // is, and a path that is not a folder is refused, naming it.
    @Test(arguments: StationImplementation.allCases)
    func aProjectIsAddedByItsFolderPath(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-projects")
        let alpha = try folder("alpha", in: scratch)
        let commands = kind.connect(to: station(scratch))

        let id = try await commands.addProject(path: alpha.path)

        let added = try #require(try await container(id, in: commands))
        #expect(added.name == "alpha")
        #expect(added.kind == .project)
        #expect(added.folder == alpha.standardizedFileURL.path)
        #expect(try await commands.addProject(path: alpha.path + "/") == id)
        #expect(try await commands.listDirectory().containers?.count == 1)

        let missing = scratch.path("nowhere").path
        await #expect(throws: StationRefusal("\(missing) is not a folder.")) {
            try await commands.addProject(path: missing)
        }
        await #expect(throws: StationRefusal("Type the folder's path.")) {
            try await commands.addProject(path: "  ")
        }
    }

    // Rename, pin and unpin, snooze and wake each change the project as the list then
    // shows it. An empty name is refused, and so is a project that has gone.
    @Test(arguments: StationImplementation.allCases)
    func aProjectIsRenamedPinnedSnoozedAndWoken(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-projects")
        let commands = kind.connect(to: station(scratch))
        let id = try await commands.addProject(path: try folder("alpha", in: scratch).path)

        try await commands.changeProject(id, .rename(name: "  Alpha app "))
        #expect(await eventually { try await container(id, in: commands)?.name == "Alpha app" })
        await #expect(throws: StationRefusal("Give Alpha app a name.")) {
            try await commands.changeProject(id, .rename(name: " "))
        }

        try await commands.changeProject(id, .pin(true))
        #expect(await eventually { try await container(id, in: commands)?.isPinned == true })
        try await commands.changeProject(id, .pin(false))
        #expect(await eventually { try await container(id, in: commands)?.isPinned == false })

        #expect(try await container(id, in: commands)?.snoozedUntil == nil)
        try await commands.changeProject(id, .snoozeCleanup)
        #expect(await eventually { try await container(id, in: commands)?.snoozedUntil != nil })
        let once = try #require(try await container(id, in: commands)?.snoozedUntil)
        #expect(abs(once.timeIntervalSinceNow - 86_400) < 60)
        // Snoozing again adds a day to the deadline it already has.
        try await commands.changeProject(id, .snoozeCleanup)
        #expect(await eventually {
            try await container(id, in: commands)?.snoozedUntil.map { abs($0.timeIntervalSince(once) - 86_400) < 1 } == true
        })
        try await commands.changeProject(id, .wakeCleanup)
        #expect(await eventually { try await container(id, in: commands)?.snoozedUntil == nil })

        await #expect(throws: StationRefusal("That project is no longer available.")) {
            try await commands.changeProject(UUID().uuidString, .pin(true))
        }
    }

    // Clearing reads first: the idle sessions that go, the running one that stays and
    // the folder that stays, with the warning. Clearing then takes the idle ones only. A
    // project with nothing idle is refused, saying so.
    @Test(arguments: StationImplementation.allCases)
    func clearingIdleSessionsSaysWhatGoesThenKeepsTheRunningOne(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        IFS= read -r never
        """)
        defer { fixture.tearDown() }
        let project = try #require(fixture.store.project(fixture.session.projectID))
        for title in ["Idle one", "Idle two"] {
            let idle = try fixture.store.insertSession(in: project.id, seed: .init(agent: .claudeCode)).get()
            fixture.store.renameSession(idle.id, to: title)
        }
        let station = StationCommands(store: fixture.store, runner: fixture.runner, refreshInterval: .milliseconds(50))
        let commands = kind.connect(to: station)
        fixture.runner.send("Keep going", sessionID: fixture.session.id, store: fixture.store)
        #expect(await eventually { try await container(project.id.uuidString, in: commands)?.running == 1 })

        let impact = try await commands.readRemoval(.idleSessions, of: project.id.uuidString)
        #expect(impact.title == "Clear 2 sessions from project?")
        #expect(impact.subject == RemoteImpact.Subject(name: "project", kind: .project))
        #expect(impact.rows == [
            RemoteImpact.Row(title: "2 sessions", detail: "Conversation history is removed from Code Station."),
            RemoteImpact.Row(title: "1 running session stays", detail: "Sessions that are still working are left alone.",
                             kept: true),
            RemoteImpact.Row(title: "Original project folder stays", detail: project.collapsedPath, kept: true),
        ])
        #expect(impact.warning == "Conversation history cannot be restored.")
        #expect(impact.action == "Clear sessions")

        try await commands.remove(.idleSessions, of: project.id.uuidString)
        #expect(await eventually {
            try await container(project.id.uuidString, in: commands)?.sessions.map(\.id) == [fixture.session.id.uuidString]
        })
        await #expect(throws: StationRefusal("project has no idle sessions.")) {
            try await commands.readRemoval(.idleSessions, of: project.id.uuidString)
        }
        fixture.runner.stopAll()
    }

    // Removing reads first: the sessions and worktrees that go, the shortcuts the host
    // saved against it, the folder that stays and the warning. Removing then takes the
    // project, its sessions and its shortcuts; the folder is left on disk.
    @Test(arguments: StationImplementation.allCases)
    func removingAProjectSaysWhatGoesThenTakesIt(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-projects")
        let host = station(scratch)
        let commands = kind.connect(to: host)
        let alpha = try folder("alpha", in: scratch)
        let id = try await commands.addProject(path: alpha.path)
        let uuid = try #require(UUID(uuidString: id))
        _ = try host.store.insertSession(in: uuid, seed: .init(agent: .claudeCode)).get()
        _ = host.shortcuts.add(name: "Tests", text: "swift test", projectID: uuid)
        _ = host.shortcuts.add(name: "Build", text: "swift build", projectID: uuid)
        let shared = try #require(host.shortcuts.add(name: "Prune", text: "git prune", availableInAllProjects: true))

        let impact = try await commands.readRemoval(.project, of: id)
        #expect(impact.title == "Remove alpha?")
        #expect(impact.message == "This project will leave Code Station and every workspace it belongs to.")
        #expect(impact.subject == RemoteImpact.Subject(name: "alpha", kind: .project))
        #expect(impact.rows.map(\.title) == ["1 session and 0 worktrees", "2 saved shortcuts",
                                            "Original project folder stays"])
        #expect(impact.rows.map(\.kept) == [false, false, true])
        #expect(impact.warning == "Session history cannot be restored.")
        #expect(impact.action == "Remove project")

        try await commands.remove(.project, of: id)
        #expect(await eventually { try await container(id, in: commands) == nil })
        #expect(host.store.sessions.isEmpty)
        #expect(host.shortcuts.shortcuts.map(\.id) == [shared])
        #expect(FileManager.default.fileExists(atPath: alpha.path))
        await #expect(throws: StationRefusal("That project is no longer available.")) {
            try await commands.readRemoval(.project, of: id)
        }
    }

    // The daemon builds its station as `code-station daemon` does, with the shortcut store
    // beside its index, so a project removed while it hosts takes its saved shortcuts too,
    // as it does under the GUI.
    @Test func removingAProjectUnderTheDaemonTakesItsShortcuts() async throws {
        let scratch = ScratchDirectory(prefix: "station-projects")
        let host = StationCommands.start(host: SilentHost(), storeURL: scratch.path("projects.json"))
        let commands = StationImplementation.socket.connect(to: host)
        let alpha = try folder("alpha", in: scratch)
        let id = try await commands.addProject(path: alpha.path)
        let saved = try await commands.saveShortcut(RemoteShortcutDraft(name: "Tests", command: "swift test",
                                                                        projectID: id))
        #expect(try await commands.readRemoval(.project, of: id).rows.map(\.title).contains("1 saved shortcut"))

        try await commands.remove(.project, of: id)

        let reread = ShortcutStore(storageURL: scratch.path("shortcuts.json"), startingShortcuts: [])
        let savedID = try #require(UUID(uuidString: saved))
        #expect(reread.shortcut(savedID) == nil)
        #expect(try await commands.listShortcuts(in: nil).shortcuts.isEmpty)
    }

    // A task deletes rather than removes, and its own folder goes with it.
    @Test(arguments: StationImplementation.allCases)
    func deletingATaskTakesItsFolder(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-projects")
        let host = station(scratch)
        let commands = kind.connect(to: host)
        let task = try host.store.addTask(named: "Sweep", prompt: "Do the thing", in: scratch.path("tasks")).get()

        let impact = try await commands.readRemoval(.project, of: task.id.uuidString)
        #expect(impact.title == "Delete Sweep?")
        #expect(impact.subject?.kind == .task)
        #expect(impact.action == "Delete task")
        await #expect(throws: StationRefusal("Sweep has no idle runs.")) {
            try await commands.readRemoval(.idleSessions, of: task.id.uuidString)
        }

        try await commands.remove(.project, of: task.id.uuidString)
        #expect(await eventually { try await container(task.id.uuidString, in: commands) == nil })
        #expect(!FileManager.default.fileExists(atPath: task.path))
    }
}
