import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

@MainActor
struct ScheduledRunConfirmationTests {
    @Test func overdueConfirmationIsOfferedOnceAndSkippingAdvancesTheSchedule() throws {
        let (store, scratch) = TestStore.make()
        let runner = SessionRunner(preferences: scratch.preferences.store,
                                   persistentAgentSessions: false, paths: [:])
        let task = try store.addTask(named: "Check", prompt: "Check the repository",
                                     in: scratch.path("tasks")).get()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var schedule = TaskSchedule()
        schedule.isEnabled = true
        schedule.requiresConfirmation = true
        schedule.interval = 1
        schedule.intervalUnit = .minutes
        schedule.restart(at: now)
        var spec = try #require(task.task)
        spec.schedule = schedule
        store.setTaskSpec(spec, for: task.id)
        let due = try #require(schedule.nextRunAt)

        ScheduledTaskExecution.tick(at: due, store: store, runner: runner, agentAvatarName: nil)
        ScheduledTaskExecution.tick(at: due, store: store, runner: runner, agentAvatarName: nil)
        #expect(ScheduledTaskExecution.awaitingConfirmation(at: due, store: store, runner: runner)
            .map(\.id) == [task.id])
        #expect(store.standaloneSessions(for: task.id).isEmpty)
        ScheduledTaskExecution.confirm(task.id, .skip, at: due, store: store, runner: runner,
                                       agentAvatarName: nil)
        ScheduledTaskExecution.tick(at: due, store: store, runner: runner, agentAvatarName: nil)
        #expect(ScheduledTaskExecution.awaitingConfirmation(at: due, store: store, runner: runner).isEmpty)
        #expect(try #require(store.project(task.id)?.task?.schedule?.nextRunAt) > due)
        #expect(store.standaloneSessions(for: task.id).isEmpty)
    }
}
