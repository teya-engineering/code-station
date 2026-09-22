import SwiftUI

// How far back the ribbon reads. Two ranges only: the day you are in, and the week
// behind it. Anything longer stops being a record of work and becomes a trend line,
// which is not what this section is for.
enum RibbonRange: String, CaseIterable, Identifiable {
    case day, week

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "24H"
        case .week: "7D"
        }
    }

    var emptyLine: String {
        switch self {
        case .day: "No sessions ran in the last 24 hours"
        case .week: "No sessions ran in the last 7 days"
        }
    }
}

// Who a block on the ribbon belongs to, named and coloured exactly the way the sidebar
// names and colours it, so the same colour means the same thing on every screen.
struct RibbonSubject: Identifiable {
    let name: String
    let tint: Theme.ProjectTint

    var id: String { name }
}

// One session the ribbon may have something to draw for, with everything a block needs
// already looked up so a block never reaches back into the store while it draws.
struct RibbonSession: Identifiable {
    let id: UUID
    let title: String
    let subject: RibbonSubject
    // The conversations whose turns count as this session's time. A session working
    // through a Design has a second, hidden conversation, and what happens there is
    // still this session's work.
    let sources: [UUID]
    // A turn in flight has not reported its end yet, so its block is drawn open, out to
    // the now edge. Only set for a session whose conversation is in memory, since a
    // reading off disk can be a whole turn behind.
    let isOpen: Bool
}

// Everything the section draws, worked out once per redraw and handed down.
struct DayRibbon {
    struct Block: Identifiable {
        struct Key: Hashable {
            let session: UUID
            let start: Date
        }

        let sessionID: UUID
        let title: String
        let subject: RibbonSubject
        let start: Date
        let end: Date
        let isOpen: Bool

        var id: Key { Key(session: sessionID, start: start) }
        var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
    }

    // One track: the whole 24 hours in day mode, one calendar day in week mode. The
    // axis is the stretch the track maps, which for today runs past `now` so the day
    // keeps the same scale as the six behind it.
    struct Band: Identifiable {
        let axis: DateInterval
        let blocks: [Block]
        let spent: TimeInterval
        let isToday: Bool

        var id: Date { axis.start }
    }

    struct Total: Identifiable {
        let subject: RibbonSubject
        let spent: TimeInterval

        var id: String { subject.id }
    }

    let range: RibbonRange
    let bands: [Band]
    let legend: [Total]
    let spent: TimeInterval
    let now: Date

    var isEmpty: Bool { legend.isEmpty }

    // The stretch each range covers, oldest first. The day is a rolling 24 hours so the
    // morning is still on the band in the evening; the week is seven calendar days, so
    // a row means the same thing as the date beside it.
    static func bandWindows(for range: RibbonRange, now: Date,
                            calendar: Calendar = .current) -> [DateInterval] {
        switch range {
        case .day:
            return [DateInterval(start: now.addingTimeInterval(-86_400), end: now)]
        case .week:
            let today = calendar.startOfDay(for: now)
            return (0..<7).reversed().compactMap { back in
                guard let start = calendar.date(byAdding: .day, value: -back, to: today),
                      let end = calendar.date(byAdding: .day, value: 1, to: start)
                else { return nil }
                return DateInterval(start: start, end: end)
            }
        }
    }

    static func build(_ sessions: [RibbonSession],
                      spans: (UUID) -> [TimeSpan],
                      range: RibbonRange,
                      now: Date,
                      calendar: Calendar = .current) -> DayRibbon {
        let windows = bandWindows(for: range, now: now, calendar: calendar)
        guard let first = windows.first else {
            return DayRibbon(range: range, bands: [], legend: [], spent: 0, now: now)
        }
        // Nothing past this moment is work that has happened, so today's band stops
        // here even though its track runs to midnight.
        let covered = DateInterval(start: first.start, end: max(first.start, now))

        var recorded: [(session: RibbonSession, span: TimeSpan, isOpen: Bool)] = []
        for session in sessions {
            var merged = SessionTime.merged(session.sources.flatMap(spans))
            if session.isOpen, let last = merged.indices.last, merged[last].end < now {
                merged[last].end = now
            }
            for (index, span) in merged.enumerated() {
                guard let clipped = span.clipped(to: covered) else { continue }
                recorded.append((session, clipped,
                                 session.isOpen && index == merged.count - 1))
            }
        }

        var bands: [Band] = []
        for window in windows {
            var blocks: [Block] = []
            var spent: TimeInterval = 0
            for entry in recorded {
                guard let clipped = entry.span.clipped(to: window) else { continue }
                spent += clipped.seconds
                blocks.append(Block(sessionID: entry.session.id,
                                    title: entry.session.title,
                                    subject: entry.session.subject,
                                    start: clipped.start,
                                    end: clipped.end,
                                    isOpen: entry.isOpen && clipped.end == entry.span.end))
            }
            bands.append(Band(axis: window,
                              blocks: blocks.sorted { $0.start < $1.start },
                              spent: spent,
                              isToday: window.contains(now) || window.end == now))
        }

        var totals: [String: (RibbonSubject, TimeInterval)] = [:]
        for entry in recorded {
            let name = entry.session.subject.name
            totals[name] = (entry.session.subject,
                            (totals[name]?.1 ?? 0) + entry.span.seconds)
        }
        var legend: [Total] = totals.values.map { Total(subject: $0.0, spent: $0.1) }
        legend.sort { first, second in
            first.spent == second.spent
                ? first.subject.name < second.subject.name
                : first.spent > second.spent
        }

        return DayRibbon(range: range, bands: bands, legend: legend,
                         spent: legend.reduce(0) { $0 + $1.spent }, now: now)
    }

    // "2h 33m", "13m", "1h". Seconds are left out: this is a day being read, not a run
    // being watched, and a turn worth noticing on the band lasted minutes.
    static func duration(_ seconds: TimeInterval) -> String {
        let rounded = Int((seconds / 60).rounded())
        let minutes = seconds > 0 ? max(1, rounded) : rounded
        guard minutes >= 60 else { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)m"
    }

    // A day with nothing in it reads as a dash rather than as "0m", which claims the
    // day was measured and found empty rather than never started.
    static func total(_ seconds: TimeInterval) -> String {
        seconds > 0 ? duration(seconds) : "-"
    }
}
