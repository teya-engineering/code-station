import CodeStationCore
import Foundation

// The task forms, each a `FormView` built as the GUI's matching sheet or card is laid
// out, and read back into what the station takes:
// - New task (`NewTaskView`): name, prompt, agent, and a time of day to run it at.
// - Edit task (the task screen's prompt card and run bar): prompt and agent.
// - An input (`TaskInputsCard`): label, kind, options or on and off text, default, hint,
//   whether it is required.
// - Run (`TaskRunView`): one field per input, file inputs as typed paths, and a note.
// - Schedule (`TaskScheduleCard`): at a time (daily, weekdays, a weekday) or every few
//   minutes or hours, a run limit and asking first.
enum TaskForms {

    // MARK: - New and edit

    static let agents: [AgentKind?] = [nil] + AgentKind.allCases.map(Optional.some)

    private static func agentTitles(default agent: String?) -> [String] {
        agents.map { $0?.title ?? "Default" + (agent.map { " (\($0))" } ?? "") }
    }

    static func newTask() -> FormView {
        var form = FormView(title: "New task",
                            subtitle: "A prompt you can run again and again. Each run starts a fresh session in the task's own folder.",
                            fields: [
                                .text("name", "Name", detail: "Name it, like Dependabot or Weekly release notes"),
                                .lines("prompt", "Prompt", detail: "What should the agent do on every run? Write {{ticket}} where each run should ask for something."),
                                .choice("agent", "Agent", agentTitles(default: nil)),
                                .choice("when", "When", ["When I run it", "On a schedule"]),
                                .text("time", "Time", "09:00", detail: "24-hour, like 09:00"),
                                .choice("repeat", "Repeat", ["Daily", "Weekdays", "Mondays"], selected: 1),
                                .toggle("runNow", "Run it now", false),
                            ],
                            submitLabel: "create", keys: "ctrl-j new line")
        refreshNewTask(&form)
        return form
    }

    static func refreshNewTask(_ form: inout FormView) {
        let scheduled = form.choice("when") == 1
        form.setHidden("time", !scheduled)
        form.setHidden("repeat", !scheduled)
        let holes = TaskTemplate.placeholders(in: form.text("prompt"))
        form.extra = holes.isEmpty ? [] : ["  Asks for \(holes.joined(separator: ", ")) on each run."]
        if scheduled, !holes.isEmpty {
            form.extra.append("  Scheduled runs need a value for \(holes.joined(separator: ", ")). Add a default under Inputs, or run it once by hand.")
        }
    }

    // What the new-task form asks the station for, or why it cannot yet.
    static func newTaskRequest(_ form: FormView) -> Result<(task: RemoteNewTask, runNow: Bool), Refusal> {
        let name = form.text("name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(Refusal("Enter a name for the task.")) }
        var schedule: TaskSchedule?
        if form.choice("when") == 1 {
            guard let minutes = TaskSchedule.parseTime(form.text("time").trimmingCharacters(in: .whitespaces)) else {
                return .failure(Refusal("Enter a time from 00:00 to 23:59, like 09:00."))
            }
            var rule = TaskSchedule()
            rule.isEnabled = true
            rule.timing = .timeOfDay
            rule.timeOfDayMinutes = minutes
            switch form.choice("repeat") {
            case 0: rule.recurrence = .daily
            case 1: rule.recurrence = .weekdays
            default:
                rule.recurrence = .weekly
                rule.weekday = .monday
            }
            schedule = rule
        }
        let prompt = form.text("prompt")
        if form.isOn("runNow"), prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(Refusal("Write a prompt to run it now."))
        }
        return .success((RemoteNewTask(name: name, prompt: prompt, agent: agents[form.choice("agent")],
                                       schedule: schedule), form.isOn("runNow")))
    }

    static func editTask(_ task: RemoteTask) -> FormView {
        var form = FormView(title: "Edit \(task.name)", subtitle: "Write {{ticket}} where each run should ask for something.",
                            fields: [
                                .lines("prompt", "Prompt", task.prompt, detail: "What should the agent do on every run?"),
                                .choice("agent", "Agent", agentTitles(default: nil),
                                        selected: agents.firstIndex(of: task.agent) ?? 0),
                            ],
                            submitLabel: "save", keys: "ctrl-j new line")
        refreshEditTask(&form)
        return form
    }

