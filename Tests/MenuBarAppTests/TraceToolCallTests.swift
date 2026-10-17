import Foundation
import Testing
@testable import MenuBarApp

struct TraceToolCallTests {
    static let id = "0af7651916cd43dd8448eb211c80319c"

    static func tool(_ name: String, _ input: [String: Any], result: String? = nil,
                     isError: Bool = false) throws -> ToolUse {
        let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        var tool = ToolUse(id: "call-1", name: name, input: String(decoding: data, as: UTF8.self))
        tool.result = result
        tool.isError = isError
        return tool
    }

    @Test func recognisesATempoRequestThroughGrafana() throws {
        let call = try #require(TraceToolCall(tool: Self.tool(
            "mcp__grafana-edge-prd__grafana_api_request",
            ["endpoint": "/api/datasources/proxy/uid/TEMPO-1/api/traces/\(Self.id)"])))
        #expect(call.server == "grafana-edge-prd")
        #expect(call.environment == "prd")
        #expect(call.traceID == Self.id)
        #expect(call.argument == "edge-prd")
    }

    @Test func readsTheTraceIdOutOfEachTracePath() {
        #expect(TraceToolCall.traceID(inEndpoint: "/api/datasources/proxy/uid/T/api/v2/traces/\(Self.id)") == Self.id)
        #expect(TraceToolCall.traceID(inEndpoint: "/api/datasources/proxy/uid/T/api/traces/\(Self.id.uppercased())?start=1") == Self.id)
        #expect(TraceToolCall.traceID(inEndpoint: "/api/datasources/proxy/uid/T/api/search?tags=x") == nil)
        #expect(TraceToolCall.traceID(inEndpoint: "/api/dashboards/uid/abc") == nil)
    }

    @Test func recognisesAProxiedTempoTool() throws {
        let call = try #require(TraceToolCall(tool: Self.tool(
            "mcp__grafana-non-platform-dev__tempo_get-trace", ["traceId": Self.id])))
        #expect(call.traceID == Self.id)
        #expect(call.environment == "dev")
        #expect(call.argument == "non-platform-dev")
    }

    @Test func leavesOtherCallsAlone() throws {
        #expect(TraceToolCall(tool: try Self.tool("mcp__grafana-edge-prd__grafana_api_request",
                                                  ["endpoint": "/api/org"])) == nil)
        #expect(TraceToolCall(tool: try Self.tool("mcp__grafana-edge-prd__query_loki_logs",
                                                  ["logql": "{a=\"b\"}"])) == nil)
        #expect(TraceToolCall(tool: try Self.tool("mcp__other__get_trace", ["traceId": Self.id])) == nil)
    }

    @Test func leavesTraceQLSearchesAndOtherTempoToolsAlone() throws {
        #expect(TraceToolCall(tool: try Self.tool("mcp__grafana-edge-prd__tempo_traceql-search",
                                                  ["query": "{status=error}"])) == nil)
        #expect(TraceToolCall(tool: try Self.tool("mcp__grafana-edge-prd__tempo_get-trace",
                                                  ["traceId": "not-an-id"])) == nil)
    }

    @Test func drawsAResultThatParsesAsATrace() throws {
        let tool = try Self.tool("mcp__grafana-edge-prd__grafana_api_request",
                                 ["endpoint": "/api/datasources/proxy/uid/T/api/traces/\(Self.id)"],
                                 result: TraceParserTests.v2)
        guard case .trace(let call, let trace)? = TraceToolCall.rendered(tool) else {
            Issue.record("expected a drawn trace")
            return
        }
        #expect(call.server == "grafana-edge-prd")
        #expect(trace.traceID == Self.id)
    }

    @Test func offersToReloadACutOffResult() throws {
        let cut = String(TraceParserTests.v2.prefix(200)) + StreamEvent.truncationMarker
        let tool = try Self.tool("mcp__grafana-edge-prd__grafana_api_request",
                                 ["endpoint": "/api/datasources/proxy/uid/T/api/traces/\(Self.id)"],
                                 result: cut)
        guard case .truncated(let call)? = TraceToolCall.rendered(tool) else {
            Issue.record("expected a truncated trace")
            return
        }
        #expect(call.traceID == Self.id)
    }

    @Test func fallsBackForFailuresAndOtherAnswers() throws {
        let endpoint = ["endpoint": "/api/datasources/proxy/uid/T/api/traces/\(Self.id)"]
        let name = "mcp__grafana-edge-prd__grafana_api_request"
        #expect(TraceToolCall.rendered(try Self.tool(name, endpoint, result: "boom", isError: true)) == nil)
        #expect(TraceToolCall.rendered(try Self.tool(name, endpoint, result: "not a trace")) == nil)
        #expect(TraceToolCall.rendered(try Self.tool(name, endpoint, result: nil)) == nil)
    }
}
