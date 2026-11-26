import Foundation

// The private-use characters that wrap a block the app writes for itself rather than as
// prose. They cannot appear in ordinary text, so a line carrying one meant it. Only the
// app may use them: they have no glyph, so an agent reading an example of one sees the
// text around the characters and not the characters themselves, and copies what it saw.
enum TranscriptMarker {
    static let open = "\u{E200}"
    static let separator = "\u{E202}"
    static let close = "\u{E201}"

    static func payload(of line: String, named name: String) -> String? {
        let prefix = open + name + separator
        guard line.hasPrefix(prefix), line.hasSuffix(close) else { return nil }
        return String(line.dropFirst(prefix.count).dropLast(close.count))
    }
}

// A chart the agent asks for, carried in the reply itself rather than written to a file.
// The data travels with it because a chart in a transcript is evidence for a finding: the
// file it was read from is gone a week later, but the reply is still there, and a chart
// that refetched would quietly stop agreeing with the words around it.
struct TranscriptChartSpec: Equatable, Sendable {
    enum Kind: String, Decodable, Sendable { case line, area, bar, stat }

    enum Position: Equatable, Sendable {
        case number(Double)
        case category(String)

        var number: Double? { if case .number(let value) = self { value } else { nil } }
        var category: String? { if case .category(let name) = self { name } else { nil } }
    }

    struct Point: Equatable, Sendable {
        let x: Position
        let y: Double
    }

    struct Series: Equatable, Sendable, Identifiable {
        let label: String
        let points: [Point]
        // What the readings count. Series that share a unit share a scale, and a series
        // with another unit gets a lane of its own, so a balance in the hundreds never
        // flattens a percentage drawn beside it.
        var unit: String? = nil
        // The label of the series this one carries on from, for a projection.
        var continues: String? = nil
        var id: String { label }

        var values: [Double] { points.map(\.y) }
    }

    // What a mark says about the moment or the level it sits on. It picks the colour, so
    // red is only ever a breach or a failure.
    enum Tone: String, Sendable { case warn, bad, good, note }

    struct Rule: Equatable, Sendable, Identifiable {
        enum Axis: String, Decodable, Sendable { case x, y }
        // Which side of a level is the wrong side to be on.
        enum Breach: String, Sendable { case below, above }
        let axis: Axis
        let value: Double
        let label: String?
        var tone: Tone? = nil
        var breach: Breach? = nil
        // The unit of the lane a level belongs to, when there is more than one.
        var unit: String? = nil
        var id: String { "\(axis.rawValue)-\(value)" }
    }

    // A stretch of time that something held for, such as an alert firing. One with no
    // end is still going, and is drawn up to the last reading.
    struct Band: Equatable, Sendable {
        let from: Double
        let to: Double?
        let label: String?
        let tone: Tone
    }

    // A named window of the time axis, for an event that is a small part of the range.
    struct Window: Equatable, Sendable {
        let label: String
        let from: Double
        let to: Double
    }

    struct Delta: Equatable, Sendable {
        let value: Double
        let label: String?
        // Whether a rise is the good news. An error rate climbing is bad, a success rate
        // climbing is good, and nothing about the number itself says which.
        let risingIsGood: Bool
    }

    let kind: Kind
    let title: String?
    let caption: String?
    let unit: String?
    // Whether x counts seconds since 1970, which is what turns the axis into clock time.
    let isTime: Bool
    let series: [Series]
    let rules: [Rule]
    let bands: [Band]
    let views: [Window]
    // Where the readings came from, such as "PROMETHEUS" on "platform-prd".
    let source: String?
    let server: String?
    let value: Double?
    let delta: Delta?

    // Eight is the whole palette, and the ninth series would have to either repeat a
    // colour or invent one. Neither is worth drawing, so the extras are named instead.
    static let seriesLimit = 8
    // Enough to draw a shape at the width a transcript gives a chart, and few enough that
    // a reply carrying one does not cost more than the answer it illustrates.
    static let pointLimit = 300

    var omittedSeriesCount: Int { max(0, rawSeriesCount - Self.seriesLimit) }

    private let rawSeriesCount: Int

