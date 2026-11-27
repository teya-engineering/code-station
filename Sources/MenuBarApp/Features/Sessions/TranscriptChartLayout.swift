import CoreGraphics
import Foundation

// A line or area chart worked out from its block, before anything is drawn: which series
// share a scale, which moments are marked, and what each one reads at a given time. Kept
// apart from the view so the rules a reader relies on can be checked without a window.
struct ChartLanes: Equatable, Sendable {
    struct Reading: Equatable, Sendable {
        let x: Double
        let y: Double
    }

    struct Line: Equatable, Identifiable, Sendable {
        let id: Int
        let label: String
        // The colour slot. A projection takes the slot of the series it carries on from.
        let slot: Int
        let readings: [Reading]
        let isProjection: Bool

        func reading(at time: Double) -> Reading? {
            guard let first = readings.first, let last = readings.last,
                  time >= first.x - ChartLanes.slack, time <= last.x + ChartLanes.slack else { return nil }
            return readings.min { abs($0.x - time) < abs($1.x - time) }
        }
    }

    // Series that share a unit, drawn on one scale. One scale per unit rather than two
    // axes on one plot, which invites reading crossings that mean nothing.
    struct Lane: Equatable, Sendable {
        let unit: String?
        var lines: [Line]
        var levels: [TranscriptChartSpec.Rule]

        // The level a reading must not cross, when the block names one.
        var breach: TranscriptChartSpec.Rule? { levels.first { $0.breach != nil } }

        func isBreach(_ value: Double) -> Bool {
            guard let rule = breach else { return false }
            return rule.breach == .below ? value < rule.value : value > rule.value
        }
    }

    // A moment named in the rail above the plot: an x rule, or the start of a band.
    struct Marker: Equatable {
        let time: Double
        let label: String
        let tone: TranscriptChartSpec.Tone
    }

    // What one series shows in the strip.
    struct Readout: Equatable {
        let value: Double
        let isProjected: Bool
        let isBreach: Bool
    }

    let lanes: [Lane]
    let bands: [TranscriptChartSpec.Band]
    let moments: [TranscriptChartSpec.Rule]
    // Every moment a reading was taken, in order. The pointer snaps to these.
    let times: [Double]
    // The whole range first, then the windows the block names.
    let windows: [TranscriptChartSpec.Window]
    // Where the measured readings end, which is where an open band stops.
    let latest: Double

    // Readings a second either side of an end still count as that end.
    static let slack: Double = 1
    static let wholeRange = "Whole range"

    init(_ spec: TranscriptChartSpec) {
        let numbered = spec.series.enumerated().map { index, series in
            (index: index, series: series,
             readings: series.points.compactMap { point in point.x.number.map { Reading(x: $0, y: point.y) } })
        }
        // A series that carries on from one the block does not hold stands on its own.
        let labels = Set(spec.series.filter { $0.continues == nil }.map(\.label))
        let solid = numbered.filter { $0.series.continues.map { !labels.contains($0) } ?? true }
        let projected = numbered.filter { $0.series.continues.map(labels.contains) ?? false }

        var lanes: [Lane] = []
        var home: [String: (lane: Int, slot: Int)] = [:]
        for (slot, entry) in solid.enumerated() {
            let unit = entry.series.unit ?? spec.unit
            let lane = lanes.firstIndex { $0.unit == unit } ?? {
                lanes.append(Lane(unit: unit, lines: [], levels: []))
                return lanes.count - 1
            }()
            lanes[lane].lines.append(Line(id: entry.index, label: entry.series.label, slot: slot,
                                          readings: entry.readings, isProjection: false))
            if home[entry.series.label] == nil { home[entry.series.label] = (lane, slot) }
        }
        for entry in projected {
            guard let parent = entry.series.continues.flatMap({ home[$0] }) else { continue }
            lanes[parent.lane].lines.append(Line(id: entry.index, label: entry.series.label,
                                                 slot: parent.slot, readings: entry.readings,
                                                 isProjection: true))
        }
        for rule in spec.rules where rule.axis == .y && !lanes.isEmpty {
            let lane = rule.unit.flatMap { unit in lanes.firstIndex { $0.unit == unit } } ?? 0
            lanes[lane].levels.append(rule)
        }
        self.lanes = lanes
        bands = spec.bands
        moments = spec.rules.filter { $0.axis == .x }

        let measured = solid.flatMap { $0.readings.map(\.x) }
        let everything = numbered.flatMap { $0.readings.map(\.x) }
        times = Array(Set(everything)).sorted()
        let low = measured.min() ?? everything.min() ?? 0
        latest = measured.max() ?? everything.max() ?? low + 1

        // With no window named, the whole range is the only way to reach a projection or
        // a moment outside the readings, so it has to hold them.
        let reach = spec.views.isEmpty
            ? everything + moments.map(\.value) + spec.bands.flatMap { [$0.from] + ($0.to.map { [$0] } ?? []) }
            : measured
        let from = min(low, reach.min() ?? low)
        let to = max(latest, reach.max() ?? latest)
        windows = [.init(label: Self.wholeRange, from: from, to: to > from ? to : from + 1)] + spec.views
    }

