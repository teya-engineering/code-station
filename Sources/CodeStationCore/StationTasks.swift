import Foundation

// What a front end does with a task, as the GUI's New task sheet, task screen and run
// sheet do it: make one from a name, a prompt template and an agent; read it back with
// its inputs, schedule and runs; change its prompt, an input, its agent or its schedule;
// and run it with its inputs filled in. Renaming, pinning and deleting a task go through
// the project commands (`StationProjects`), as its sidebar menu shares them.
extension StationCommands {

    // MARK: - Create

    // Makes the task in an empty folder of its own under `taskFolder`, and answers with
    // its id. The GUI's own selection is left where it was.
    public func createTask(_ request: RemoteNewTask) throws(StationRefusal) -> String {
        if let schedule = request.schedule {
            try check(schedule, for: TaskSpec(prompt: request.prompt.trimmed))
        }
        let selected = store.selectedProjectID
        let made = store.addTask(named: request.name, prompt: request.prompt, in: taskFolder)
        store.selectedProjectID = selected
        let task: Project
        switch made {
        case .success(let created): task = created
        case .failure(let failure): throw StationRefusal(failure.message)
        }
        var spec = task.task ?? TaskSpec(prompt: request.prompt.trimmed)
        spec.agent = request.agent
        if var schedule = request.schedule {
            schedule.restart()
            spec.schedule = schedule
        }
        store.setTaskSpec(spec, for: task.id)
        return task.id.uuidString
    }

    // MARK: - Read

    // The task as its screen shows it: the prompt and who runs it, what each run asks
    // for and starts from, the schedule, and every run, newest first.
    public func readTask(_ taskID: String) throws(StationRefusal) -> RemoteTask {
        let task = try self.task(taskID)
        let spec = task.task ?? TaskSpec(prompt: "")
        let inputs = TaskTemplate.inputs(in: spec)
        let runs = store.standaloneSessions(for: task.id).sorted { $0.createdAt > $1.createdAt }
        return RemoteTask(
            id: task.id.uuidString, name: task.name, prompt: spec.prompt, agent: spec.agent,
            inputs: inputs,
            values: Dictionary(uniqueKeysWithValues: inputs.map { input in
                let key = TaskTemplate.key(input.name)
                return (key, spec.lastValues[key] ?? input.startingValue)
            }),
            schedule: spec.schedule,
            runs: runs.map { run in
                let live = LiveConversation.id(of: run.id, store: store, runner: runner)
                return RemoteTaskRun(
                    sessionID: run.id.uuidString, title: run.title,
                    state: SessionTone(run.id, store: store, runner: runner).word,
                    isScheduled: run.isScheduledRun, createdAt: run.createdAt, lastActivity: run.lastActivity,
                    given: TaskTemplate.summary(of: run.taskValues ?? [:], inputs: inputs),
                    failure: RemoteDirectoryListing.failure(runner.state(live)))
            })
    }

    // MARK: - Change

    // One change to the task, as its screen saves it. Everything else in it stays.
    public func changeTask(_ taskID: String, _ change: TaskChange) throws(StationRefusal) {
        let task = try self.task(taskID)
        var spec = task.task ?? TaskSpec(prompt: "")
        switch change {
        case .prompt(let prompt):
            spec.prompt = prompt.trimmed
        case .input(let input):
            guard TaskTemplate.placeholders(in: spec.prompt).contains(where: {
                TaskTemplate.key($0) == TaskTemplate.key(input.name)
            }) else {
                throw StationRefusal("The prompt does not ask for {{\(input.name)}}.")
            }
            spec.inputs = TaskTemplate.saving(input, in: spec)
        case .agent(let agent):
            spec.agent = agent
        case .schedule(var schedule):
            schedule.isEnabled = true
            try check(schedule, for: spec)
            // Only an interval can ask first or stop after a number of runs, as the
            // GUI's editor saves it.
            if schedule.timing == .timeOfDay {
                schedule.maximumRuns = nil
                schedule.requiresConfirmation = false
            }
            schedule.restart()
            spec.schedule = schedule
        case .turnOffSchedule:
            guard var schedule = spec.schedule else { return }
            schedule.turnOff()
            spec.schedule = schedule
        }
        store.setTaskSpec(spec, for: task.id)
    }

    // MARK: - Run

    // A fresh session in the task's folder with the prompt filled in and sent, `note`
    // added at its end, as the GUI's run sheet starts one. A path input's `~` is the
    // host's home. Refused while the folder is missing, while another run still works
    // in it, and while a required input has no answer.
    public func runTask(_ taskID: String, values: [String: String], note: String) throws(StationRefusal) -> String {
        followSharedDefaults()
        let task = try self.task(taskID)
        try admitTurn()
        if store.isMissing(task) { throw StationRefusal("\(task.name)'s folder is no longer on disk.") }
        if ScheduledTaskExecution.isBusy(task, store: store, runner: runner) {
            throw StationRefusal("Another run is still working in the task folder.")
        }
        let inputs = TaskTemplate.inputs(in: task.task ?? TaskSpec(prompt: ""))
        var filled: [String: String] = [:]
        for input in inputs {
            let key = TaskTemplate.key(input.name)
            var value = values[key] ?? input.startingValue
            if input.kind == .path, !value.isBlank { value = (value.trimmed as NSString).expandingTildeInPath }
            if input.required, !input.isAnswered(value) { throw StationRefusal("Fill in \(input.title) first.") }
            filled[key] = value
        }
        let result = TaskRun.run(task, values: filled, note: note, store: store, runner: runner,
                                 agentAvatarName: Preferences.defaultAgentAvatarName())
        switch result {
        case .success(let session): return session.id.uuidString
        case .failure(let failure): throw StationRefusal(failure.message)
        }
    }

