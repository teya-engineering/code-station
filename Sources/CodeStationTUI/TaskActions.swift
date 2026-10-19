import CodeStationCore
import Foundation
import TerminalKit

// What the TUI does with a task, as the GUI's New task sheet, task screen, run sheet and
// scheduled-run dialog do it. The forms are `TaskForms`; this opens them, hands what was
// filled in to the station, and shows what came of it. A refusal stays in the form's
// footer, with what was typed kept.
extension TUIApp {

    // MARK: - The task screen's keys

    // n runs the task (new work in a task is another run of its prompt, as ⌘N does in the
    // GUI), e edits its prompt and agent, i its inputs, s its schedule, f filters its
    // runs, and c answers a scheduled run waiting for confirmation.
    func handleInTaskScreen(_ key: Key) -> Bool {
        guard let screen = containerScreen else { return false }
        let id = screen.id
        switch key {
        case .char("n", []): runTask(id)
        case .char("e", []): withTask(id) { [weak self] task in self?.editTask(task) }
        case .char("i", []): withTask(id) { [weak self] task in self?.editInputs(task) }
        case .char("s", []): withTask(id) { [weak self] task in self?.editSchedule(task) }
        case .char("f", []): containerScreen?.cycleFilter()
        case .char("c", []): askAboutScheduledRun(id)
        default: return false
        }
        return true
    }

    // Reads the task fresh for the screen showing it.
    func readTask(_ id: String) async {
        guard let task = try? await commands.readTask(id), containerScreen?.id == id else { return }
        containerScreen?.show(task)
        paint()
    }

    private func withTask(_ id: String, _ then: @escaping @MainActor (RemoteTask) -> Void) {
        work { [weak self, commands] in
            do throws(StationRefusal) {
                let task = try await commands.readTask(id)
                if self?.containerScreen?.id == id { self?.containerScreen?.show(task) }
                then(task)
            } catch {
                self?.sidebar.notice = error.message
            }
            self?.paint()
        }
    }

    // MARK: - The row menu

    // What a task's menu lists before the GUI's own entries: answering a scheduled run
    // that waits for confirmation, while one does.
    func taskActions(_ container: RemoteContainer) -> [MenuAction] {
        guard container.schedule?.isWaiting == true else { return [] }
        return [MenuAction("Confirm scheduled run…", detail: "c", .run { [weak self] in
            self?.askAboutScheduledRun(container.id)
        })]
    }

    // MARK: - The form on screen

    func handleInTaskForm(_ key: Key) {
        guard var open = taskForm else { return }
        let outcome = open.view.handle(key)
        if outcome == .edited { open.refresh(&open.view) }
        taskForm = open
        switch outcome {
        case .cancel: taskForm = nil
        case .edited, .ignored: break
        case .submit: open.submit(open.view)
        }
    }

    private func showForm(_ view: FormView, refresh: @escaping (inout FormView) -> Void = { _ in },
                          submit: @escaping @MainActor (FormView) -> Void) {
        taskForm = (view, refresh, submit)
    }

    // Hands the form's request to the station; the form closes once it is taken, or
    // shows why it was refused.
    private func submit(_ request: @escaping @MainActor () async throws(StationRefusal) -> Void) {
        taskForm?.view.busy = true
        work { [weak self] in
            do throws(StationRefusal) {
                try await request()
            } catch {
                self?.taskForm?.view.busy = false
                self?.taskForm?.view.notice = error.message
            }
            self?.paint()
        }
    }

    // MARK: - New task

    // Add's "New task…". The task made is shown on its screen, as the GUI lands on it,
    // and run straight away when that was asked for.
    func newTask() {
        showForm(TaskForms.newTask(), refresh: TaskForms.refreshNewTask) { [weak self] form in
            guard let self else { return }
            switch TaskForms.newTaskRequest(form) {
            case .failure(let refusal): self.taskForm?.view.notice = refusal.message
            case .success(let (request, runNow)):
                self.submit { [weak self, commands] () throws(StationRefusal) in
                    let id = try await commands.createTask(request)
                    guard let self else { return }
                    self.taskForm = nil
                    if let directory = try? await commands.listDirectory() { self.sidebar.show(directory) }
                    self.sidebar.clearFilter()
                    self.openContainer(id)
                    if runNow { self.runTask(id) }
                }
            }
        }
    }

    // MARK: - Edit

    private func editTask(_ task: RemoteTask) {
        showForm(TaskForms.editTask(task), refresh: TaskForms.refreshEditTask) { [weak self] form in
            guard let self else { return }
            let prompt = form.text("prompt")
            let agent = TaskForms.agents[form.choice("agent")]
            self.submit { [weak self, commands] () throws(StationRefusal) in
                if prompt != task.prompt { try await commands.changeTask(task.id, .prompt(prompt)) }
                if agent != task.agent { try await commands.changeTask(task.id, .agent(agent)) }
                self?.taskForm = nil
                await self?.readTask(task.id)
            }
        }
    }