    var solidLines: [Line] { lanes.flatMap { $0.lines.filter { !$0.isProjection } }.sorted { $0.slot < $1.slot } }

    var hasMarkers: Bool { !moments.isEmpty || bands.contains { $0.label != nil } }

    func lane(of line: Line) -> Int { lanes.firstIndex { $0.lines.contains { $0.id == line.id } } ?? 0 }

    func projection(of line: Line) -> Line? {
        lanes[lane(of: line)].lines.first { $0.isProjection && $0.slot == line.slot }
    }

    // MARK: - Scales

    // The scale of one lane for a stretch of time: fitted to what is in view, so zooming
    // in on a quiet stretch shows its shape, and rounded out to whole steps so the grid
    // lands on numbers worth reading.
    func scale(lane index: Int, from: Double, to: Double, steps: Int) -> ClosedRange<Double> {
        let lane = lanes[index]
        var values = lane.lines.flatMap { $0.readings.filter { $0.x >= from && $0.x <= to }.map(\.y) }
        if values.isEmpty { values = lane.lines.flatMap { $0.readings.map(\.y) } }
        values += lane.levels.map(\.value)
        var low = values.min() ?? 0
        var high = values.max() ?? 1
        // A scale that starts well above zero is kept, since a queue that never drops
        // below nine hundred would otherwise draw flat along the top. One that already
        // reaches most of the way down starts at zero, where the eye expects it.
        if low >= 0, lane.unit == "%" || low < high * 0.5 { low = 0 }
        if high <= low { high = low + 1 }
        let step = Self.niceStep((high - low) / Double(max(steps, 1)))
        return (low / step).rounded(.down) * step...(high / step).rounded(.up) * step
    }

    // The first lane is the tall one, with room for three steps of grid. The strips
    // under it have room for two.
    static func steps(lane: Int) -> Int { lane == 0 ? 3 : 2 }

    func frame(from: Double, to: Double) -> ChartFrame {
        ChartFrame(from: from, to: to, scales: lanes.indices.map {
            let fitted = scale(lane: $0, from: from, to: to, steps: Self.steps(lane: $0))
            return ChartFrame.Scale(low: fitted.lowerBound, high: fitted.upperBound)
        })
    }

    static func niceStep(_ rough: Double) -> Double {
        guard rough > 0, rough.isFinite else { return 1 }
        let power = pow(10, (log10(rough)).rounded(.down))
        let share = rough / power
        return (share <= 1 ? 1 : share <= 2 ? 2 : share <= 5 ? 5 : 10) * power
    }

    static func gridValues(_ scale: ChartFrame.Scale, steps: Int) -> [Double] {
        let step = niceStep((scale.high - scale.low) / Double(max(steps, 1)))
        guard step > 0, scale.high > scale.low else { return [] }
        var values: [Double] = []
        var value = (scale.low / step - 1e-9).rounded(.up) * step
        while value <= scale.high + step * 1e-6, values.count < 12 {
            values.append(value)
            value += step
        }
        return values
    }

