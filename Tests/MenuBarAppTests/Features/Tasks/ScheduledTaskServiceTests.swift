import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct ScheduledTaskServiceTests {
    @Test func overdueConfirmationIsOfferedOnceAndSkippingAdvancesTheSchedule() throws {
        let (store, scratch) = TestStore.make()
        let runner = SessionRunner(store: store, preferences: scratch.preferences.store,
                                   persistentAgentSessions: false, paths: [:])
        let service = ScheduledTaskService(store: store, runner: runner, agentAvatarName: { nil })
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

        service.tick(at: due)
        service.tick(at: due)
        #expect(service.pendingConfirmationID == task.id)
        #expect(store.standaloneSessions(for: task.id).isEmpty)
        service.confirm(.skip, projectID: task.id, at: due)
        service.tick(at: due)
        #expect(service.pendingConfirmationID == nil)
        #expect(try #require(store.project(task.id)?.task?.schedule?.nextRunAt) > due)
        #expect(store.standaloneSessions(for: task.id).isEmpty)
    }
}
