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

// Only what a stored turn says about when it worked and what it wrote. A transcript
// holds every message, call, result and patch a session ever produced, and rebuilding
// all of that to answer those two questions would cost more than the answers are worth.
//
// Every field is optional, since a conversation written before the app kept it is still
// read back.
struct TurnTimes: Decodable, Sendable {
    struct Call: Decodable, Sendable {
        var name: String?
        var input: String?
        var isError: Bool?
        // What the call left behind on disk when its input did not describe the change.
        var written: WrittenChange?
        var startedAt: Date?
        var finishedAt: Date?
    }

    var role: MessageRole
    var date: Date
    var tools: [Call]?
}

// One change a session made, at the moment the call that made it reported in. Dated so
// a day can be asked what was written in it, rather than what every session that ran in
// it has written since it began.
struct DatedChange: Equatable, Sendable {
    var date: Date
    var added: Int
    var removed: Int
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

    // Every change the turns made, dated by the call that made it. A call is dated by
    // the moment it reported in: one still running has no time to file a change under,
    // and its input describes a change that has not landed yet.
    //
    // The counts are read the way the rest of the app reads them, so a number on Home
    // and the number on the call's own row cannot disagree. The reading is not put
    // through ToolPresentationCache, whose budget is there to hold the calls being
    // drawn, not every call of every session a scan happens to pass over.
    static func changes(of turns: [TurnTimes], projectPath: String) -> [DatedChange] {
        var changes: [DatedChange] = []
        for turn in turns {
            for call in turn.tools ?? [] where call.isError != true {
                guard let finishedAt = call.finishedAt else { continue }
                let tool = ToolUse(id: "", name: call.name ?? "", input: call.input ?? "",
                                   result: "", written: call.written)
                let reading = ToolPresentation(tool: tool, projectPath: projectPath)
                let added = reading.added ?? 0
                let removed = reading.removed ?? 0
                guard added > 0 || removed > 0 else { continue }
                changes.append(DatedChange(date: finishedAt, added: added, removed: removed))
            }
        }
        return changes
    }

    // A conversation held in memory, read as the slim shape a stored one is read as. It
    // makes no difference to anything downstream which of the two a reading came from.
    static func turns(of messages: [ChatMessage]) -> [TurnTimes] {
        messages.map { message in
            TurnTimes(role: message.role, date: message.date,
                      tools: message.tools.map {
                          TurnTimes.Call(name: $0.name, input: $0.input, isError: $0.isError,
                                         written: $0.written, startedAt: $0.startedAt,
                                         finishedAt: $0.finishedAt)
                      })
        }
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
