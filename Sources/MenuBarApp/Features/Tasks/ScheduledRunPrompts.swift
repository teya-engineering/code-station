import SwiftUI
import CodeStationCore

// What the GUI says about task schedules. The schedule loop itself is the station's
// (`StationUpkeep`), so it runs whichever host is up; a run that needs confirmation waits
// in its schedule, and this asks about it in a Dialog. A scheduled run that could not
// start is reported the same way.
struct ScheduledRunPrompts: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var appSettings
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(StationUpkeep.self) private var upkeep

    @State private var confirmationProjectID: UUID?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: waiting, initial: true) { _, _ in presentConfirmation() }
            .onChange(of: dialogs.current == nil) { _, _ in presentConfirmation() }
            .onChange(of: upkeep.scheduleFailure) { _, failure in
                guard let failure else { return }
                dialogs.show(Dialog.notice("Could not run the scheduled task",
                                           message: failure.message))
            }
    }

    // The first task whose run is waiting for an answer and could start once given one.
    private var waiting: UUID? {
        ScheduledTaskExecution.awaitingConfirmation(store: store, runner: runner).first?.id
    }

    private func presentConfirmation() {
        guard confirmationProjectID == nil, dialogs.current == nil, let id = waiting,
              let task = store.project(id), let schedule = task.task?.schedule else { return }
        confirmationProjectID = task.id
        dialogs.show(Dialog(
            title: "Run \"\(task.name)\"?",
            message: "Its \(schedule.summary.lowercased()) timer is due. Start the next scheduled run?",
            actions: [
                .init(label: "Run now", kind: .primary) { answer(task.id, .run) },
                .init(label: "Skip this run", kind: .cancel) { answer(task.id, .skip) },
                .init(label: "Turn off timer") { answer(task.id, .turnOff) }
            ],
            onCancel: { answer(task.id, .skip) }))
    }

    private func answer(_ projectID: UUID, _ choice: ScheduledRunChoice) {
        confirmationProjectID = nil
        let result = ScheduledTaskExecution.confirm(
            projectID, choice, store: store, runner: runner,
            agentAvatarName: appSettings.defaultAgentAvatarName)
        if case .failure(let failure) = result {
            dialogs.show(Dialog.notice("Could not run the scheduled task",
                                       message: failure.message))
        }
    }
}
