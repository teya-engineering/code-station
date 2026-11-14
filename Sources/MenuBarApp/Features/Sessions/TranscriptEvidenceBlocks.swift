import Foundation
import SwiftUI

// A trace the agent fetched and wrote out for the reader, carried in the reply the way a
// chart is. The agent fetches it with whatever Grafana tools and skills it has, so the app
// never needs its own way into Grafana, and the reply keeps the evidence after Tempo has
// let the trace go.
struct TranscriptTraceSpec: Equatable, Sendable {
    let title: String?
    // The MCP server the trace was read from, such as "grafana-edge-dev".
    let server: String?
    // Spans the agent left out to keep the block short. The waterfall says so, because a
    // trace that looks whole but is not would hide where the rest of the time went.
    let omittedSpans: Int
    let trace: Trace

    static let fenceLanguage = "trace"
    // Enough for every failure, its callers and the slowest spans of a large trace, and
    // few enough that the reply does not cost more than the answer it supports.
    static let spanLimit = 200

    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "This trace could not be read." }
    }

    static func parse(_ json: String) -> Result<Self, Failure> {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: Data(json.utf8)) else {
            return .failure(.unreadable)
        }
        // Spans are timed from the trace's start, which the block gives as a clock time.
        // Without one the waterfall still draws, and just has no clock to show.
        let base = wire.time.flatMap(Self.date).map { Int64($0.timeIntervalSince1970 * 1_000_000_000) } ?? 0
        let spans = wire.spans.prefix(spanLimit).compactMap { span -> Trace.Span? in
            let id = span.id.trimmed
            guard !id.isEmpty, span.start.isFinite, span.duration.isFinite else { return nil }
            let parent = span.parent?.trimmed.nilIfBlank
            return Trace.Span(
                id: id, parentID: parent,
                service: span.service.trimmed.nilIfBlank ?? "unknown",
                operation: span.name?.trimmed ?? "",
                kind: span.kind?.trimmed.nilIfBlank ?? "unspecified",
                startNanos: base + Int64(span.start * 1_000_000),
                durationNanos: Int64(max(span.duration, 0) * 1_000_000),
                isError: span.error ?? false,
                statusMessage: span.message?.trimmed.nilIfBlank,
                attributes: WireValue.texts(span.attributes).sorted { $0.key < $1.key }
                    .map { Trace.Attribute(key: $0.key, value: $0.value) },
                resourceAttributes: [],
                events: [])
        }
        guard !spans.isEmpty else { return .failure(.unreadable) }
        let traceID = TraceInput.traceID(from: wire.traceId ?? "") ?? wire.traceId?.trimmed ?? ""
        let dropped = wire.spans.count - spans.count
        return .success(TranscriptTraceSpec(
            title: wire.title?.trimmed.nilIfBlank,
            server: wire.server?.trimmed.nilIfBlank,
            omittedSpans: max(wire.omitted ?? 0, 0) + max(dropped, 0),
            trace: Trace(traceID: traceID, spans: spans)))
    }

    // What can still be made out of a block that cannot be read, often one cut off part
    // way, so asking for it again names the trace and where it came from.
    static func salvage(_ text: String) -> (traceID: String?, server: String?) {
        func field(_ name: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: #""\#(name)"\s*:\s*"([^"]+)""#),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range]).trimmed.nilIfBlank
        }
        let traceID = field("traceId").map { TraceInput.traceID(from: $0) ?? $0 }
        return (traceID, field("server"))
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private struct Wire: Decodable {
        struct Span: Decodable {
            let id: String
            let parent: String?
            let service: String
            let name: String?
            let kind: String?
            let start: Double
            let duration: Double
            let error: Bool?
            let message: String?
            let attributes: [String: WireValue]?
        }
        let traceId: String?
        let time: String?
        let title: String?
        let server: String?
        let omitted: Int?
        let spans: [Span]
    }
}

// The log lines a finding rests on, chosen by the agent from what it read in Loki.
struct TranscriptLogsSpec: Equatable, Sendable {
    let title: String?
    let server: String?
    let query: String?
    let entries: [GrafanaToolResult.LogEntry]

