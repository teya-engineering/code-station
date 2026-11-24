import Foundation

// One bar of Home's glance chart: the stretch of time it covers, and what each project
// or workspace put into it in the lens being looked at.
struct GlanceBar {
    typealias Piece = DayRibbon.Activity.Share

    let interval: DateInterval
    // Biggest first, so the projects that filled the bar lead its card.
    let pieces: [Piece]
    // The sessions behind a bar of the rolling day, for its menu. Empty on the longer
    // stretches, where a click zooms in instead.
    var sessions: [DayRibbon.Block] = []

    var total: Double { pieces.reduce(0) { $0 + $1.spent } }
}

// Everything the glance chart draws for one stretch and one lens, worked out once per
// redraw. The rolling day reads agent time off the sessions themselves, so it is there
// even with Stats off; every other lens and stretch comes from a Stats report.
struct GlanceShape {
    let stretch: StatsRange
    let lens: StatsLens
    // The time the chart's width maps. Bars are placed on it by their own times, so a
    // zoom can put two stretches on one axis.
    let domain: DateInterval
    let bars: [GlanceBar]
    // The stretch's projects, biggest first. Every bar stacks in this order, so a project
    // sits at the same level in every bar it appears in.
    let rank: [String: Int]

    var wide: Bool { stretch != .today }
    var peak: Double { bars.map(\.total).max() ?? 0 }
    var isEmpty: Bool { peak <= 0 }

    // The bars' mean, empty ones included, which is what the dashed line marks.
    var average: Double {
        bars.isEmpty ? 0 : bars.reduce(0) { $0 + $1.total } / Double(bars.count)
    }

    // How many bars the rolling day is cut into at a width. Always a factor of the 64
    // slots a report cuts the day into, so slots merge into bars exactly.
    static func dayBars(width: CGFloat) -> Int {
        let fits = Int(width / 7)
        return [StatsReport.slots, StatsReport.slots / 2, StatsReport.slots / 4]
            .first { $0 <= fits } ?? StatsReport.slots / 4
    }

    static func ribbon(_ ribbon: DayRibbon, bars count: Int) -> GlanceShape {
        let bars = ribbon.activity(bucketCount: count).map {
            GlanceBar(interval: $0.interval, pieces: $0.projects, sessions: $0.sessions)
        }
        return GlanceShape(stretch: .today, lens: .time, domain: ribbon.axis, bars: bars,
                           rank: ribbon.rank)
    }

    // A lens of a Stats report. The rolling day's slots are merged down to the number of
    // bars the width takes, and each bar keeps the ribbon's sessions for the same minutes
    // so its menu still opens them.
    static func report(_ report: StatsReport, stretch: StatsRange, lens: StatsLens,
                       dayBars count: Int, sessions: [[DayRibbon.Block]] = [],
                       tint: (StatsSubject) -> Theme.ProjectTint) -> GlanceShape {
        var buckets = report.buckets
        if stretch == .today, count > 0, buckets.count > count, buckets.count % count == 0 {
            let group = buckets.count / count
            buckets = stride(from: 0, to: buckets.count, by: group).map { start in
                merged(Array(buckets[start..<start + group]))
            }
        }
        var subjects: [UUID: RibbonSubject] = [:]
        func subject(_ stats: StatsSubject) -> RibbonSubject {
            if let known = subjects[stats.id] { return known }
            let made = RibbonSubject(name: stats.name, tint: tint(stats), subjectID: stats.id)
            subjects[stats.id] = made
            return made
        }
        var totals: [String: Double] = [:]
        let bars = buckets.enumerated().map { index, bucket in
            let pieces = bucket.segments
                .map { GlanceBar.Piece(subject: subject($0.subject), spent: $0.value(lens)) }
                .filter { $0.spent > 0 }
                .sorted { ($0.spent, $1.subject.name) > ($1.spent, $0.subject.name) }
            for piece in pieces { totals[piece.subject.name, default: 0] += piece.spent }
            return GlanceBar(interval: DateInterval(start: bucket.start, end: bucket.end),
                             pieces: pieces,
                             sessions: index < sessions.count ? sessions[index] : [])
        }
        let order = totals.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        let domain = buckets.first.map { first in
            DateInterval(start: first.start, end: max(first.start, buckets.last?.end ?? first.end))
        } ?? report.interval
        return GlanceShape(stretch: stretch, lens: lens, domain: domain, bars: bars,
                           rank: Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) }))
    }

    private static func merged(_ buckets: [StatsReport.Bucket]) -> StatsReport.Bucket {
        var parts: [UUID: StatsReport.Segment] = [:]
        for segment in buckets.flatMap(\.segments) {
            var part = parts[segment.id] ?? StatsReport.Segment(subject: segment.subject)
            part.seconds += segment.seconds
            part.prompts += segment.prompts
            part.waiting += segment.waiting
            part.cost += segment.cost
            parts[segment.id] = part
        }
        return StatsReport.Bucket(start: buckets.first?.start ?? .distantPast,
                                  end: buckets.last?.end ?? .distantPast,
                                  segments: Array(parts.values))
    }
}
