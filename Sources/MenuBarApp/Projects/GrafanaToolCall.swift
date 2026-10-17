import Foundation

// A Grafana MCP query the agent made, read back from the call's own input. Claude names
// MCP tools "mcp__<server>__<tool>", and only servers following the "grafana-" naming the
// app uses for Grafana are treated as Grafana, so a look-alike tool elsewhere is left be.
struct GrafanaToolCall: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case lokiLogs, prometheus }

    let kind: Kind
    let server: String
    let environment: String?
    let datasourceUID: String?
    let query: String
    let start: String?
    let end: String?
    let queryType: String?
    let input: String
    let toolName: String

    init?(tool: ToolUse) {
        let parts = tool.name.components(separatedBy: "__")
        guard parts.count == 3, parts[0] == "mcp",
              parts[1].hasPrefix(Grafana.namePrefix) else { return nil }
        let kind: Kind
        switch parts[2] {
        case "query_loki_logs": kind = .lokiLogs
        case "query_prometheus": kind = .prometheus
        default: return nil
        }
        guard let input = (try? JSONSerialization.jsonObject(with: Data(tool.input.utf8)))
                as? [String: Any] else { return nil }
        let queryKey = kind == .lokiLogs ? "logql" : "expr"
        guard let query = input[queryKey] as? String, !query.isEmpty else { return nil }

        self.kind = kind
        server = parts[1]
        environment = Grafana.environment(from: parts[1])
        datasourceUID = input["datasourceUid"] as? String
        self.query = query
        start = input[kind == .lokiLogs ? "startRfc3339" : "startTime"] as? String
        end = input[kind == .lokiLogs ? "endRfc3339" : "endTime"] as? String
        queryType = input["queryType"] as? String
        self.input = tool.input
        toolName = parts[2]
    }

    var title: String {
        switch kind {
        case .lokiLogs: "Queried Loki"
        case .prometheus: "Queried Prometheus"
        }
    }

    // The instance rather than the bare environment: "cde-dev" and "platform-dev" are both
    // "dev", and which Grafana answered is what a reader needs.
    var argument: String { String(server.dropFirst(Grafana.namePrefix.count)) }
}

struct GrafanaRendering: Equatable, Sendable {
    let call: GrafanaToolCall
    let result: GrafanaToolResult
    // The site file's service whose selector the query used, when one did.
    let service: SiteDefaults.Service?

    init(call: GrafanaToolCall, result: GrafanaToolResult, service: SiteDefaults.Service? = nil) {
        self.call = call
        self.result = result
        self.service = service
    }
}

extension GrafanaToolCall {
    static func rendered(_ tool: ToolUse, services: [SiteDefaults.Service] = []) -> GrafanaRendering? {
        guard !tool.isError, let text = tool.result,
              let call = GrafanaToolCall(tool: tool) else { return nil }
        let service = services.first { $0.matches(call) }
        guard let result = GrafanaToolResult.parse(text, levelField: service?.levelField) else { return nil }
        return GrafanaRendering(call: call, result: result, service: service)
    }
}
