import Foundation

// A traceId as typed, or pulled out of a pasted Grafana link: 32 hex characters, or the 16
// an older tracer writes. Anything else is not sent anywhere. A link carries other ids as
// well, a datasource uid among them, so a full 32-character run is preferred to a short one.
enum TraceInput {
    static func traceID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTraceID(trimmed) { return trimmed.lowercased() }
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        let runs = decoded.split(whereSeparator: { !$0.isHexDigit }).map(String.init)
        return (runs.first { $0.count == 32 } ?? runs.first { $0.count == 16 })?.lowercased()
    }

    static func isTraceID(_ text: String) -> Bool {
        (text.count == 16 || text.count == 32) && text.allSatisfy(\.isHexDigit)
    }
}

enum TraceLink {
    // Grafana's Explore with the trace open in the Tempo datasource it came from.
    static func explore(grafanaURL: String, datasourceUID: String, traceID: String) -> URL? {
        var base = grafanaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let pane: [String: Any] = [
            "datasource": datasourceUID,
            "queries": [[
                "refId": "A",
                "datasource": ["type": "tempo", "uid": datasourceUID],
                "queryType": "traceql",
                "query": traceID,
            ]],
            "range": ["from": "now-1h", "to": "now"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: ["a": pane], options: [.sortedKeys]),
              var components = URLComponents(string: base + "/explore") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "schemaVersion", value: "1"),
            URLQueryItem(name: "panes", value: String(decoding: data, as: UTF8.self)),
        ]
        return components.url
    }
}
