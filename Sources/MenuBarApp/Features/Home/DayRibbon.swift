import SwiftUI
import CodeStationCore

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
                         blocks: blocks.sorted {
                             $0.start == $1.start
                                 ? $0.sessionID.uuidString < $1.sessionID.uuidString
                                 : $0.start < $1.start
                         },
                         legend: legend,
                         spent: legend.reduce(0) { $0 + $1.spent },
                         now: now)
    }

    struct Activity: Identifiable {
        // One project's share of a bucket.
        struct Share: Identifiable {
            let subject: RibbonSubject
            let spent: TimeInterval

            var id: String { subject.id }
        }

        let interval: DateInterval
        let spent: TimeInterval
        let sessions: [Block]
        // Biggest first, so the projects that filled the bucket lead.
        let projects: [Share]

        var id: Date { interval.start }

        // One project's slice of a bar.
        struct Segment: Identifiable {
            let subject: RibbonSubject
            let height: CGFloat

            var id: String { subject.id }
        }

        static let segmentGap: CGFloat = 1
        static let minimumSegment: CGFloat = 1.5

        // The bar's projects bottom first, in the day's order rather than the bucket's
        // own, so a project sits at the same level in every bar it appears in. A slice
        // too thin to see is left out, and the rest share its room, so the bar still
        // stands as tall as its time.
        func segments(height: CGFloat, rank: [String: Int]) -> [Segment] {
            let ordered = projects.sorted {
                (rank[$0.subject.name] ?? .max) < (rank[$1.subject.name] ?? .max)
            }
            guard let first = ordered.first, spent > 0 else { return [] }
            let visible = ordered.filter { height * $0.spent / spent >= Self.minimumSegment }
            let shown = visible.isEmpty ? [first] : visible
            let room = height - Self.segmentGap * Double(shown.count - 1)
            let shownSpent = shown.reduce(0) { $0 + $1.spent }
            return shown.map {
                Segment(subject: $0.subject,
                        height: max(Self.minimumSegment, room * $0.spent / shownSpent))
            }
        }
    }

    // Biggest project of the day first. The legend sums the same clipped time the
    // buckets split up, so its order is the day-wide order every bar stacks in.
    var rank: [String: Int] {
        Dictionary(uniqueKeysWithValues: legend.enumerated().map { ($1.subject.name, $0) })
    }

    // Equal time buckets preserve gaps and add parallel sessions instead of letting
    // the last session drawn hide the work underneath it.
    func activity(bucketCount: Int = 64) -> [Activity] {
        guard bucketCount > 0, axis.duration > 0 else { return [] }
        let step = axis.duration / Double(bucketCount)
        return (0..<bucketCount).map { index in
            let start = axis.start.addingTimeInterval(Double(index) * step)
            let end = axis.start.addingTimeInterval(Double(index + 1) * step)
            var spent: TimeInterval = 0
            var sessions: [Block] = []
            var seen: Set<UUID> = []
            var shares: [String: (RibbonSubject, TimeInterval)] = [:]
            for block in blocks {
                let overlap = min(end, block.end).timeIntervalSince(max(start, block.start))
                guard overlap > 0 else { continue }
                spent += overlap
                if seen.insert(block.sessionID).inserted { sessions.append(block) }
                let name = block.subject.name
                shares[name] = (block.subject, (shares[name]?.1 ?? 0) + overlap)
            }
            var projects: [Activity.Share] = shares.values.map {
                Activity.Share(subject: $0.0, spent: $0.1)
            }
            projects.sort { (first: Activity.Share, second: Activity.Share) -> Bool in
                first.spent == second.spent
                    ? first.subject.name < second.subject.name
                    : first.spent > second.spent
            }
            return Activity(interval: DateInterval(start: start, end: end),
                            spent: spent, sessions: sessions, projects: projects)
        }
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
