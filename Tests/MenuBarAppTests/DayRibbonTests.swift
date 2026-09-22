import Foundation
import Testing
@testable import MenuBarApp

// Where the day went: how a conversation is read back as stretches of work, and how
// those stretches land on the band Home draws.
struct DayRibbonTests {
    private let day = Date(timeIntervalSince1970: 1_758_499_200)

    private func at(_ hour: Double, _ minute: Double = 0) -> Date {
        day.addingTimeInterval(hour * 3_600 + minute * 60)
    }

    private func turn(_ start: Date, calls: [(Date, Date?)]) -> TurnTimes {
        TurnTimes(role: .assistant, date: start,
                  tools: calls.map { TurnTimes.Call(startedAt: $0.0, finishedAt: $0.1) })
    }

    // MARK: - Reading a conversation

    @Test func timesATurnByTheLastCallThatReportedIn() {
        let spans = SessionTime.spans(of: [
            TurnTimes(role: .user, date: at(9, 0), tools: nil),
            turn(at(9, 1), calls: [(at(9, 2), at(9, 5)), (at(9, 6), at(9, 20))]),
            TurnTimes(role: .user, date: at(11, 0), tools: nil)
        ])

        #expect(spans.count == 1)
        #expect(spans.first?.start == at(9, 1))
        #expect(spans.first?.end == at(9, 20))
    }

    // A prompt sent at nine and answered at nine twenty, then nothing until five, is
    // nineteen minutes of work rather than eight hours of it.
    @Test func leavesTheGapBetweenTurnsOutOfTheTotal() {
        let spans = SessionTime.spans(of: [
            turn(at(9, 1), calls: [(at(9, 2), at(9, 20))]),
            turn(at(17, 0), calls: [(at(17, 1), at(17, 10))])
        ])

        #expect(spans.count == 2)
        let total: TimeInterval = spans.reduce(0) { $0 + $1.seconds }
        #expect(total == 1_740)
    }

    @Test func creditsATurnThatOnlyWroteText() {
        let spans = SessionTime.spans(of: [turn(at(9, 0), calls: [])])

        #expect(spans.count == 1)
        #expect(spans.first?.seconds == SessionTime.quietTurn)
    }

    // A call still running has only a start, and that is still evidence of work.
    @Test func timesACallThatHasNotReportedInByItsStart() {
        let spans = SessionTime.spans(of: [turn(at(9, 0), calls: [(at(9, 4), nil)])])

        #expect(spans.first?.end == at(9, 4))
    }

    @Test func mergesTurnsThatOverlap() {
        let spans = SessionTime.spans(of: [
            turn(at(9, 0), calls: [(at(9, 0), at(9, 30))]),
            turn(at(9, 20), calls: [(at(9, 20), at(9, 45))])
        ])

        #expect(spans.count == 1)
        #expect(spans.first?.end == at(9, 45))
    }

    @Test func ignoresPrompts() {
        #expect(SessionTime.spans(of: [TurnTimes(role: .user, date: at(9, 0), tools: nil)])
                    .isEmpty)
    }

    // MARK: - Building the band

    private func session(_ id: UUID = UUID(), project: String,
                         open: Bool = false) -> RibbonSession {
        RibbonSession(id: id, title: "A session",
                      subject: RibbonSubject(name: project,
                                             tint: Theme.projectTint(for: project)),
                      sources: [id], isOpen: open)
    }

    @Test func clipsBlocksToTheBand() {
        let now = at(12, 0)
        let work = session(project: "robota")
        let ribbon = DayRibbon.build([work],
                                     spans: { _ in
                                         [TimeSpan(start: now.addingTimeInterval(-93_600),
                                                   end: now.addingTimeInterval(-82_800))]
                                     },
                                     range: .day, now: now)

        // Two of the three hours are older than the band, so only one is drawn.
        #expect(ribbon.bands.first?.blocks.count == 1)
        #expect(ribbon.spent == 3_600)
        let edge: Date = now.addingTimeInterval(-86_400)
        #expect(ribbon.bands.first?.blocks.first?.start == edge)
    }

    @Test func drawsARunningSessionOutToNow() {
        let now = at(12, 0)
        let work = session(project: "Code Station", open: true)
        let ribbon = DayRibbon.build([work],
                                     spans: { _ in [TimeSpan(start: at(11, 0), end: at(11, 5))] },
                                     range: .day, now: now)

        #expect(ribbon.bands.first?.blocks.first?.end == now)
        #expect(ribbon.bands.first?.blocks.first?.isOpen == true)
        #expect(ribbon.spent == 3_600)
    }

    @Test func ranksTheLegendByTimeSpent() {
        let now = at(18, 0)
        let small = session(project: "robota")
        let large = session(project: "Code Station")
        let ribbon = DayRibbon.build([small, large],
                                     spans: { id in
                                         id == small.id
                                             ? [TimeSpan(start: at(9, 0), end: at(9, 30))]
                                             : [TimeSpan(start: at(10, 0), end: at(12, 0))]
                                     },
                                     range: .day, now: now)

        #expect(ribbon.legend.map(\.subject.name) == ["Code Station", "robota"])
        #expect(ribbon.legend.first?.spent == 7_200)
        #expect(ribbon.spent == 9_000)
    }

    // A session and the hidden Design conversation beside it are one piece of work, so
    // their turns land on one block rather than two.
    @Test func poolsTheTimeOfEveryConversationBehindASession() {
        let now = at(18, 0)
        let design = UUID()
        let id = UUID()
        let work = RibbonSession(id: id, title: "A session",
                                 subject: RibbonSubject(name: "robota",
                                                        tint: Theme.projectTint(for: "robota")),
                                 sources: [id, design], isOpen: false)
        let ribbon = DayRibbon.build([work],
                                     spans: { source in
                                         source == id
                                             ? [TimeSpan(start: at(9, 0), end: at(9, 30))]
                                             : [TimeSpan(start: at(9, 20), end: at(10, 0))]
                                     },
                                     range: .day, now: now)

        #expect(ribbon.bands.first?.blocks.count == 1)
        #expect(ribbon.spent == 3_600)
    }

    @Test func splitsTheWeekIntoSevenDays() {
        let now = at(36, 0)
        let work = session(project: "robota")
        let ribbon = DayRibbon.build([work],
                                     spans: { _ in [TimeSpan(start: at(10, 0), end: at(11, 0))] },
                                     range: .week, now: now)

        #expect(ribbon.bands.count == 7)
        let worked = ribbon.bands.filter { $0.spent > 0 }
        #expect(worked.count == 1)
        #expect(ribbon.bands.last?.isToday == true)
    }

    // A day with nothing in it was never started, rather than measured and found empty.
    @Test func readsAnEmptyDayAsADash() {
        #expect(DayRibbon.total(0) == "-")
        #expect(DayRibbon.total(5_400) == "1h 30m")
    }

    @Test func readsDurationsInHoursAndMinutes() {
        #expect(DayRibbon.duration(0) == "0m")
        #expect(DayRibbon.duration(20) == "1m")
        #expect(DayRibbon.duration(780) == "13m")
        #expect(DayRibbon.duration(3_600) == "1h")
        #expect(DayRibbon.duration(9_180) == "2h 33m")
    }

    @Test func readsAnEmptyWindowAsNothingAtAll() {
        let now = at(12, 0)
        let ribbon = DayRibbon.build([session(project: "robota")],
                                     spans: { _ in [] }, range: .day, now: now)

        #expect(ribbon.isEmpty)
        #expect(ribbon.spent == 0)
        #expect(ribbon.bands.count == 1)
    }
}
