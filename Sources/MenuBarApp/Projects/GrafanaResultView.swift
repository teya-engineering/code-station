import SwiftUI

// A Grafana query's result drawn as what it is: log lines as a table whose rows open to
// show everything Loki returned with them, samples as a table, and range series as a chart.
struct GrafanaResultView: View {
    @Environment(\.textScale) private var textScale
    @Environment(GrafanaQueryRunner.self) private var runner: GrafanaQueryRunner?

    let call: GrafanaToolCall
    let result: GrafanaToolResult
    let toolID: String?
    let service: SiteDefaults.Service?
    // A result with no agent answer behind it, such as a span's logs, shows its newest run
    // rather than an empty "agent" result.
    let followsLatestRun: Bool

    @State private var expanded: Set<Int> = []
    @State private var showsTable = false

    @State private var draftQuery: String?
    @State private var selectedRun: UUID?

    init(call: GrafanaToolCall, result: GrafanaToolResult,
         toolID: String? = nil, service: SiteDefaults.Service? = nil,
         followsLatestRun: Bool = false) {
        self.call = call
        self.result = result
        self.toolID = toolID
        self.service = service
        self.followsLatestRun = followsLatestRun
    }

    private var runs: [GrafanaRun] { toolID.map { runner?.runs(for: $0) ?? [] } ?? [] }
    private var shownRun: GrafanaRun? {
        runs.first { $0.id == selectedRun } ?? (followsLatestRun ? runs.last : nil)
    }
    private var shown: GrafanaToolResult { shownRun?.result ?? result }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let runner, let toolID {
                queryBar(runner, toolID: toolID)
                if !runs.isEmpty { chips }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.sunken, cornerRadius: 8, border: Theme.border)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(call.kind == .lokiLogs ? "LOKI" : "PROMETHEUS")
                    .scaledMono(10.5, .bold)
                    .foregroundStyle(.secondary)
                Text(call.argument)
                    .scaledMono(10.5)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(summary)
                    .scaledMono(10.5)
                    .foregroundStyle(shown.isTruncated ? AnyShapeStyle(Theme.attention)
                                                        : AnyShapeStyle(.secondary))
            }
            Text(shownRun?.query ?? call.query)
                .scaledMono(11.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let window = shownRun.map({ $0.window.label }) ?? window {
                Text(window)
                    .scaledMono(10.5)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if let error = shownRun?.error {
            Text(error)
                .scaledMono(11.5)
                .foregroundStyle(Theme.deletion)
                .textSelection(.enabled)
                .padding(12)
        } else if shownRun?.isRunning == true {
            Text("Running…")
                .scaledMono(11.5)
                .foregroundStyle(.secondary)
                .padding(12)
        } else {
            resultContent
        }
    }

    @ViewBuilder private var resultContent: some View {
        switch shown {
        case .logs(let entries, _):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        logRow(entry)
                    }
                }
            }
            .frame(maxHeight: 320 * textScale)
        case .samples(let samples, _):
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(samples) { sample in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(Self.labelText(sample.labels))
                                .scaledMono(11)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(sample.value)
                                .scaledMono(11.5, .semibold)
                        }
                        .textSelection(.enabled)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 260 * textScale)
        case .series(let series, _):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ChoicePill(title: "Chart", selected: !showsTable) { showsTable = false }
                    ChoicePill(title: "Table", selected: showsTable) { showsTable = true }
                }
                if !showsTable, let spec = Self.chartSpec(series) {
                    TranscriptChartView(spec: spec)
                } else {
                    seriesTable(series)
                }
            }
            .padding(12)
        case .empty:
            Text("The query returned nothing.")
                .scaledMono(11.5)
                .foregroundStyle(.secondary)
                .padding(12)
        }
    }

    private func logRow(_ entry: GrafanaToolResult.LogEntry) -> some View {
        let isOpen = expanded.contains(entry.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if isOpen { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.date.map(Self.time) ?? entry.rawTimestamp)
                        .scaledMono(11)
                        .foregroundStyle(.secondary)
                    Text(entry.level ?? "")
                        .scaledMono(11, .bold)
                        .foregroundStyle(Self.levelColour(entry.level))
                        .frame(minWidth: 44 * textScale, alignment: .leading)
                    Text(entry.message)
                        .scaledMono(11.5)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    detail("LINE", entry.line)
                    if !entry.labels.isEmpty { detail("LABELS", Self.fieldText(entry.labels)) }
                    if !entry.fields.isEmpty { detail("FIELDS", Self.fieldText(entry.fields)) }
                    if !entry.metadata.isEmpty { detail("METADATA", Self.fieldText(entry.metadata)) }
                    if runner != nil, toolID != nil, call.kind == .lokiLogs {
                        HStack(spacing: 12) {
                            if let date = entry.date, !entry.labels.isEmpty {
                                pivot("Lines around this entry") {
                                    start(.around(date),
                                          query: GrafanaQueryEdit.aroundSelector(labels: entry.labels))
                                }
                            }
                            if let service, let field = service.traceField,
                               let traceID = entry.fields[field] ?? entry.metadata[field] ?? entry.labels[field],
                               !traceID.isEmpty {
                                pivot("All lines for this trace") {
                                    start(.same, query: GrafanaQueryEdit.traceQuery(
                                        selector: service.lokiSelector, traceID: traceID))
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    @ViewBuilder private func queryBar(_ runner: GrafanaQueryRunner, toolID: String) -> some View {
        switch runner.availability(of: call) {
        case .ready:
            VStack(alignment: .leading, spacing: 6) {
                TextField("Query", text: Binding(get: { draftQuery ?? call.query },
                                                 set: { draftQuery = $0 }))
                    .textFieldStyle(.plain)
                    .scaledMono(11.5)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .surface(Theme.field, cornerRadius: 6, border: Theme.border)
                    .onSubmit { start(.same) }
                HStack(spacing: 6) {
                    ChoicePill(title: "Run", selected: false) { start(.same) }
                    if call.queryType != "instant" {
                        ForEach(GrafanaQueryEdit.windowChoices, id: \.seconds) { choice in
                            ChoicePill(title: "Last \(choice.label)", selected: false) {
                                start(.last(seconds: choice.seconds))
                            }
                        }
                    }
                    if result.isTruncated {
                        ChoicePill(title: "Reload full result", selected: false) {
                            start(.same, query: call.query)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        case .notConfigured(let reason), .disabled(let reason), .notLocal(let reason):
            Text(reason + " Add or enable it under MCP servers to run queries from here.")
                .scaledMono(10.5)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if !followsLatestRun {
                    ChoicePill(title: "agent", selected: selectedRun == nil) { selectedRun = nil }
                }
                ForEach(runs) { run in
                    ChoicePill(title: run.chipLabel, selected: shownRun?.id == run.id) {
                        selectedRun = run.id
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }

    private func start(_ window: GrafanaQueryWindow, query: String? = nil) {
        guard let runner, let toolID else { return }
        runner.run(call, toolID: toolID, query: query ?? draftQuery ?? call.query,
                   window: window, levelField: service?.levelField)
        selectedRun = runner.runs(for: toolID).last?.id
    }

    private func pivot(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title + " →")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .scaledMono(10, .bold)
                .foregroundStyle(.secondary)
            Text(text)
                .scaledMono(11)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func seriesTable(_ series: [GrafanaToolResult.Series]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(series) { one in
                    Text(Self.labelText(one.labels))
                        .scaledMono(11, .semibold)
                    ForEach(Array(one.points.enumerated()), id: \.offset) { _, point in
                        HStack(spacing: 12) {
                            Text(Self.time(Date(timeIntervalSince1970: point.seconds)))
                                .scaledMono(11)
                                .foregroundStyle(.secondary)
                            Text(point.raw)
                                .scaledMono(11)
                        }
                    }
                }
            }
            .textSelection(.enabled)
        }
        .frame(maxHeight: 260 * textScale)
    }

    private var summary: String {
        let noun: String
        switch shown {
        case .logs: noun = "line"
        case .samples: noun = "sample"
        case .series: noun = "series"
        case .empty: return "0 results"
        }
        let count = shown.count
        let counted = noun == "series" || count == 1 ? "\(count) \(noun)" : "\(count) \(noun)s"
        return shown.isTruncated ? "showing \(counted) · result truncated" : counted
    }

    private var window: String? {
        let dates = [call.start, call.end].map { $0.flatMap(Self.rfc3339) }
        switch (dates[0], dates[1]) {
        case (let start?, let end?): return "\(Self.time(start)) – \(Self.time(end))"
        case (let start?, nil): return "from \(Self.time(start))"
        default: return nil
        }
    }

    nonisolated static func chartSpec(_ series: [GrafanaToolResult.Series]) -> TranscriptChartSpec? {
        let wire: [String: Any] = [
            "kind": "line",
            "time": true,
            "series": series.map { one in
                ["label": labelText(one.labels),
                 "points": one.points.compactMap { point in
                     point.value.map { [point.seconds, $0] }
                 }] as [String: Any]
            }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: wire),
              case .success(let spec) = TranscriptChartSpec.parse(String(decoding: data, as: UTF8.self))
        else { return nil }
        return spec
    }

    private static func levelColour(_ level: String?) -> AnyShapeStyle {
        switch level?.uppercased() {
        case "ERROR", "ERR", "FATAL", "CRITICAL", "CRIT": AnyShapeStyle(Theme.deletion)
        case "WARN", "WARNING": AnyShapeStyle(Theme.attention)
        default: AnyShapeStyle(.secondary)
        }
    }

    nonisolated static func labelText(_ labels: [String: String]) -> String {
        labels.isEmpty ? "{}" : "{" + labels.sorted { $0.key < $1.key }
            .map { "\($0.key)=\"\($0.value)\"" }.joined(separator: ", ") + "}"
    }

    private static func fieldText(_ fields: [String: String]) -> String {
        fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    private static func time(_ date: Date) -> String { clock(date) }

    // Always a 24-hour clock: a log line read at "02:15" in a 12-hour locale could be
    // either end of the day.
    nonisolated static func clock(_ date: Date, in timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private static func rfc3339(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
