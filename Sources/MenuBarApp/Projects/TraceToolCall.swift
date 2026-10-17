import Foundation

// A trace the agent fetched from Grafana: a Tempo request through Grafana's datasource
// proxy, or a proxied Tempo tool that names a traceId. Only servers following the app's
// "grafana-" naming count, as for Loki and Prometheus results.
struct TraceToolCall: Equatable, Sendable {
    static let title = "Fetched trace"

    let server: String
    let environment: String?
    let traceID: String?

    init?(tool: ToolUse) {
        let parts = tool.name.components(separatedBy: "__")
        guard parts.count == 3, parts[0] == "mcp",
              parts[1].hasPrefix(Grafana.namePrefix) else { return nil }
        let input = (try? JSONSerialization.jsonObject(with: Data(tool.input.utf8)))
            as? [String: Any] ?? [:]
        if parts[2] == "grafana_api_request" {
            guard let endpoint = input["endpoint"] as? String,
                  let traceID = Self.traceID(inEndpoint: endpoint) else { return nil }
            self.traceID = traceID
        } else if parts[2].lowercased().contains("trace") {
            let key = input.keys.sorted().first {
                $0.lowercased().contains("trace") && $0.lowercased().contains("id")
            }
            // A TraceQL search or a docs lookup names no trace, so it is not one.
            guard let traceID = key.flatMap({ input[$0] as? String })
                .flatMap(TraceInput.traceID(from:)) else { return nil }
            self.traceID = traceID
        } else {
            return nil
        }
        server = parts[1]
        environment = Grafana.environment(from: parts[1])
    }

    // The instance rather than the bare environment, as for Loki and Prometheus results.
    var argument: String { String(server.dropFirst(Grafana.namePrefix.count)) }

    // "/api/datasources/proxy/uid/<uid>/api/traces/<id>", or the v2 "…/api/v2/traces/<id>",
    // with or without a query string.
    static func traceID(inEndpoint endpoint: String) -> String? {
        let path = endpoint.split(separator: "?", maxSplits: 1).first.map(String.init) ?? endpoint
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 7, parts[0] == "api", parts[1] == "datasources",
              parts[2] == "proxy", parts[3] == "uid", parts[5] == "api" else { return nil }
        let rest = Array(parts[6...])
        let id: String
        if rest.count == 2, rest[0] == "traces" {
            id = rest[1]
        } else if rest.count == 3, rest[0] == "v2", rest[1] == "traces" {
            id = rest[2]
        } else {
            return nil
        }
        return TraceInput.isTraceID(id) ? id.lowercased() : nil
    }
}

enum TraceRendering: Equatable, Sendable {
    case trace(TraceToolCall, Trace)
    // Cut by the transcript's cap, so it cannot be drawn from what was kept.
    case truncated(TraceToolCall)
}

extension TraceToolCall {
    static func rendered(_ tool: ToolUse) -> TraceRendering? {
        guard !tool.isError, let text = tool.result,
              let call = TraceToolCall(tool: tool) else { return nil }
        if case .trace(let trace) = TraceParser.parse(text) { return .trace(call, trace) }
        if text.hasSuffix(StreamEvent.truncationMarker), call.traceID != nil {
            return .truncated(call)
        }
        return nil
    }
}
