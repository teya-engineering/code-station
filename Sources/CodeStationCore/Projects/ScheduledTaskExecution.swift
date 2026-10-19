import Foundation

// What a person can say to a scheduled run that waits for their go-ahead.
public enum ScheduledRunChoice: String, Codable, Sendable, CaseIterable {
    // Start the run now.
    case run
    // Let this occurrence pass; the timer carries on to the next one.
    case skip
    // Stop the timer altogether.
    case turnOff
}

// A scheduled run that could not start, for the front ends to report.
public struct ScheduledRunFailure: Equatable, Sendable, Identifiable {
    // Each failure is news of its own, even when it says what the last one said.
    public let id = UUID()
    public let taskID: UUID
    public let taskName: String
    public let message: String

    public init(taskID: UUID, taskName: String, message: String) {
        self.taskID = taskID
        self.taskName = taskName
        self.message = message
    }
}

// Keeps task schedules moving: what a pass of the schedule loop does, and what a person's
// answer to a run waiting for confirmation does. Every host runs the loop (see
// `StationUpkeep`), and a run that needs confirmation waits in its schedule, persisted,
// until a front end answers it.
@MainActor
public enum ScheduledTaskExecution {
    // One pass over every task with a live timer. A timer with no next run yet is given
    // one; a due run starts, unless its timer asks for confirmation first, in which case
    // it waits for an answer. Only one overdue occurrence is handled, however many were
    // missed while nothing was running. Answers with the runs that could not start.
    @discardableResult
    public static func tick(at date: Date, store: ProjectStore, runner: SessionRunner,
                            agentAvatarName: String?) -> [ScheduledRunFailure] {
        var failures: [ScheduledRunFailure] = []
        for var task in store.projects where task.kind == .adHoc {
            guard var spec = task.task, var schedule = spec.schedule, schedule.isActive else {
                continue
            }

            if schedule.nextRunAt == nil, !schedule.isWaitingForConfirmation {
                schedule.prepareIfNeeded(at: date)
                spec.schedule = schedule
                task.task = spec
                store.setTaskSpec(spec, for: task.id)
            }

            guard blocker(for: task, at: date, store: store, runner: runner) == nil,
                  !schedule.isWaitingForConfirmation else { continue }

            if schedule.timing == .interval, schedule.requiresConfirmation {
                schedule.waitForConfirmation()
                spec.schedule = schedule
                store.setTaskSpec(spec, for: task.id)
                continue
            }

            if case .failure(let failure) = run(task.id, at: date, store: store, runner: runner,
                                                agentAvatarName: agentAvatarName) {
                failures.append(ScheduledRunFailure(taskID: task.id, taskName: task.name,
                                                    message: failure.message))
            }
        }
        return failures
    }

    // Tasks whose run waits for confirmation and could start the moment it is given.
    public static func awaitingConfirmation(at date: Date = Date(), store: ProjectStore,
                                            runner: SessionRunner) -> [Project] {
        store.projects.filter { task in
            task.kind == .adHoc && task.task?.schedule?.isWaitingForConfirmation == true
                && blocker(for: task, at: date, store: store, runner: runner) == nil
        }
    }

    // A person's answer to a run waiting for confirmation. A run answers with the
    // session it started.
    @discardableResult
    public static func confirm(_ projectID: UUID, _ choice: ScheduledRunChoice,
                               at date: Date = Date(), store: ProjectStore, runner: SessionRunner,
                               agentAvatarName: String?) -> Result<ChatSession?, PersistenceFailure> {
        switch choice {
        case .run:
            return run(projectID, at: date, store: store, runner: runner,
                       agentAvatarName: agentAvatarName).map(Optional.some)
        case .skip:
            skip(projectID, at: date, store: store)
        case .turnOff:
            turnOff(projectID, store: store)
        }
        return .success(nil)
    }

    public static func isBusy(_ task: Project, store: ProjectStore, runner: SessionRunner) -> Bool {
        store.standaloneSessions(for: task.id).contains { runner.state($0.id).isBusy }
    }

    // Why a scheduled run cannot start right now, or nil when it can. The loop passes
    // over a blocked task quietly and a run asked for by hand reports the reason, so the
    // two agree on what counts as ready.
    public static func blocker(for task: Project, at date: Date, store: ProjectStore,
                        runner: SessionRunner) -> String? {
        guard task.kind == .adHoc, let schedule = task.task?.schedule, schedule.isActive else {
            return "The task timer is no longer active."
        }
        guard schedule.isWaitingForConfirmation
                || schedule.nextRunAt.map({ $0 <= date }) == true else {
            return "The task timer is not due yet."
        }
        if store.isMissing(task) { return "The task folder is no longer on disk." }
        if task.task?.prompt.isBlank ?? true { return "The task has no prompt to run." }
        if isBusy(task, store: store, runner: runner) {
            return "Another run is still working in the task folder."
        }
        if TaskRun.automaticValues(for: task) == nil {
            return "Run the task once to save its required input values."
        }
        return nil
    }

    @discardableResult
    public static func run(_ projectID: UUID, at date: Date = Date(), store: ProjectStore,
                    runner: SessionRunner, agentAvatarName: String?)
        -> Result<ChatSession, PersistenceFailure> {
        guard let task = store.project(projectID) else {
            return .failure(PersistenceFailure(message: "The task timer is no longer active."))
        }
        if let blocker = blocker(for: task, at: date, store: store, runner: runner) {
            return .failure(PersistenceFailure(message: blocker))
        }
        // The blocker check has already made sure every required answer is there.
        let values = TaskRun.automaticValues(for: task) ?? [:]

        let result = TaskRun.run(task, values: values, scheduled: true, store: store,
                                 runner: runner,
                                 agentAvatarName: agentAvatarName)
        switch result {
        case .success(let session):
            changeSchedule(projectID, store: store) { $0.recordRun(at: date) }
            return .success(session)
        case .failure(let failure):
            // A storage failure should not be retried every two seconds. The occurrence
            // is skipped and the visible error lets the user deal with the cause.
            skip(projectID, at: date, store: store)
            return .failure(failure)
        }
    }

    public static func skip(_ projectID: UUID, at date: Date = Date(), store: ProjectStore) {
        changeSchedule(projectID, store: store) { $0.skip(at: date) }
    }

    public static func turnOff(_ projectID: UUID, store: ProjectStore) {
        changeSchedule(projectID, store: store) { $0.turnOff() }
    }

    private static func changeSchedule(_ projectID: UUID, store: ProjectStore,
                                       change: (inout TaskSchedule) -> Void) {
        guard var spec = store.project(projectID)?.task, var schedule = spec.schedule else { return }
        change(&schedule)
        spec.schedule = schedule
        store.setTaskSpec(spec, for: projectID)
    }
}
