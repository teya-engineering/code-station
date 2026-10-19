import SwiftUI
import CodeStationCore

// Everything a new task needs before it exists: what to call it, what it runs, which
// agent runs it, and whether it runs on its own. Nil choices follow the app defaults.
struct NewTaskDraft {
    let name: String
    let prompt: String
    var agent: AgentKind? = nil
    var agentAvatarName: String? = nil
    var schedule: TaskSchedule? = nil
    let runNow: Bool
}

// A task has no existing folder to pick: it starts in an empty one of its own. What it
// does have is a prompt, saved on the task so a run is one click rather than a retype.
// A time of day is the one schedule offered here, since "set a schedule" is the most
// common next step; intervals, run limits and confirmation stay on the task page.
struct NewTaskView: View {
    let onCreate: (NewTaskDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var appSettings

    private enum When { case manual, schedule }
    private enum Repeat: CaseIterable { case daily, weekdays, mondays }

    @State private var name = ""
    @State private var prompt = ""
    @State private var agent: AgentKind?
    @State private var avatarName: String?
    @State private var when: When = .manual
    @State private var timeText = "09:00"
    @State private var repeatRule: Repeat = .weekdays
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("New task")
                        .font(.serif(22, .semibold))
                    Text("A prompt you can run again and again. Each run starts a fresh session in the task's own folder.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        nameField
                            .padding(.top, 18)
                        promptBox
                            .padding(.top, 12)
                        whenSection
                            .padding(.top, 16)
                    }
                }
                .frame(maxHeight: 470)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            SheetFooter(title: "More schedule options, inputs and run choices are on the task page.",
                        primary: SheetAction(title: "Create and run", icon: "play.fill",
                                             enabled: canRun, shortcut: .defaultAction) {
                            create(runNow: true)
                        },
                        secondary: SheetAction(title: "Create", enabled: canCreate) {
                            create(runNow: false)
                        },
                        dismiss: { dismiss() })
        }
        .frame(width: 560)
        .background(Theme.background)
        .smoothlyResizes(when: when == .schedule)
        .task { nameFocused = true }
    }

    private var nameField: some View {
        TextField("Name it, like Dependabot or Weekly release notes", text: $name)
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .focused($nameFocused)
            .accessibilityLabel("Task name")
            .padding(.horizontal, 14)
            .frame(height: 44)
            .fieldSurface(cornerRadius: 10)
    }

    // The prompt and who runs it, in one box: the agent is part of what a run sends.
    private var promptBox: some View {
        let holes = TaskTemplate.placeholders(in: prompt)
        return VStack(alignment: .leading, spacing: 0) {
            TaskPromptEditor(text: $prompt,
                             placeholder: "What should the agent do on every run? Write {{ticket}} where each run should ask for something.",
                             fontSize: 13.5,
                             minHeight: 120)
                .padding(.horizontal, 14)
                .padding(.top, 12)

            Divider().overlay(Theme.hairline)
                .padding(.top, 12)

            HStack(spacing: 12) {
                if !holes.isEmpty {
                    asks(holes)
                }
                Spacer(minLength: 8)
                AgentAndBotPicker(avatars: appSettings.agentAvatars,
                                  selectedAvatarName: avatarBinding,
                                  agentTitle: (agent ?? runner.agent).title,
                                  agentMenu: agentMenu)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 9)
        }
        .cardSurface(cornerRadius: 10)
    }

    private func asks(_ holes: [String]) -> some View {
        var names = holeName(holes[0])
        for hole in holes.dropFirst() {
            names = Text("\(names), \(holeName(hole))")
        }
        return Text("Asks for \(names) on each run")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func holeName(_ name: String) -> Text {
        Text(verbatim: name).font(.mono(11)).foregroundStyle(Theme.accent)
    }

    private var avatarBinding: Binding<String> {
        Binding(get: { avatarName ?? appSettings.defaultAgentAvatarName },
                set: { avatarName = $0 })
    }

    private var agentMenu: [MenuEntry] {
        [.item("Use the default (\(runner.agent.title))", checked: agent == nil) {
            agent = nil
        }, .separator]
        + AgentKind.allCases.map { kind in
            .item(kind.title, checked: agent == kind) { agent = kind }
        }
    }

    // MARK: - When

    private var whenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("When should it run?")
                .font(.system(size: 12.5, weight: .semibold))
            HStack(spacing: 8) {
                whenChoice(.manual, title: "When I run it", detail: "Click Run task each time.")
                whenChoice(.schedule, title: "On a schedule",
                           detail: "While Teya Code Station is open.")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("When should it run")

            if when == .schedule {
                scheduleFields
                    .padding(.top, 2)
                    .transition(.fadeIn)
            }
        }
    }

    private func whenChoice(_ value: When, title: String, detail: String) -> some View {
        let selected = when == value
        return Button { when = value } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .motion(Motion.control, value: selected)
    }

    private var scheduleFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                LabeledField("TIME") {
                    TextField("09:00", text: $timeText)
                        .font(.mono(12))
                        .appTextField(size: 12)
                        .frame(width: 90)
                        .accessibilityLabel("Time, 24-hour")
                }
                LabeledField("REPEAT") {
                    HStack(spacing: 6) {
                        ForEach(Repeat.allCases, id: \.self) { rule in
                            ChoicePill(title: title(of: rule), selected: repeatRule == rule) {
                                repeatRule = rule
                            }
                        }
                    }
                }
            }
            scheduleNote
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sunken))
    }

    @ViewBuilder private var scheduleNote: some View {
        let holes = TaskTemplate.placeholders(in: prompt)
        if let schedule {
            if holes.isEmpty {
                Text("\(schedule.summary). The first run is \(RelativeTime.stamp(schedule.nextDate(after: Date()))).")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                warning("Scheduled runs need a value for \(holes.joined(separator: ", ")). "
                        + "Add a default on the task page, or run it once by hand.")
            }
        } else {
            warning("Enter a time from 00:00 to 23:59, like 09:00.")
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.attentionText)
    }

    private func title(of rule: Repeat) -> String {
        switch rule {
        case .daily: "Daily"
        case .weekdays: "Weekdays"
        case .mondays: "Mondays"
        }
    }

    // The schedule the task is created with, or nil while the time cannot be read.
    private var schedule: TaskSchedule? {
        guard let minutes = TaskSchedule.parseTime(timeText) else { return nil }
        var schedule = TaskSchedule()
        schedule.isEnabled = true
        schedule.timing = .timeOfDay
        schedule.timeOfDayMinutes = minutes
        switch repeatRule {
        case .daily: schedule.recurrence = .daily
        case .weekdays: schedule.recurrence = .weekdays
        case .mondays:
            schedule.recurrence = .weekly
            schedule.weekday = .monday
        }
        return schedule
    }

    // MARK: - Creating

    private var scheduleReady: Bool { when == .manual || schedule != nil }

    private var canCreate: Bool { !name.isBlank && scheduleReady }

    // Running straight away only makes sense once there is a prompt to send.
    private var canRun: Bool { canCreate && !prompt.isBlank }

    private func create(runNow: Bool) {
        guard canCreate, !runNow || canRun else { return }
        onCreate(NewTaskDraft(name: name, prompt: prompt, agent: agent,
                              agentAvatarName: avatarName,
                              schedule: when == .schedule ? schedule : nil,
                              runNow: runNow))
        dismiss()
    }
}