    static let fenceLanguage = "logs"
    static let lineLimit = 100

    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "These log lines could not be read." }
    }

    var result: GrafanaToolResult { .logs(entries, truncated: false) }

    static func parse(_ json: String) -> Result<Self, Failure> {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: Data(json.utf8)) else {
            return .failure(.unreadable)
        }
        let entries = wire.lines.prefix(lineLimit).enumerated().compactMap { index, line in
            let message = line.message.trimmed
            guard !message.isEmpty else { return nil as GrafanaToolResult.LogEntry? }
            let labels = line.service.map { ["service": $0] } ?? [:]
            return GrafanaToolResult.LogEntry(
                id: index, rawTimestamp: line.time ?? "", date: line.time.flatMap(date),
                line: message, labels: labels, fields: WireValue.texts(line.fields), metadata: [:],
                level: line.level?.trimmed.nilIfBlank, message: message)
        }
        guard !entries.isEmpty else { return .failure(.unreadable) }
        return .success(TranscriptLogsSpec(title: wire.title?.trimmed.nilIfBlank,
                                           server: wire.server?.trimmed.nilIfBlank,
                                           query: wire.query?.trimmed.nilIfBlank,
                                           entries: Array(entries)))
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private struct Wire: Decodable {
        struct Line: Decodable {
            let time: String?
            let level: String?
            let service: String?
            let message: String
            let fields: [String: WireValue]?
        }
        let title: String?
        let server: String?
        let query: String?
        let lines: [Line]
    }
}

// A value in a block's "attributes" or "fields". The agent copies these from the tools,
// which give a status code as a number and a flag as a boolean. They are read as text,
// and a value with no text form, such as null or an object, is left out rather than
// making the whole block unreadable.
private struct WireValue: Decodable {
    let text: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self.text = text
        } else if let number = try? container.decode(Int64.self) {
            self.text = String(number)
        } else if let number = try? container.decode(Double.self) {
            self.text = String(number)
        } else if let flag = try? container.decode(Bool.self) {
            self.text = String(flag)
        } else {
            self.text = nil
        }
    }

    static func texts(_ values: [String: WireValue]?) -> [String: String] {
        (values ?? [:]).compactMapValues(\.text)
    }
}

enum TranscriptEvidenceBlocks {
    // Told to the agent with a diagnosis brief, since a diagnosis is where these blocks
    // earn their place. The examples are short on purpose: the agent copies their shape.
    static let agentInstructions = """
        You can also show evidence in the transcript with two fenced blocks that hold \
        JSON, the same way as a chart:

        ```\(TranscriptTraceSpec.fenceLanguage)
        {"traceId":"4bf92f3577b34da6a3ce929d0e0e4736","title":"Payment times out in ledger",\
        "server":"grafana-edge-dev","time":"2026-10-23T14:02:08.240Z",
         "spans":[{"id":"a1","service":"checkout-api","name":"POST /pay","start":0,\
        "duration":2140,"error":true,"message":"upstream timeout"},
                  {"id":"b2","parent":"a1","service":"ledger","name":"INSERT entry",\
        "start":12.5,"duration":2101,"error":true,"attributes":{"db.system":"postgresql"}}]}
        ```

        - One object per span. "start" and "duration" are in milliseconds, and "start" \
        counts from the trace's first span, whose clock time goes in "time" (RFC 3339). \
        "parent" is the id of the span that called it.
        - Keep every failed span, the spans above it, and the slowest spans. At most \
        \(TranscriptTraceSpec.spanLimit) spans; put the number you left out in "omitted".
        - Add "attributes" only for what the diagnosis rests on, such as an HTTP status.

        ```\(TranscriptLogsSpec.fenceLanguage)
        {"title":"ledger errors for this trace","server":"grafana-platform-dev",\
        "query":"{namespace=\\"ledger\\"} |= \\"4bf92f35\\"",
         "lines":[{"time":"2026-10-23T14:02:11.418Z","level":"error","service":"ledger",\
        "message":"deadlock detected"}]}
        ```

        - Only the lines the diagnosis rests on, oldest first, at most \
        \(TranscriptLogsSpec.lineLimit). "time" is RFC 3339.
        - Draw a block only after fetching what it shows, and copy the values exactly as \
        the tools returned them. Like a chart, a block cannot fetch anything itself.
        """
}