    static func refreshEditTask(_ form: inout FormView) {
        let holes = TaskTemplate.placeholders(in: form.text("prompt"))
        form.extra = holes.isEmpty ? ["  Type {{ticket}} anywhere and each run asks for a ticket before it starts."]
            : ["  Each run asks for \(holes.joined(separator: ", ")) before it starts."]
    }

    // MARK: - An input

    static func input(_ input: TaskInput) -> FormView {
        var form = FormView(title: "{{\(input.name)}}", subtitle: "How each run asks for it.",
                            fields: [
                                .text("label", "Label", input.label ?? "", detail: input.title),
                                .choice("kind", "Kind", TaskInput.Kind.allCases.map(\.title),
                                        selected: TaskInput.Kind.allCases.firstIndex(of: input.kind) ?? 0),
                                .text("options", "Options", input.options.joined(separator: ", "),
                                      detail: "dev, staging, production"),
                                .text("whenOn", "When on", input.options.first ?? "", detail: "yes"),
                                .text("whenOff", "When off", input.options.count > 1 ? input.options[1] : "",
                                      detail: "left out"),
                                .text("default", "Default", input.defaultValue ?? "", detail: "Empty"),
                                .text("hint", "Hint", input.hint ?? "", detail: "What this is for"),
                                .toggle("required", "Required", input.required),
                            ],
                            submitLabel: "save")
        refreshInput(&form)
        return form
    }

    static func refreshInput(_ form: inout FormView) {
        let kind = TaskInput.Kind.allCases[form.choice("kind")]
        form.setHidden("options", kind != .choice)
        form.setHidden("whenOn", kind != .toggle)
        form.setHidden("whenOff", kind != .toggle)
        form.setHidden("default", kind == .toggle)
        form.setHidden("required", kind == .toggle)
    }

    static func savedInput(_ form: FormView, name: String) -> TaskInput {
        let kind = TaskInput.Kind.allCases[form.choice("kind")]
        let trimmed = { (id: String) -> String? in
            let text = form.text(id).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        let options: [String] = switch kind {
        case .choice: form.text("options").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        case .toggle: [form.text("whenOn"), form.text("whenOff")]
        default: []
        }
        return TaskInput(name: name, label: trimmed("label"), kind: kind, options: options, hint: trimmed("hint"),
                         defaultValue: kind == .toggle ? nil : trimmed("default"),
                         required: kind == .toggle ? true : form.isOn("required"))
    }

    // MARK: - Run

    static let leaveOut = "Leave it out"

    static func run(_ task: RemoteTask, base: String?) -> FormView {
        var fields: [FormView.Field] = task.inputs.map { input in
            let key = TaskTemplate.key(input.name)
            let value = task.values[key] ?? input.startingValue
            let detail = [input.required ? nil : "optional", input.hint].compactMap { $0 }.joined(separator: " · ")
            let shown = detail.isEmpty ? nil : detail
            switch input.kind {
            case .text: return .text(key, input.title, value, detail: shown)
            case .longText: return .lines(key, input.title, value, detail: shown)
            case .path: return .path(key, input.title, value, detail: shown ?? "a file or folder, tab completes")
            case .toggle:
                return .toggle(key, input.title, value == "on", detail: input.onText)
            case .choice:
                let options = (input.required ? [] : [leaveOut]) + input.options
                let selected = value.isEmpty ? 0 : options.firstIndex(of: value) ?? 0
                return .choice(key, input.title, options, selected: selected, detail: shown)
            }
        }
        fields.append(.lines("note", "Anything else", detail: "Added to the end of the prompt, for this run only."))
        var form = FormView(title: "Run \(task.name)",
                            subtitle: task.inputs.contains { !$0.required }
                                ? "Fill in what this run needs. A line that only asked for something left blank is left out."
                                : "Fill in what this run needs.",
                            fields: fields, submitLabel: "run", keys: "tab completes a path")
        form.pathBase = base
        refreshRun(&form, task: task)
        return form
    }

    static func runValues(_ form: FormView, task: RemoteTask) -> [String: String] {
        Dictionary(uniqueKeysWithValues: task.inputs.map { input in
            let key = TaskTemplate.key(input.name)
            let text = form.text(key)
            return (key, input.kind == .choice && text == leaveOut ? "" : text)
        })
    }

    // The prompt the run will send, as the GUI's "Show the prompt" shows it.
    static func refreshRun(_ form: inout FormView, task: RemoteTask) {
        let spec = TaskSpec(prompt: task.prompt, inputs: task.inputs)
        var text = TaskTemplate.render(spec, values: runValues(form, task: task))
        let note = form.text("note").trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { text = text.isEmpty ? note : text + "\n\n" + note }
        form.extra = ["  THE PROMPT"] + (text.isEmpty ? ["    Nothing to send yet."]
            : text.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).map { "    " + $0 })
    }

