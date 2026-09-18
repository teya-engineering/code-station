import Foundation

// The private-use characters that wrap a block the app draws itself rather than as prose.
// They cannot appear in ordinary text, so a reply carrying one meant it.
enum TranscriptMarker {
    static let open = "\u{E200}"
    static let separator = "\u{E202}"
    static let close = "\u{E201}"

    static func payload(of line: String, named name: String) -> String? {
        let prefix = open + name + separator
        guard line.hasPrefix(prefix), line.hasSuffix(close) else { return nil }
        return String(line.dropFirst(prefix.count).dropLast(close.count))
    }

    // A marker arrives a few characters at a time like everything else in a reply, so one
    // carrying a payload big enough to be worth hiding is held back until its closing
    // character lands. A marker whose payload is small enough to read, such as a file
    // path, is better left on screen: a malformed one then says so rather than vanishing.
    static func isIncomplete(_ line: String, named name: String) -> Bool {
        line.hasPrefix(open + name + separator) && !line.hasSuffix(close)
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
        var id: String { label }

        var values: [Double] { points.map(\.y) }
    }

    struct Rule: Equatable, Sendable, Identifiable {
        enum Axis: String, Decodable, Sendable { case x, y }
        let axis: Axis
        let value: Double
        let label: String?
        var id: String { "\(axis.rawValue)-\(value)" }
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
    enum Failure: LocalizedError {
        case unreadable

        var errorDescription: String? { "This chart could not be read." }
    }

    static func parse(_ line: String) -> Result<Self, Failure>? {
        guard let payload = TranscriptMarker.payload(of: line, named: "chart") else { return nil }
        guard let decoded = try? JSONDecoder().decode(Wire.self, from: Data(payload.utf8)),
              let spec = Self(decoded), !spec.isEmpty else { return .failure(.unreadable) }
        return .success(spec)
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
            return Rule(axis: Rule.Axis(rawValue: ($0.axis ?? "y").lowercased()) ?? .y,
                        value: $0.value, label: $0.label?.trimmed.nilIfBlank)
        }

        let cleaned = (wire.series ?? []).map { wired in
            Series(label: wired.label.trimmed,
                   points: Self.sampled(wired.points.filter(\.y.isFinite)))
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
        }
        struct Rule: Decodable {
            let axis: String?
            let value: Double
            let label: String?
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
        You can draw a chart in the transcript by putting a marker on a line of its own:

        \(TranscriptMarker.open)chart\(TranscriptMarker.separator)\
        {"kind":"line","title":"p99 checkout latency","unit":"ms","time":true,\
        "series":[{"label":"checkout","points":[[1757000000,412],[1757000060,438]]}],\
        "rules":[{"axis":"y","value":500,"label":"SLO"}]}\(TranscriptMarker.close)

        - "kind" is "line", "area", "bar" or "stat".
        - "line" and "area" take points as [x, y] with a numeric x. Set "time": true when \
        x is a unix timestamp in seconds.
        - "bar" takes points as [category, y], where the category is a string. It is drawn \
        as horizontal bars, so long names are fine.
        - "stat" is one headline number: "value", plus an optional "delta" of \
        {"value": n, "label": "vs the hour before", "goodDirection": "down"}. Give it a \
        single series as well to draw a sparkline under the number.
        - "rules" marks a threshold or a moment: an SLO on the y axis, a deploy or an \
        alert firing on the x axis.
        - At most \(seriesLimit) series, and two to four reads best. At most \(pointLimit) \
        points per series: sample a longer range down yourself, rather than sending every \
        scrape.
        - All the data must be inside the marker. The chart cannot fetch anything, which \
        is what keeps it agreeing with the words around it later.

        Chart the evidence a finding rests on, not every query you ran. Fewer than about \
        five numbers belong in a markdown table instead, and a single number usually \
        belongs in the sentence that explains it.
        """
}
