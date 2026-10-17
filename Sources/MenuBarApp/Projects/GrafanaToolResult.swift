import Foundation

// What a Grafana MCP query returned, in the shapes mcp-grafana writes: Loki log lines,
// Loki metric samples, and Prometheus instant or range results. Anything else is not
// read at all, so the caller can fall back to showing the text as it came.
enum GrafanaToolResult: Equatable, Sendable {
    struct LogEntry: Equatable, Sendable, Identifiable {
        let id: Int
        let rawTimestamp: String
        let date: Date?
        let line: String
        let labels: [String: String]
        let fields: [String: String]
        let metadata: [String: String]
        let level: String?
        let message: String
    }

    struct Sample: Equatable, Sendable, Identifiable {
        let id: Int
        let labels: [String: String]
        let date: Date?
        let value: String
    }

    struct Series: Equatable, Sendable, Identifiable {
        // Prometheus writes values as strings, and "NaN" or "+Inf" are real readings a
        // table still has to show, so the text is kept beside the number a chart can use.
        struct Point: Equatable, Sendable {
            let seconds: Double
            let raw: String
            let value: Double?
        }
        let id: Int
        let labels: [String: String]
        let points: [Point]
    }

    case logs([LogEntry], truncated: Bool)
    case samples([Sample], truncated: Bool)
    case series([Series], truncated: Bool)
    case empty

    static let levelFields = ["level", "lvl", "severity"]
    static let messageFields = ["message", "msg"]

    static func parse(_ text: String, levelField: String? = nil) -> GrafanaToolResult? {
        if text.hasSuffix(StreamEvent.truncationMarker) {
            let body = String(text.dropLast(StreamEvent.truncationMarker.count))
            guard let objects = GrafanaJSONScanner.completeObjects(inArrayNamed: "data", of: body) else {
                return nil
            }
            return parse(entries: objects, truncated: true, levelField: levelField)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let entries = object["data"] as? [Any] else { return nil }
        let objects = entries.compactMap { $0 as? [String: Any] }
        guard objects.count == entries.count else { return nil }
        return parse(entries: objects, truncated: false, levelField: levelField)
    }

    static func parse(entries: [[String: Any]], truncated: Bool,
                      levelField: String?) -> GrafanaToolResult? {
        if entries.isEmpty { return truncated ? nil : .empty }
        if entries.allSatisfy({ $0["line"] is String }) {
            return .logs(entries.enumerated().map { logEntry($1, id: $0, levelField: levelField) },
                         truncated: truncated)
        }
        if entries.allSatisfy({ $0["metric"] is [String: Any] }) {
            if entries.allSatisfy({ $0["values"] is [Any] }) {
                return .series(entries.enumerated().map { series($1, id: $0) }, truncated: truncated)
            }
            let samples = entries.enumerated().compactMap { prometheusSample($1, id: $0) }
            return samples.count == entries.count ? .samples(samples, truncated: truncated) : nil
        }
        if entries.allSatisfy({ $0["value"] != nil && $0["labels"] is [String: Any] }) {
            return .samples(entries.enumerated().map { lokiSample($1, id: $0) }, truncated: truncated)
        }
        return nil
    }

    var count: Int {
        switch self {
        case .logs(let entries, _): entries.count
        case .samples(let samples, _): samples.count
        case .series(let series, _): series.count
        case .empty: 0
        }
    }

    var isTruncated: Bool {
        switch self {
        case .logs(_, let truncated), .samples(_, let truncated), .series(_, let truncated): truncated
        case .empty: false
        }
    }

    private static func logEntry(_ entry: [String: Any], id: Int, levelField: String?) -> LogEntry {
        let line = entry["line"] as? String ?? ""
        let fields = strings(entry["parsed"])
        let labels = strings(entry["labels"])
        let metadata = strings(entry["structuredMetadata"])
        let rawTimestamp = text(entry["timestamp"])
        return LogEntry(id: id,
                        rawTimestamp: rawTimestamp,
                        date: nanosecondDate(rawTimestamp),
                        line: line,
                        labels: labels,
                        fields: fields,
                        metadata: metadata,
                        level: level(fields: fields, labels: labels, metadata: metadata,
                                     preferred: levelField),
                        message: message(line: line, fields: fields))
    }

    private static func level(fields: [String: String], labels: [String: String],
                              metadata: [String: String], preferred: String?) -> String? {
        let names = [preferred].compactMap { $0 } + levelFields
        for name in names {
            if let value = fields[name] ?? labels[name], !value.isEmpty { return value }
        }
        guard let detected = metadata["detected_level"], detected != "unknown" else { return nil }
        return detected.uppercased()
    }

    // Loki's logfmt parser stops an unquoted value at the first space, so a message
    // written unquoted keeps only its first word in `parsed`. The line itself has all of
    // it, running from the key to the end of the first line.
    private static func message(line: String, fields: [String: String]) -> String {
        let firstLine = String(line.split(separator: "\n", maxSplits: 1,
                                          omittingEmptySubsequences: false).first ?? "")
        for name in messageFields {
            let key = name + "="
            let start: String.Index?
            if firstLine.hasPrefix(key) {
                start = firstLine.startIndex
            } else {
                start = firstLine.range(of: " " + key).map { firstLine.index(after: $0.lowerBound) }
            }
            if let start {
                let value = firstLine[firstLine.index(start, offsetBy: key.count)...]
                if value.hasPrefix("\""), let parsed = fields[name] { return parsed }
                return String(value)
            }
        }
        for name in messageFields {
            if let value = fields[name], !value.isEmpty { return value }
        }
        return firstLine
    }

    private static func lokiSample(_ entry: [String: Any], id: Int) -> Sample {
        Sample(id: id, labels: strings(entry["labels"]),
               date: Double(text(entry["timestamp"])).map(Date.init(timeIntervalSince1970:)),
               value: text(entry["value"]))
    }

    private static func prometheusSample(_ entry: [String: Any], id: Int) -> Sample? {
        guard let pair = entry["value"] as? [Any], pair.count == 2 else { return nil }
        return Sample(id: id, labels: strings(entry["metric"]),
                      date: Double(text(pair[0])).map(Date.init(timeIntervalSince1970:)),
                      value: text(pair[1]))
    }

    private static func series(_ entry: [String: Any], id: Int) -> Series {
        let points = (entry["values"] as? [Any] ?? []).compactMap { item -> Series.Point? in
            guard let pair = item as? [Any], pair.count == 2,
                  let seconds = Double(text(pair[0])) else { return nil }
            let raw = text(pair[1])
            return Series.Point(seconds: seconds, raw: raw,
                                value: Double(raw).flatMap { $0.isFinite ? $0 : nil })
        }
        return Series(id: id, labels: strings(entry["metric"]), points: points)
    }

    // Loki writes a log line's time as nanoseconds in a string that itself carries quotes.
    private static func nanosecondDate(_ raw: String) -> Date? {
        let digits = raw.replacingOccurrences(of: "\"", with: "")
        guard digits.count >= 10, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let nanoseconds = Int64(digits) else { return nil }
        return Date(timeIntervalSince1970: Double(nanoseconds) / 1_000_000_000)
    }

    private static func strings(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        return dictionary.mapValues(text)
    }

    private static func text(_ value: Any?) -> String {
        switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        case nil: ""
        case let other?: String(describing: other)
        }
    }
}
