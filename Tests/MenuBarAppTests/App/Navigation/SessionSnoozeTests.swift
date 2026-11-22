import Foundation
import Testing
@testable import MenuBarApp

// A session put out of the way: what hides it, what keeps it quiet, and what brings it back.
@MainActor
struct SessionSnoozeTests {
    private let testPreferences = TestPreferences()
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let project: Project

    init() throws {
        (store, scratch) = TestStore.make()
        project = try TestStore.project(in: store)
    }

    @Test func aSnoozedSessionStopsAskingForAnyone() {
        let sleeping = store.newSession(in: project.id)
        let open = store.newSession(in: project.id)
        store.selection = .session(open.id)
        store.noteTurnEnded(for: sleeping.id)
        #expect(store.unreadCount(in: project.id) == 1)

        store.snooze(sleeping.id, .untilWoken)

        #expect(store.isSnoozed(sleeping.id))
        #expect(store.unreadCount(in: project.id) == 0)

        store.wake(sleeping.id)

        #expect(store.isSnoozed(sleeping.id) == false)
        #expect(store.unreadCount(in: project.id) == 1)
    }

    @Test func theReplyEndsASnoozeThatWaitedForIt() {
        let sleeping = store.newSession(in: project.id)
        let open = store.newSession(in: project.id)
        store.selection = .session(open.id)
        store.snooze(sleeping.id, .untilReply)

        #expect(store.noteTurnEnded(for: sleeping.id))

        #expect(store.isSnoozed(sleeping.id) == false)
        #expect(store.isUnread(sleeping.id))
        #expect(store.unreadCount(in: project.id) == 1)
    }

    @Test func aTimedSnoozeStaysQuietThroughAReplyUntilItsTimeIsUp() {
        let sleeping = store.newSession(in: project.id)
        let open = store.newSession(in: project.id)
        store.selection = .session(open.id)
        let now = Date()
        store.snooze(sleeping.id, .until(now.addingTimeInterval(3_600)))

        store.noteTurnEnded(for: sleeping.id)
        #expect(store.isSnoozed(sleeping.id, now: now))
        #expect(store.unreadCount(in: project.id) == 0)

        // Past its time the snooze is over even before the sweep has run.
        #expect(store.isSnoozed(sleeping.id, now: now.addingTimeInterval(3_601)) == false)
        store.expireSnoozes(now: now.addingTimeInterval(3_601))
        #expect(store.session(sleeping.id)?.snooze == nil)
        #expect(store.unreadCount(in: project.id) == 1)
    }

    @Test func aTimedSnoozeRunningOutLeavesOneReminder() {
        let sleeping = store.newSession(in: project.id)
        let now = Date()
        let snooze = SessionSnooze.until(now.addingTimeInterval(60))
        store.snooze(sleeping.id, snooze)

        store.expireSnoozes(now: now)
        #expect(store.snoozeReminders.isEmpty)

        store.expireSnoozes(now: now.addingTimeInterval(61))
        let due = store.takeSnoozeReminders()
        #expect(due.map(\.session.id) == [sleeping.id])
        #expect(due.first?.snooze == snooze)
        #expect(store.takeSnoozeReminders().isEmpty)
    }

    @Test func aSnoozeEndedByTheSessionOrThePersonLeavesNoReminder() {
        let replied = store.newSession(in: project.id)
        let woken = store.newSession(in: project.id)
        store.snooze(replied.id, .untilReply)
        store.snooze(woken.id, .until(Date().addingTimeInterval(3_600)))

        store.noteTurnEnded(for: replied.id)
        store.wake(woken.id)

        #expect(store.snoozeReminders.isEmpty)
    }

    @Test func aSnoozeThatRanOutWhileTheAppWasClosedIsRemindedAtLaunch() throws {
        let sleeping = store.newSession(in: project.id)
        store.snooze(sleeping.id, .until(Date().addingTimeInterval(-60)))
        #expect(store.save())

        let reloaded = ProjectStore(preferences: testPreferences.store, storeURL: store.storeURL)

        #expect(reloaded.session(sleeping.id)?.snooze == nil)
        #expect(reloaded.takeSnoozeReminders().map(\.session.id) == [sleeping.id])
    }

    @Test func theSnoozeSurvivesARelaunch() throws {
        let sleeping = store.newSession(in: project.id)
        store.snooze(sleeping.id, .untilWoken)
        #expect(store.save())

        let reloaded = ProjectStore(preferences: testPreferences.store, storeURL: store.storeURL)

        #expect(reloaded.isSnoozed(sleeping.id))
        #expect(reloaded.session(sleeping.id)?.snooze == .untilWoken)
    }

