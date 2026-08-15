import SwiftUI

// Keeps persisted task schedules moving while the app is running. The loop is deliberately
// coarse because the smallest user-facing unit is a minute. It also wakes promptly after
// system sleep and handles one overdue occurrence rather than replaying every missed one.
struct ScheduledTaskRunner: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var appSettings
    @Environment(DialogPresenter.self) private var dialogs

    @State private var confirmationProjectID: UUID?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task { await watch() }
    }

    private func watch() async {
        while !Task.isCancelled {
            tick(at: Date())
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    private func tick(at date: Date) {
        for task in store.projects where task.kind == .adHoc {
            guard var spec = task.task, var schedule = spec.schedule, schedule.isActive else {
                continue
            }

            if schedule.nextRunAt == nil, !schedule.isWaitingForConfirmation {
                schedule.prepareIfNeeded(at: date)
                spec.schedule = schedule
                store.setTaskSpec(spec, for: task.id)
            }

            guard schedule.isWaitingForConfirmation
                    || schedule.nextRunAt.map({ $0 <= date }) == true else { continue }
            guard !store.isMissing(task), !ScheduledTaskExecution.isBusy(task, store: store,
                                                                          runner: runner),
                  task.task?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    == false,
                  TaskRun.automaticValues(for: task) != nil else { continue }

            if schedule.isWaitingForConfirmation {
                presentConfirmation(for: task)
                return
            }

            if schedule.timing == .interval, schedule.requiresConfirmation {
                schedule.waitForConfirmation()
                spec.schedule = schedule
                store.setTaskSpec(spec, for: task.id)
                presentConfirmation(for: task)
                return
            }

            run(task.id, at: date)
        }
    }

    private func presentConfirmation(for task: Project) {
        guard confirmationProjectID == nil, dialogs.current == nil,
              let schedule = store.project(task.id)?.task?.schedule else { return }
        confirmationProjectID = task.id
        dialogs.show(Dialog(
            title: "Run \"\(task.name)\"?",
            message: "Its \(schedule.summary.lowercased()) timer is due. Start the next scheduled run?",
            actions: [
                .init(label: "Run now", kind: .primary) {
                    confirmationProjectID = nil
                    run(task.id, at: Date())
                },
                .init(label: "Skip this run", kind: .cancel) {
                    confirmationProjectID = nil
                    ScheduledTaskExecution.skip(task.id, at: Date(), store: store)
                },
                .init(label: "Turn off timer") {
                    confirmationProjectID = nil
                    ScheduledTaskExecution.turnOff(task.id, store: store)
                }
            ],
            onCancel: {
                confirmationProjectID = nil
                ScheduledTaskExecution.skip(task.id, at: Date(), store: store)
            }))
    }

    private func run(_ projectID: UUID, at date: Date) {
        switch ScheduledTaskExecution.run(projectID, at: date, store: store, runner: runner,
                                          agentAvatarName: appSettings.defaultAgentAvatarName) {
        case .success:
            break
        case .failure(let failure):
            dialogs.show(Dialog(
                title: "Could not run the scheduled task",
                message: failure.message,
                actions: [.init(label: "OK", kind: .cancel)]))
        }
    }
}

@MainActor
enum ScheduledTaskExecution {
    static func isBusy(_ task: Project, store: ProjectStore, runner: SessionRunner) -> Bool {
        store.standaloneSessions(for: task.id).contains { runner.state($0.id).isBusy }
    }

    @discardableResult
    static func run(_ projectID: UUID, at date: Date = Date(), store: ProjectStore,
                    runner: SessionRunner, agentAvatarName: String?)
        -> Result<ChatSession, PersistenceFailure> {
        guard let task = store.project(projectID), task.kind == .adHoc,
              let schedule = task.task?.schedule, schedule.isActive else {
            return .failure(PersistenceFailure(message: "The task timer is no longer active."))
        }
        guard schedule.isWaitingForConfirmation
                || schedule.nextRunAt.map({ $0 <= date }) == true else {
            return .failure(PersistenceFailure(message: "The task timer is not due yet."))
        }
        guard !store.isMissing(task) else {
            return .failure(PersistenceFailure(message: "The task folder is no longer on disk."))
        }
        guard task.task?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                == false else {
            return .failure(PersistenceFailure(message: "The task has no prompt to run."))
        }
        guard !isBusy(task, store: store, runner: runner) else {
            return .failure(PersistenceFailure(
                message: "Another run is still working in the task folder."))
        }
        guard let values = TaskRun.automaticValues(for: task) else {
            return .failure(PersistenceFailure(
                message: "Run the task once to save its required input values."))
        }

        let result = TaskRun.run(task, values: values, store: store, runner: runner,
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

    static func skip(_ projectID: UUID, at date: Date = Date(), store: ProjectStore) {
        changeSchedule(projectID, store: store) { $0.skip(at: date) }
    }

    static func turnOff(_ projectID: UUID, store: ProjectStore) {
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
