import SwiftUI

// A Grafana query's result drawn as what it is: log lines as a table whose rows open to
// show everything Loki returned with them, samples as a table, and range series as a chart.
// It reads what the agent already fetched. Asking for more goes back to the agent, which
// runs the query with its own tools, so the follow-up shows in the conversation.
struct GrafanaResultView: View {
    @Environment(\.textScale) private var textScale
    @Environment(\.askAgent) private var askAgent

    // What the result answers: the agent's own call, or log lines it picked out for a reply.
    struct Source: Equatable {
        enum Kind: Equatable { case loki, prometheus }

        let kind: Kind
        let title: String?
        let server: String?
        let query: String?
        let start: String?
        let end: String?
        let isInstant: Bool
        // Lines the agent chose from a larger result. How busy the log was cannot be
        // read off them, since the lines left out are the ones that would say.
        let isPicked: Bool

        init(call: GrafanaToolCall) {
            isPicked = false
            kind = call.kind == .lokiLogs ? .loki : .prometheus
            title = nil
            server = call.server
            query = call.query
            start = call.start
            end = call.end
            isInstant = call.queryType == "instant"
        }

        init(logs: TranscriptLogsSpec) {
            isPicked = true
            kind = .loki
            title = logs.title
            server = logs.server
            query = logs.query
            start = nil
            end = nil
            isInstant = false
        }

        // The instance rather than the bare environment: "cde-dev" and "platform-dev" are
        // both "dev", and which Grafana answered is what a reader needs.
        var instance: String? {
            server.map { $0.hasPrefix(Grafana.namePrefix) ? String($0.dropFirst(Grafana.namePrefix.count)) : $0 }
        }

        var kindName: String { kind == .loki ? "Loki" : "Prometheus" }
    }

    let source: Source
    let result: GrafanaToolResult

    @State private var expanded: Set<Int> = []
    @State private var showsTable = false
    // The bar of the rhythm strip the pointer is on, or the bar of the line it is on.
    @State private var hotBucket: Int?

