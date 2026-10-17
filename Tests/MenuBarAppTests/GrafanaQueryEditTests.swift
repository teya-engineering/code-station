import Foundation
import Testing
@testable import MenuBarApp

struct GrafanaQueryEditTests {
    private let now = Date(timeIntervalSince1970: 1_790_938_800) // 2026-10-02T11:00:00Z

    private func call(_ name: String, _ input: [String: Any]) throws -> GrafanaToolCall {
        let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        var tool = ToolUse(id: "c", name: name, input: String(decoding: data, as: UTF8.self))
        tool.result = "{}"
        return try #require(GrafanaToolCall(tool: tool))
    }

    private func object(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private var loki: GrafanaToolCall {
        get throws {
            try call("mcp__grafana-cde-dev__query_loki_logs",
                     ["datasourceUid": "L", "logql": "{a=\"b\"}", "limit": 50,
                      "startRfc3339": "2026-10-02T10:00:00Z", "endRfc3339": "2026-10-02T10:30:00Z"])
        }
    }

    @Test func keepsTheWindowAndOtherArgumentsForARerun() throws {
        let args = try object(GrafanaQueryEdit.arguments(for: try loki, query: "{a=\"c\"}",
                                                         window: .same, now: now))
        #expect(args["logql"] as? String == "{a=\"c\"}")
        #expect(args["datasourceUid"] as? String == "L")
        #expect(args["startRfc3339"] as? String == "2026-10-02T10:00:00Z")
        #expect(args["endRfc3339"] as? String == "2026-10-02T10:30:00Z")
        #expect(args["limit"] as? Int == 1000)
    }

    @Test func endsALastWindowNow() throws {
        let args = try object(GrafanaQueryEdit.arguments(for: try loki, query: "{a=\"b\"}",
                                                         window: .last(seconds: 3600), now: now))
        #expect(args["startRfc3339"] as? String == "2026-10-02T10:00:00.000Z")
        #expect(args["endRfc3339"] as? String == "2026-10-02T11:00:00.000Z")
    }

    @Test func surroundsAnEntry() throws {
        let entry = Date(timeIntervalSince1970: 1_790_935_210.5)
        let args = try object(GrafanaQueryEdit.arguments(for: try loki, query: "{a=\"b\"}",
                                                         window: .around(entry), now: now))
        #expect(args["startRfc3339"] as? String == "2026-10-02T10:00:05.500Z")
        #expect(args["endRfc3339"] as? String == "2026-10-02T10:00:40.500Z")
    }

    @Test func setsPrometheusTimesAndExpression() throws {
        let prom = try call("mcp__grafana-cde-dev__query_prometheus",
                            ["datasourceUid": "P", "expr": "up", "queryType": "range",
                             "startTime": "2026-10-02T10:00:00Z", "endTime": "2026-10-02T10:30:00Z",
                             "stepSeconds": 60])
        let args = try object(GrafanaQueryEdit.arguments(for: prom, query: "up{job=\"x\"}",
                                                         window: .last(seconds: 900), now: now))
        #expect(args["expr"] as? String == "up{job=\"x\"}")
        #expect(args["startTime"] as? String == "2026-10-02T10:45:00.000Z")
        #expect(args["endTime"] as? String == "2026-10-02T11:00:00.000Z")
        #expect(args["stepSeconds"] as? Int == 60)
        #expect(args["limit"] == nil)
    }

    @Test func buildsAValidSelectorFromLabelsWithQuotes() {
        let selector = GrafanaQueryEdit.aroundSelector(labels: ["pod": "api-1", "msg": #"say "hi" \ bye"#])
        #expect(selector == #"{msg="say \"hi\" \\ bye", pod="api-1"}"#)
    }

    @Test func buildsATraceQuery() {
        #expect(GrafanaQueryEdit.traceQuery(selector: #"{tki="x"}"#, traceID: #"ab"c"#)
                == #"{tki="x"} |= "ab\"c""#)
    }

    @Test func labelsWindows() {
        #expect(GrafanaQueryWindow.same.label == "same window")
        #expect(GrafanaQueryWindow.last(seconds: 3600).label == "last 1h")
        #expect(GrafanaQueryWindow.last(seconds: 300).label == "last 5m")
    }

    @Test func writesNanosecondTimes() {
        #expect(GrafanaQueryEdit.rfc3339(nanoseconds: 1_790_935_200_123_456_789)
                == "2026-10-02T10:00:00.123456789Z")
    }
}
