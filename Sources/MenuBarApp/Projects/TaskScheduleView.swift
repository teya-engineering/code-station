import SwiftUI

// Edits a task's timer as one saved rule. Numeric text stays local until Save so a
// half-typed value never replaces a valid schedule that may already be running.
struct TaskScheduleCard: View {
    let task: Project
    let schedule: TaskSchedule?
    let onSave: (TaskSchedule) -> Void

    @State private var draft: Draft

    init(task: Project, schedule: TaskSchedule?, onSave: @escaping (TaskSchedule) -> Void) {
        self.task = task
        self.schedule = schedule
        self.onSave = onSave
        _draft = State(initialValue: Draft(schedule ?? TaskSchedule()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionRule(title: "TIMER") {
                if schedule?.isWaitingForConfirmation == true {
                    MonoChip(text: "CONFIRM", size: 9, tint: Theme.attentionText)
                } else if schedule?.isActive == true {
                    MonoChip(text: "ACTIVE", size: 9, tint: Theme.accent)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(draft.isEnabled ? Theme.accent : Color.secondary)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Scheduled runs")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Runs happen while Teya Code Station is open. A missed time runs once "
                         + "when the app is available again.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("Scheduled runs", isOn: $draft.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.appSwitch)
            }

            if draft.isEnabled {
                VStack(alignment: .leading, spacing: 13) {
                    Divider().overlay(Theme.hairline)

                    HStack(spacing: 8) {
                        ChoicePill(title: "Every interval", selected: draft.timing == .interval) {
                            draft.timing = .interval
                        }
                        ChoicePill(title: "Time of day", selected: draft.timing == .timeOfDay) {
                            draft.timing = .timeOfDay
                        }
                    }

                    if draft.timing == .interval {
                        intervalEditor
                    } else {
                        timeOfDayEditor
                    }

                    if let issue {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text(issue)
                                .font(.system(size: 11.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(Theme.attentionText)
                        .transition(.fadeIn)
                    }
                }
                .transition(.fadeIn)
            }

            Divider().overlay(Theme.hairline)
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 12)
        .smoothlyResizes(when: layoutState)
        .onChange(of: schedule) { oldValue, newValue in
            let old = oldValue ?? TaskSchedule()
            guard !draft.differs(from: old) else { return }
            draft = Draft(newValue ?? TaskSchedule())
        }
    }

    private var intervalEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 10) {
                LabeledField("EVERY") {
                    numberField("30", text: $draft.intervalText, width: 100)
                }
                OptionMenu(caption: "UNIT",
                           value: draft.intervalUnit.label(for: draft.interval ?? 2).capitalized) {
                    TaskSchedule.IntervalUnit.allCases.map { unit in
                        .item(unit.label(for: draft.interval ?? 2).capitalized,
                              checked: draft.intervalUnit == unit) {
                            draft.intervalUnit = unit
                        }
                    }
                }
                .frame(width: 130)
                Spacer(minLength: 0)
            }

            HStack(alignment: .center, spacing: 16) {
                Toggle(isOn: $draft.hasMaximum) {
                    Text("Stop after")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .toggleStyle(.appSwitch)

                if draft.hasMaximum {
                    HStack(spacing: 7) {
                        numberField("10", text: $draft.maximumRunsText, width: 76)
                        Text("scheduled runs")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            Toggle(isOn: $draft.requiresConfirmation) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirm before each run")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("When the interval is due, choose whether to run, skip, or turn off the timer.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.appSwitch)
        }
        .padding(13)
        .surface(Theme.sunken, cornerRadius: 10)
    }

    private var timeOfDayEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledField("TIME", note: "Use 24-hour time in HH:mm format.") {
                numberField("09:00", text: $draft.timeText, width: 120)
            }

            LabeledField("RECURRENCE") {
                HStack(spacing: 8) {
                    ForEach(TaskSchedule.Recurrence.allCases, id: \.self) { recurrence in
                        ChoicePill(title: recurrence.title,
                                   selected: draft.recurrence == recurrence) {
                            draft.recurrence = recurrence
                        }
                    }
                }
            }

            if draft.recurrence == .weekly {
                LabeledField("DAY") {
                    HStack(spacing: 6) {
                        ForEach(TaskSchedule.Weekday.allCases, id: \.self) { weekday in
                            ChoicePill(title: weekday.shortTitle,
                                       selected: draft.weekday == weekday) {
                                draft.weekday = weekday
                            }
                        }
                    }
                }
                .transition(.fadeIn)
            }
        }
        .padding(13)
        .surface(Theme.sunken, cornerRadius: 10)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let schedule, schedule.isWaitingForConfirmation {
                    Text("Waiting for confirmation")
                        .foregroundStyle(Theme.attentionText)
                } else if let schedule, let next = schedule.nextRunAt, schedule.isActive {
                    Text("Next run \(next.formatted(date: .abbreviated, time: .shortened))")
                } else if let schedule, schedule.hasReachedMaximum {
                    Text("Finished after \(schedule.completedRuns) scheduled runs")
                } else {
                    Text("Timer off")
                }
                if let schedule, schedule.completedRuns > 0 {
                    Text("\(counted(schedule.completedRuns, "scheduled run")) completed")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                ActionButton(title: "Cancel", tone: .danger, icon: "xmark") {
                    draft = Draft(schedule ?? TaskSchedule())
                }
                .disabled(!isDirty)

                ActionButton(title: "Save timer", tone: .green, icon: "clock") {
                    save()
                }
                .disabled(!isDirty || issue != nil)
            }
        }
    }

    // Why the timer cannot be saved as it stands. The draft knows its own numbers; the
    // task adds whether it has anything to run.
    private var issue: String? {
        guard draft.isEnabled else { return nil }
        guard task.task?.prompt.isBlank == false else {
            return "Add a prompt before turning on scheduled runs."
        }
        if let problem = draft.problem { return problem }
        if TaskRun.automaticValues(for: task) == nil {
            return "Run the task once to save values for every required input, or add "
                + "defaults to those inputs."
        }
        return nil
    }

    private var isDirty: Bool { draft.differs(from: schedule ?? TaskSchedule()) }

    private var layoutState: LayoutState {
        LayoutState(isEnabled: draft.isEnabled,
                    timing: draft.timing,
                    hasMaximum: draft.hasMaximum,
                    recurrence: draft.recurrence,
                    issue: issue)
    }

    private func save() {
        guard issue == nil, var value = draft.schedule else { return }
        value.restart()
        onSave(value)
    }

    // A number is typed in mono, so a column of them lines up.
    private func numberField(_ placeholder: String, text: Binding<String>,
                             width: CGFloat) -> some View {
        TextField(placeholder, text: text)
            .font(.mono(12))
            .appTextField(size: 12)
            .frame(width: width)
    }

    private struct LayoutState: Equatable {
        let isEnabled: Bool
        let timing: TaskSchedule.Timing
        let hasMaximum: Bool
        let recurrence: TaskSchedule.Recurrence
        let issue: String?
    }

    private struct Draft {
        var isEnabled: Bool
        var timing: TaskSchedule.Timing
        var intervalText: String
        var intervalUnit: TaskSchedule.IntervalUnit
        var timeText: String
        var recurrence: TaskSchedule.Recurrence
        var weekday: TaskSchedule.Weekday
        var hasMaximum: Bool
        var maximumRunsText: String
        var requiresConfirmation: Bool

        init(_ schedule: TaskSchedule) {
            isEnabled = schedule.isEnabled
            timing = schedule.timing
            intervalText = String(schedule.interval)
            intervalUnit = schedule.intervalUnit
            timeText = schedule.timeText
            recurrence = schedule.recurrence
            weekday = schedule.weekday
            hasMaximum = schedule.maximumRuns != nil
            maximumRunsText = schedule.maximumRuns.map(String.init) ?? ""
            requiresConfirmation = schedule.requiresConfirmation
        }

        var interval: Int? {
            Int(intervalText).flatMap { TaskSchedule.countRange.contains($0) ? $0 : nil }
        }

        var maximumRuns: Int? {
            Int(maximumRunsText).flatMap { TaskSchedule.countRange.contains($0) ? $0 : nil }
        }

        // What is wrong with the numbers, if anything. Only the timing in use is checked:
        // a bad value on the other side is kept but never runs, and a timer that is off
        // keeps whatever was typed until it is turned on.
        var problem: String? {
            guard isEnabled else { return nil }
            switch timing {
            case .interval:
                if interval == nil { return "Enter an interval from 1 to 10,000." }
                if hasMaximum, maximumRuns == nil {
                    return "Enter a maximum from 1 to 10,000 scheduled runs."
                }
            case .timeOfDay:
                if TaskSchedule.parseTime(timeText) == nil {
                    return "Enter a valid time from 00:00 to 23:59."
                }
            }
            return nil
        }

        // A value that cannot be read falls back to the model's own default, which is
        // what an unsaved side of the timer would have held anyway.
        var schedule: TaskSchedule? {
            guard problem == nil else { return nil }
            var value = TaskSchedule()
            value.isEnabled = isEnabled
            value.timing = timing
            value.interval = interval ?? TaskSchedule.defaultInterval
            value.intervalUnit = intervalUnit
            value.timeOfDayMinutes = TaskSchedule.parseTime(timeText)
                ?? TaskSchedule.defaultTimeOfDayMinutes
            value.recurrence = recurrence
            value.weekday = weekday
            value.maximumRuns = timing == .interval && hasMaximum ? maximumRuns : nil
            value.requiresConfirmation = timing == .interval && requiresConfirmation
            return value
        }

        func differs(from saved: TaskSchedule) -> Bool {
            guard let schedule else { return true }
            return !schedule.hasSameConfiguration(as: saved)
        }
    }
}