    // MARK: - Schedule

    static let weekdays: [TaskSchedule.Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]

    static func schedule(_ task: RemoteTask) -> FormView {
        let rule = task.schedule ?? {
            var fresh = TaskSchedule()
            fresh.timing = .timeOfDay
            fresh.recurrence = .weekdays
            return fresh
        }()
        var form = FormView(title: "Schedule \(task.name)", subtitle: "Runs only while a Code Station host is up. A missed time runs once when one is up again.",
                            fields: [
                                .choice("timing", "Runs", ["At a time", "Every few minutes"],
                                        selected: rule.timing == .timeOfDay ? 0 : 1),
                                .text("time", "Time", rule.timeText, detail: "24-hour, like 09:00"),
                                .choice("repeat", "Repeat", TaskSchedule.Recurrence.allCases.map(\.title),
                                        selected: TaskSchedule.Recurrence.allCases.firstIndex(of: rule.recurrence) ?? 0),
                                .choice("weekday", "On", weekdays.map(\.shortTitle),
                                        selected: weekdays.firstIndex(of: rule.weekday) ?? 0),
                                .text("every", "Every", String(rule.interval), detail: "30"),
                                .choice("unit", "Unit", TaskSchedule.IntervalUnit.allCases.map { $0.label(for: 2).capitalized },
                                        selected: TaskSchedule.IntervalUnit.allCases.firstIndex(of: rule.intervalUnit) ?? 0),
                                .text("stopAfter", "Stop after", rule.maximumRuns.map(String.init) ?? "",
                                      detail: "No limit"),
                                .toggle("ask", "Ask before each run", rule.requiresConfirmation,
                                        detail: "run it, skip it, or turn the schedule off"),
                            ],
                            submitLabel: task.schedule?.isActive == true ? "save schedule" : "turn on schedule")
        refreshSchedule(&form)
        return form
    }

    static func refreshSchedule(_ form: inout FormView) {
        let atATime = form.choice("timing") == 0
        form.setHidden("time", !atATime)
        form.setHidden("repeat", !atATime)
        form.setHidden("weekday", !atATime || TaskSchedule.Recurrence.allCases[form.choice("repeat")] != .weekly)
        for id in ["every", "unit", "stopAfter", "ask"] { form.setHidden(id, atATime) }
        if case .success(let rule) = scheduleRule(form) {
            form.extra = ["  \(rule.summary)."]
        } else {
            form.extra = []
        }
    }

    // The rule the form describes, or what is wrong with its numbers, worded as the
    // GUI's schedule card words it.
    static func scheduleRule(_ form: FormView) -> Result<TaskSchedule, Refusal> {
        var rule = TaskSchedule()
        rule.isEnabled = true
        if form.choice("timing") == 0 {
            guard let minutes = TaskSchedule.parseTime(form.text("time").trimmingCharacters(in: .whitespaces)) else {
                return .failure(Refusal("Enter a time from 00:00 to 23:59, like 09:00."))
            }
            rule.timing = .timeOfDay
            rule.timeOfDayMinutes = minutes
            rule.recurrence = TaskSchedule.Recurrence.allCases[form.choice("repeat")]
            rule.weekday = weekdays[form.choice("weekday")]
        } else {
            guard let every = Int(form.text("every").trimmingCharacters(in: .whitespaces)),
                  TaskSchedule.countRange.contains(every) else {
                return .failure(Refusal("Enter an interval from 1 to 10,000."))
            }
            let limit = form.text("stopAfter").trimmingCharacters(in: .whitespaces)
            if !limit.isEmpty {
                guard let maximum = Int(limit), TaskSchedule.countRange.contains(maximum) else {
                    return .failure(Refusal("Enter a run limit from 1 to 10,000, or leave it empty."))
                }
                rule.maximumRuns = maximum
            }
            rule.timing = .interval
            rule.interval = every
            rule.intervalUnit = TaskSchedule.IntervalUnit.allCases[form.choice("unit")]
            rule.requiresConfirmation = form.isOn("ask")
        }
        return .success(rule)
    }

    struct Refusal: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
