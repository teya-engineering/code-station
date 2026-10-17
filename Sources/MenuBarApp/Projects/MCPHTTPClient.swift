import Foundation

// Just enough of MCP's streamable HTTP transport to call a tool on a server the app runs
// itself: initialise once, keep the session the server hands back, and call tools on it.
// A server that was restarted forgets the session and answers 404 (or 400, depending on
// the version), which earns one fresh initialise before the call is tried again.
actor MCPHTTPClient {
    struct ToolResult: Equatable, Sendable {
        let text: String
        let isError: Bool
    }

    enum Failure: LocalizedError, Equatable {
        case http(Int)
        case rpc(String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .http(let status): "The Grafana MCP server answered HTTP \(status)."
            case .rpc(let message): message
            case .unreadable: "The Grafana MCP server's answer could not be read."
            }
        }
    }

    private let endpoint: URL
    private let session: URLSession
    private var sessionID: String?
    private var protocolVersion = "2025-03-26"
    private var nextID = 1

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func callTool(_ name: String, argumentsJSON: Data) async throws -> ToolResult {
        if sessionID == nil { try await initialize() }
        do {
            return try await toolCall(name, argumentsJSON: argumentsJSON)
        } catch Failure.http(let status) where status == 404 || status == 400 {
            sessionID = nil
            try await initialize()
            return try await toolCall(name, argumentsJSON: argumentsJSON)
        }
    }

    func prepare() async throws {
        if sessionID == nil { try await initialize() }
    }

    private func initialize() async throws {
        let params: [String: Any] = [
            "protocolVersion": protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "code-station", "version": "1"],
        ]
        let (result, session) = try await request(method: "initialize", params: params)
        sessionID = session
        if let version = result["protocolVersion"] as? String { protocolVersion = version }
        try await notify("notifications/initialized")
    }

    private func toolCall(_ name: String, argumentsJSON: Data) async throws -> ToolResult {
        let arguments = (try? JSONSerialization.jsonObject(with: argumentsJSON)) ?? [String: Any]()
        let (result, _) = try await request(method: "tools/call",
                                            params: ["name": name, "arguments": arguments])
        let blocks = result["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return ToolResult(text: text, isError: result["isError"] as? Bool ?? false)
    }

    private func request(method: String, params: [String: Any]) async throws
        -> (result: [String: Any], sessionID: String?) {
        let id = nextID
        nextID += 1
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ])
        let (data, response) = try await session.data(for: post(body))
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadable }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let message = contentType.contains("text/event-stream")
            ? Self.eventStreamMessage(data, id: id)
            : (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let message else { throw Failure.unreadable }
        if let error = message["error"] as? [String: Any] {
            throw Failure.rpc(error["message"] as? String ?? "The Grafana MCP server reported an error.")
        }
        guard let result = message["result"] as? [String: Any] else { throw Failure.unreadable }
        return (result, http.value(forHTTPHeaderField: "Mcp-Session-Id"))
    }

    private func notify(_ method: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method])
        let (_, response) = try await session.data(for: post(body))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private func post(_ body: Data) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        return request
    }

    // An event-stream reply can carry notifications before the answer, so the answer is
    // the data line whose id matches the request.
    private static func eventStreamMessage(_ data: Data, id: Int) -> [String: Any]? {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        for line in lines where line.hasPrefix("data:") {
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard let message = (try? JSONSerialization.jsonObject(with: Data(payload.utf8)))
                    as? [String: Any] else { continue }
            if (message["id"] as? Int) == id { return message }
        }
        return nil
    }
}
