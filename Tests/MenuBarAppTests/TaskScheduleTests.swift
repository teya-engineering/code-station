import Foundation
import Testing
@testable import MenuBarApp

struct TaskScheduleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day,
                                           hour: hour, minute: minute))!
    }

    @Test func intervalStartsWhenSavedAndMovesOnWhenSkipped() {
        let now = date(17, 8)
        var schedule = TaskSchedule()
        schedule.isEnabled = true
        schedule.interval = 45
        schedule.intervalUnit = .minutes
        schedule.requiresConfirmation = true

        schedule.restart(at: now, calendar: calendar)
        #expect(schedule.nextRunAt == date(17, 8, 45))

        schedule.waitForConfirmation()
        #expect(schedule.isWaitingForConfirmation)

        schedule.skip(at: date(17, 9), calendar: calendar)
        #expect(!schedule.isWaitingForConfirmation)
        #expect(schedule.completedRuns == 0)
        #expect(schedule.nextRunAt == date(17, 9, 45))
    }

    @Test func maximumTurnsTheTimerOffAfterTheRequestedNumberOfRuns() {
        var schedule = TaskSchedule()
        schedule.isEnabled = true
        schedule.interval = 1
        schedule.intervalUnit = .hours
        schedule.maximumRuns = 2
        schedule.restart(at: date(17, 8), calendar: calendar)

        schedule.recordRun(at: date(17, 9), calendar: calendar)
        #expect(schedule.isActive)
        #expect(schedule.completedRuns == 1)
        #expect(schedule.nextRunAt == date(17, 10))

        schedule.recordRun(at: date(17, 10), calendar: calendar)
        #expect(!schedule.isEnabled)
        #expect(schedule.hasReachedMaximum)
        #expect(schedule.completedRuns == 2)
        #expect(schedule.nextRunAt == nil)
    }

    @Test func timeOfDayRecurrenceFindsTheNextAllowedDay() {
        var schedule = TaskSchedule()
        schedule.timing = .timeOfDay
        schedule.timeOfDayMinutes = 9 * 60 + 30

        schedule.recurrence = .daily
        #expect(schedule.nextDate(after: date(17, 8), calendar: calendar)
                == date(17, 9, 30))
        #expect(schedule.nextDate(after: date(17, 10), calendar: calendar)
                == date(18, 9, 30))

        // 21 August 2026 is Friday, so the next weekday after its morning slot is Monday.
        schedule.recurrence = .weekdays
        #expect(schedule.nextDate(after: date(21, 10), calendar: calendar)
                == date(24, 9, 30))

        schedule.recurrence = .weekly
        schedule.weekday = .wednesday
        #expect(schedule.nextDate(after: date(17, 10), calendar: calendar)
                == date(19, 9, 30))
    }

    @Test func parsesOnlyValidTwentyFourHourTimes() {
        #expect(TaskSchedule.parseTime("00:00") == 0)
        #expect(TaskSchedule.parseTime("23:59") == 23 * 60 + 59)
        #expect(TaskSchedule.parseTime("24:00") == nil)
        #expect(TaskSchedule.parseTime("9") == nil)
        #expect(TaskSchedule.parseTime("9:00") == nil)
        #expect(TaskSchedule.parseTime("09:0") == nil)
        #expect(TaskSchedule.parseTime("+9:00") == nil)
        #expect(TaskSchedule.parseTime("09:+0") == nil)
        #expect(TaskSchedule.parseTime("09:60") == nil)
    }

    @Test func invalidSavedSchedulesNeverBecomeDue() {
        var interval = TaskSchedule()
        interval.isEnabled = true
        interval.interval = 0
        interval.restart(at: date(17, 8), calendar: calendar)

        var timeOfDay = TaskSchedule()
        timeOfDay.isEnabled = true
        timeOfDay.timing = .timeOfDay
        timeOfDay.timeOfDayMinutes = 24 * 60
        timeOfDay.restart(at: date(17, 8), calendar: calendar)

        #expect(!interval.isActive)
        #expect(interval.nextRunAt == nil)
        #expect(!timeOfDay.isActive)
        #expect(timeOfDay.nextRunAt == nil)
    }
}

@MainActor
struct ScheduledTaskExecutionTests {
    @Test func scheduledRunUsesSavedInputsPersistsProgressAndHonoursTheMaximum() throws {
        let scratch = ScratchDirectory(prefix: "code-station-task-schedule-tests")
        let storeURL = scratch.path("projects.json")
        let store = ProjectStore(storeURL: storeURL)
        let task = try store.addTask(named: "Deploy", prompt: "Deploy {{environment}}.",
                                     in: scratch.path("tasks")).get()
        let runner = SessionRunner(paths: [:])
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        var schedule = TaskSchedule()
        schedule.isEnabled = true
        schedule.interval = 1
        schedule.intervalUnit = .minutes
        schedule.maximumRuns = 1
        schedule.restart(at: now)
        var spec = try #require(task.task)
        spec.inputs = [TaskInput(name: "environment", defaultValue: "production")]
        spec.schedule = schedule
        store.setTaskSpec(spec, for: task.id)

        let due = try #require(schedule.nextRunAt)
        let session = try ScheduledTaskExecution.run(
            task.id, at: due, store: store, runner: runner, agentAvatarName: nil).get()

        #expect(store.transcript(of: session.id).contains {
            $0.role == .user && $0.text == "Deploy production."
        })
        let saved = try #require(store.project(task.id)?.task?.schedule)
        #expect(saved.completedRuns == 1)
        #expect(saved.hasReachedMaximum)
        #expect(!saved.isEnabled)
        #expect(ProjectStore(storeURL: storeURL).project(task.id)?.task?.schedule == saved)
    }

    @Test func scheduledRunWaitsForARequiredValue() throws {
        let task = Project(name: "Deploy", path: "/tmp/deploy", kind: .adHoc,
                           task: TaskSpec(prompt: "Deploy {{environment}}."))

        #expect(TaskRun.automaticValues(for: task) == nil)
    }
}
