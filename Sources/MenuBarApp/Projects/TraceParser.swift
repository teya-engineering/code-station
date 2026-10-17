import Foundation

// Tempo's answer for one trace, read as OTLP JSON in each shape it comes in: the v1 API's
// "batches" with base64 ids, the v2 API's "trace" wrapper around "resourceSpans" with hex
// ids, and the older "instrumentationLibrarySpans" name for "scopeSpans". A Grafana API
// reply that wraps the body is unwrapped first.
enum TraceParser {
    enum Outcome: Equatable, Sendable {
        case trace(Trace)
        // Readable, but with no spans in it: Tempo's way of saying it has no such trace.
        case empty
        case unreadable
    }

    static func parse(_ text: String) -> Outcome {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                as? [String: Any] else { return .unreadable }
        return parse(object)
    }

    private static func parse(_ object: [String: Any]) -> Outcome {
        if let inner = object["trace"] as? [String: Any] { return parse(inner) }
        // mcp-grafana's API tool wraps Grafana's answer: {"status":…, "headers":…, "data": body}.
        if let data = object["data"] as? [String: Any] { return parse(data) }
        if let body = object["body"] as? [String: Any] { return parse(body) }
        if let body = object["body"] as? String { return parse(body) }
        if object.isEmpty || object["trace"] is NSNull { return .empty }
        guard let batches = (object["batches"] ?? object["resourceSpans"]) as? [[String: Any]] else {
            return .unreadable
        }

        var spans: [Trace.Span] = []
        var traceID: String?
        for batch in batches {
            let resource = attributes((batch["resource"] as? [String: Any])?["attributes"])
            let service = resource.first { $0.key == "service.name" }?.value ?? "unknown"
            let scopes = (batch["scopeSpans"] ?? batch["instrumentationLibrarySpans"])
                as? [[String: Any]] ?? []
            for scope in scopes {
                for raw in scope["spans"] as? [[String: Any]] ?? [] {
                    guard let span = span(raw, service: service, resource: resource) else { continue }
                    if traceID == nil, let id = raw["traceId"] as? String { traceID = hexID(id) }
                    spans.append(span)
                }
            }
        }
        guard !spans.isEmpty else { return .empty }
        return .trace(Trace(traceID: traceID ?? "", spans: spans))
    }

    private static func span(_ raw: [String: Any], service: String,
                             resource: [Trace.Attribute]) -> Trace.Span? {
        guard let rawID = raw["spanId"] as? String, !rawID.isEmpty,
              let start = nanos(raw["startTimeUnixNano"]) else { return nil }
        let end = nanos(raw["endTimeUnixNano"]) ?? start
        let parent = (raw["parentSpanId"] as? String).flatMap { $0.isEmpty ? nil : hexID($0) }
        let status = raw["status"] as? [String: Any] ?? [:]
        let message = (status["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let events = (raw["events"] as? [[String: Any]] ?? []).map { event in
            Trace.Event(name: event["name"] as? String ?? "",
                        offsetNanos: (nanos(event["timeUnixNano"]) ?? start) - start,
                        attributes: attributes(event["attributes"]))
        }
        return Trace.Span(id: hexID(rawID), parentID: parent, service: service,
                          operation: raw["name"] as? String ?? "",
                          kind: kind(raw["kind"]), startNanos: start,
                          durationNanos: max(end - start, 0),
                          isError: isError(status["code"]), statusMessage: message,
                          attributes: attributes(raw["attributes"]),
                          resourceAttributes: resource, events: events)
    }

    // v2 and OTLP proper write ids as hex; v1 writes them base64. Either way they come out
    // as lowercase hex, the form people paste and Grafana shows.
    static func hexID(_ raw: String) -> String {
        if raw.count == 16 || raw.count == 32, raw.allSatisfy(\.isHexDigit) {
            return raw.lowercased()
        }
        if let data = Data(base64Encoded: raw) {
            return data.map { String(format: "%02x", $0) }.joined()
        }
        return raw.lowercased()
    }

    // OTLP's enum arrives as its name ("SPAN_KIND_SERVER") or as its number.
    static func kind(_ value: Any?) -> String {
        let names = ["unspecified", "internal", "server", "client", "producer", "consumer"]
        if let number = value as? NSNumber, names.indices.contains(number.intValue) {
            return names[number.intValue]
        }
        if let text = value as? String {
            let name = text.replacingOccurrences(of: "SPAN_KIND_", with: "").lowercased()
            return names.contains(name) ? name : "unspecified"
        }
        return "unspecified"
    }

    private static func isError(_ code: Any?) -> Bool {
        if let number = code as? NSNumber { return number.intValue == 2 }
        return (code as? String) == "STATUS_CODE_ERROR"
    }

    private static func nanos(_ value: Any?) -> Int64? {
        if let text = value as? String { return Int64(text) }
        if let number = value as? NSNumber { return number.int64Value }
        return nil
    }

    static func attributes(_ value: Any?) -> [Trace.Attribute] {
        (value as? [[String: Any]] ?? []).compactMap { entry in
            guard let key = entry["key"] as? String else { return nil }
            return Trace.Attribute(key: key, value: text(entry["value"]))
        }
    }

    // An OTLP AnyValue: exactly one of its typed fields is set.
    private static func text(_ value: Any?) -> String {
        guard let value = value as? [String: Any] else { return "" }
        if let string = value["stringValue"] as? String { return string }
        if let bool = value["boolValue"] as? Bool { return bool ? "true" : "false" }
        if let int = value["intValue"] { return "\(int)" }
        if let double = value["doubleValue"] as? NSNumber { return double.stringValue }
        if let array = (value["arrayValue"] as? [String: Any])?["values"] as? [Any] {
            return "[" + array.map { text($0) }.joined(separator: ", ") + "]"
        }
        if let list = (value["kvlistValue"] as? [String: Any])?["values"] {
            return "{" + attributes(list).map { "\($0.key): \($0.value)" }
                .joined(separator: ", ") + "}"
        }
        if let bytes = value["bytesValue"] as? String { return bytes }
        return ""
    }
}
