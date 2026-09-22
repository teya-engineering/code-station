import SwiftUI

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

    struct Total: Identifiable {
        let subject: RibbonSubject
        let spent: TimeInterval

        var id: String { subject.id }
    }

    // The stretch the band maps. It is a rolling day rather than a calendar one, so the
    // morning is still on the band in the evening.
    let axis: DateInterval
    let blocks: [Block]
    let legend: [Total]
    let spent: TimeInterval
    let now: Date

    var isEmpty: Bool { legend.isEmpty }

    static let window: TimeInterval = 24 * 3_600

    static func axis(endingAt now: Date) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-window), end: now)
    }

    static func build(_ sessions: [RibbonSession],
                      spans: (UUID) -> [TimeSpan],
                      now: Date) -> DayRibbon {
        let axis = axis(endingAt: now)

        var blocks: [Block] = []
        var totals: [String: (RibbonSubject, TimeInterval)] = [:]
        for session in sessions {
            var merged = SessionTime.merged(session.sources.flatMap(spans))
            if session.isOpen, let last = merged.indices.last, merged[last].end < now {
                merged[last].end = now
            }
            for (index, span) in merged.enumerated() {
                guard let clipped = span.clipped(to: axis) else { continue }
                blocks.append(Block(sessionID: session.id,
                                    title: session.title,
                                    subject: session.subject,
                                    start: clipped.start,
                                    end: clipped.end,
                                    isOpen: session.isOpen
                                        && index == merged.count - 1
                                        && clipped.end == span.end))
                let name = session.subject.name
                totals[name] = (session.subject, (totals[name]?.1 ?? 0) + clipped.seconds)
            }
        }

        var legend: [Total] = totals.values.map { Total(subject: $0.0, spent: $0.1) }
        legend.sort { first, second in
            first.spent == second.spent
                ? first.subject.name < second.subject.name
                : first.spent > second.spent
        }

        return DayRibbon(axis: axis,
                         blocks: blocks.sorted { $0.start < $1.start },
                         legend: legend,
                         spent: legend.reduce(0) { $0 + $1.spent },
                         now: now)
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
}
