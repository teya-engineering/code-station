import Foundation

// One stretch of time a session can be proved to have been worked on: a single turn,
// from the moment the reply was opened to the last thing inside it that reported in.
// Time is read this way rather than from a session's first message to its last, so a
// session left open overnight does not count as twelve hours of work.
struct TimeSpan: Equatable, Sendable {
    var start: Date
    var end: Date

    var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }

    func clipped(to window: DateInterval) -> TimeSpan? {
        let start = Swift.max(start, window.start)
        let end = Swift.min(end, window.end)
        guard end > start else { return nil }
        return TimeSpan(start: start, end: end)
    }
}

// Only the times out of a stored turn. A transcript holds every message, call, result
// and patch a session ever produced, and rebuilding all of that to find out when the
// agent was busy would cost more than the answer is worth.
struct TurnTimes: Decodable, Sendable {
    struct Call: Decodable, Sendable {
        var startedAt: Date?
        var finishedAt: Date?
    }

    var role: MessageRole
    var date: Date
    var tools: [Call]?
}

enum SessionTime {
    // A turn that only wrote text leaves no call to time it by, and crediting it with
    // nothing would drop it out of the day altogether.
    static let quietTurn: TimeInterval = 30

    // The turns of one conversation as spans, oldest first. Only the agent's turns
    // count: a prompt is a moment rather than a stretch of work.
    static func spans(of turns: [TurnTimes]) -> [TimeSpan] {
        var spans: [TimeSpan] = []
        for turn in turns where turn.role == .assistant {
            var start = turn.date
            var end = turn.date
            for call in turn.tools ?? [] {
                if let began = call.startedAt { start = min(start, began) }
                // A call still running has only a start, and that is still evidence the
                // turn was working at least up to then.
                if let last = call.finishedAt ?? call.startedAt { end = max(end, last) }
            }
            if end <= start { end = start.addingTimeInterval(quietTurn) }
            spans.append(TimeSpan(start: start, end: end))
        }
        return merged(spans)
    }

    static func spans(of messages: [ChatMessage]) -> [TimeSpan] {
        spans(of: messages.map { message in
            TurnTimes(role: message.role, date: message.date,
                      tools: message.tools.map {
                          TurnTimes.Call(startedAt: $0.startedAt, finishedAt: $0.finishedAt)
                      })
        })
    }

    // The union of the spans. Two turns that overlap are one stretch of work, and the
    // gaps between the rest are half of what the ribbon has to say.
    static func merged(_ spans: [TimeSpan]) -> [TimeSpan] {
        var result: [TimeSpan] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, span.start <= last.end {
                result[result.count - 1].end = max(last.end, span.end)
            } else {
                result.append(span)
            }
        }
        return result
    }
}
