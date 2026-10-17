import Foundation

enum GrafanaQueryWindow: Equatable, Sendable {
    case same
    case last(seconds: Int)
    case around(Date)

    var label: String {
        switch self {
        case .same: "same window"
        case .last(let seconds):
            seconds % 3600 == 0 ? "last \(seconds / 3600)h" : "last \(seconds / 60)m"
        case .around(let date): "around \(GrafanaResultView.clock(date))"
        }
    }
}

// The arguments for running a query the agent made again, changed the way the person asked:
// a new query, a new window, or a pivot. Everything else the agent sent is kept, so the
// same datasource answers.
enum GrafanaQueryEdit {
    static let windowChoices: [(label: String, seconds: Int)] = [
        ("5m", 300), ("15m", 900), ("1h", 3600), ("6h", 21_600), ("24h", 86_400)
    ]
    static let pageLimit = 1000

    static func arguments(for call: GrafanaToolCall, query: String,
                          window: GrafanaQueryWindow, now: Date) -> Data? {
        guard var args = (try? JSONSerialization.jsonObject(with: Data(call.input.utf8)))
                as? [String: Any] else { return nil }
        let startKey = call.kind == .lokiLogs ? "startRfc3339" : "startTime"
        let endKey = call.kind == .lokiLogs ? "endRfc3339" : "endTime"
        args[call.kind == .lokiLogs ? "logql" : "expr"] = query
        if call.kind == .lokiLogs { args["limit"] = pageLimit }
        switch window {
        case .same:
            break
        case .last(let seconds):
            args[startKey] = rfc3339(now.addingTimeInterval(-Double(seconds)))
            args[endKey] = rfc3339(now)
        case .around(let date):
            args[startKey] = rfc3339(date.addingTimeInterval(-5))
            args[endKey] = rfc3339(date.addingTimeInterval(30))
        }
        return try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
    }

    static func aroundSelector(labels: [String: String]) -> String {
        "{" + labels.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(quoted($0.value))" }
            .joined(separator: ", ") + "}"
    }

    static func traceQuery(selector: String, traceID: String) -> String {
        "\(selector) |= \(quoted(traceID))"
    }

    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    // Loki's own precision. A page boundary written to the millisecond would skip the other
    // lines logged in the same millisecond as the oldest one seen.
    static func rfc3339(nanoseconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        let seconds = formatter.string(from: Date(timeIntervalSince1970: Double(nanoseconds / 1_000_000_000)))
        return String(seconds.dropLast()) + "." + String(format: "%09lld", nanoseconds % 1_000_000_000) + "Z"
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
