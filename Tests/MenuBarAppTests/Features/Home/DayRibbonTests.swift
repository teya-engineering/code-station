import Foundation
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

// Where the day went: how a conversation is read back as stretches of work and as the
// changes it wrote, and how those stretches land on the band Home draws.
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

    // MARK: - What a turn wrote

    private func call(_ name: String, input: String, finished: Date?,
                      isError: Bool = false,
                      written: WrittenChange? = nil) -> TurnTimes.Call {
        TurnTimes.Call(name: name, input: input, isError: isError, written: written,
                       startedAt: finished, finishedAt: finished)
    }

    // A day is asked what was written in it, so a change is dated by the call that made
    // it rather than by the last time its session stirred.
    @Test func datesEachChangeByTheCallThatMadeIt() {
        let changes = SessionTime.changes(of: [
            TurnTimes(role: .assistant, date: at(9, 0), tools: [
                call("Edit", input: #"{"file_path":"/repo/a.swift","old_string":"one\ntwo","new_string":"one\ntwo\nthree"}"#,
                     finished: at(9, 5)),
                call("Write", input: #"{"file_path":"/repo/b.swift","content":"a\nb"}"#,
                     finished: at(9, 6))
            ])
        ], projectPath: "/repo")

        #expect(changes.map(\.date) == [at(9, 5), at(9, 6)])
        #expect(changes.map(\.added) == [1, 2])
        #expect(changes.allSatisfy { $0.removed == 0 })
    }

    // The input of a call still running describes a change that has not landed yet.
    @Test func leavesOutACallThatHasNotReportedIn() {
        let changes = SessionTime.changes(of: [
            TurnTimes(role: .assistant, date: at(9, 0), tools: [
                call("Write", input: #"{"file_path":"/repo/b.swift","content":"a\nb"}"#,
                     finished: nil)
            ])
        ], projectPath: "/repo")

        #expect(changes.isEmpty)
    }

    @Test func leavesOutACallThatFailed() {
        let changes = SessionTime.changes(of: [
            TurnTimes(role: .assistant, date: at(9, 0), tools: [
                call("Write", input: #"{"file_path":"/repo/b.swift","content":"a\nb"}"#,
                     finished: at(9, 2), isError: true)
            ])
        ], projectPath: "/repo")

        #expect(changes.isEmpty)
    }

    // A command says nothing about what it changed, so what counts is the change
    // measured off the working tree afterwards.
    @Test func countsAChangeMeasuredOffTheTree() {
        let changes = SessionTime.changes(of: [
            TurnTimes(role: .assistant, date: at(9, 0), tools: [
                call("Bash", input: #"{"command":"make fmt"}"#, finished: at(9, 8),
                     written: WrittenChange(files: 2, added: 30, removed: 4))
            ])
        ], projectPath: "/repo")

        #expect(changes.count == 1)
        #expect(changes.first?.added == 30)
        #expect(changes.first?.removed == 4)
    }

    @Test func ignoresCallsThatWroteNothing() {
        let changes = SessionTime.changes(of: [
            TurnTimes(role: .assistant, date: at(9, 0), tools: [
                call("Read", input: #"{"file_path":"/repo/a.swift"}"#, finished: at(9, 1))
            ])
        ], projectPath: "/repo")

        #expect(changes.isEmpty)
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
                                     now: now)

        // Two of the three hours are older than the band, so only one is drawn.
        #expect(ribbon.blocks.count == 1)
        #expect(ribbon.spent == 3_600)
        let edge: Date = now.addingTimeInterval(-86_400)
        #expect(ribbon.blocks.first?.start == edge)
    }

    @Test func drawsARunningSessionOutToNow() {
        let now = at(12, 0)
        let work = session(project: "Code Station", open: true)
        let ribbon = DayRibbon.build([work],
                                     spans: { _ in [TimeSpan(start: at(11, 0), end: at(11, 5))] },
                                     now: now)

        #expect(ribbon.blocks.first?.end == now)
        #expect(ribbon.blocks.first?.isOpen == true)
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
                                     now: now)

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
                                     now: now)

        #expect(ribbon.blocks.count == 1)
        #expect(ribbon.spent == 3_600)
    }

    @Test func activityAddsParallelWorkAndPreservesGaps() {
        let first = session(project: "First")
        let second = session(project: "Second")
        let ribbon = DayRibbon.build([first, second], spans: { id in
            id == first.id
                ? [TimeSpan(start: at(9, 30), end: at(10, 30))]
                : [TimeSpan(start: at(9, 45), end: at(10, 15))]
        }, now: at(24))

        let activity = ribbon.activity(bucketCount: 24)
        #expect(activity.count == 24)
        #expect(activity[9].spent == 2_700)
        #expect(activity[10].spent == 2_700)
        #expect(activity[9].sessions.count == 2)
        #expect(activity[8].spent == 0)
        #expect(activity[11].sessions.isEmpty)
        #expect(activity.reduce(0) { $0 + $1.spent } == ribbon.spent)
        #expect(activity[9].projects.map(\.subject.name) == ["First", "Second"])
        #expect(activity[9].projects.map(\.spent) == [1_800, 900])
        #expect(activity[11].projects.isEmpty)
    }

    @Test func activityCountsEachSessionOncePerBucketAndClipsAtEdges() {
        let work = session(project: "First")
        let ribbon = DayRibbon.build([work], spans: { _ in
            [TimeSpan(start: at(-1), end: at(0, 10)),
             TimeSpan(start: at(0, 20), end: at(0, 30)),
             TimeSpan(start: at(23, 45), end: at(25))]
        }, now: at(24))

        let activity = ribbon.activity(bucketCount: 24)
        #expect(activity[0].spent == 1_200)
        #expect(activity[0].sessions.count == 1)
        #expect(activity[23].spent == 900)
        #expect(activity.last?.interval.end == ribbon.now)
        #expect(activity.reduce(0) { $0 + $1.spent } == ribbon.spent)
        #expect(ribbon.activity(bucketCount: 0).isEmpty)
    }

    // Two sessions of one project in the same bucket are one row on the hover card.
    @Test func activityPoolsSessionsOfOneProject() {
        let first = session(project: "Shared")
        let second = session(project: "Shared")
        let other = session(project: "Other")
        let ribbon = DayRibbon.build([first, second, other], spans: { id in
            id == other.id
                ? [TimeSpan(start: at(9, 0), end: at(9, 40))]
                : [TimeSpan(start: at(9, 0), end: at(9, 30))]
        }, now: at(24))

        let bucket = ribbon.activity(bucketCount: 24)[9]
        #expect(bucket.sessions.count == 3)
        #expect(bucket.projects.map(\.subject.name) == ["Shared", "Other"])
        #expect(bucket.projects.map(\.spent) == [3_600, 2_400])
    }

    @Test func activityIncludesRunningSessionsAndAnEmptyDay() {
        let work = session(project: "First", open: true)
        let ribbon = DayRibbon.build([work], spans: { _ in
            [TimeSpan(start: at(23, 30), end: at(23, 35))]
        }, now: at(24))
        #expect(ribbon.activity(bucketCount: 24)[23].spent == 1_800)

        let empty = DayRibbon.build([], spans: { _ in [] }, now: at(24)).activity()
        #expect(empty.count == 64)
        #expect(empty.allSatisfy { $0.spent == 0 && $0.sessions.isEmpty })
    }

    // The bigger project of the day stays at the bottom, even in a bar where the other
    // one filled more of the time.
    @Test func stacksEveryBarInTheDaysOrder() {
        let big = session(project: "Big")
        let small = session(project: "Small")
        let ribbon = DayRibbon.build([big, small], spans: { id in
            id == big.id
                ? [TimeSpan(start: at(8, 0), end: at(8, 45)), TimeSpan(start: at(10, 0), end: at(10, 15))]
                : [TimeSpan(start: at(10, 0), end: at(10, 45))]
        }, now: at(24))

        let bucket = ribbon.activity(bucketCount: 24)[10]
        #expect(bucket.projects.map(\.subject.name) == ["Small", "Big"])

        let segments = bucket.segments(height: 60, rank: ribbon.rank)
        #expect(segments.map(\.subject.name) == ["Big", "Small"])
        #expect(segments.map(\.height) == [14.75, 44.25])
        let drawn = segments.reduce(0) { $0 + $1.height } + DayRibbon.Activity.segmentGap
        #expect(drawn == 60)
    }

    @Test func leavesASliverOutOfTheBarButKeepsItsHeight() {
        let big = session(project: "Big")
        let tiny = session(project: "Tiny")
        let ribbon = DayRibbon.build([big, tiny], spans: { id in
            id == big.id
                ? [TimeSpan(start: at(10, 0), end: at(11, 0))]
                : [TimeSpan(start: at(10, 0), end: at(10, 1))]
        }, now: at(24))

        let bucket = ribbon.activity(bucketCount: 24)[10]
        let segments = bucket.segments(height: 30, rank: ribbon.rank)
        #expect(segments.map(\.subject.name) == ["Big"])
        #expect(segments.first?.height == 30)
        #expect(bucket.projects.count == 2)
        #expect(ribbon.activity(bucketCount: 24)[11].segments(height: 30, rank: ribbon.rank).isEmpty)
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
                                     spans: { _ in [] }, now: now)

        #expect(ribbon.isEmpty)
        #expect(ribbon.spent == 0)
        #expect(ribbon.blocks.isEmpty)
    }
}