    private static let clockSteps: [Double] = [1, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600,
                                               7200, 10800, 21600, 43200, 86400, 172_800, 604_800]

    // Where the time axis is marked, at most `limit` times. Clock time steps by whole
    // minutes and hours rather than by tens, so the marks are times people say.
    static func ticks(from: Double, to: Double, limit: Int, isTime: Bool) -> (values: [Double], step: Double) {
        let span = to - from
        guard span > 0 else { return ([], 1) }
        let limit = Double(max(limit, 2))
        let step = isTime
            ? clockSteps.first { span / $0 <= limit } ?? niceStep(span / limit)
            : niceStep(span / limit)
        var values: [Double] = []
        var value = (from / step).rounded(.up) * step
        while value <= to + step * 1e-6, values.count < 40 {
            values.append(value)
            value += step
        }
        return (values, step)
    }

    // MARK: - Reading

    func snapped(_ time: Double, in frame: ChartFrame) -> Double? {
        times.filter { $0 >= frame.from - Self.slack && $0 <= frame.to + Self.slack }
            .min { abs($0 - time) < abs($1 - time) }
    }

    // What a series reads at a moment. Past the end of its measurements the projection
    // answers, and says that it did.
    func readout(_ line: Line, at time: Double) -> Readout? {
        let lane = lanes[lane(of: line)]
        if let reading = line.reading(at: time) {
            return Readout(value: reading.y, isProjected: false, isBreach: lane.isBreach(reading.y))
        }
        if let reading = projection(of: line)?.reading(at: time) {
            return Readout(value: reading.y, isProjected: true, isBreach: lane.isBreach(reading.y))
        }
        return nil
    }

    func latestReadout(_ line: Line) -> Readout? {
        guard let last = line.readings.last else { return nil }
        return Readout(value: last.y, isProjected: false, isBreach: lanes[lane(of: line)].isBreach(last.y))
    }

    func markers(in frame: ChartFrame) -> [Marker] {
        var found = moments.filter { $0.value >= frame.from && $0.value <= frame.to }.map {
            Marker(time: $0.value, label: $0.label ?? "", tone: $0.tone ?? .warn)
        }
        for band in bands {
            guard let label = band.label, (band.to ?? latest) > frame.from, band.from < frame.to else { continue }
            found.append(Marker(time: max(band.from, frame.from), label: label, tone: band.tone))
        }
        return found.sorted { $0.time < $1.time }
    }

    // First, low, high and last for the stretch in view: a chart in a reply is read for
    // its extremes and where it ended up.
    func summary(_ line: Line, in frame: ChartFrame) -> (first: Double, low: Double, high: Double, last: Double)? {
        let values = line.readings.filter { $0.x >= frame.from && $0.x <= frame.to }.map(\.y)
        guard let first = values.first, let last = values.last,
              let low = values.min(), let high = values.max() else { return nil }
        return (first, low, high, last)
    }
}

// The stretch of time on screen and each lane's scale for it. Two frames can be mixed,
// which is how a change of view moves the axis and the scales together.
struct ChartFrame: Equatable, Sendable {
    struct Scale: Equatable, Sendable {
        var low: Double
        var high: Double
    }

    var from: Double
    var to: Double
    var scales: [Scale]

    func mixed(with other: ChartFrame, _ share: Double) -> ChartFrame {
        guard scales.count == other.scales.count else { return other }
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * share }
        return ChartFrame(from: mix(from, other.from), to: mix(to, other.to),
                          scales: zip(scales, other.scales).map {
                              Scale(low: mix($0.low, $1.low), high: mix($0.high, $1.high))
                          })
    }
}

// Where the parts of the plot sit, in points, for a width.
struct ChartGeometry: Equatable, Sendable {
    let width: CGFloat
    let leading: CGFloat
    let trailing: CGFloat
    let rail: CGFloat
    let laneTops: [CGFloat]
    let laneHeights: [CGFloat]
    let bottom: CGFloat
    let height: CGFloat

