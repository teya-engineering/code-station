import Foundation

// A span's own logs: its service's selector filtered to the traceId, read from the Grafana
// that holds that service's logs, over the trace's window with a minute either side for
// lines written a little before or after the spans that caused them.
enum TraceSpanLogs {
    enum Plan: Equatable {
        case run(server: String, query: String, start: Date, end: Date,
                 service: SiteDefaults.Service)
        case unavailable(String)
    }

    static func service(for span: Trace.Span,
                        in services: [SiteDefaults.Service]) -> SiteDefaults.Service? {
        services.first { $0.traceName == span.service }
    }

    static func plan(span: Trace.Span, trace: Trace, environment: String,
                     services: [SiteDefaults.Service]) -> Plan {
        guard let service = service(for: span, in: services) else {
            return .unavailable("No service in the site file is called \(span.service).")
        }
        guard let scope = service.scope else {
            return .unavailable("\(service.name) has no scope in the site file, so the Grafana holding its logs is not known.")
        }
        return .run(server: Grafana.serverName(scope: scope, environment: environment),
                    query: GrafanaQueryEdit.traceQuery(selector: service.lokiSelector,
                                                       traceID: trace.traceID),
                    start: Date(timeIntervalSince1970: Double(trace.startNanos) / 1_000_000_000 - 60),
                    end: Date(timeIntervalSince1970: Double(trace.endNanos) / 1_000_000_000 + 60),
                    service: service)
    }

    // The call the Grafana runner runs, written as if the agent had made it, so a span's
    // logs page, re-run and pivot like any other Loki result.
    static func toolUse(id: String, server: String, datasourceUID: String, query: String,
                        start: Date, end: Date) -> ToolUse {
        let input: [String: Any] = [
            "datasourceUid": datasourceUID,
            "logql": query,
            "startRfc3339": GrafanaQueryEdit.rfc3339(start),
            "endRfc3339": GrafanaQueryEdit.rfc3339(end),
            "limit": GrafanaQueryEdit.pageLimit,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        var tool = ToolUse(id: id, name: "mcp__\(server)__query_loki_logs",
                           input: String(decoding: data, as: UTF8.self))
        tool.result = "{}"
        return tool
    }

    static func toolID(traceID: String, spanID: String, environment: String) -> String {
        "trace-logs-\(environment)-\(traceID)-\(spanID)"
    }
}
