import Foundation

// Asking a Grafana MCP server for one trace: find its Tempo datasource, then fetch the
// trace through Grafana's datasource proxy. The call itself is handed in, so this is
// tested without a server and the app hands it the runner's client.
enum TraceFetcher {
    typealias Call = @Sendable (String, Data) async throws -> MCPHTTPClient.ToolResult

    struct Datasource: Equatable, Sendable {
        let uid: String
        let name: String
    }

    enum Outcome: Equatable, Sendable {
        case found(Trace, Datasource)
        case notFound
        case noDatasource
        case unreadable(String)
        case failed(String)
    }

    static func fetch(traceID: String, datasource known: Datasource?, call: Call) async -> Outcome {
        do {
            let datasource: Datasource
            if let known {
                datasource = known
            } else if let found = try await lookUp(type: "tempo", call: call) {
                datasource = found
            } else {
                return .noDatasource
            }
            let reply = try await call("grafana_api_request",
                                       arguments(traceID: traceID, datasourceUID: datasource.uid))
            // A remembered datasource can be gone since it was looked up; Grafana says so,
            // and one fresh lookup is cheaper than calling the trace missing. An older
            // mcp-grafana reports Grafana's 404 as an error, a newer one in its envelope.
            if known != nil, mentionsMissingDatasource(reply.text),
               reply.isError || status(of: reply.text) == 404 {
                return await fetch(traceID: traceID, datasource: nil, call: call)
            }
            if reply.isError {
                return looksNotFound(reply.text) ? .notFound : .failed(reply.text)
            }
            switch TraceParser.parse(reply.text) {
            case .trace(let trace): return .found(trace, datasource)
            case .empty: return .notFound
            case .unreadable:
                // The status is read from the envelope, never from the body: a trace's own
                // timestamps are full of digits like 404.
                if status(of: reply.text) == 404 || reply.text.lowercased().contains("trace not found") {
                    return .notFound
                }
                return .unreadable(String(reply.text.prefix(2_000)))
            }
        } catch {
            // A thrown error is the MCP server or its transport failing, a missing tool
            // among them, and says nothing about whether the trace exists.
            return .failed(error.localizedDescription)
        }
    }

    static func lookUp(type: String, call: Call) async throws -> Datasource? {
        let arguments = try JSONSerialization.data(withJSONObject: ["type": type, "limit": 100],
                                                   options: [.sortedKeys])
        let reply = try await call("list_datasources", arguments)
        guard !reply.isError else { throw MCPHTTPClient.Failure.rpc(reply.text) }
        return datasource(ofType: type, in: reply.text)
    }

    // The datasource list in either shape mcp-grafana has answered with: a bare array, or
    // an object holding it under "datasources". Of several of one type, Grafana's default
    // comes first, then the one named for the type itself, as "loki" is beside audit-loki
    // and loki-combined; the rest are told apart by name, so the same one is chosen every
    // time.
    static func datasource(ofType type: String, in text: String) -> Datasource? {
        let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
        let list = (object as? [[String: Any]])
            ?? ((object as? [String: Any])?["datasources"] as? [[String: Any]])
            ?? []
        let candidates = list.compactMap { entry -> (datasource: Datasource, rank: Int)? in
            guard (entry["type"] as? String)?.lowercased() == type.lowercased(),
                  let uid = entry["uid"] as? String, !uid.isEmpty else { return nil }
            let datasource = Datasource(uid: uid, name: entry["name"] as? String ?? uid)
            let rank = entry["isDefault"] as? Bool == true ? 0
                : datasource.name.lowercased() == type.lowercased() ? 1 : 2
            return (datasource, rank)
        }
        return candidates.min {
            $0.rank != $1.rank ? $0.rank < $1.rank
                : $0.datasource.name.localizedStandardCompare($1.datasource.name) == .orderedAscending
        }?.datasource
    }

    // Tempo answers this path in protobuf unless asked for JSON.
    static func arguments(traceID: String, datasourceUID: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "endpoint": endpoint(traceID: traceID, datasourceUID: datasourceUID),
            "method": "GET",
            "headers": ["Accept": "application/json"],
        ], options: [.sortedKeys])
    }

    static func endpoint(traceID: String, datasourceUID: String) -> String {
        "/api/datasources/proxy/uid/\(datasourceUID)/api/traces/\(traceID)"
    }

    // Tempo's own answer for a trace it does not hold: "trace not found", or a bare 404
    // from the proxied request that is not Grafana missing the datasource.
    private static func looksNotFound(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("trace not found")
            || (lower.contains("404") && !mentionsMissingDatasource(text))
    }

    private static func mentionsMissingDatasource(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("data source not found") || lower.contains("datasource not found")
            || lower.contains("unable to find datasource")
    }

    // The HTTP status in mcp-grafana's envelope, {"status": 404, "headers": …, "data": …}.
    private static func status(of text: String) -> Int? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                as? [String: Any], object["data"] != nil else { return nil }
        return object["status"] as? Int
    }
}