    init(lanes: Int, width: CGFloat, hasMarkers: Bool, textScale: CGFloat) {
        self.width = width
        leading = ChartMetrics.axisWidth * textScale
        trailing = ChartMetrics.trailingInset
        rail = hasMarkers ? ChartMetrics.railHeight * textScale : ChartMetrics.unitRoom * textScale
        var tops: [CGFloat] = []
        var heights: [CGFloat] = []
        var y = rail
        for lane in 0..<max(lanes, 1) {
            let height = lane == 0 ? ChartMetrics.leadLaneHeight : ChartMetrics.laneHeight
            tops.append(y)
            heights.append(height)
            y += height + ChartMetrics.laneGap * textScale
        }
        laneTops = tops
        laneHeights = heights
        bottom = y - ChartMetrics.laneGap * textScale
        height = bottom + ChartMetrics.axisHeight * textScale
    }

    var plotWidth: CGFloat { max(width - leading - trailing, 1) }

    func x(_ time: Double, in frame: ChartFrame) -> CGFloat {
        leading + CGFloat((time - frame.from) / max(frame.to - frame.from, .ulpOfOne)) * plotWidth
    }

    func time(at x: CGFloat, in frame: ChartFrame) -> Double {
        frame.from + Double((x - leading) / plotWidth) * (frame.to - frame.from)
    }

    func y(_ value: Double, lane: Int, in frame: ChartFrame) -> CGFloat {
        let scale = frame.scales[lane]
        let share = (value - scale.low) / max(scale.high - scale.low, .ulpOfOne)
        return laneTops[lane] + laneHeights[lane] * CGFloat(1 - share)
    }

    // MARK: - Flags

    struct FlagPlace: Equatable {
        // The row counted up from the plot, or nil when the name fits nowhere and only
        // the stem is drawn.
        let row: Int?
        // A flipped flag hangs to the left of its stem.
        let flipped: Bool
    }

    // Seats each flag in the rail, in the order given, which is left to right. A flag
    // hangs to the right of its stem, flips to the left, or moves up a row, in that
    // order of preference. It never crosses the edge of the plot or another flag.
    static func place(flags: [(x: CGFloat, width: CGFloat)], within width: CGFloat,
                      rows: Int = ChartMetrics.flagRows) -> [FlagPlace] {
        let gap = ChartMetrics.flagGap
        var ends = Array(repeating: -CGFloat.infinity, count: rows)
        return flags.enumerated().map { index, flag in
            let next = index + 1 < flags.count ? flags[index + 1].x : .infinity
            for row in 0..<rows {
                let clear = flag.x >= ends[row] + gap
                // On the row beside the plot a flag also stops short of the next stem, so
                // the name is not read as belonging to it.
                let roomRight = flag.x + flag.width <= min(width, row == 0 ? next - gap : .infinity)
                if clear && roomRight {
                    ends[row] = flag.x + flag.width
                    return FlagPlace(row: row, flipped: false)
                }
                if flag.x - flag.width >= max(0, ends[row] + gap) {
                    ends[row] = flag.x
                    return FlagPlace(row: row, flipped: true)
                }
            }
            return FlagPlace(row: nil, flipped: false)
        }
    }
}

// The follow-ups a chart can ask the agent for.
enum ChartFollowUp {
    static func window(title: String?, from: String, to: String, change: String?) -> String {
        let chart = title.map { " on the chart \"\($0)\"" } ?? " on the chart"
        return "Look closer at \(from) to \(to)\(chart)." + (change.map { " \($0)" } ?? "")
            + " What else changed in that window? Show what you find as evidence."
    }

    static func drawAgain() -> String {
        "The ```\(TranscriptChartSpec.fenceLanguage) block you wrote could not be read. "
            + "Draw it again as a complete ```\(TranscriptChartSpec.fenceLanguage) block."
    }

    static func widen(title: String?) -> String {
        let chart = title.map { "The chart \"\($0)\"" } ?? "The chart you drew"
        return "\(chart) came back with no readings. Run its query again over the last 6 hours "
            + "and draw what it finds as a ```\(TranscriptChartSpec.fenceLanguage) block."
    }
}