    var isEmpty: Bool {
        switch kind {
        case .stat: value == nil
        case .line, .area, .bar: series.allSatisfy(\.points.isEmpty)
        }
    }
}

// MARK: - Reading one out of a reply

extension TranscriptChartSpec {
    enum Failure: LocalizedError, Equatable {
        case unreadable
        // The block was whole and named its series, but none of them had a reading.
        case noReadings(title: String?)

        var errorDescription: String? {
            switch self {
            case .unreadable: "This chart could not be read."
            case .noReadings: "No readings in this window."
            }
        }
    }

    // The language tag of a fenced block, which is how a reply asks for a chart.
    static let fenceLanguage = "chart"

    static func parse(_ json: String) -> Result<Self, Failure> {
        guard let decoded = try? JSONDecoder().decode(Wire.self, from: Data(json.utf8)),
              let spec = Self(decoded) else { return .failure(.unreadable) }
        guard spec.isEmpty else { return .success(spec) }
        return .failure(spec.kind != .stat && !spec.series.isEmpty
            ? .noReadings(title: spec.title) : .unreadable)
    }

    private init?(_ wire: Wire) {
        guard let kind = Kind(rawValue: wire.kind.lowercased()) else { return nil }
        self.kind = kind
        title = wire.title?.trimmed.nilIfBlank
        caption = wire.caption?.trimmed.nilIfBlank
        unit = wire.unit?.trimmed.nilIfBlank
        isTime = wire.time ?? false
        value = wire.value?.isFinite == true ? wire.value : nil
        delta = wire.delta.map {
            Delta(value: $0.value, label: $0.label?.trimmed.nilIfBlank,
                  risingIsGood: ($0.goodDirection ?? "up").lowercased() != "down")
        }
        rules = (wire.rules ?? []).compactMap {
            guard $0.value.isFinite else { return nil }
            let axis = Rule.Axis(rawValue: ($0.axis ?? "y").lowercased()) ?? .y
            return Rule(axis: axis, value: $0.value, label: $0.label?.trimmed.nilIfBlank,
                        tone: $0.tone.flatMap { Tone(rawValue: $0.lowercased()) },
                        // A moment has no wrong side, so only a level can be breached.
                        breach: axis == .y ? $0.breach.flatMap { Rule.Breach(rawValue: $0.lowercased()) } : nil,
                        unit: $0.unit?.trimmed.nilIfBlank)
        }
        bands = (wire.bands ?? []).compactMap {
            guard $0.from.isFinite, $0.to?.isFinite ?? true, ($0.to ?? .infinity) > $0.from else { return nil }
            return Band(from: $0.from, to: $0.to, label: $0.label?.trimmed.nilIfBlank,
                        tone: $0.tone.flatMap { Tone(rawValue: $0.lowercased()) } ?? .bad)
        }
        views = (wire.views ?? []).compactMap {
            guard let label = $0.label?.trimmed.nilIfBlank, $0.from.isFinite, $0.to.isFinite,
                  $0.to > $0.from else { return nil }
            return Window(label: label, from: $0.from, to: $0.to)
        }
        source = wire.source?.trimmed.nilIfBlank
        server = wire.server?.trimmed.nilIfBlank

        let cleaned = (wire.series ?? []).map { wired in
            Series(label: wired.label.trimmed,
                   points: Self.sampled(wired.points.filter(\.y.isFinite)),
                   unit: wired.unit?.trimmed.nilIfBlank,
                   continues: wired.continues?.trimmed.nilIfBlank)
        }
        rawSeriesCount = cleaned.count
        series = Array(cleaned.prefix(Self.seriesLimit))
    }

    // Keeping every nth point rather than the first few holds the shape and the span of
    // what was asked for. The last point is always kept, since a chart of a live incident
    // is read from its right edge.
    private static func sampled(_ points: [Point]) -> [Point] {
        guard points.count > pointLimit else { return points }
        let stride = Double(points.count - 1) / Double(pointLimit - 1)
        var kept = (0..<(pointLimit - 1)).map { points[Int((Double($0) * stride).rounded(.down))] }
        kept.append(points[points.count - 1])
        return kept
    }