    static let widerWindows = ["1h", "6h", "24h"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if askAgent != nil, source.query != nil, !source.isInstant || result.isTruncated {
                followUps
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.sunken, cornerRadius: Radius.control, border: Theme.border)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.md) {
                Text(source.kindName.uppercased())
                    .scaledMono(Typography.Size.caption, .bold)
                    .foregroundStyle(.secondary)
                if let instance = source.instance {
                    Text(instance)
                        .scaledMono(Typography.Size.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(summary)
                    .scaledMono(Typography.Size.caption)
                    .foregroundStyle(result.isTruncated ? AnyShapeStyle(Theme.attention)
                                                        : AnyShapeStyle(.secondary))
            }
            if let title = source.title {
                Text(title).scaledText(Typography.Size.body, .semibold)
            }
            if let query = source.query {
                Text(query)
                    .scaledMono(Typography.Size.detail)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let window {
                Text(window)
                    .scaledMono(Typography.Size.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    private var followUps: some View {
        HStack(spacing: Space.lg) {
            if !source.isInstant {
                ForEach(Self.widerWindows, id: \.self) { window in
                    InlineAskButton(title: "Last \(window)") { ask(Self.widen(source, to: window)) }
                }
            }
            if result.isTruncated {
                InlineAskButton(title: "Fetch the rest") { ask(Self.fetchRest(source)) }
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.bottom, Space.md)
    }

    @ViewBuilder private var content: some View {
        switch result {
        case .logs(let entries, _):
            let rhythm = source.isPicked ? nil : LogRhythm(entries)
            if let rhythm {
                LogRhythmStrip(rhythm: rhythm, hot: $hotBucket)
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        logRow(entry, bucket: rhythm?.bucket(of: entry.date))
                    }
                }
                .smoothlyResizes(when: expanded)
            }
            .scrollCap(ScrollCap.medium)
        case .samples(let samples, _):
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(samples) { sample in
                        HStack(alignment: .firstTextBaseline, spacing: Space.lg) {
                            Text(Self.labelText(sample.labels))
                                .scaledMono(Typography.Size.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(sample.value)
                                .scaledMono(Typography.Size.detail, .semibold)
                        }
                        .textSelection(.enabled)
                    }
                }
                .padding(Space.lg)
            }
            .scrollCap(ScrollCap.short)
        case .series(let series, _):
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    ChoicePill(title: "Chart", selected: !showsTable) { showsTable = false }
                    ChoicePill(title: "Table", selected: showsTable) { showsTable = true }
                }
                Group {
                    if !showsTable, let spec = Self.chartSpec(series) {
                        TranscriptChartView(spec: spec)
                    } else {
                        seriesTable(series)
                    }
                }
                .id(showsTable)
                .transition(.fadeIn)
            }
            .padding(Space.lg)
            .motion(Motion.reveal, value: showsTable)
        case .empty:
            Text("The query returned nothing.")
                .scaledMono(Typography.Size.detail)
                .foregroundStyle(.secondary)
                .padding(Space.lg)
        }
    }

    private func logRow(_ entry: GrafanaToolResult.LogEntry, bucket: Int?) -> some View {
        let isOpen = expanded.contains(entry.id)
        let lit = bucket != nil && hotBucket == bucket
        return VStack(alignment: .leading, spacing: Space.sm) {
            Button {
                if isOpen { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                    Text(entry.date.map { Self.clock($0) } ?? entry.rawTimestamp)
                        .scaledMono(Typography.Size.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.level ?? "")
                        .scaledMono(Typography.Size.caption, .bold)
                        .foregroundStyle(Self.levelColour(entry.level))
                        .frame(minWidth: 44 * textScale, alignment: .leading)
                    if let service = entry.labels["service"] {
                        Text(service)
                            .scaledMono(Typography.Size.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.message)
                        .scaledMono(Typography.Size.detail)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverFill(cornerRadius: Radius.inset)
            if isOpen {
                VStack(alignment: .leading, spacing: Space.xs) {
                    detail("LINE", entry.line)
                    if !entry.labels.isEmpty { detail("LABELS", Self.fieldText(entry.labels)) }
                    if !entry.fields.isEmpty { detail("FIELDS", Self.fieldText(entry.fields)) }
                    if !entry.metadata.isEmpty { detail("METADATA", Self.fieldText(entry.metadata)) }
                    if askAgent != nil, let date = entry.date {
                        HStack(spacing: Space.lg) {
                            InlineAskButton(title: "Lines around this") {
                                ask(Self.around(source, entry: entry, at: date))
                            }
                            if let traceID = Self.traceID(in: entry) {
                                InlineAskButton(title: "Follow this trace") {
                                    ask(Self.followTrace(traceID))
                                }
                            }
                        }
                    }
                }
                .padding(.leading, Space.md)
                .transition(.fold)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.xs)
        .background(Color.primary.opacity(lit ? 0.05 : 0))
        // An edge in the level's colour, so the bad lines can be found by running an eye
        // down the side of the list.
        .overlay(alignment: .leading) {
            Rectangle().fill(Self.levelEdge(entry.level)).frame(width: 2)
        }
        .onPointerHover { inside in
            guard let bucket else { return }
            if inside { hotBucket = bucket } else if hotBucket == bucket { hotBucket = nil }
        }
        .motion(Motion.hover, value: lit)
    }

    private func ask(_ text: String) { askAgent?(text) }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title)
                .scaledMono(Typography.Size.micro, .bold)
                .foregroundStyle(.secondary)
            Text(text)
                .scaledMono(Typography.Size.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func seriesTable(_ series: [GrafanaToolResult.Series]) -> some View {
        let table = SeriesTable(series)
        return ScrollView {
            Grid(alignment: .leading, horizontalSpacing: Space.lg, verticalSpacing: 0) {
                GridRow {
                    tableHeader("TIME", alignment: .leading)
                    ForEach(table.names.indices, id: \.self) { column in
                        tableHeader(table.names[column], alignment: .trailing)
                    }
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ForEach(table.rows.indices, id: \.self) { index in
                    let row = table.rows[index]
                    GridRow {
                        Text(row.time)
                            .scaledMono(Typography.Size.caption)
                            .foregroundStyle(.secondary)
                        ForEach(row.readings.indices, id: \.self) { column in
                            Text(row.readings[column] ?? "–")
                                .scaledMono(Typography.Size.caption)
                                .foregroundStyle(row.readings[column] == nil
                                                 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                                .gridColumnAlignment(.trailing)
                        }
                    }
                    .padding(.vertical, Space.xxs)
                }
            }
            .padding(.horizontal, Space.xs)
            .textSelection(.enabled)
        }
        .scrollCap(ScrollCap.short)
    }

    // A reading column is wide enough for a long series name to wrap rather than push
    // the next column off the card, and no wider, so a lone series sits next to its times.
    private func tableHeader(_ title: String, alignment: Alignment) -> some View {
        Text(title)
            .scaledMono(Typography.Size.micro, .bold)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            .frame(maxWidth: alignment == .trailing ? 220 * textScale : nil, alignment: alignment)
            .padding(.bottom, Space.xs)
    }

    private var summary: String {
        let noun: String
        switch result {
        case .logs: noun = "line"
        case .samples: noun = "sample"
        case .series: noun = "series"
        case .empty: return "0 results"
        }
        let count = result.count
        let counted = noun == "series" || count == 1 ? "\(count) \(noun)" : "\(count) \(noun)s"
        return result.isTruncated ? "showing \(counted) · result truncated" : counted
    }

    private var window: String? {
        let dates = [source.start, source.end].map { $0.flatMap(Self.rfc3339) }
        switch (dates[0], dates[1]) {
        case (let start?, let end?): return "\(Self.clock(start)) – \(Self.clock(end))"
        case (let start?, nil): return "from \(Self.clock(start))"
        default: return nil
        }
    }

    // MARK: - Follow-ups

    nonisolated static func widen(_ source: Source, to window: String) -> String {
        "Run the \(source.kindName) query `\(source.query ?? "")`\(on(source)) again over the "
            + "last \(window), and show what it found."
    }

    nonisolated static func fetchRest(_ source: Source) -> String {
        "The result of the \(source.kindName) query `\(source.query ?? "")`\(on(source)) was "
            + "cut short in the transcript. Fetch it again in smaller pages, and show the "
            + "lines that matter in a ```\(TranscriptLogsSpec.fenceLanguage) block."
    }

    nonisolated static func around(_ source: Source, entry: GrafanaToolResult.LogEntry, at date: Date) -> String {
        let stream = entry.labels.isEmpty ? "" : " from the stream \(labelText(entry.labels))"
        return "Show the log lines\(stream)\(on(source)) from 5 seconds before to 30 seconds "
            + "after \(isoTime(date)), around the line \"\(entry.message.prefix(160))\". "
            + "Put them in a ```\(TranscriptLogsSpec.fenceLanguage) block."
    }

    nonisolated static func followTrace(_ traceID: String) -> String {
        "Fetch trace `\(traceID)` and draw it as a ```\(TranscriptTraceSpec.fenceLanguage) "
            + "block, then say how it bears on the problem."
    }

    nonisolated private static func on(_ source: Source) -> String {
        source.server.map { " on \($0)" } ?? ""
    }

    // A trace id a log line carries in any of the names tracers write it under.
    nonisolated static func traceID(in entry: GrafanaToolResult.LogEntry) -> String? {
        let names = ["trace_id", "traceid", "traceId", "trace.id", "traceID"]
        for fields in [entry.fields, entry.metadata, entry.labels] {
            for name in names {
                if let value = fields[name], let id = TraceInput.traceID(from: value) { return id }
            }
        }
        return nil
    }

    nonisolated private static func isoTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: - Drawing helpers

    nonisolated static func chartSpec(_ series: [GrafanaToolResult.Series]) -> TranscriptChartSpec? {
        let names = seriesNames(series)
        let wire: [String: Any] = [
            "kind": "line",
            "time": true,
            "series": zip(series, names).map { one, name in
                ["label": name,
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
        switch LogRhythm.level(level) {
        case .error: AnyShapeStyle(Theme.deletion)
        case .warning: AnyShapeStyle(Theme.attention)
        case .other: AnyShapeStyle(.secondary)
        }
    }

    private static func levelEdge(_ level: String?) -> Color {
        switch LogRhythm.level(level) {
        case .error: Theme.deletion
        case .warning: Theme.attention
        case .other: .clear
        }
    }

    // Names series by the labels that tell them apart. The labels they all share are the
    // ones the query asked for, which the card already shows, and spelling them out on
    // every series buries the one part that differs.
    nonisolated static func seriesNames(_ series: [GrafanaToolResult.Series]) -> [String] {
        let keys = Set(series.flatMap(\.labels.keys)).sorted()
        let varying = keys.filter { key in Set(series.map { $0.labels[key] }).count > 1 }
        let names = series.map { one -> String in
            switch varying.count {
            case 0: one.labels["__name__"] ?? "value"
            case 1: one.labels[varying[0]] ?? "(none)"
            default: labelText(one.labels.filter { varying.contains($0.key) })
            }
        }
        // The chart keys its series by name, so two series with the same name would merge.
        guard Set(names).count < names.count else { return names }
        return names.enumerated().map { "\($1) #\($0 + 1)" }
    }

    // A range result laid out as one row per moment and one column per series, so series
    // read side by side. A series with no reading at a moment leaves its cell empty.
    struct SeriesTable: Equatable {
        struct Row: Equatable {
            let time: String
            let readings: [String?]
        }

        let names: [String]
        let rows: [Row]

        init(_ series: [GrafanaToolResult.Series], in timeZone: TimeZone = .current) {
            names = GrafanaResultView.seriesNames(series)
            let moments = Set(series.flatMap { $0.points.map(\.seconds) }).sorted()
            let lookup = series.map { one in
                Dictionary(one.points.map { ($0.seconds, $0.raw) }, uniquingKeysWith: { first, _ in first })
            }
            let format = Self.timeFormat(moments, in: timeZone)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            rows = moments.map { moment in
                Row(time: formatter.string(from: Date(timeIntervalSince1970: moment)),
                    readings: lookup.map { $0[moment].map(GrafanaResultView.reading) })
            }
        }

        // Milliseconds only when a step falls between whole seconds, and the day only when
        // the range crosses midnight, since otherwise they are the same on every row.
        private static func timeFormat(_ moments: [Double], in timeZone: TimeZone) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let clock = moments.contains { $0 != $0.rounded() } ? "HH:mm:ss.SSS" : "HH:mm:ss"
            guard let first = moments.first, let last = moments.last,
                  !calendar.isDate(Date(timeIntervalSince1970: first),
                                   inSameDayAs: Date(timeIntervalSince1970: last))
            else { return clock }
            return "MMM d " + clock
        }
    }

    // Prometheus writes readings with every digit a double holds. A few are enough to
    // compare rows, and the rest make the column too wide to scan. Text that is not a
    // plain number, such as "NaN" or "+Inf", is shown as written.
    nonisolated static func reading(_ raw: String) -> String {
        guard let value = Double(raw), value.isFinite else { return raw }
        let locale = Locale(identifier: "en_US_POSIX")
        if value == 0 || abs(value) >= 1 {
            return value.formatted(.number.precision(.fractionLength(0...3)).grouping(.never).locale(locale))
        }
        return value.formatted(.number.precision(.significantDigits(1...3)).grouping(.never).locale(locale))
    }

    nonisolated static func labelText(_ labels: [String: String]) -> String {
        labels.isEmpty ? "{}" : "{" + labels.sorted { $0.key < $1.key }
            .map { "\($0.key)=\"\($0.value)\"" }.joined(separator: ", ") + "}"
    }

    private static func fieldText(_ fields: [String: String]) -> String {
        fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

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
