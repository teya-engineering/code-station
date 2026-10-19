import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): what a front end does with a
// task, as the GUI's New task sheet, task screen and run sheet do it. It creates one with
// a prompt template, edits the prompt, its inputs and its agent, runs it with the inputs
// filled in, reads its run history, and sets or turns off its schedule.
@MainActor
struct StationTasksTests {

    private func station(_ scratch: ScratchDirectory) -> StationCommands {
        let station = StationCommands(store: ProjectStore(storeURL: scratch.path("projects.json")),
                                      runner: StationNewSessionTests.runner(), refreshInterval: .milliseconds(50))
        station.taskFolder = scratch.path("tasks")
        return station
    }

    private func container(_ id: String, in commands: any StationInterface) async throws -> RemoteContainer? {
        try await commands.listDirectory().containers?.first { $0.id == id }
    }

    // A task is made from its name, prompt and agent, in a folder of its own under the
    // host's task folder, and answers with its id. The list then has it as a task, and
    // reading it gives back what it was made with: the holes in the prompt are its
    // inputs, and it has never run. A task with no name is refused.
    @Test(arguments: StationImplementation.allCases)
    func aTaskIsCreatedFromItsNamePromptAndAgent(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-tasks")
        let host = station(scratch)
        let commands = kind.connect(to: host)

        let id = try await commands.createTask(RemoteNewTask(name: " Review ", prompt: "Review PR {{pr}}.\n",
                                                             agent: .codex))

        let found = try await container(id, in: commands)
        let listed = try #require(found)
        #expect(listed.kind == .task)
        #expect(listed.name == "Review")
        #expect(listed.folder?.hasPrefix(scratch.path("tasks").standardizedFileURL.path) == true)
        let task = try await commands.readTask(id)
        #expect(task.name == "Review")
        #expect(task.prompt == "Review PR {{pr}}.")
        #expect(task.agent == .codex)
        #expect(task.inputs == [TaskInput(name: "pr")])
        #expect(task.runs.isEmpty)
        #expect(task.schedule == nil)

        await #expect(throws: StationRefusal("Enter a name for the task.")) {
            try await commands.createTask(RemoteNewTask(name: "  ", prompt: "Anything"))
        }
        await #expect(throws: StationRefusal("That task is no longer available.")) {
            try await commands.readTask(UUID().uuidString)
        }
    }

    // The prompt, an input and the agent are each changed on their own, the rest of the
    // task kept. A prompt's new holes are new inputs, and an input keeps how it was set
    // up when the prompt spells it in another case. An input the prompt does not ask
    // for is refused.
    @Test(arguments: StationImplementation.allCases)
    func aTasksPromptInputsAndAgentAreEdited(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-tasks")
        let commands = kind.connect(to: station(scratch))
        let id = try await commands.createTask(RemoteNewTask(name: "Deploy", prompt: "Deploy {{env}}", agent: .codex))

        let choice = TaskInput(name: "env", label: "Environment", kind: .choice, options: ["dev", "prod"],
                               hint: "Where it goes", defaultValue: "dev")
        try await commands.changeTask(id, .input(choice))
        try await commands.changeTask(id, .prompt("Deploy {{ENV}} with {{notes}}"))
        try await commands.changeTask(id, .agent(nil))

        let task = try await commands.readTask(id)
        #expect(task.prompt == "Deploy {{ENV}} with {{notes}}")
        #expect(task.agent == nil)
        var renamed = choice
        renamed.name = "ENV"
        #expect(task.inputs == [renamed, TaskInput(name: "notes")])
        #expect(task.values == ["env": "dev", "notes": ""])

        await #expect(throws: StationRefusal("The prompt does not ask for {{ticket}}.")) {
            try await commands.changeTask(id, .input(TaskInput(name: "ticket")))
        }
        await #expect(throws: StationRefusal("That task is no longer available.")) {
            try await commands.changeTask(UUID().uuidString, .agent(.codex))
        }
    }

    // A run is refused while a required input has no answer. Filled in, it starts a
    // session in the task's folder that sends the prompt with the answers in it and the
    // note at its end, a line asking only for something left out dropped, and a path's
    // `~` expanded. The task then starts its next run from those answers, and the run
    // lists what it was given.
    @Test(arguments: StationImplementation.allCases)
    func aRunFillsInTheInputsAndSendsThePrompt(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-tasks")
        let host = station(scratch)
        let commands = kind.connect(to: host)
        let id = try await commands.createTask(RemoteNewTask(
            name: "Review", prompt: "Review PR {{pr}} in {{repo}}.\nMention {{extra}}."))
        try await commands.changeTask(id, .input(TaskInput(name: "repo", kind: .path)))
        try await commands.changeTask(id, .input(TaskInput(name: "extra", required: false)))

        await #expect(throws: StationRefusal("Fill in Pr first.")) {
            try await commands.runTask(id, values: ["repo": "~/code"], note: "")
        }

        let runID = try await commands.runTask(id, values: ["pr": "12", "repo": "~/code", "extra": ""],
                                               note: "Be brief.")

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let runUUID = try #require(UUID(uuidString: runID))
        let session = try #require(host.store.session(runUUID))
        #expect(session.projectID.uuidString == id)
        #expect(await eventually {
            host.store.session(session.id)?.messages.first?.text == "Review PR 12 in \(home)/code.\n\nBe brief."
        })
        let task = try await commands.readTask(id)
        #expect(task.values == ["pr": "12", "repo": "\(home)/code", "extra": ""])
        #expect(task.runs.map(\.sessionID) == [runID])
        #expect(task.runs.first?.given.hasPrefix("pr 12 · repo /") == true)
        #expect(task.runs.first?.isScheduled == false)
    }

    // The history lists every run newest first, each saying whether the schedule or a
    // person started it and what it was given.
    @Test(arguments: StationImplementation.allCases)
    func theHistoryListsRunsNewestFirst(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-tasks")
        let host = station(scratch)
        let commands = kind.connect(to: host)
        let id = try await commands.createTask(RemoteNewTask(name: "Sweep", prompt: "Sweep {{area}}"))
        let uuid = try #require(UUID(uuidString: id))
        let first = try host.store.insertSession(in: uuid, seed: .init(agent: .claudeCode)).get()
        host.store.setTaskValues(["area": "docs"], for: first.id)
        try await Task.sleep(for: .milliseconds(20))
        let second = try host.store.insertSession(in: uuid, seed: .init(agent: .claudeCode)).get()
        host.store.markScheduledRun(second.id)
        host.store.setTaskValues(["area": "tests"], for: second.id)

        let runs = try await commands.readTask(id).runs
        #expect(runs.map(\.sessionID) == [second.id.uuidString, first.id.uuidString])
        #expect(runs.map(\.isScheduled) == [true, false])
        #expect(runs.map(\.given) == ["area tests", "area docs"])
        #expect(runs.map(\.state) == ["IDLE", "IDLE"])
        #expect(runs.allSatisfy { $0.failure == nil })
    }

    // A schedule is turned on with its rule and counts from now: the list shows it with
    // its next run, and reading the task gives the rule back. It is refused while the
    // task has no prompt, while a required input has no answer, and with numbers out of
    // range. Turning it off stops it.
    @Test(arguments: StationImplementation.allCases)
    func aScheduleIsSetAndTurnedOff(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-tasks")
        let commands = kind.connect(to: station(scratch))
        let id = try await commands.createTask(RemoteNewTask(name: "Nightly", prompt: ""))
        var rule = TaskSchedule()
        rule.timing = .interval
        rule.interval = 15
        rule.intervalUnit = .minutes
        rule.maximumRuns = 3
        rule.requiresConfirmation = true

        await #expect(throws: StationRefusal("Add a prompt before turning on a schedule.")) {
            try await commands.changeTask(id, .schedule(rule))
        }
        try await commands.changeTask(id, .prompt("Check {{branch}}"))
        await #expect(throws: StationRefusal(
            "Give branch a default under Inputs, or run the task once by hand, so a scheduled run has something to fill in.")) {
            try await commands.changeTask(id, .schedule(rule))
        }
        try await commands.changeTask(id, .input(TaskInput(name: "branch", defaultValue: "main")))
        var tooOften = rule
        tooOften.interval = 0
        await #expect(throws: StationRefusal("Enter an interval from 1 to 10,000.")) {
            try await commands.changeTask(id, .schedule(tooOften))
        }

        try await commands.changeTask(id, .schedule(rule))

        let listedContainer = try await container(id, in: commands)
        let listed = try #require(listedContainer?.schedule)
        #expect(listed.summary == "Every 15 minutes")
        #expect(listed.isActive)
        #expect(!listed.isWaiting)
        #expect(abs((listed.nextRunAt ?? .distantPast).timeIntervalSinceNow - 900) < 60)
        let read = try await commands.readTask(id)
        let saved = try #require(read.schedule)
        #expect(saved.maximumRuns == 3)
        #expect(saved.requiresConfirmation)
        #expect(saved.completedRuns == 0)

        try await commands.changeTask(id, .turnOffSchedule)
        #expect(try await container(id, in: commands)?.schedule?.isActive == false)
    }
}
