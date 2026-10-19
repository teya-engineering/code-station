import Foundation
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

struct TaskRunHistoryTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func run(_ created: Date, scheduled: Bool = false) -> ChatSession {
        var session = ChatSession(projectID: UUID())
        session.createdAt = created
        session.isScheduledRun = scheduled
        return session
    }

    @Test func groupsRunsUnderTheDayTheyStartedNewestFirst() {
        let now = date(10, 4, 12)
        let older = run(date(10, 2, 9))
        let yesterdayMorning = run(date(10, 3, 8))
        let today = run(date(10, 4, 10))
        let yesterdayEvening = run(date(10, 3, 22))

        let days = TaskRunHistory.days(of: [older, yesterdayMorning, today, yesterdayEvening],
                                       now: now, calendar: calendar)

        #expect(days.map(\.title) == ["Today", "Yesterday", "2 Oct"])
        #expect(days.map { $0.runs.map(\.id) } == [
            [today.id], [yesterdayEvening.id, yesterdayMorning.id], [older.id]
        ])
    }

    @Test func namesTheYearOnlyForADayFromAnotherYear() {
        let title = TaskRunHistory.dayTitle(date(12, 30, 0, year: 2025), now: date(10, 4, 12),
                                            calendar: calendar)

        #expect(title.contains("2025"))
    }

    @Test func filtersByWhoStartedARunAndHowItEnded() {
        let manual = run(date(10, 4, 9))
        let scheduled = run(date(10, 4, 10), scheduled: true)
        let failedIDs: Set<UUID> = [manual.id]

        let runs = [manual, scheduled]
        let failed = { (session: ChatSession) in failedIDs.contains(session.id) }

        #expect(TaskRunHistory.filtered(runs, by: .all, failed: failed).count == 2)
        #expect(TaskRunHistory.filtered(runs, by: .scheduled, failed: failed).map(\.id)
                == [scheduled.id])
        #expect(TaskRunHistory.filtered(runs, by: .failed, failed: failed).map(\.id)
                == [manual.id])
    }

    @Test func saysHowLongARunTookInTheTwoLargestUnits() {
        #expect(TaskRunHistory.duration(42) == "42s")
        #expect(TaskRunHistory.duration(252) == "4m 12s")
        #expect(TaskRunHistory.duration(302) == "5m 02s")
        #expect(TaskRunHistory.duration(3_900) == "1h 05m")
        #expect(TaskRunHistory.duration(-5) == "0s")
    }

    @Test func readsARunSavedBeforeItsTriggerWasKeptAsStartedByHand() throws {
        var session = ChatSession(projectID: UUID())
        let plain = try JSONEncoder().encode(session)
        #expect(!String(decoding: plain, as: UTF8.self).contains("isScheduledRun"))
        #expect(try JSONDecoder().decode(ChatSession.self, from: plain).isScheduledRun == false)

        session.isScheduledRun = true
        let marked = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(ChatSession.self, from: marked).isScheduledRun)
    }
}
