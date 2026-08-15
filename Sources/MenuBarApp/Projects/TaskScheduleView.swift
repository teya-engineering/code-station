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
                    Text("Runs happen while Teya Conductor is open. A missed time runs once "
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
                }
            }

            Divider().overlay(Theme.hairline)
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
        .onChange(of: schedule) { oldValue, newValue in
            let old = oldValue ?? TaskSchedule()
            guard !draft.differs(from: old) else { return }
            draft = Draft(newValue ?? TaskSchedule())
        }
    }

    private var intervalEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 10) {
                field("EVERY", placeholder: "30", text: $draft.intervalText, width: 100)
                menuField("UNIT", value: draft.intervalUnit.label(for: draft.interval ?? 2)) {
                    TaskSchedule.IntervalUnit.allCases.map { unit in
                        .item(unit.label(for: draft.interval ?? 2).capitalized,
                              checked: draft.intervalUnit == unit) {
                            draft.intervalUnit = unit
                        }
                    }
                }
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
                        field(nil, placeholder: "10", text: $draft.maximumRunsText, width: 76)
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
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }

    private var timeOfDayEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("TIME", placeholder: "09:00", text: $draft.timeText, width: 120,
                  note: "Use 24-hour time in HH:mm format.")

            VStack(alignment: .leading, spacing: 7) {
                FieldLabel(text: "RECURRENCE")
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
                VStack(alignment: .leading, spacing: 7) {
                    FieldLabel(text: "DAY")
                    HStack(spacing: 6) {
                        ForEach(TaskSchedule.Weekday.allCases, id: \.self) { weekday in
                            ChoicePill(title: weekday.shortTitle,
                                       selected: draft.weekday == weekday) {
                                draft.weekday = weekday
                            }
                        }
                    }
                }
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
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
                    Text("\(schedule.completedRuns) scheduled run"
                         + "\(schedule.completedRuns == 1 ? "" : "s") completed")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            ActionButton(title: "Save timer", tone: .green, icon: "clock") {
                save()
            }
            .disabled(!isDirty || issue != nil)
            .opacity(isDirty && issue == nil ? 1 : 0.45)
        }
    }

    private var issue: String? {
        guard draft.isEnabled else { return nil }
        guard task.task?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return "Add a prompt before turning on scheduled runs."
        }
        if draft.timing == .interval, draft.interval == nil {
            return "Enter an interval from 1 to 10,000."
        }
        if draft.timing == .timeOfDay, TaskSchedule.parseTime(draft.timeText) == nil {
            return "Enter a valid time from 00:00 to 23:59."
        }
        if draft.timing == .interval, draft.hasMaximum, draft.maximumRuns == nil {
            return "Enter a maximum from 1 to 10,000 scheduled runs."
        }
        if TaskRun.automaticValues(for: task) == nil {
            return "Run the task once to save values for every required input, or add "
                + "defaults to those inputs."
        }
        return nil
    }

    private var isDirty: Bool { draft.differs(from: schedule ?? TaskSchedule()) }

    private func save() {
        guard issue == nil, var value = draft.schedule else { return }
        value.restart()
        onSave(value)
    }

    private func field(_ label: String?, placeholder: String, text: Binding<String>,
                       width: CGFloat, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label { FieldLabel(text: label) }
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.mono(12))
                .padding(.horizontal, 10)
                .frame(width: width, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func menuField(_ label: String, value: String,
                           entries: @escaping () -> [MenuEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: label)
            HStack(spacing: 8) {
                Text(value.capitalized)
                    .font(.system(size: 12))
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(width: 130, height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            .appMenu(matchWidth: true) { entries() }
        }
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
            Int(intervalText).flatMap { (1...10_000).contains($0) ? $0 : nil }
        }

        var maximumRuns: Int? {
            Int(maximumRunsText).flatMap { (1...10_000).contains($0) ? $0 : nil }
        }

        var schedule: TaskSchedule? {
            let savedInterval = interval ?? 30
            let savedTime = TaskSchedule.parseTime(timeText) ?? 9 * 60
            guard !isEnabled || (timing != .interval || interval != nil),
                  !isEnabled || (timing != .timeOfDay || TaskSchedule.parseTime(timeText) != nil),
                  !isEnabled || timing != .interval || !hasMaximum || maximumRuns != nil else {
                return nil
            }
            var value = TaskSchedule()
            value.isEnabled = isEnabled
            value.timing = timing
            value.interval = savedInterval
            value.intervalUnit = intervalUnit
            value.timeOfDayMinutes = savedTime
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
