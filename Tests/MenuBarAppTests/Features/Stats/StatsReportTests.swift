import Foundation
import Testing
@testable import MenuBarApp

// What Stats reads out of a conversation, how the report adds it up over a stretch of
// days, and that nothing is written down until the person turns Stats on.
@MainActor
struct StatsReportTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    // Monday 22 September 2025, midnight UTC.
    private let monday = Date(timeIntervalSince1970: 1_758_499_200)

    private func at(day: Int = 0, _ hour: Double, _ minute: Double = 0) -> Date {
        monday.addingTimeInterval(Double(day) * 86_400 + hour * 3_600 + minute * 60)
    }

    private let project = StatsSubject(id: UUID(), name: "code-station", isWorkspace: false)
    private let other = StatsSubject(id: UUID(), name: "payments", isWorkspace: true)

    private func header(_ subject: StatsSubject, created: Date, cost: Double = 0) -> StatsDigest.Header {
        var usage = SessionUsage()
        usage.costUSD = cost
        return StatsDigest.Header(id: UUID(), title: "A session", subject: subject,
                                  agent: .claudeCode, mode: .chat, createdAt: created,
                                  usage: usage)
    }

    private func digest(_ subject: StatsSubject, spans: [(Date, Date)], prompts: [Date] = [],
                        cost: Double = 0) -> StatsDigest {
        var digest = StatsDigest(header: header(subject, created: spans.first?.0 ?? prompts.first ?? monday,
                                                cost: cost))
        digest.spans = spans.map { StatsDigest.Span(start: $0.0, end: $0.1) }
        digest.prompts = prompts.map { StatsDigest.Prompt(date: $0) }
        return digest
    }

    // MARK: - Reading a conversation

    @Test func readsAReplyOnlyWhenItCameSoonAfterTheTurn() {
        let turns = [
            StatsTurn(role: .user, date: at(9, 0)),
            StatsTurn(role: .assistant, date: at(9, 1),
                      tools: [TurnTimes.Call(name: "Bash", startedAt: at(9, 2), finishedAt: at(9, 10))]),
            // Two minutes after the turn ended: a reply.
            StatsTurn(role: .user, date: at(9, 12), dictated: true),
            StatsTurn(role: .assistant, date: at(9, 13),
                      tools: [TurnTimes.Call(name: "Edit", isError: true, startedAt: at(9, 13), finishedAt: at(9, 20))]),
            // Sent into the running turn, so it answers nothing.
            StatsTurn(role: .user, date: at(9, 15), steered: true),
            // Three hours later: a return to the work rather than a reply.
            StatsTurn(role: .user, date: at(12, 30))
        ]
        let digest = StatsDigestBuilder.digest(header(project, created: at(9, 0)), turns: turns,
                                               projectPath: "/tmp", calendar: calendar)

        #expect(digest.prompts.count == 4)
        #expect(digest.prompts.map(\.replySeconds) == [nil, 120, nil, nil])
        #expect(digest.prompts.map(\.dictated) == [false, true, false, false])
        #expect(digest.prompts.map(\.steered) == [false, false, true, false])
        #expect(digest.turns.map(\.seconds) == [540, 420])
        #expect(digest.days.count == 1)
        #expect(digest.days.first?.tools == ["Bash": 1, "Edit": 1])
        #expect(digest.days.first?.failedCalls == 1)
    }

    // MARK: - Adding up a stretch

    @Test func countsOnlyWhatFellInsideTheRangeAndComparesItWithTheStretchBefore() {
        let digests = [
            // Today: an hour. Yesterday: half an hour, so today is double.
            digest(project, spans: [(at(day: 1, 9), at(day: 1, 10))], prompts: [at(day: 1, 9), at(day: 1, 9, 30)]),
            digest(project, spans: [(at(day: 0, 9), at(day: 0, 9, 30))], prompts: [at(day: 0, 9)])
        ]
        let report = StatsReport.build(digests: digests, events: [], range: .today,
                                       now: at(day: 1, 18), calendar: calendar)

        #expect(report.agentTime.value == 3_600)
        #expect(report.agentTime.previous == 1_800)
        #expect(report.agentTime.change == 1)
        #expect(report.prompts.value == 2)
        #expect(report.grain == .hour)
        #expect(report.buckets.count == 24)
        #expect(report.buckets[9].seconds == 3_600)
    }

    // A session reports its cost as one total, so the total is spread over the days by
    // how long it worked on each.
    @Test func spreadsASessionsCostOverTheDaysItWorked() {
        let session = digest(project, spans: [(at(day: 0, 9), at(day: 0, 12)), (at(day: 1, 9), at(day: 1, 10))],
                             cost: 8)
        let today = StatsReport.build(digests: [session], events: [], range: .today,
                                      now: at(day: 1, 18), calendar: calendar)
        let week = StatsReport.build(digests: [session], events: [], range: .week,
                                     now: at(day: 1, 18), calendar: calendar)

        #expect(today.cost.value == 2)
        #expect(today.cost.previous == 6)
        #expect(week.cost.value == 8)
    }

    @Test func filtersToOneProjectOrWorkspace() {
        let digests = [
            digest(project, spans: [(at(9), at(10))]),
            digest(other, spans: [(at(9), at(11))])
        ]
        let all = StatsReport.build(digests: digests, events: [], range: .week,
                                    now: at(18), calendar: calendar)
        let one = StatsReport.build(digests: digests, events: [], range: .week,
                                    subject: project.id, now: at(18), calendar: calendar)

        #expect(all.agentTime.value == 10_800)
        #expect(all.subjects.map(\.subject) == [other, project])
        #expect(one.agentTime.value == 3_600)
        #expect(one.subjects.map(\.subject) == [project])
    }

    // Two sessions working the same hour is two hours of agent work in one of the
    // person's, and the busiest moment had both going.
    @Test func measuresHowManySessionsWorkedAtOnce() {
        let digests = [
            digest(project, spans: [(at(9), at(11))]),
            digest(other, spans: [(at(10), at(11))])
        ]
        let report = StatsReport.build(digests: digests, events: [], range: .today,
                                       now: at(18), calendar: calendar)

        #expect(report.peakAtOnce == 2)
        #expect(report.averageAtOnce == 1.5)
    }

    @Test func touchingTurnsAreOneAfterTheOtherNotTwoAtOnce() {
        let overlap = StatsReport.overlap([StatsDigest.Span(start: at(9), end: at(10)),
                                           StatsDigest.Span(start: at(10), end: at(11))])
        #expect(overlap.peak == 1)
        #expect(overlap.average == 1)
    }

    @Test func countsTheWaitsAndTheAnswers() {
        let session = UUID()
        func asked(_ tool: String, at date: Date, waited: TimeInterval, allowed: Bool) -> StatsEvent {
            StatsEvent(kind: .answered, sessionID: session, subjectID: project.id, date: date,
                       seconds: waited, tool: tool, isQuestion: false, allowed: allowed)
        }
        var events = (0..<5).map { asked("Bash", at: at(9, Double($0)), waited: 30, allowed: true) }
        events.append(asked("Write", at: at(10), waited: 600, allowed: false))
        events.append(StatsEvent(kind: .answered, sessionID: session, subjectID: project.id,
                                 date: at(11), seconds: 60, isQuestion: true))
        events.append(StatsEvent(kind: .turnEnded, sessionID: session, subjectID: project.id,
                                 date: at(12), seconds: 100, outcome: .stopped))
        let report = StatsReport.build(digests: [digest(project, spans: [(at(9), at(12))])],
                                       events: events, range: .today, now: at(18), calendar: calendar)

        #expect(report.waiting.value == 5 * 30 + 600 + 60)
        #expect(report.permissions == 6)
        #expect(report.allowed == 5)
        #expect(report.questions == 1)
        #expect(report.longestWait == 600)
        #expect(report.stopped == 1)
        #expect(report.alwaysAllowed.map(\.name) == ["Bash"])
    }

    @Test func doesNotCompareWaitsWithAStretchBeforeTheyWereCounted() {
        let event = StatsEvent(kind: .answered, sessionID: UUID(), subjectID: nil, date: at(day: 1, 9),
                               seconds: 60, tool: "Bash", isQuestion: false, allowed: true)
        let counted = StatsReport.build(digests: [], events: [event], range: .today,
                                        waitsSince: at(day: 1, 8), now: at(day: 1, 18), calendar: calendar)
        let earlier = StatsReport.build(digests: [], events: [event], range: .today,
                                        waitsSince: at(day: -3, 8), now: at(day: 1, 18), calendar: calendar)
        #expect(counted.waiting.previous == nil)
        #expect(earlier.waiting.previous == 0)
    }

    @Test func aToolRefusedOnceIsNotOfferedAsARule() {
        let session = UUID()
        let events = (0..<6).map { index in
            StatsEvent(kind: .answered, sessionID: session, subjectID: nil, date: at(9, Double(index)),
                       seconds: 5, tool: "Bash", isQuestion: false, allowed: index != 3)
        }
        let report = StatsReport.build(digests: [], events: events, range: .today,
                                       now: at(18), calendar: calendar)
        #expect(report.alwaysAllowed.isEmpty)
    }

    @Test func placesPromptsOnAWeekThatStartsOnMonday() {
        let report = StatsReport.build(digests: [digest(project, spans: [], prompts: [at(day: 0, 14, 5), at(day: 6, 8)])],
                                       events: [], range: .week, now: at(day: 6, 18), calendar: calendar)
        #expect(report.heat[0][14] == 1)
        #expect(report.heat[6][8] == 1)
    }

    // A streak that reached yesterday still stands before today's first prompt.
    @Test func countsTheStreakBackFromToday() {
        let prompts = [at(day: 0, 9), at(day: 1, 9), at(day: 2, 9), at(day: 4, 9)]
        let session = digest(project, spans: [], prompts: prompts)
        #expect(StatsReport.streak([session], now: at(day: 4, 18), calendar: calendar) == 1)
        #expect(StatsReport.streak([session], now: at(day: 3, 8), calendar: calendar) == 3)
        #expect(StatsReport.streak([session], now: at(day: 6, 8), calendar: calendar) == 0)
    }

    // MARK: - Asking first

    @Test func recordsNothingAndWritesNothingUntilTurnedOn() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("stats-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("stats.json")
        var enabled = false
        let stats = StatsStore(fileURL: file, transcripts: folder)
        stats.isEnabled = { enabled }

        let ending = TurnEnding(started: at(9), ended: at(9, 5), outcome: .finished)
        stats.recordTurn(ending, sessionID: UUID(), subjectID: nil)
        stats.flush()
        #expect(stats.archive.events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        enabled = true
        stats.turnOn(at: at(8))
        stats.recordTurn(ending, sessionID: UUID(), subjectID: nil)
        stats.flush()
        #expect(stats.archive.events.count == 1)
        #expect(stats.archive.enabledAt == at(8))
        #expect(FileManager.default.fileExists(atPath: file.path))

        // Turning off takes the file with it.
        enabled = false
        stats.erase()
        #expect(stats.archive == StatsStore.Archive())
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
