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

    @Test func namesSeriesByTheLabelsThatTellThemApart() {
        let shared = ["__name__": "cpu", "job": "rds"]
        let one = GrafanaToolResult.Series(id: 0, labels: shared.merging(["db": "a"]) { $1 }, points: [])
        let two = GrafanaToolResult.Series(id: 1, labels: shared.merging(["db": "b"]) { $1 }, points: [])
        #expect(GrafanaResultView.seriesNames([one, two]) == ["a", "b"])
        #expect(GrafanaResultView.seriesNames([one]) == ["cpu"])

        let three = GrafanaToolResult.Series(id: 2, labels: ["db": "c", "az": "1"], points: [])
        let four = GrafanaToolResult.Series(id: 3, labels: ["db": "d", "az": "2"], points: [])
        #expect(GrafanaResultView.seriesNames([three, four])
                == ["{az=\"1\", db=\"c\"}", "{az=\"2\", db=\"d\"}"])
    }

    @Test func keepsSeriesNamesApartWhenTheirLabelsMatch() {
        let one = GrafanaToolResult.Series(id: 0, labels: ["job": "api"], points: [])
        let two = GrafanaToolResult.Series(id: 1, labels: ["job": "api"], points: [])
        #expect(GrafanaResultView.seriesNames([one, two]) == ["value #1", "value #2"])
    }

    @Test func roundsReadingsToAFewDigits() {
        #expect(GrafanaResultView.reading("10.432824618463847") == "10.433")
        #expect(GrafanaResultView.reading("19.95") == "19.95")
        #expect(GrafanaResultView.reading("1200") == "1200")
        #expect(GrafanaResultView.reading("0.000123456") == "0.000123")
        #expect(GrafanaResultView.reading("0") == "0")
        #expect(GrafanaResultView.reading("+Inf") == "+Inf")
        #expect(GrafanaResultView.reading("NaN") == "NaN")
    }

    @Test func laysSeriesOutAsOneRowPerMoment() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let one = GrafanaToolResult.Series(id: 0, labels: ["db": "a"], points: [
            .init(seconds: 1_790_935_200, raw: "1.5", value: 1.5),
            .init(seconds: 1_790_935_500, raw: "2", value: 2)
        ])
        let two = GrafanaToolResult.Series(id: 1, labels: ["db": "b"], points: [
            .init(seconds: 1_790_935_500, raw: "3", value: 3)
        ])
        let table = GrafanaResultView.SeriesTable([one, two], in: utc)
        #expect(table.names == ["a", "b"])
        #expect(table.rows == [
            .init(time: "10:00:00", readings: ["1.5", nil]),
            .init(time: "10:05:00", readings: ["2", "3"])
        ])
    }

    @Test func showsTheDayWhenARangeCrossesMidnight() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let series = GrafanaToolResult.Series(id: 0, labels: [:], points: [
            .init(seconds: 1_790_985_600 - 60, raw: "1", value: 1),
            .init(seconds: 1_790_985_600, raw: "2", value: 2)
        ])
        let times = GrafanaResultView.SeriesTable([series], in: utc).rows.map(\.time)
        #expect(times == ["Oct 2 23:59:00", "Oct 3 00:00:00"])
    }

    @Test func showsClockTimesOnATwentyFourHourClock() throws {
        let afternoon = Date(timeIntervalSince1970: 1_790_957_703.123)
        #expect(GrafanaResultView.clock(afternoon, in: try #require(TimeZone(identifier: "UTC")))
                == "16:15:03.123")
    }
}
