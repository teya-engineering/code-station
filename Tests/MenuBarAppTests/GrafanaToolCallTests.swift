import Foundation
import Testing
@testable import MenuBarApp

struct GrafanaToolCallTests {
    private func tool(_ name: String, _ input: [String: Any],
                      result: String? = "{}", isError: Bool = false) throws -> ToolUse {
        let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        var tool = ToolUse(id: "call-1", name: name, input: String(decoding: data, as: UTF8.self))
        tool.result = result
        tool.isError = isError
        return tool
    }

    @Test func recognisesALokiQuery() throws {
        let call = try #require(GrafanaToolCall(tool: tool(
            "mcp__grafana-cde-dev__query_loki_logs",
            ["datasourceUid": "LOKI-1", "logql": "{app=\"orders\"} |= \"timeout\"",
             "startRfc3339": "2026-10-02T10:00:00Z", "endRfc3339": "2026-10-02T11:00:00Z",
             "limit": 100])))

        #expect(call.kind == .lokiLogs)
        #expect(call.server == "grafana-cde-dev")
        #expect(call.environment == "dev")
        #expect(call.datasourceUID == "LOKI-1")
        #expect(call.query == "{app=\"orders\"} |= \"timeout\"")
        #expect(call.start == "2026-10-02T10:00:00Z")
        #expect(call.end == "2026-10-02T11:00:00Z")
        #expect(call.title == "Queried Loki")
        #expect(call.argument == "cde-dev")
    }

    @Test func recognisesAPrometheusQuery() throws {
        let call = try #require(GrafanaToolCall(tool: tool(
            "mcp__grafana-cde-prd__query_prometheus",
            ["datasourceUid": "PROM-1", "expr": "up", "queryType": "range",
             "startTime": "2026-10-02T10:00:00Z", "endTime": "2026-10-02T11:00:00Z",
             "stepSeconds": 60])))

        #expect(call.kind == .prometheus)
        #expect(call.environment == "prd")
        #expect(call.query == "up")
        #expect(call.queryType == "range")
        #expect(call.start == "2026-10-02T10:00:00Z")
        #expect(call.title == "Queried Prometheus")
    }

    @Test func namesAServerWithoutAnEnvironmentByItsInstance() throws {
        let call = try #require(GrafanaToolCall(tool: tool(
            "mcp__grafana-shared__query_loki_logs", ["logql": "{a=\"b\"}"])))

        #expect(call.environment == nil)
        #expect(call.argument == "shared")
    }

    @Test func ignoresTheSameToolOnAServerThatIsNotGrafana() throws {
        #expect(GrafanaToolCall(tool: try tool("mcp__loki-local__query_loki_logs",
                                               ["logql": "{a=\"b\"}"])) == nil)
    }

    @Test func ignoresOtherGrafanaTools() throws {
        #expect(GrafanaToolCall(tool: try tool("mcp__grafana-cde-dev__search_dashboards",
                                               ["query": "x"])) == nil)
    }

    @Test func ignoresACallWithoutAQuery() throws {
        #expect(GrafanaToolCall(tool: try tool("mcp__grafana-cde-dev__query_loki_logs",
                                               ["datasourceUid": "LOKI-1"])) == nil)
    }

    @Test func relabelsTheRow() throws {
        let presentation = ToolPresentation(
            tool: try tool("mcp__grafana-cde-dev__query_loki_logs", ["logql": "{a=\"b\"}"]),
            projectPath: "/tmp/project")

        #expect(presentation.verb == "Queried Loki")
        #expect(presentation.label == "Queried Loki · cde-dev")
    }

    @Test func leavesOtherMCPToolsAlone() throws {
        let presentation = ToolPresentation(
            tool: try tool("mcp__github__get_issue", ["number": 7]),
            projectPath: "/tmp/project")

        #expect(presentation.verb == "mcp__github__get_issue")
    }

    private let oneLine = #"{"data":[{"timestamp":"\"1790935200000000000\"","line":"level=INFO message=ok","labels":{}}]}"#

    @Test func rendersAFinishedQuery() throws {
        let rendered = try #require(GrafanaToolCall.rendered(try tool(
            "mcp__grafana-cde-dev__query_loki_logs", ["logql": "{a=\"b\"}"], result: oneLine)))
        #expect(rendered.result.count == 1)
    }

    @Test func doesNotRenderARunningQuery() throws {
        #expect(GrafanaToolCall.rendered(try tool(
            "mcp__grafana-cde-dev__query_loki_logs", ["logql": "{a=\"b\"}"], result: nil)) == nil)
    }

    @Test func doesNotRenderAFailedQuery() throws {
        #expect(GrafanaToolCall.rendered(try tool(
            "mcp__grafana-cde-dev__query_loki_logs", ["logql": "{a=\"b\"}"],
            result: oneLine, isError: true)) == nil)
    }

    @Test func doesNotRenderAResultItCannotRead() throws {
        #expect(GrafanaToolCall.rendered(try tool(
            "mcp__grafana-cde-dev__query_loki_logs", ["logql": "{a=\"b\"}"],
            result: "parse error at line 1")) == nil)
    }

    @Test func chartsOnlyTheValuesThatAreNumbers() throws {
        let series = GrafanaToolResult.Series(id: 0, labels: ["job": "api"], points: [
            .init(seconds: 1_790_935_200, raw: "1", value: 1),
            .init(seconds: 1_790_935_260, raw: "+Inf", value: nil),
            .init(seconds: 1_790_935_320, raw: "3", value: 3)
        ])
        let spec = try #require(GrafanaResultView.chartSpec([series]))
        #expect(spec.series.first?.values == [1, 3])
    }

    @Test func showsClockTimesOnATwentyFourHourClock() throws {
        let afternoon = Date(timeIntervalSince1970: 1_790_957_703.123)
        #expect(GrafanaResultView.clock(afternoon, in: try #require(TimeZone(identifier: "UTC")))
                == "16:15:03.123")
    }

    @Test func takesTheLevelFieldFromTheMatchingService() throws {
        let service = SiteDefaults.Service(name: "s", lokiSelector: #"{a="b"}"#,
                                           logFormat: .logfmt, levelField: "sev")
        let result = #"{"data":[{"timestamp":"\"1790935200000000000\"","line":"x","labels":{},"parsed":{"level":"info","sev":"CRIT"}}]}"#
        let query = try tool("mcp__grafana-cde-dev__query_loki_logs", ["logql": "{a=\"b\"}"], result: result)

        guard case .logs(let withService, _)? = GrafanaToolCall.rendered(query, services: [service])?.result,
              case .logs(let without, _)? = GrafanaToolCall.rendered(query)?.result else {
            Issue.record("not logs"); return
        }
        #expect(withService.first?.level == "CRIT")
        #expect(without.first?.level == "info")
    }
}
