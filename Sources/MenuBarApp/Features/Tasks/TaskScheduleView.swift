import SwiftUI
import CodeStationCore

// A task's schedule, as a quiet setting beside the prompt. Most of the time it is one
// summary line: off, or the rule it follows and when it next runs. The editor only opens
// on request, so Save and Cancel only exist while there is something to save. Numbers
// stay local to the editor until saved, so a half-typed value never replaces a schedule
// that may already be running.
struct TaskScheduleCard: View {
    let task: Project
    let schedule: TaskSchedule?
    let onSave: (TaskSchedule) -> Void

    @State private var draft: Draft?

    private var isOn: Bool { schedule?.isActive == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Schedule")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if draft == nil {
                    stateCaps
                }
            }

            if let draft {
                editor(draft)
                    .transition(.fadeIn)
            } else if isOn, let schedule {
                onSummary(schedule)
                    .transition(.fadeIn)
            } else {
                offSummary
                    .transition(.fadeIn)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 12)
        .smoothlyResizes(when: layoutState)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Schedule")
    }

    // The state is a word as well as a colour, so it reads the same without the colour.
    @ViewBuilder private var stateCaps: some View {
        if schedule?.isWaitingForConfirmation == true {
            StatusCaps(text: "CONFIRM", tint: Theme.attentionText)
        } else if isOn {
            StatusCaps(text: "ON", tint: Theme.accent)
        } else {
            StatusCaps(text: "OFF")
        }
    }

    // MARK: - Summaries

    private var offSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(offDetail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            ActionButton(title: "Set a schedule", tone: .outlined, height: 28, size: 12,
                         icon: "clock") {
                startEditing()
            }
            .fixedSize()
        }
    }

    private var offDetail: String {
        if let schedule, schedule.hasReachedMaximum, schedule.completedRuns > 0 {
            return "Finished after \(counted(schedule.completedRuns, "scheduled run")). "
                + "Runs only when you click Run task now."
        }
        return "Runs only when you click Run task."
    }

    private func onSummary(_ schedule: TaskSchedule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.summary)
                    .font(.serif(17, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(nextLine(schedule))
                    .font(.system(size: 12))
                    .foregroundStyle(schedule.isWaitingForConfirmation
                                     ? Theme.attentionText : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sunken))

            HStack(spacing: 8) {
                ActionButton(title: "Change schedule", tone: .outlined, height: 28, size: 12) {
                    startEditing()
                }
                .fixedSize()
                Spacer(minLength: 8)
                InlineLink(title: "Turn off") {
                    var off = schedule
                    off.turnOff()
                    onSave(off)
                }
            }

            Text("Runs only while Teya Code Station is open. A missed time runs once when "
                 + "the app is open again.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
    }

    private func nextLine(_ schedule: TaskSchedule) -> String {
        var parts: [String] = []
        if schedule.isWaitingForConfirmation {
            parts.append("Waiting for you to confirm the next run")
        } else if let next = schedule.nextRunAt {
            parts.append("Next run \(RelativeTime.stamp(next))")
        }
        if let maximum = schedule.maximumRuns {
            parts.append("\(schedule.completedRuns) of \(counted(maximum, "run")) done")
        }
        if schedule.timing == .interval, schedule.requiresConfirmation {
            parts.append("asks first")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Editor

    private func editor(_ current: Draft) -> some View {
        let draft = Binding(get: { self.draft ?? current }, set: { self.draft = $0 })
        let issue = issue(for: current)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ChoicePill(title: "At a time", selected: current.timing == .timeOfDay) {
                    draft.wrappedValue.timing = .timeOfDay
                }
                ChoicePill(title: "Every few minutes", selected: current.timing == .interval) {
                    draft.wrappedValue.timing = .interval
                }
            }

            if current.timing == .timeOfDay {
                timeOfDayEditor(draft)
            } else {
                intervalEditor(draft)
            }

            if let issue {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(issue)
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.attentionText)
                .transition(.fadeIn)
            } else if let rule = current.schedule {
                Text("\(rule.summary). Runs only while Teya Code Station is open.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ActionButton(title: "Cancel", tone: .outlined, height: 28, size: 12) {
                    self.draft = nil
                }
                ActionButton(title: isOn ? "Save schedule" : "Turn on schedule", tone: .green,
                             height: 28, size: 12) {
                    save(current)
                }
                .disabled(issue != nil)
            }
        }
        .padding(.top, 12)
    }

    private func timeOfDayEditor(_ draft: Binding<Draft>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledField("TIME") {
                numberField("09:00", text: draft.timeText, width: 90)
                    .accessibilityLabel("Time, 24-hour")
            }
            LabeledField("REPEAT") {
                HStack(spacing: 6) {
                    ForEach(TaskSchedule.Recurrence.allCases, id: \.self) { recurrence in
                        ChoicePill(title: recurrence.title,
                                   selected: draft.wrappedValue.recurrence == recurrence) {
                            draft.wrappedValue.recurrence = recurrence
                        }
                    }
                }
            }
            if draft.wrappedValue.recurrence == .weekly {
                // Seven pills do not fit across the side column, so the week wraps after
                // Thursday.
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(weekRows, id: \.self) { row in
                        GridRow {
                            ForEach(row, id: \.self) { weekday in
                                ChoicePill(title: weekday.shortTitle,
                                           selected: draft.wrappedValue.weekday == weekday) {
                                    draft.wrappedValue.weekday = weekday
                                }
                            }
                        }
                    }
                }
                .transition(.fadeIn)
            }
        }
    }

    private var weekRows: [[TaskSchedule.Weekday]] {
        [[.monday, .tuesday, .wednesday, .thursday], [.friday, .saturday, .sunday]]
    }

    private func intervalEditor(_ draft: Binding<Draft>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 8) {
                LabeledField("EVERY") {
                    numberField("30", text: draft.intervalText, width: 72)
                        .accessibilityLabel("Every")
                }
                HStack(spacing: 6) {
                    ForEach(TaskSchedule.IntervalUnit.allCases, id: \.self) { unit in
                        ChoicePill(title: unit.label(for: 2).capitalized,
                                   selected: draft.wrappedValue.intervalUnit == unit) {
                            draft.wrappedValue.intervalUnit = unit
                        }
                    }
                }
            }

            LabeledField("STOP AFTER (OPTIONAL)") {
                numberField("No limit", text: draft.maximumRunsText, width: 110)
                    .accessibilityLabel("Stop after this many runs")
            }

            Toggle(isOn: draft.requiresConfirmation) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask before each run")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("When a run is due, choose to run it, skip it, or turn the schedule off.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.appSwitch)
        }
    }

    // A number is typed in mono, so a column of them lines up.
    private func numberField(_ placeholder: String, text: Binding<String>,
                             width: CGFloat) -> some View {
        TextField(placeholder, text: text)
            .font(.mono(12))
            .appTextField(size: 12)
            .frame(width: width)
    }

    // MARK: - Saving

    // Why the schedule cannot be turned on as it stands. The draft knows its own numbers;
    // the task adds whether it has a prompt and an answer for every required input.
    private func issue(for draft: Draft) -> String? {
        guard let spec = task.task, !spec.prompt.isBlank else {
            return "Add a prompt before turning on a schedule."
        }
        if let problem = draft.problem { return problem }
        let missing = TaskRun.unansweredInputs(in: spec).map(\.name)
        if !missing.isEmpty {
            let names = missing.joined(separator: ", ")
            return "Give \(names) a default under Inputs, or run the task once by hand, so "
                + "a scheduled run has something to fill in."
        }
        return nil
    }

    private func startEditing() {
        draft = schedule.map(Draft.init) ?? Draft.fresh
    }

    private func save(_ draft: Draft) {
        guard issue(for: draft) == nil, var value = draft.schedule else { return }
        value.restart()
        onSave(value)
        self.draft = nil
    }

    private var layoutState: LayoutState {
        LayoutState(editing: draft != nil,
                    isOn: isOn,
                    timing: draft?.timing,
                    recurrence: draft?.recurrence,
                    issue: draft.flatMap(issue(for:)))
    }

    private struct LayoutState: Equatable {
        let editing: Bool
        let isOn: Bool
        let timing: TaskSchedule.Timing?
        let recurrence: TaskSchedule.Recurrence?
        let issue: String?
    }

    struct Draft: Equatable {
        var timing: TaskSchedule.Timing
        var intervalText: String
        var intervalUnit: TaskSchedule.IntervalUnit
        var timeText: String
        var recurrence: TaskSchedule.Recurrence
        var weekday: TaskSchedule.Weekday
        var maximumRunsText: String
        var requiresConfirmation: Bool

        init(_ schedule: TaskSchedule) {
            timing = schedule.timing
            intervalText = String(schedule.interval)
            intervalUnit = schedule.intervalUnit
            timeText = schedule.timeText
            recurrence = schedule.recurrence
            weekday = schedule.weekday
            maximumRunsText = schedule.maximumRuns.map(String.init) ?? ""
            requiresConfirmation = schedule.requiresConfirmation
        }

        // A schedule set for the first time starts on the most common rule: a time on
        // working days.
        static var fresh: Draft {
            var schedule = TaskSchedule()
            schedule.timing = .timeOfDay
            schedule.recurrence = .weekdays
            return Draft(schedule)
        }

        var interval: Int? {
            Int(intervalText).flatMap { TaskSchedule.countRange.contains($0) ? $0 : nil }
        }

        var maximumRuns: Int? {
            Int(maximumRunsText.trimmed).flatMap {
                TaskSchedule.countRange.contains($0) ? $0 : nil
            }
        }

        // What is wrong with the numbers, if anything. Only the timing in use is checked:
        // a bad value on the other side is kept but never runs.
        var problem: String? {
            switch timing {
            case .interval:
                if interval == nil { return "Enter an interval from 1 to 10,000." }
                if !maximumRunsText.isBlank, maximumRuns == nil {
                    return "Enter a run limit from 1 to 10,000, or leave it empty."
                }
            case .timeOfDay:
                if TaskSchedule.parseTime(timeText) == nil {
                    return "Enter a time from 00:00 to 23:59, like 09:00."
                }
            }
            return nil
        }

        // A value that cannot be read falls back to the model's own default, which is
        // what an unused side of the schedule would have held anyway.
        var schedule: TaskSchedule? {
            guard problem == nil else { return nil }
            var value = TaskSchedule()
            value.isEnabled = true
            value.timing = timing
            value.interval = interval ?? TaskSchedule.defaultInterval
            value.intervalUnit = intervalUnit
            value.timeOfDayMinutes = TaskSchedule.parseTime(timeText)
                ?? TaskSchedule.defaultTimeOfDayMinutes
            value.recurrence = recurrence
            value.weekday = weekday
            value.maximumRuns = timing == .interval ? maximumRuns : nil
            value.requiresConfirmation = timing == .interval && requiresConfirmation
            return value
        }
    }
}
