import Foundation
import SwiftUI
import Testing
@testable import MenuBarApp

struct TranscriptEvidenceBlocksTests {
    private static let traceID = "0af7651916cd43dd8448eb211c80319c"

    private static let trace = """
        {"traceId":"\(traceID)","title":"Payment times out","server":"grafana-edge-dev","omitted":12,
         "spans":[{"id":"a1","service":"checkout-api","name":"POST /pay","start":0,"duration":2140,
                   "error":true,"message":"upstream timeout"},
                  {"id":"b2","parent":"a1","service":"ledger","name":"INSERT entry","start":12.5,
                   "duration":2101,"error":true,"attributes":{"db.system":"postgresql"}}]}
        """

    @Test func readsATraceTheAgentWroteOut() throws {
        guard case .success(let spec) = TranscriptTraceSpec.parse(Self.trace) else {
            Issue.record("not read"); return
        }
        #expect(spec.title == "Payment times out")
        #expect(spec.server == "grafana-edge-dev")
        #expect(spec.omittedSpans == 12)
        #expect(spec.trace.traceID == Self.traceID)
        #expect(spec.trace.rows.map(\.span.id) == ["a1", "b2"])
        #expect(spec.trace.rows.map(\.depth) == [0, 1])
        #expect(spec.trace.errorCount == 2)
        let ledger = try #require(spec.trace.spans.last)
        #expect(ledger.startNanos == 12_500_000)
        #expect(ledger.durationNanos == 2_101_000_000)
        #expect(ledger.attributes == [Trace.Attribute(key: "db.system", value: "postgresql")])
        #expect(spec.trace.spans.first?.statusMessage == "upstream timeout")
    }

    // A trace past the cap is cut rather than refused, and the cut is counted, so the
    // waterfall never looks whole when it is not.
    @Test func countsTheSpansPastTheCapAsLeftOut() {
        let spans = (0..<(TranscriptTraceSpec.spanLimit + 5)).map {
            #"{"id":"s\#($0)","service":"api","start":\#($0),"duration":1}"#
        }.joined(separator: ",")
        guard case .success(let spec) = TranscriptTraceSpec.parse(#"{"spans":[\#(spans)]}"#) else {
            Issue.record("not read"); return
        }
        #expect(spec.trace.rows.count == TranscriptTraceSpec.spanLimit)
        #expect(spec.omittedSpans == 5)
    }

