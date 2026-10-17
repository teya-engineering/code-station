import Foundation
import Testing
@testable import MenuBarApp

struct GrafanaToolResultTests {
    private func logs(_ text: String, levelField: String? = nil) throws -> [GrafanaToolResult.LogEntry] {
        guard case .logs(let entries, _)? = GrafanaToolResult.parse(text, levelField: levelField) else {
            Issue.record("not logs: \(text)")
            return []
        }
        return entries
    }

    @Test func readsALogfmtLineWithAnUnquotedMessage() throws {
        let text = #"""
        {"data":[{"timestamp":"\"1790935200123000000\"",
          "line":"time=10:00:00 level=ERROR logger=c.e.Pay message=Payment failed for order 42",
          "labels":{"app":"orders"},
          "structuredMetadata":{"detected_level":"error"},
          "parsed":{"level":"ERROR","logger":"c.e.Pay","message":"Payment"}}],
         "metadata":{}}
        """#
        let entry = try #require(try logs(text).first)

        #expect(abs((entry.date?.timeIntervalSince1970 ?? 0) - 1_790_935_200.123) < 0.000_001)
        #expect(entry.level == "ERROR")
        #expect(entry.message == "Payment failed for order 42")
        #expect(entry.labels == ["app": "orders"])
        #expect(entry.fields["logger"] == "c.e.Pay")
        #expect(entry.metadata == ["detected_level": "error"])
    }

    @Test func readsAQuotedLogfmtMessageFromTheParsedFields() throws {
        let text = #"""
        {"data":[{"timestamp":"\"1790935200000000000\"",
          "line":"level=info msg=\"cache warmed\" took=3ms",
          "labels":{},"parsed":{"level":"info","msg":"cache warmed","took":"3ms"}}]}
        """#
        #expect(try logs(text).first?.message == "cache warmed")
    }

    @Test func readsAJSONLine() throws {
        let text = #"""
        {"data":[{"timestamp":"\"1790935200000000000\"",
          "line":"{\"severity\":\"WARN\",\"message\":\"slow query\"}",
          "labels":{},"parsed":{"severity":"WARN","message":"slow query"}}]}
        """#
        let entry = try #require(try logs(text).first)
        #expect(entry.level == "WARN")
        #expect(entry.message == "slow query")
    }

    @Test func showsOnlyTheFirstLineOfAStackTraceInTheMessage() throws {
        let text = #"""
        {"data":[{"timestamp":"\"1790935200000000000\"",
          "line":"level=ERROR message=Boom\n\tat a.B.c(B.java:1)\n\tat a.B.d(B.java:2)",
          "labels":{},"parsed":{"level":"ERROR"}}]}
        """#
        let entry = try #require(try logs(text).first)
        #expect(entry.message == "Boom")
        #expect(entry.line.contains("B.java:2"))
    }

    @Test func prefersTheConfiguredLevelField() throws {
        let text = #"""
        {"data":[{"timestamp":"\"1790935200000000000\"","line":"x",
          "labels":{},"parsed":{"level":"info","sev":"CRIT"}}]}
        """#
        #expect(try logs(text, levelField: "sev").first?.level == "CRIT")
    }

    @Test func fallsBackToDetectedLevelButNotUnknown() throws {
        let detected = #"""
        {"data":[{"timestamp":"\"1790935200000000000\"","line":"x","labels":{},
          "structuredMetadata":{"detected_level":"warn"}}]}
        """#
        let unknown = #"""
        {"data":[{"timestamp":"\"1790935200000000000\"","line":"x","labels":{},
          "structuredMetadata":{"detected_level":"unknown"}}]}
        """#
        #expect(try logs(detected).first?.level == "WARN")
        #expect(try logs(unknown).first?.level == nil)
    }

    @Test func keepsAnUnexpectedTimestampAsText() throws {
        let text = #"{"data":[{"timestamp":"yesterday","line":"x","labels":{}}]}"#
        let entry = try #require(try logs(text).first)
        #expect(entry.date == nil)
        #expect(entry.rawTimestamp == "yesterday")
    }

    @Test func readsALokiMetricResult() throws {
        let text = #"{"data":[{"timestamp":"1790935200.000","value":"12","labels":{"level":"error"}}]}"#
        guard case .samples(let samples, false)? = GrafanaToolResult.parse(text) else {
            Issue.record("not samples"); return
        }
        #expect(samples == [.init(id: 0, labels: ["level": "error"],
                                  date: Date(timeIntervalSince1970: 1_790_935_200), value: "12")])
    }

    @Test func readsAPrometheusInstantResult() throws {
        let text = #"{"data":[{"metric":{"job":"api"},"value":[1790935200,"0.5"]}]}"#
        guard case .samples(let samples, false)? = GrafanaToolResult.parse(text) else {
            Issue.record("not samples"); return
        }
        #expect(samples.first?.value == "0.5")
        #expect(samples.first?.labels == ["job": "api"])
    }

    @Test func readsAPrometheusRangeResultKeepingValuesThatAreNotNumbersAsText() throws {
        let text = #"""
        {"data":[{"metric":{"job":"api"},
          "values":[[1790935200,"1"],[1790935260,"NaN"],[1790935320,"+Inf"],[1790935380,"4"]]}]}
        """#
        guard case .series(let series, false)? = GrafanaToolResult.parse(text) else {
            Issue.record("not series"); return
        }
        #expect(series.first?.points.map(\.raw) == ["1", "NaN", "+Inf", "4"])
        #expect(series.first?.points.map(\.value) == [1, nil, nil, 4])
    }

    @Test func readsAnEmptyResult() {
        #expect(GrafanaToolResult.parse(#"{"data":[]}"#) == .empty)
    }

    @Test func rejectsAnythingElse() {
        #expect(GrafanaToolResult.parse("not json") == nil)
        #expect(GrafanaToolResult.parse(#"{"error":"bad query"}"#) == nil)
        #expect(GrafanaToolResult.parse(#"{"data":[{"something":"else"}]}"#) == nil)
    }

    @Test func recoversTheCompleteLinesOfATruncatedResult() throws {
        let complete = #"{"timestamp":"\"1790935200000000000\"","line":"level=ERROR message=first {x}","labels":{}}"#
        let cut = #"{"timestamp":"\"1790935201000000000\"","line":"level=ERROR message=sec"#
        let text = #"{"data":["# + complete + "," + cut + StreamEvent.truncationMarker

        guard case .logs(let entries, let truncated)? = GrafanaToolResult.parse(text) else {
            Issue.record("not logs"); return
        }
        #expect(truncated)
        #expect(entries.map(\.message) == ["first {x}"])
    }

    @Test func givesUpOnATruncatedResultWithNothingComplete() {
        let text = #"{"data":[{"line":"half"# + StreamEvent.truncationMarker
        #expect(GrafanaToolResult.parse(text) == nil)
    }

    @Test func treatsTheMarkerAsTruncationOnlyAtTheEnd() throws {
        let text = #"{"data":[{"timestamp":"\"1790935200000000000\"","line":"says \n… truncated inside","labels":{}}]}"#
        guard case .logs(_, let truncated)? = GrafanaToolResult.parse(text) else {
            Issue.record("not logs"); return
        }
        #expect(!truncated)
    }
}