    // The shape as it arrives, kept apart from the shape the app draws so that anything
    // missing, misspelled or out of range is dealt with in one place.
    private struct Wire: Decodable {
        struct Series: Decodable {
            let label: String
            let points: [Point]
            let unit: String?
            let continues: String?
        }
        struct Rule: Decodable {
            let axis: String?
            let value: Double
            let label: String?
            let tone: String?
            let breach: String?
            let unit: String?
        }
        struct Band: Decodable {
            let from: Double
            let to: Double?
            let label: String?
            let tone: String?
        }
        struct Window: Decodable {
            let label: String?
            let from: Double
            let to: Double
        }
        struct Delta: Decodable {
            let value: Double
            let label: String?
            let goodDirection: String?
        }
        let kind: String
        let title: String?
        let caption: String?
        let unit: String?
        let time: Bool?
        let series: [Series]?
        let rules: [Rule]?
        let bands: [Band]?
        let views: [Window]?
        let source: String?
        let server: String?
        let value: Double?
        let delta: Delta?
    }
}

// A point is written as a two-element array so a long series stays cheap to send. Its
// first element is a number for a time or a measurement, and a name for a category.
extension TranscriptChartSpec.Point: Decodable {
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        if let number = try? container.decode(Double.self) {
            x = .number(number)
        } else {
            x = .category(try container.decode(String.self).trimmed)
        }
        y = (try? container.decode(Double.self)) ?? .nan
    }
}

// MARK: - What the agent is told

extension TranscriptChartSpec {
    // The app can draw a chart, but nothing about a transcript says so, so every agent
    // that can reach this renderer is handed the shape it reads.
    static let agentInstructions = """
        You can draw a chart in the transcript with a fenced block tagged \
        `\(fenceLanguage)`, holding the chart as JSON:

        ```\(fenceLanguage)
        {"kind":"line","title":"p99 checkout latency","unit":"ms","time":true,
         "series":[{"label":"checkout","points":[[1757000000,412],[1757000060,438]]}],
         "rules":[{"axis":"y","value":500,"label":"SLO"}]}
        ```

        - "kind" is "line", "area", "bar" or "stat".
        - "line" and "area" take points as [x, y] with a numeric x. Set "time": true when \
        x is a unix timestamp in seconds.
        - "bar" takes points as [category, y], where the category is a string. It is drawn \
        as horizontal bars, so long names are fine.
        - "stat" is one headline number: "value", plus an optional "delta" of \
        {"value": n, "label": "vs the hour before", "goodDirection": "down"}. Give it a \
        single series as well to draw a sparkline under the number.
        - "rules" marks a threshold or a moment: an SLO on the y axis, a deploy on the x \
        axis. A rule may take a "tone" of "warn", "bad", "good" or "note". A y rule may \
        take "breach": "below" or "above" to say which side is the wrong one, and the \
        "unit" of the series it belongs to.
        - Give each series its "unit", such as "credits" or "%". Series with different \
        units are drawn on their own scales, one above the other, on one time axis.
        - A series that projects another forward takes "continues": the label of that \
        series. It is drawn dotted and marked as projected.
        - "bands" shades a stretch of time: {"from": x, "to": x, "label": "alert firing", \
        "tone": "bad"}. Leave "to" out while it is still going.
        - "views" names windows of the time axis the reader can jump to: \
        {"label": "The reset", "from": x, "to": x}. Add one when the event is a small \
        part of the range.
        - "source" and "server" say where the readings came from, such as "PROMETHEUS" \
        and "platform-prd".
        - A "stat" with a y rule draws a meter from zero to that rule, as a target.
        - At most \(seriesLimit) series, and two to four reads best. At most \(pointLimit) \
        points per series: sample a longer range down yourself, rather than sending every \
        scrape.
        - All the data must be inside the block. The chart cannot fetch anything, which \
        is what keeps it agreeing with the words around it later.

        Chart the evidence a finding rests on, not every query you ran. Fewer than about \
        five numbers belong in a markdown table instead, and a single number usually \
        belongs in the sentence that explains it.
        """
}