    // MARK: - Helpers

    func task(_ taskID: String) throws(StationRefusal) -> Project {
        guard let id = UUID(uuidString: taskID), let task = store.project(id), task.kind == .adHoc else {
            throw .noTask
        }
        return task
    }

    // Why the schedule cannot be turned on for a task with this spec, as the GUI's
    // schedule card says it, or nothing when it can.
    func check(_ schedule: TaskSchedule, for spec: TaskSpec) throws(StationRefusal) {
        guard !spec.prompt.isBlank else { throw StationRefusal("Add a prompt before turning on a schedule.") }
        switch schedule.timing {
        case .interval:
            guard TaskSchedule.countRange.contains(schedule.interval) else {
                throw StationRefusal("Enter an interval from 1 to 10,000.")
            }
            if let maximum = schedule.maximumRuns, !TaskSchedule.countRange.contains(maximum) {
                throw StationRefusal("Enter a run limit from 1 to 10,000, or leave it empty.")
            }
        case .timeOfDay:
            guard (0..<(24 * 60)).contains(schedule.timeOfDayMinutes) else {
                throw StationRefusal("Enter a time from 00:00 to 23:59, like 09:00.")
            }
        }
        let missing = TaskRun.unansweredInputs(in: spec).map(\.name)
        if !missing.isEmpty {
            throw StationRefusal("Give \(missing.joined(separator: ", ")) a default under Inputs, or run the task "
                                 + "once by hand, so a scheduled run has something to fill in.")
        }
    }
}

// One change a front end makes to a task.
public enum TaskChange: Codable, Equatable, Sendable {
    case prompt(String)
    // How one of the prompt's holes is asked for, matched to it by name.
    case input(TaskInput)
    // Nil follows the app's default agent.
    case agent(AgentKind?)
    // Turns the schedule on with this rule, counting from now.
    case schedule(TaskSchedule)
    case turnOffSchedule
}

// What a new task is made from, as the GUI's New task sheet asks for it. Nil choices
// follow the app defaults at run time.
public struct RemoteNewTask: Codable, Equatable, Sendable {
    public var name: String
    public var prompt: String
    public var agent: AgentKind?
    // A schedule to start with; it starts counting from when the task is made.
    public var schedule: TaskSchedule?

    public init(name: String, prompt: String, agent: AgentKind? = nil, schedule: TaskSchedule? = nil) {
        self.name = name
        self.prompt = prompt
        self.agent = agent
        self.schedule = schedule
    }
}

// A task as its screen shows it.
public struct RemoteTask: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let prompt: String
    // Who runs it; nil follows the app's default agent.
    public let agent: AgentKind?
    // What each run asks for, in the order the prompt asks it, dressed as the task saved
    // each one.
    public let inputs: [TaskInput]
    // What a run starts with for each input, by `TaskTemplate.key`: the last run's
    // answer, else the input's default.
    public let values: [String: String]
    public let schedule: TaskSchedule?
    // Every run, newest first.
    public let runs: [RemoteTaskRun]

    public init(id: String, name: String, prompt: String, agent: AgentKind?, inputs: [TaskInput],
                values: [String: String], schedule: TaskSchedule?, runs: [RemoteTaskRun]) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.agent = agent
        self.inputs = inputs
        self.values = values
        self.schedule = schedule
        self.runs = runs
    }
}

// One run of a task, as a line in its history (the GUI's `TaskRunRow`).
public struct RemoteTaskRun: Codable, Equatable, Sendable {
    public let sessionID: String
    public let title: String
    // Its state word, as its sidebar card says it.
    public let state: String
    // Started by the task's schedule rather than by a person.
    public let isScheduled: Bool
    public let createdAt: Date
    public let lastActivity: Date
    // What it was given, as "pr 12 · repo alpha".
    public let given: String
    // Why it stopped, when its turn ended in an error.
    public let failure: String?

    public init(sessionID: String, title: String, state: String, isScheduled: Bool, createdAt: Date,
                lastActivity: Date, given: String, failure: String?) {
        self.sessionID = sessionID
        self.title = title
        self.state = state
        self.isScheduled = isScheduled
        self.createdAt = createdAt
        self.lastActivity = lastActivity
        self.given = given
        self.failure = failure
    }
}

extension StationRefusal {
    static let noTask = StationRefusal("That task is no longer available.")
}
