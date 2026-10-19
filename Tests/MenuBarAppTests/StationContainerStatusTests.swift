import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): what the status strip under
// a project, workspace or task screen reads, as the GUI's detail screens read it. A
// project says how its checkout stands (branch, ahead and behind, clean or how many
// files are uncommitted, the last commit); a workspace lists its projects, lead first,
// each with its checkout; a task counts its runs and inputs, names its last run and when
// the next one is due.
@MainActor
struct StationContainerStatusTests {

    @Test(arguments: StationImplementation.allCases)
    func aProjectReadsItsCheckout(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-status")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let alpha = try repository(named: "alpha", in: store, under: scratch)
        try "changed\n".write(to: scratch.path("alpha/README.md"), atomically: true, encoding: .utf8)
        let commands = kind.connect(to: StationCommands(store: store, runner: runner()))

        let status = try await commands.readContainerStatus(alpha.id.uuidString)

        #expect(status.kind == .project)
        let checkout = try #require(status.checkout)
        #expect(checkout.state == "ready")
        #expect(checkout.branch == "main")
        #expect(checkout.ahead == 0)
        #expect(checkout.behind == 0)
        #expect(checkout.uncommitted == 1)
        #expect(checkout.lastCommitSubject == "first")
        #expect(checkout.lastCommitDate != nil)
        #expect(status.members == nil)
        #expect(status.task == nil)
    }

    @Test(arguments: StationImplementation.allCases)
    func aWorkspaceListsItsProjectsLeadFirst(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-status")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let alpha = try repository(named: "alpha", in: store, under: scratch)
        let beta = try folder(named: "beta", in: store, under: scratch)
        let both = try #require(store.addWorkspace(name: "both", projectIDs: [beta.id, alpha.id],
                                                   leadProjectID: alpha.id))
        let commands = kind.connect(to: StationCommands(store: store, runner: runner()))

        let status = try await commands.readContainerStatus(both.id.uuidString)

        #expect(status.kind == .workspace)
        let members = try #require(status.members)
        #expect(members.map(\.name) == ["alpha", "beta"])
        #expect(members.map(\.isLead) == [true, false])
        #expect(members[0].checkout?.branch == "main")
        #expect(members[0].checkout?.uncommitted == 0)
        #expect(members[1].checkout?.state == "notARepo")
        #expect(status.checkout == nil)
    }

    @Test(arguments: StationImplementation.allCases)
    func aTaskCountsItsRunsAndSaysWhenTheNextIsDue(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-status")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let nightly = try store.addTask(named: "nightly", prompt: "Check {{branch}} on {{host}}",
                                        in: scratch.path("tasks")).get()
        let commands = kind.connect(to: StationCommands(store: store, runner: runner()))

        let never = try #require(try await commands.readContainerStatus(nightly.id.uuidString).task)
        #expect(never.runs == 0)
        #expect(never.inputs == 2)
        #expect(never.lastRun == nil)
        #expect(never.nextRunAt == nil)

        var schedule = TaskSchedule()
        schedule.isEnabled = true
        schedule.interval = 15
        schedule.intervalUnit = .minutes
        schedule.restart(at: Date())
        var spec = try #require(store.project(nightly.id)?.task)
        spec.schedule = schedule
        store.setTaskSpec(spec, for: nightly.id)
        let run = try store.insertSession(in: nightly.id, seed: .init(agent: .claudeCode)).get()
        store.append(ChatMessage(role: .assistant, text: "Done", date: Date(timeIntervalSinceNow: -60)), to: run.id)

        let status = try await commands.readContainerStatus(nightly.id.uuidString)
        #expect(status.kind == .task)
        let task = try #require(status.task)
        #expect(task.runs == 1)
        #expect(task.lastRun?.sessionID == run.id.uuidString)
        #expect(task.lastRun?.state == "IDLE")
        #expect(task.nextRunAt != nil)
    }

    @Test(arguments: StationImplementation.allCases)
    func anUnknownContainerIsRefused(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-status")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let commands = kind.connect(to: StationCommands(store: store, runner: runner()))

        await #expect(throws: StationRefusal.self) {
            try await commands.readContainerStatus(UUID().uuidString)
        }
    }

    private func runner() -> SessionRunner {
        SessionRunner(paths: [.claudeCode: "/usr/bin/true"], host: RecordingHost())
    }

    private func folder(named name: String, in store: ProjectStore, under scratch: ScratchDirectory) throws -> Project {
        let folder = scratch.path(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try #require(store.addProject(at: folder))
    }

    private func repository(named name: String, in store: ProjectStore,
                            under scratch: ScratchDirectory) throws -> Project {
        let folder = scratch.path(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try GitRepo.run(["init", "-q", "-b", "main"], in: folder)
        try GitRepo.run(["config", "user.email", "test@example.com"], in: folder)
        try GitRepo.run(["config", "user.name", "Test"], in: folder)
        try GitRepo.run(["config", "commit.gpgsign", "false"], in: folder)
        try "one\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try GitRepo.run(["add", "-A"], in: folder)
        try GitRepo.run(["commit", "-qm", "first"], in: folder)
        return try #require(store.addProject(at: folder))
    }
}