    @Test(arguments: [SessionSnooze.untilReply, .untilWoken, .until(Date.distantFuture)])
    func wakingKeepsTheAgentRunningAndAQuestionEndsEverySnooze(_ snooze: SessionSnooze) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: #"""
        printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Working."}]}}'
        wait_for "$folder/ask"
        printf '%s\n' '{"type":"control_request","request_id":"question","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which option?","header":"Choice","options":[{"label":"One","description":"First"},{"label":"Two","description":"Second"}]}]},"requires_user_interaction":true}}'
        wait_for "$folder/finish"
        """#)
        defer { fixture.tearDown() }
        fixture.runner.send("Work", sessionID: fixture.session.id)
        #expect(await waitUntil {
            fixture.store.transcript(of: fixture.session.id).contains { $0.text.contains("Working.") }
        })
        fixture.store.snooze(fixture.session.id, snooze)
        #expect(fixture.runner.state(fixture.session.id).isBusy)
        SessionSnoozeMenu.wake(fixture.session.id, store: fixture.store)
        #expect(fixture.runner.state(fixture.session.id).isBusy)
        #expect(!fixture.store.isSnoozed(fixture.session.id))
        fixture.store.snooze(fixture.session.id, snooze)
        try Data().write(to: fixture.scratch.path("ask"))
        #expect(await waitUntil { fixture.runner.question(fixture.session.id) != nil })
        #expect(!fixture.store.isSnoozed(fixture.session.id))
        #expect(fixture.store.snoozeReminders.isEmpty)
        #expect(fixture.store.session(fixture.session.id)?.projectID == fixture.session.projectID)
    }

    @Test func choicesLandOnTheNextMorningAndAMondayAfterIt() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }

        // A Saturday mid-morning: 8:00 is tomorrow, Monday is two days on.
        let saturday = date(2026, 10, 24, 10)
        #expect(SessionSnooze.Choice.morning.snooze(now: saturday, calendar: calendar)
            == .until(date(2026, 10, 25, 8)))
        #expect(SessionSnooze.Choice.nextWeek.snooze(now: saturday, calendar: calendar)
            == .until(date(2026, 10, 26, 8)))

        // Early on a Monday the morning is today, so the week waits for the next Monday.
        let earlyMonday = date(2026, 10, 26, 6, 40)
        #expect(SessionSnooze.Choice.morning.snooze(now: earlyMonday, calendar: calendar)
            == .until(date(2026, 10, 26, 8)))
        #expect(SessionSnooze.Choice.nextWeek.snooze(now: earlyMonday, calendar: calendar)
            == .until(date(2026, 11, 2, 8)))

        // Later on a Monday it is a week away.
        #expect(SessionSnooze.Choice.nextWeek.snooze(now: date(2026, 10, 26, 10, 30), calendar: calendar)
            == .until(date(2026, 11, 2, 8)))

        // On a Sunday evening the morning is Monday, so the week skips to the Monday after.
        let sundayEvening = date(2026, 11, 1, 21)
        #expect(SessionSnooze.Choice.morning.snooze(now: sundayEvening, calendar: calendar)
            == .until(date(2026, 11, 2, 8)))
        #expect(SessionSnooze.Choice.nextWeek.snooze(now: sundayEvening, calendar: calendar)
            == .until(date(2026, 11, 9, 8)))

        #expect(SessionSnooze.Choice.untilWoken.snooze().deadline == nil)
        #expect(SessionSnooze.Choice.allCases == [.morning, .nextWeek, .untilWoken])
    }

    @Test func timedChoicesNameTheirDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        calendar.locale = Locale(identifier: "en_GB")
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }

        let lateMonday = date(2026, 10, 26, 10, 30)
        // The hour follows the locale's own clock, so only the day is pinned down here.
        #expect(SessionSnooze.Choice.morning.title(now: lateMonday, calendar: calendar).hasSuffix(":00 tomorrow"))
        #expect(SessionSnooze.Choice.morning.note(now: lateMonday, calendar: calendar)
            .hasPrefix("Comes back tomorrow, Tuesday 27 October, at "))
        #expect(SessionSnooze.Choice.nextWeek.title(now: lateMonday, calendar: calendar) == "Until Monday 2 Nov")
        #expect(SessionSnooze.Choice.nextWeek.note(now: lateMonday, calendar: calendar)
            .hasPrefix("Comes back on Monday 2 November at "))

        let earlyMonday = date(2026, 10, 26, 6, 40)
        #expect(SessionSnooze.Choice.morning.title(now: earlyMonday, calendar: calendar).hasSuffix(":00 today"))
        #expect(SessionSnooze.Choice.nextWeek.title(now: earlyMonday, calendar: calendar) == "Until Monday 2 Nov")

        let sundayEvening = date(2026, 11, 1, 21)
        #expect(SessionSnooze.Choice.morning.title(now: sundayEvening, calendar: calendar).hasSuffix(":00 tomorrow"))
        #expect(SessionSnooze.Choice.nextWeek.title(now: sundayEvening, calendar: calendar) == "Until Monday 9 Nov")
    }

    @Test func aSavedUntilReplySnoozeStillEndsOnTheReplyButOpensOnTheMorning() {
        #expect(SessionSnooze.untilReply.endsOnReply)
        #expect(SnoozeChoice(snooze: .untilReply).choice == .morning)
        #expect(SnoozeChoice().choice == .morning)
        #expect(SnoozeChoice(snooze: .untilWoken).choice == .untilWoken)
    }
}
