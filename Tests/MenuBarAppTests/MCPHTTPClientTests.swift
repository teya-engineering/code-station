import Foundation
import Testing
@testable import MenuBarApp

// One handler for the whole suite, so the suite runs its tests one at a time.
final class MCPStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, [String: Any]) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var requests: [(method: String, sessionID: String?)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        } else if let data = request.httpBody {
            body = data
        }
        let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        Self.requests.append((message["method"] as? String ?? "",
                              request.value(forHTTPHeaderField: "Mcp-Session-Id")))
        let (status, headers, data) = Self.handler?(request, message) ?? (500, [:], Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct MCPHTTPClientTests {
    private let endpoint = URL(string: "http://localhost:9/mcp")!

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func reply(_ id: Any?, _ result: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private static var toolResult: [String: Any] { ["content": [["type": "text", "text": "{\"data\":[]}"]]] }

    private func standardServer(sse: Bool = false) {
        MCPStubProtocol.requests = []
        MCPStubProtocol.handler = { _, message in
            let method = message["method"] as? String
            let id = message["id"]
            switch method {
            case "initialize":
                return (200, ["Content-Type": "application/json", "Mcp-Session-Id": "s1"],
                        Self.reply(id, ["protocolVersion": "2025-03-26"]))
            case "notifications/initialized":
                return (202, [:], Data())
            default:
                let json = Self.reply(id, Self.toolResult)
                if sse {
                    let body = "event: message\ndata: " + String(decoding: json, as: UTF8.self) + "\n\n"
                    return (200, ["Content-Type": "text/event-stream"], Data(body.utf8))
                }
                return (200, ["Content-Type": "application/json"], json)
            }
        }
    }

    private let args = Data(#"{"logql":"{a=\"b\"}"}"#.utf8)

    @Test func initialisesThenCallsTheTool() async throws {
        standardServer()
        let client = MCPHTTPClient(endpoint: endpoint, session: session())
        let result = try await client.callTool("query_loki_logs", argumentsJSON: args)
        #expect(result == .init(text: "{\"data\":[]}", isError: false))
        #expect(MCPStubProtocol.requests.map(\.method)
                == ["initialize", "notifications/initialized", "tools/call"])
        #expect(MCPStubProtocol.requests.last?.sessionID == "s1")
    }

    @Test func readsAnEventStreamReply() async throws {
        standardServer(sse: true)
        let client = MCPHTTPClient(endpoint: endpoint, session: session())
        #expect(try await client.callTool("query_loki_logs", argumentsJSON: args).text == "{\"data\":[]}")
    }

    @Test func reusesTheSessionForLaterCalls() async throws {
        standardServer()
        let client = MCPHTTPClient(endpoint: endpoint, session: session())
        _ = try await client.callTool("query_loki_logs", argumentsJSON: args)
        _ = try await client.callTool("query_loki_logs", argumentsJSON: args)
        #expect(MCPStubProtocol.requests.map(\.method)
                == ["initialize", "notifications/initialized", "tools/call", "tools/call"])
    }

    @Test func initialisesAgainWhenTheServerForgotTheSession() async throws {
        standardServer()
        let client = MCPHTTPClient(endpoint: endpoint, session: session())
        _ = try await client.callTool("query_loki_logs", argumentsJSON: args)
        var forgotten = true
        let normal = MCPStubProtocol.handler
        MCPStubProtocol.handler = { request, message in
            if forgotten, message["method"] as? String == "tools/call" {
                forgotten = false
                return (404, [:], Data())
            }
            return normal!(request, message)
        }
        #expect(try await client.callTool("query_loki_logs", argumentsJSON: args).isError == false)
        #expect(MCPStubProtocol.requests.map(\.method).suffix(4)
                == ["tools/call", "initialize", "notifications/initialized", "tools/call"])
    }

    @Test func reportsAJSONRPCError() async throws {
        standardServer()
        let normal = MCPStubProtocol.handler
        MCPStubProtocol.handler = { request, message in
            guard message["method"] as? String == "tools/call" else { return normal!(request, message) }
            let body = try! JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": message["id"] ?? NSNull(),
                "error": ["code": -32602, "message": "bad logql"]])
            return (200, ["Content-Type": "application/json"], body)
        }
        let client = MCPHTTPClient(endpoint: endpoint, session: session())
        await #expect(throws: MCPHTTPClient.Failure.rpc("bad logql")) {
            try await client.callTool("query_loki_logs", argumentsJSON: args)
        }
    }

    @Test func passesThroughAToolError() async throws {
        standardServer()
        let normal = MCPStubProtocol.handler
        MCPStubProtocol.handler = { request, message in
            guard message["method"] as? String == "tools/call" else { return normal!(request, message) }
            return (200, ["Content-Type": "application/json"],
                    Self.reply(message["id"], ["content": [["type": "text", "text": "parse error"]], "isError": true]))
        }
        let client = MCPHTTPClient(endpoint: endpoint, session: session())
        #expect(try await client.callTool("query_loki_logs", argumentsJSON: args)
                == .init(text: "parse error", isError: true))
    }

    @Test func initialisesAgainWhenTheServerRejectsTheSessionAsABadRequest() async throws {
        standardServer()
        let client = MCPHTTPClient(endpoint: endpoint, session: session())
        _ = try await client.callTool("query_loki_logs", argumentsJSON: args)
        var rejected = true
        let normal = MCPStubProtocol.handler
        MCPStubProtocol.handler = { request, message in
            if rejected, message["method"] as? String == "tools/call" {
                rejected = false
                return (400, [:], Data())
            }
            return normal!(request, message)
        }
        #expect(try await client.callTool("query_loki_logs", argumentsJSON: args).isError == false)
    }
}
