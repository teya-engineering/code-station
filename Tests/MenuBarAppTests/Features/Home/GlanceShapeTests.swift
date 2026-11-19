import Foundation
import Testing
@testable import MenuBarApp

// How Home's glance turns a Stats report into bars: the rolling day merged down to the
// bars the width takes, the lens deciding what each bar measures, and one stacking order
// for the whole stretch.
@MainActor
struct GlanceShapeTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    // Monday 22 September 2025, midnight UTC.
    private let monday = Date(timeIntervalSince1970: 1_758_499_200)
    private let big = StatsSubject(id: UUID(), name: "big", isWorkspace: false)
    private let small = StatsSubject(id: UUID(), name: "small", isWorkspace: false)

    private func at(day: Int = 0, _ hour: Double, _ minute: Double = 0) -> Date {
        monday.addingTimeInterval(Double(day) * 86_400 + hour * 3_600 + minute * 60)
    }

    private func digest(_ subject: StatsSubject, spans: [(Date, Date)], prompts: [Date] = []) -> StatsDigest {
        var digest = StatsDigest(header: StatsDigest.Header(
            id: UUID(), title: "A session", subject: subject, agent: .claudeCode, mode: .chat,
            createdAt: spans.first?.0 ?? monday, usage: nil))
        digest.spans = spans.map { StatsDigest.Span(start: $0.0, end: $0.1) }
        digest.prompts = prompts.map { StatsDigest.Prompt(date: $0) }
        return digest
    }

    private func tint(_ subject: StatsSubject) -> Theme.ProjectTint { Theme.projectTint(for: subject.name) }

    @Test func cutsTheDayIntoAFactorOfTheReportsSlots() {
        #expect(GlanceShape.dayBars(width: 1_000) == 64)
        #expect(GlanceShape.dayBars(width: 300) == 32)
        #expect(GlanceShape.dayBars(width: 120) == 16)
        #expect(GlanceShape.dayBars(width: 0) == 16)
    }

    // Merging slots keeps every minute and every prompt, and the bars still span the day.
    @Test func mergesTheRollingDayIntoFewerBarsWithoutLosingAnything() {
        let digests = [
            digest(big, spans: [(at(day: 1, 9), at(day: 1, 11))], prompts: [at(day: 1, 9), at(day: 1, 10)]),
            digest(small, spans: [(at(day: 1, 9, 30), at(day: 1, 10))], prompts: [at(day: 1, 9, 45)])
        ]
        let report = StatsReport.build(digests: digests, events: [], range: .today,
                                       now: at(day: 1, 18), calendar: calendar)
        let time = GlanceShape.report(report, stretch: .today, lens: .time, dayBars: 16, tint: tint)
        let prompts = GlanceShape.report(report, stretch: .today, lens: .prompts, dayBars: 16, tint: tint)

        #expect(time.bars.count == 16)
        #expect(time.domain == report.interval)
        #expect(time.bars.reduce(0) { $0 + $1.total } == 9_000)
        #expect(prompts.bars.reduce(0) { $0 + $1.total } == 3)
        #expect(!time.wide)
    }

    // Every bar stacks in the stretch's order, biggest first, so a project keeps its
    // level from bar to bar even where it was the smaller one.
    @Test func ranksTheStretchByTheLensBeingLookedAt() {
        let digests = [
            digest(big, spans: [(at(day: 0, 9), at(day: 0, 12))], prompts: [at(day: 0, 9)]),
            digest(small, spans: [(at(day: 1, 9), at(day: 1, 10))],
                   prompts: [at(day: 1, 9), at(day: 1, 9, 10), at(day: 1, 9, 20)])
        ]
        let report = StatsReport.build(digests: digests, events: [], range: .week,
                                       now: at(day: 1, 18), calendar: calendar)
        let time = GlanceShape.report(report, stretch: .week, lens: .time, dayBars: 64, tint: tint)
        let prompts = GlanceShape.report(report, stretch: .week, lens: .prompts, dayBars: 64, tint: tint)

        #expect(time.wide)
        #expect(time.bars.count == 7)
        #expect(time.rank == ["big": 0, "small": 1])
        #expect(prompts.rank == ["small": 0, "big": 1])
        #expect(time.peak == 10_800)
        #expect(abs(time.average - 14_400 / 7) < 0.001)
        #expect(time.bars.first { $0.total > 0 }?.pieces.first?.subject.subjectID == big.id)
    }

    @Test func zoomingInGoesOneStepShorter() {
        #expect(StatsRange.all.zoomedIn == .month)
        #expect(StatsRange.month.zoomedIn == .week)
        #expect(StatsRange.week.zoomedIn == .today)
    }

    // Two stretches placed on one axis: today lands at the right end of the week.
    @Test func placesAStretchOnAnotherStretchsAxis() {
        let week = DateInterval(start: at(day: -6, 0), end: at(day: 1, 0))
        let today = DateInterval(start: at(day: 0, 0), end: at(day: 1, 0))
        let place = ChartMotion.place(today, in: week, width: 700)
        #expect(place.x == 600)
        #expect(place.width == 100)
    }
}