// Sends a follow-up to the session's agent. Set where a transcript or its evidence is
// drawn, so a result can ask for more without the app reaching Grafana itself. Compared
// by session, so handing a new one down on every redraw does not redraw its readers.
struct AgentAsk: Equatable {
    let sessionID: UUID
    let send: (String) -> Void

    func callAsFunction(_ text: String) { send(text) }

    static func == (lhs: AgentAsk, rhs: AgentAsk) -> Bool { lhs.sessionID == rhs.sessionID }
}

extension EnvironmentValues {
    @Entry var askAgent: AgentAsk? = nil
}

// A trace block in place of the fence that carried it, the same way a chart is drawn.
struct TranscriptTraceBlock: View, Equatable {
    let segment: MessageSegment

    var body: some View {
        if segment.isOpen {
            TraceArrivingCard()
        } else {
            switch TranscriptTraceSpec.parse(segment.text) {
            case .success(let spec):
                TranscriptTraceCard(spec: spec, maxHeight: 460)
            case .failure:
                let named = TranscriptTraceSpec.salvage(segment.text)
                TraceUnreadableCard(traceID: named.traceID, server: named.server)
            }
        }
    }
}

struct TranscriptLogsBlock: View, Equatable {
    let segment: MessageSegment

    var body: some View {
        if segment.isOpen {
            EmptyView()
        } else {
            switch TranscriptLogsSpec.parse(segment.text) {
            case .success(let spec):
                GrafanaResultView(source: .init(logs: spec), result: spec.result)
            case .failure(let failure):
                TranscriptBlockFailure(message: failure.localizedDescription)
            }
        }
    }
}

struct TranscriptBlockFailure: View {
    let message: String

    var body: some View {
        Text(message)
            .scaledText(Typography.Size.detail)
            .foregroundStyle(Theme.warningText)
            .padding(.vertical, Space.xxs)
    }
}

// A trace with its title and where it came from. Opening a span offers to ask the agent
// for that span's logs, since the agent is the one with the way in.
struct TranscriptTraceCard: View {
    let spec: TranscriptTraceSpec
    var maxHeight: CGFloat? = nil

    var body: some View {
        TraceWaterfallView(trace: spec.trace, title: spec.title, server: spec.server,
                           omittedSpans: spec.omittedSpans, maxHeight: maxHeight)
    }
}

// The small accent-coloured action the design system uses inline.
struct InlineAskButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title + " →")
                .font(Typography.label)
                .foregroundStyle(Theme.accent)
                .opacity(hovering ? 0.75 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
    }
}

// The follow-ups a result can ask the agent for. Each names what to fetch and how to show
// it, so the answer comes back as evidence rather than as prose about evidence.
enum TraceFollowUp {
    static func spanLogs(_ span: Trace.Span, traceID: String) -> String {
        let state = span.isError ? "failed" : "took \(Trace.durationText(span.durationNanos))"
        return "Read \(span.service)'s logs for trace `\(traceID)` around the span "
            + "\"\(span.operation)\", which \(state). Use the Grafana that holds "
            + "\(span.service)'s logs, and show the lines that matter in a "
            + "```\(TranscriptLogsSpec.fenceLanguage) block."
    }

    static func fullTrace(_ traceID: String, server: String?) -> String {
        "The trace `\(traceID)`\(server.map { " from \($0)" } ?? "") was too long to keep in "
            + "the transcript. Fetch it again and draw it as a "
            + "```\(TranscriptTraceSpec.fenceLanguage) block."
    }

    static func drawAgain(_ traceID: String?, server: String?) -> String {
        let trace = traceID.map { "for trace `\($0)`" } ?? "you wrote"
        let source = server.map { " from \($0)" } ?? ""
        return "The ```\(TranscriptTraceSpec.fenceLanguage) block \(trace) could not be read. "
            + "Fetch the trace again\(source) and draw it as a complete "
            + "```\(TranscriptTraceSpec.fenceLanguage) block."
    }
}