    @MainActor @Test func placesTheSpansAtTheTracesClockTime() {
        let text = #"{"time":"2026-10-23T14:02:08.240Z","spans":[{"id":"a","service":"api","start":5,"duration":1}]}"#
        guard case .success(let spec) = TranscriptTraceSpec.parse(text) else {
            Issue.record("not read"); return
        }
        #expect(spec.trace.startNanos == 1_792_764_128_245_000_000)
        #expect(String(TraceWaterfallView.startLine(spec.trace).characters) == "Starts in api at "
            + GrafanaResultView.clock(Date(timeIntervalSince1970: 1_792_764_128.245)))
    }

    // Without a clock time the spans count from zero, and the waterfall shows no clock
    // rather than one in 1970.
    @MainActor @Test func aTraceWithoutAClockTimeShowsNone() {
        guard case .success(let spec) = TranscriptTraceSpec.parse(Self.trace) else {
            Issue.record("not read"); return
        }
        #expect(String(TraceWaterfallView.startLine(spec.trace).characters) == "Starts in checkout-api")
    }

    // The agent copies attribute values as the tools gave them, so a status code comes as
    // a number. That must not cost the reader the whole trace.
    @Test func readsAttributesThatAreNotText() throws {
        let text = """
            {"spans":[{"id":"TF4DTVIJeSg=","service":"payments-gateway","start":0,"duration":3,"error":true,
              "attributes":{"http.response.status_code":400,"latency":1.5,"retry":false,
                            "http.route":"/pay","extra":{"a":1},"gone":null}}]}
            """
        guard case .success(let spec) = TranscriptTraceSpec.parse(text) else {
            Issue.record("not read"); return
        }
        let span = try #require(spec.trace.spans.first)
        #expect(span.attributes == [
            Trace.Attribute(key: "http.response.status_code", value: "400"),
            Trace.Attribute(key: "http.route", value: "/pay"),
            Trace.Attribute(key: "latency", value: "1.5"),
            Trace.Attribute(key: "retry", value: "false"),
        ])
    }

    @Test func readsLogFieldsThatAreNotText() throws {
        let text = #"{"lines":[{"message":"rejected","fields":{"status":400,"trace_id":"abc"}}]}"#
        guard case .success(let spec) = TranscriptLogsSpec.parse(text) else {
            Issue.record("not read"); return
        }
        #expect(spec.entries.first?.fields == ["status": "400", "trace_id": "abc"])
    }

    // A block cut off part way still names its trace, so asking for it again asks for
    // the right one.
    @Test func namesTheTraceInABlockThatCannotBeRead() {
        let cut = #"{"traceId":"\#(Self.traceID)","server":"grafana-edge-dev","spans":[{"id":"a1","serv"#
        guard case .failure = TranscriptTraceSpec.parse(cut) else {
            Issue.record("read a cut block"); return
        }
        let named = TranscriptTraceSpec.salvage(cut)
        #expect(named.traceID == Self.traceID)
        #expect(named.server == "grafana-edge-dev")
        #expect(TraceFollowUp.drawAgain(named.traceID, server: named.server)
            .contains("`\(Self.traceID)` could not be read"))
        let nothing = TranscriptTraceSpec.salvage("not json")
        #expect(nothing.traceID == nil && nothing.server == nil)
    }

    @Test func aTraceWithNoUsableSpanIsUnreadable() {
        let unreadable = ["", "not json", #"{"spans":[]}"#,
                          #"{"spans":[{"id":"  ","service":"a","start":0,"duration":1}]}"#]
        for text in unreadable {
            guard case .failure = TranscriptTraceSpec.parse(text) else {
                Issue.record("read \(text)"); continue
            }
        }
    }

    @Test func readsTheLogLinesTheAgentPicked() throws {
        let text = """
            {"title":"ledger errors","server":"grafana-platform-dev","query":"{namespace=\\"ledger\\"}",
             "lines":[{"time":"2026-10-23T14:02:11.418Z","level":"error","service":"ledger",
                       "message":"deadlock detected","fields":{"trace_id":"\(Self.traceID)"}},
                      {"time":"2026-10-23T14:02:12Z","message":"   "}]}
            """
        guard case .success(let spec) = TranscriptLogsSpec.parse(text) else {
            Issue.record("not read"); return
        }
        #expect(spec.title == "ledger errors")
        #expect(spec.server == "grafana-platform-dev")
        #expect(spec.query == #"{namespace="ledger"}"#)
        #expect(spec.entries.count == 1)
        let line = try #require(spec.entries.first)
        #expect(line.level == "error")
        #expect(line.labels == ["service": "ledger"])
        #expect(line.message == "deadlock detected")
        #expect(line.date == Date(timeIntervalSince1970: 1_792_764_131.418))
        #expect(GrafanaResultView.traceID(in: line) == Self.traceID)
    }

    // The transcript is one tall stack inside a scroll view. A card that gives up height
    // when offered less makes the stack measure shorter than it draws, and the end of the
    // conversation can no longer be scrolled into view.
    @MainActor @Test func aLogsCardKeepsItsHeightWhenOfferedLess() throws {
        let line = #"{"time":"2026-10-23T14:02:11.418Z","level":"error","service":"ledger","message":"deadlock detected"}"#
        let text = #"{"title":"ledger errors","lines":["# + Array(repeating: line, count: 40).joined(separator: ",") + "]}"
        guard case .success(let spec) = TranscriptLogsSpec.parse(text) else {
            Issue.record("not read"); return
        }
        let card = NSHostingController(rootView: GrafanaResultView(source: .init(logs: spec), result: spec.result)
            .environment(TooltipPresenter())
            .environment(DialogPresenter())
            .environment(MenuPresenter()))

        let roomy = card.sizeThatFits(in: CGSize(width: 600, height: 4000))
        let tight = card.sizeThatFits(in: CGSize(width: 600, height: 150))

        #expect(tight.height == roomy.height)
    }

    @Test func theAgentIsShownBothBlockShapes() {
        let instructions = TranscriptEvidenceBlocks.agentInstructions
        #expect(instructions.contains("```trace"))
        #expect(instructions.contains("```logs"))
        #expect(instructions.contains("At most \(TranscriptTraceSpec.spanLimit) spans"))
    }

    // The examples the agent copies are drawn by the same parser that reads its replies,
    // so a change to either side that breaks the other fails here.
    @Test func theExamplesTheAgentCopiesAreReadable() {
        let segments = MessageSegment.split(TranscriptEvidenceBlocks.agentInstructions)
        let trace = segments.first(where: \.isTrace)
        let logs = segments.first(where: \.isLogs)
        guard let trace, case .success = TranscriptTraceSpec.parse(trace.text) else {
            Issue.record("trace example unreadable"); return
        }
        guard let logs, case .success = TranscriptLogsSpec.parse(logs.text) else {
            Issue.record("logs example unreadable"); return
        }
    }

    @Test func fencesForEvidenceAreDrawnRatherThanPrinted() {
        let text = "Found it.\n\n```trace\n\(Self.trace)\n```\n\n```logs\n{}\n```\n\n```swift\nlet a = 1\n```"
        let segments = MessageSegment.split(text)
        #expect(segments.filter(\.isDrawn).count == 2)
        #expect(segments.first(where: \.isTrace) != nil)
        #expect(segments.first(where: \.isLogs) != nil)
        #expect(segments.contains { $0.isCode && !$0.isDrawn })
    }

    private func line(_ id: Int, at seconds: Double, _ level: String?) -> GrafanaToolResult.LogEntry {
        .init(id: id, rawTimestamp: "", date: Date(timeIntervalSince1970: seconds), line: "l", labels: [:],
              fields: [:], metadata: [:], level: level, message: "l")
    }

    // The strip above a query's log lines: how many landed in each stretch, by level.
    @Test func logLinesAreCountedIntoBarsByLevel() throws {
        let entries = [line(0, at: 1000, "info"), line(1, at: 1002, "ERROR"), line(2, at: 1003, "warn"),
                       line(3, at: 1004, "error"), line(4, at: 1290, nil)]
        let rhythm = try #require(LogRhythm(entries))

        // Five minutes of lines fit in bars of five seconds, starting on a whole step.
        #expect(rhythm.step == 5)
        #expect(rhythm.start == 1000)
        #expect(rhythm.buckets.count == 59)
        #expect(rhythm.buckets[0] == .init(errors: 2, warnings: 1, others: 1))
        #expect(rhythm.buckets[58] == .init(errors: 0, warnings: 0, others: 1))
        #expect(rhythm.peak == 4)
        #expect(rhythm.bucket(of: Date(timeIntervalSince1970: 1004)) == 0)
        #expect(rhythm.bucket(of: Date(timeIntervalSince1970: 999)) == nil)
        #expect(rhythm.bucket(of: nil) == nil)
        #expect(rhythm.stepText == "5 seconds")
        #expect(rhythm.summary(0) == "2 errors, 1 warning, 1 other")
    }

    // A handful of lines, or lines that all landed at once, have no rhythm to show.
    @Test func tooFewLinesDrawNoStrip() {
        #expect(LogRhythm([line(0, at: 1, nil), line(1, at: 9, nil)]) == nil)
        #expect(LogRhythm((0..<8).map { line($0, at: 100, "error") }) == nil)
    }

    // Lines the agent picked say nothing about how busy the log was, so only a whole
    // query result gets the strip.
    @Test func pickedLinesAreNotCountedAsVolume() throws {
        let spec = try TranscriptLogsSpec.parse(#"{"lines":[{"level":"error","message":"deadlock detected"}]}"#).get()
        #expect(GrafanaResultView.Source(logs: spec).isPicked)
    }
}
