import Foundation

// What Stats keeps about one session: when it worked, when it was prompted, what its
// calls were and what it cost. Never a word of what was written. A digest is small enough
// to keep after the session itself is gone, which is what lets a person keep the stats of
// the sessions they clean up when they ask for that.

// Who a session's time belongs to: the workspace it ran in, or else its project. Named at
// the time the digest was made, so a digest that outlives its project still has a name.
struct StatsSubject: Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var isWorkspace: Bool
}

struct StatsDigest: Codable, Equatable, Sendable {
    struct Span: Codable, Equatable, Sendable {
        var start: Date
        var end: Date

        var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }

        func clipped(to window: DateInterval) -> Span? {
            let start = max(start, window.start)
            let end = min(end, window.end)
            guard end > start else { return nil }
            return Span(start: start, end: end)
        }
    }

    struct Prompt: Codable, Equatable, Sendable {
        var date: Date
        var dictated = false
        // Sent into a turn already running rather than starting one.
        var steered = false
        // How long the person took to answer the turn before it, when the answer came
        // soon enough to have been a reply rather than a return to the work later.
        var replySeconds: TimeInterval?
    }

    // One of the agent's turns: when it opened and how long it worked.
    struct Turn: Codable, Equatable, Sendable {
        var start: Date
        var seconds: TimeInterval
    }

    // The calls and changes of one calendar day. Kept by day rather than one by one: a
    // long session makes thousands of calls, and no stat asks for them at a finer grain.
    struct Day: Codable, Equatable, Sendable {
        var day: Date
        var tools: [String: Int] = [:]
        var failedCalls = 0
        var added = 0
        var removed = 0
    }

    // What the session record says about itself, as opposed to what its turns say.
    struct Header: Codable, Equatable, Sendable {
        var id: UUID
        var title: String
        var subject: StatsSubject
        var agent: AgentKind
        var mode: SessionMode
        var createdAt: Date
        var usage: SessionUsage?
        var pullRequests = 0
        var usesWorktree = false
    }

    var header: Header
    var spans: [Span] = []
    var turns: [Turn] = []
    var prompts: [Prompt] = []
    var days: [Day] = []

    var id: UUID { header.id }
    var subject: StatsSubject { header.subject }
    var activeSeconds: TimeInterval { spans.reduce(0) { $0 + $1.seconds } }

    // How much of the session's time fell inside the window, as a fraction. The cost and
    // tokens a session reports are totals with no date, so they are spread over the days
    // by the time the agent worked on each. A session that never worked is placed on the
    // day it was made.
    func share(of window: DateInterval) -> Double {
        let total = activeSeconds
        guard total > 0 else { return window.contains(header.createdAt) ? 1 : 0 }
        let inside = spans.compactMap { $0.clipped(to: window) }.reduce(0) { $0 + $1.seconds }
        return inside / total
    }
}

// A turn as Stats reads it off disk: TurnTimes plus the two marks a prompt carries.
struct StatsTurn: Decodable, Sendable {
    var role: MessageRole
    var date: Date
    var dictated: Bool?
    var steered: Bool?
    var tools: [TurnTimes.Call]?

    var times: TurnTimes { TurnTimes(role: role, date: date, tools: tools) }

    static func of(_ messages: [ChatMessage]) -> [StatsTurn] {
        zip(messages, SessionTime.turns(of: messages)).map { message, times in
            StatsTurn(role: message.role, date: message.date, dictated: message.dictated,
                      steered: message.steered, tools: times.tools)
        }
    }
}

enum StatsDigestBuilder {
    // A prompt sent longer than this after the turn it follows is a return to the work,
    // not a reply to it, so it says nothing about how long the person took to answer.
    static let replyCap: TimeInterval = 30 * 60

    static func digest(_ header: StatsDigest.Header, turns: [StatsTurn], projectPath: String,
                       calendar: Calendar = .current) -> StatsDigest {
        var digest = StatsDigest(header: header)
        let times = turns.map(\.times)
        digest.spans = SessionTime.spans(of: times).map { StatsDigest.Span(start: $0.start, end: $0.end) }

        var lastTurnEnd: Date?
        for turn in turns {
            switch turn.role {
            case .assistant:
                let spans = SessionTime.spans(of: [turn.times])
                let seconds = spans.reduce(0) { $0 + $1.seconds }
                digest.turns.append(StatsDigest.Turn(start: turn.date, seconds: seconds))
                if let end = spans.map(\.end).max() {
                    lastTurnEnd = max(lastTurnEnd ?? end, end)
                }
            case .user:
                let steered = turn.steered == true
                var reply: TimeInterval?
                if !steered, let lastTurnEnd {
                    let gap = turn.date.timeIntervalSince(lastTurnEnd)
                    if gap >= 0, gap <= replyCap { reply = gap }
                }
                digest.prompts.append(StatsDigest.Prompt(date: turn.date,
                                                         dictated: turn.dictated == true,
                                                         steered: steered,
                                                         replySeconds: reply))
            case .system, .instructions:
                break
            }
        }

        var days: [Date: StatsDigest.Day] = [:]
        func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
        for turn in times {
            for call in turn.tools ?? [] {
                guard let name = call.name, !name.isEmpty,
                      let date = call.finishedAt ?? call.startedAt else { continue }
                let key = day(date)
                days[key, default: StatsDigest.Day(day: key)].tools[name, default: 0] += 1
                if call.isError == true { days[key, default: StatsDigest.Day(day: key)].failedCalls += 1 }
            }
        }
        for change in SessionTime.changes(of: times, projectPath: projectPath) {
            let key = day(change.date)
            days[key, default: StatsDigest.Day(day: key)].added += change.added
            days[key, default: StatsDigest.Day(day: key)].removed += change.removed
        }
        digest.days = days.values.sorted { $0.day < $1.day }
        return digest
    }
}

// Something Stats saw happen that leaves no trace in a transcript. Only written while
// stats are on, and only ever a time, a length and a tool's name.
struct StatsEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        // The agent asked, and the person answered.
        case answered
        // A turn came to an end.
        case turnEnded
    }

    enum Outcome: String, Codable, Sendable { case finished, stopped, failed }

    var kind: Kind
    var sessionID: UUID
    var subjectID: UUID?
    // When the question was asked, or when the turn began.
    var date: Date
    var seconds: TimeInterval
    var tool: String?
    var isQuestion: Bool?
    var allowed: Bool?
    var outcome: Outcome?

    var end: Date { date.addingTimeInterval(seconds) }
}