    // One input goes straight to its form; with several, a menu asks which.
    private func editInputs(_ task: RemoteTask) {
        guard !task.inputs.isEmpty else {
            sidebar.notice = "None yet. Write {{ticket}} in the prompt and every run asks for a ticket first."
            return
        }
        guard task.inputs.count > 1 else { return editInput(task.inputs[0], of: task.id) }
        menu = ActionMenu(title: "Inputs", subtitle: "Asked for before each run, in the order they appear.",
                          actions: task.inputs.map { input in
                              MenuAction("{{\(input.name)}}  \(input.title)",
                                         detail: input.kind.title.lowercased() + (input.required ? "" : ", optional"),
                                         .run { [weak self] in self?.editInput(input, of: task.id) })
                          })
    }

    private func editInput(_ input: TaskInput, of taskID: String) {
        showForm(TaskForms.input(input), refresh: TaskForms.refreshInput) { [weak self] form in
            guard let self else { return }
            let saved = TaskForms.savedInput(form, name: input.name)
            self.submit { [weak self, commands] () throws(StationRefusal) in
                try await commands.changeTask(taskID, .input(saved))
                self?.taskForm = nil
                await self?.readTask(taskID)
            }
        }
    }

    // MARK: - Schedule

    // A schedule that is on offers to change it or turn it off; one that is off opens
    // straight on its form.
    private func editSchedule(_ task: RemoteTask) {
        guard task.schedule?.isActive == true else { return scheduleForm(task) }
        menu = ActionMenu(title: "Schedule", subtitle: task.schedule?.summary, actions: [
            MenuAction("Change schedule…", .run { [weak self] in self?.scheduleForm(task) }),
            MenuAction("Turn off", .run { [weak self, commands] in
                self?.work { [weak self] in
                    do throws(StationRefusal) {
                        try await commands.changeTask(task.id, .turnOffSchedule)
                    } catch {
                        self?.sidebar.notice = error.message
                    }
                    await self?.readTask(task.id)
                }
            }),
        ])
    }

    private func scheduleForm(_ task: RemoteTask) {
        showForm(TaskForms.schedule(task), refresh: TaskForms.refreshSchedule) { [weak self] form in
            guard let self else { return }
            switch TaskForms.scheduleRule(form) {
            case .failure(let refusal): self.taskForm?.view.notice = refusal.message
            case .success(let rule):
                self.submit { [weak self, commands] () throws(StationRefusal) in
                    try await commands.changeTask(task.id, .schedule(rule))
                    self?.taskForm = nil
                    await self?.readTask(task.id)
                }
            }
        }
    }

    // MARK: - Run

    // A task whose prompt asks for something opens the run form; one that asks for
    // nothing starts on the key. The run opens once started.
    func runTask(_ id: String) {
        withTask(id) { [weak self] task in
            guard let self else { return }
            if task.inputs.isEmpty {
                self.work { [weak self] in await self?.startRun(task, values: [:], note: "") }
                return
            }
            self.showForm(TaskForms.run(task, base: FileManager.default.currentDirectoryPath),
                          refresh: { TaskForms.refreshRun(&$0, task: task) }) { [weak self] form in
                let values = TaskForms.runValues(form, task: task)
                let note = form.text("note")
                self?.taskForm?.view.busy = true
                self?.work { [weak self] in await self?.startRun(task, values: values, note: note) }
            }
        }
    }

    private func startRun(_ task: RemoteTask, values: [String: String], note: String) async {
        do throws(StationRefusal) {
            let sessionID = try await commands.runTask(task.id, values: values, note: note)
            taskForm = nil
            if let directory = try? await commands.listDirectory() { sidebar.show(directory) }
            sidebar.reveal(sessionID)
            await open(sessionID)
        } catch {
            if taskForm != nil {
                taskForm?.view.busy = false
                taskForm?.view.notice = error.message
            } else {
                sidebar.notice = error.message
            }
        }
        paint()
    }

    // MARK: - A scheduled run waiting for confirmation

    // Asks as the GUI's dialog asks: run it now, skip this run, or turn the timer off.
    // Esc leaves it waiting.
    func askAboutScheduledRun(_ id: String) {
        guard let container = sidebar.directory?.containers?.first(where: { $0.id == id }),
              let schedule = container.schedule, schedule.isWaiting else {
            sidebar.notice = "No scheduled run is waiting for confirmation."
            return
        }
        scheduledRunQuestion = (ChoiceDialog("Run \"\(container.name)\"?",
                                             message: "Its \(schedule.summary.lowercased()) timer is due. Start the next scheduled run?",
                                             buttons: [("Run now", .run), ("Skip this run", .skip),
                                                       ("Turn off timer", .turnOff)]), id)
    }

    func handleInScheduledRunQuestion(_ key: Key) -> Bool {
        guard var open = scheduledRunQuestion else { return false }
        let outcome = open.view.handle(key)
        scheduledRunQuestion = open
        switch outcome {
        case .ignored: return false
        case .handled: break
        case .cancel: scheduledRunQuestion = nil
        case .answer(let choice):
            scheduledRunQuestion = nil
            work { [weak self, commands] in
                do throws(StationRefusal) {
                    let started = try await commands.confirmScheduledRun(open.taskID, choice)
                    guard let self else { return }
                    if let started {
                        if let directory = try? await commands.listDirectory() { self.sidebar.show(directory) }
                        self.sidebar.reveal(started)
                        await self.open(started)
                    } else {
                        await self.readTask(open.taskID)
                    }
                } catch {
                    self?.sidebar.notice = error.message
                }
                self?.paint()
            }
        }
        return true
    }
}
