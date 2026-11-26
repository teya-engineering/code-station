import SwiftUI

// A chart drawn in the transcript from the data the reply carried. Everything here is the
// app's own palette and type, so a chart reads as part of the answer rather than as a
// picture pasted into it.
struct TranscriptChartView: View {
    let spec: TranscriptChartSpec
    // Whether the chart plays its arrival. One that streamed into a reply does not.
    var arrives = true

    var body: some View {
        Group {
            switch spec.kind {
            case .stat:
                TranscriptStatTile(spec: spec, arrives: arrives)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            case .bar:
                TranscriptBarChart(spec: spec, arrives: arrives).padding(Space.lg)
            case .line, .area:
                TranscriptLineChart(spec: spec, arrives: arrives).padding(Space.lg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(Theme.border))
    }
}

// MARK: - Palette

enum TranscriptChartPalette {
    static func colour(_ index: Int) -> Color {
        Theme.chartSeries[index % Theme.chartSeries.count]
    }
}

// MARK: - Legend

// The key of a bar chart with more than one series, so identity never rests on matching
// colours from memory. A line chart needs none: its readout strip names every series.
struct TranscriptChartLegend: View {
    let spec: TranscriptChartSpec

    var body: some View {
        FlowRow(spacing: Space.lg) {
            ForEach(Array(spec.series.enumerated()), id: \.element.id) { index, series in
                HStack(spacing: Space.sm) {
                    RoundedRectangle(cornerRadius: Radius.tag / 2)
                        .fill(TranscriptChartPalette.colour(index))
                        .frame(width: Space.md, height: Space.md)
                    Text(series.label)
                        .scaledText(Typography.Size.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// The legend wraps rather than scrolls: a name pushed off the edge is a name nobody reads.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - Bars

// Drawn along the x axis because the things being compared are named: endpoints, pods
// and queues have long names, and a horizontal bar lets them be read straight. A name
// wraps rather than being cut, since the end of a pod's name is the part that tells it
// from the next one.
struct TranscriptBarChart: View {
    let spec: TranscriptChartSpec
    let arrives: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.textScale) private var textScale
    @State private var grown: Bool
    @State private var width: CGFloat = 0

    private let categories: [String]
    private let peak: Double
    private let levels: [TranscriptChartSpec.Rule]

    // Past this many rows the bars scroll inside the card instead of running down the page.
    private static let openRows = 12

    init(spec: TranscriptChartSpec, arrives: Bool = true) {
        self.spec = spec
        self.arrives = arrives
        _grown = State(initialValue: !arrives)
        var seen = Set<String>()
        categories = spec.series.flatMap { $0.points.compactMap(\.x.category) }.filter { seen.insert($0).inserted }
        levels = spec.rules.filter { $0.axis == .y }
        peak = max((spec.series.flatMap(\.values) + levels.map(\.value)).max() ?? 0, .leastNonzeroMagnitude)
    }

    // A short unit rides with each number. A longer one is said once under the bars.
    private var inlineUnit: String? { spec.unit.flatMap { $0.count <= 3 ? $0 : nil } }

    private var nameWidth: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: Typography.Size.caption * textScale, weight: .regular)
        let widest = categories.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(widest.rounded(.up) + Space.xs, width * ChartMetrics.barNameShare)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ChartHeading(title: spec.title, caption: spec.caption)
            if categories.count > Self.openRows {
                ScrollView { rows }.scrollCap(ScrollCap.tall)
            } else {
                rows
            }
            if spec.series.count > 1 { TranscriptChartLegend(spec: spec) }
            footer
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear {
            guard !grown else { return }
            if reduceMotion { grown = true } else { withAnimation { grown = true } }
        }
    }

    private var rows: some View {
        let nameWidth = nameWidth
        return VStack(spacing: 0) {
            ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                HStack(alignment: .center, spacing: Space.lg) {
                    Text(category)
                        .scaledMono(Typography.Size.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: nameWidth, alignment: .leading)
                    VStack(spacing: Space.xxs) {
                        ForEach(Array(spec.series.enumerated()), id: \.element.id) { slot, series in
                            if let value = series.points.first(where: { $0.x.category == category })?.y {
                                bar(value, slot: slot, row: index)
                            }
                        }
                    }
                }
                .padding(.vertical, Space.sm)
                .padding(.horizontal, Space.sm)
                .hoverFill(cornerRadius: Radius.inset)
                .accessibilityElement(children: .combine)
            }
        }
        .textSelection(.enabled)
    }

    private func bar(_ value: Double, slot: Int, row: Int) -> some View {
        let label = TranscriptChartFormat.value(value, unit: inlineUnit)
        let waiting = min(row, ChartMotion.staggerLimit)
        return GeometryReader { proxy in
            // Room is kept for the number, so the longest bar and its value both fit.
            let room = max(proxy.size.width - ChartMetrics.barValueRoom * textScale, 1)
            let length = room * CGFloat(max(value, 0) / peak)
            ZStack(alignment: .leading) {
                HStack(spacing: Space.md) {
                    if value <= 0 {
                        // Nothing to draw a bar from, so zero is a hairline where a bar would start.
                        Rectangle().fill(.tertiary).frame(width: 1)
                    } else {
                        RoundedRectangle(cornerRadius: Radius.tag)
                            .fill(TranscriptChartPalette.colour(slot))
                            .frame(width: max(length * (grown ? 1 : ChartMotion.zoomGrowth), 2))
                    }
                    Text(label)
                        .scaledMono(Typography.Size.caption, .semibold)
                        .lineLimit(1)
                        .fixedSize()
                }
                ForEach(levels) { level in
                    Rectangle()
                        .fill((level.tone ?? .warn).ink)
                        .frame(width: 1)
                        .offset(x: room * CGFloat(max(level.value, 0) / peak))
                }
            }
        }
        .frame(height: ChartMetrics.barHeight * textScale)
        .motion(ChartMotion.restack(bar: waiting, of: ChartMotion.staggerLimit + 1), value: grown)
    }

    @ViewBuilder private var footer: some View {
        let longUnit = inlineUnit == nil ? spec.unit : nil
        if longUnit != nil || !levels.isEmpty || spec.omittedSeriesCount > 0 {
            FlowRow(spacing: Space.lg) {
                if let longUnit {
                    Text("in \(longUnit)").scaledText(Typography.Size.caption).foregroundStyle(.secondary)
                }
                ForEach(levels) { level in
                    HStack(spacing: Space.sm) {
                        Rectangle().fill((level.tone ?? .warn).ink).frame(width: 1, height: Space.lg)
                        Text([level.label, TranscriptChartFormat.value(level.value, unit: spec.unit)]
                            .compactMap { $0 }.joined(separator: " "))
                            .scaledText(Typography.Size.caption, .medium)
                            .foregroundStyle((level.tone ?? .warn).ink)
                    }
                }
                if spec.omittedSeriesCount > 0 {
                    Text("\(counted(spec.omittedSeriesCount, "more series")) not shown.")
                        .scaledText(Typography.Size.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Stat

// One number, at the size that says it is the finding, with a sentence for how it moved.
// The series behind it runs along the bottom edge of the tile, small enough to read as
// context rather than a chart. With a level to reach, a meter to that level takes its place.
struct TranscriptStatTile: View {
    let spec: TranscriptChartSpec
    let arrives: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.textScale) private var textScale
    @State private var landed: Bool

    init(spec: TranscriptChartSpec, arrives: Bool = true) {
        self.spec = spec
        self.arrives = arrives
        _landed = State(initialValue: !arrives)
    }

    private var target: TranscriptChartSpec.Rule? {
        spec.rules.first { $0.axis == .y && $0.value > 0 }
    }

    private var spark: [Double]? {
        guard target == nil, let values = spec.series.first?.values, values.count > 1 else { return nil }
        return values
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let title = spec.title {
                Text(title)
                    .scaledText(Typography.Size.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                CountingFigure(value: spec.value ?? 0, share: landed ? 1 : 0)
                    .scaledSerif(Typography.Size.figure)
                if let unit = spec.unit {
                    Text(unit).scaledText(Typography.Size.detail).foregroundStyle(.secondary)
                }
            }
            if let target { meter(to: target) }
            if let delta = spec.delta { change(delta) }
            if let caption = spec.caption {
                Text(caption)
                    .scaledText(Typography.Size.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .padding(Space.xl)
        .padding(.bottom, spark == nil ? 0 : ChartMetrics.sparkHeight - Space.xl)
        .frame(maxWidth: .infinity, minHeight: ChartMetrics.statMinHeight * textScale, alignment: .topLeading)
        .background(alignment: .bottom) {
            if let spark {
                StatSpark(values: spark, colour: TranscriptChartPalette.colour(0), drawn: landed)
                    .frame(height: ChartMetrics.sparkHeight)
            }
        }
        .accessibilityElement(children: .combine)
        .onAppear {
            guard !landed else { return }
            if reduceMotion { landed = true } else { withAnimation(ChartMotion.count) { landed = true } }
        }
    }

    // How it moved, as words: the size of the move and which way, then what it is
    // measured against. The colour says whether that was the good way to go.
    private func change(_ delta: TranscriptChartSpec.Delta) -> some View {
        let good = delta.value >= 0 ? delta.risingIsGood : !delta.risingIsGood
        let size = TranscriptChartFormat.value(abs(delta.value), unit: spec.unit)
        return (Text("\(size) \(delta.value >= 0 ? "higher" : "lower")")
            .fontWeight(.semibold)
            .foregroundStyle(good ? Theme.addition : Theme.warningText)
            + Text(delta.label.map { " \($0)" } ?? "").foregroundStyle(.secondary))
            .scaledText(Typography.Size.detail)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func meter(to target: TranscriptChartSpec.Rule) -> some View {
        let share = min(max((spec.value ?? 0) / target.value, 0), 1)
        let ink = (target.tone ?? .warn).ink
        return VStack(spacing: Space.xs) {
            Meter(fraction: landed ? share : share * Double(ChartMotion.zoomGrowth),
                  colour: TranscriptChartPalette.colour(0), height: ChartMetrics.meterHeight)
                .overlay(alignment: .trailing) {
                    Capsule().fill(ink).frame(width: 2, height: ChartMetrics.meterHeight + Space.md)
                }
                .motion(ChartMotion.sparkDraw, value: landed)
            HStack {
                Text(TranscriptChartFormat.compact(spec.value ?? 0))
                    .scaledMono(Typography.Size.micro)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: Space.md)
                Text(target.label ?? TranscriptChartFormat.value(target.value, unit: spec.unit))
                    .scaledText(Typography.Size.micro, .semibold)
                    .foregroundStyle(ink)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, Space.sm)
    }
}

// A number that counts up to its value as `share` goes from nothing to one.
nonisolated private struct CountingFigure: View, Animatable {
    let value: Double
    var share: Double

    var animatableData: Double {
        get { share }
        set { share = newValue }
    }

    var body: some View {
        Text(TranscriptChartFormat.compact(share >= 1 ? value : value * share))
            .monospacedDigit()
    }
}

// The readings behind a headline number, as a line that draws itself along the bottom
// of the tile over a faint wash.
private struct StatSpark: View {
    let values: [Double]
    let colour: Color
    let drawn: Bool

    private struct Line: Shape {
        let values: [Double]
        var closed = false

        func path(in rect: CGRect) -> Path {
            guard values.count > 1, let low = values.min(), let high = values.max() else { return Path() }
            let range = max(high - low, .ulpOfOne)
            // Kept off the top and bottom edges, so the stroke is never cut in half.
            let room = rect.height - Space.md
            var path = Path()
            path.addLines(values.enumerated().map { index, value in
                CGPoint(x: rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1),
                        y: rect.minY + Space.xs + room * CGFloat(1 - (value - low) / range))
            })
            if closed {
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.closeSubpath()
            }
            return path
        }
    }

    var body: some View {
        ZStack {
            Line(values: values, closed: true)
                .fill(colour.opacity(drawn ? 0.09 : 0))
            Line(values: values)
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(colour, style: StrokeStyle(lineWidth: ChartMetrics.sparkLineWidth, lineJoin: .round))
        }
        .motion(ChartMotion.sparkDraw, value: drawn)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Not ready

// What stands in for a chart while the agent is still writing its block: the room it
// will take, with a streak running along the line it will become.
struct ChartArrivingCard: View {
    private static let ghost = [CGPoint(x: 0, y: 0.2), CGPoint(x: 0.6, y: 0.2),
                                CGPoint(x: 0.66, y: 0.85), CGPoint(x: 1, y: 0.74)]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            skeleton(0.55)
            skeleton(0.32)
            CometPath(points: Self.ghost, colour: TranscriptChartPalette.colour(0))
                .frame(height: ChartMetrics.cometHeight)
            Text("The agent is writing out the chart. It draws once the block is complete.")
                .scaledText(Typography.Size.detail)
                .foregroundStyle(.secondary)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chart arriving")
        .accessibilityValue("The agent is writing out the chart")
    }

    private func skeleton(_ share: CGFloat) -> some View {
        GeometryReader { proxy in
            Capsule().fill(Theme.field).frame(width: proxy.size.width * share)
        }
        .frame(height: Space.md)
    }
}

// A chart block that did not draw, with the way to get it. A block that could not be
// read is a failure and says so in the warning colours. One that was whole but empty is
// an answer, and offers a wider window to look in.
struct ChartMissingCard: View {
    let failure: TranscriptChartSpec.Failure

    @Environment(\.askAgent) private var askAgent
    @State private var asked = false

    private var isEmpty: Bool { if case .noReadings = failure { true } else { false } }

    private var detail: String {
        switch failure {
        case .unreadable:
            "The block the agent wrote could not be read, so nothing was drawn."
        case .noReadings(let title):
            "\(title.map { "\"\($0)\"" } ?? "The chart") named its series, but none of them had a reading."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(isEmpty ? "No readings in this window" : "This chart could not be read")
                .scaledText(Typography.Size.body, .semibold)
            Text(detail)
                .scaledText(Typography.Size.detail)
                .opacity(isEmpty ? 1 : 0.85)
                .foregroundStyle(isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warningText))
                .fixedSize(horizontal: false, vertical: true)
            if let askAgent {
                Group {
                    if asked {
                        Text("Asked the agent")
                            .font(Typography.label)
                            .foregroundStyle(.secondary)
                            .transition(.fadeIn)
                    } else {
                        InlineAskButton(title: isEmpty ? "Ask for the last 6 hours"
                                                       : "Ask the agent to draw it again") {
                            askAgent(isEmpty ? ChartFollowUp.widen(title: title) : ChartFollowUp.drawAgain())
                            asked = true
                        }
                    }
                }
                .padding(.top, Space.xs)
            }
        }
        .foregroundStyle(isEmpty ? Color.primary : Theme.warningText)
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(isEmpty ? Theme.card : Theme.warningBackground))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(isEmpty ? Theme.border : Color.clear))
        .motion(Motion.reveal, value: asked)
    }

    private var title: String? { if case .noReadings(let title) = failure { title } else { nil } }
}

// MARK: - Numbers

enum TranscriptChartFormat {
    static func value(_ number: Double, unit: String?) -> String {
        guard let unit, !unit.isEmpty else { return compact(number) }
        // A percent sign sits against its number; a word needs the space.
        return unit == "%" ? "\(compact(number))%" : "\(compact(number)) \(unit)"
    }

    static func compact(_ number: Double) -> String {
        let magnitude = abs(number)
        if magnitude >= 1_000_000 { return trimmed(number / 1_000_000) + "M" }
        if magnitude >= 10_000 { return trimmed(number / 1_000) + "K" }
        if magnitude >= 100 { return String(format: "%.0f", number) }
        if magnitude >= 1 { return trimmed(number) }
        return magnitude == 0 ? "0" : String(format: "%.3g", number)
    }

    // A change, which always says which way it went.
    static func signed(_ number: Double) -> String {
        number > 0 ? "+" + compact(number) : number < 0 ? "-" + compact(-number) : "0"
    }

    // Always a 24-hour clock: a reading at "02:15" in a 12-hour locale could be either
    // end of the day.
    static func clock(_ seconds: Double, seconds showsSeconds: Bool = false,
                      in zone: TimeZone = .current) -> String {
        let local = Int(seconds.rounded(.down)) + zone.secondsFromGMT(for: Date(timeIntervalSince1970: seconds))
        let day = ((local % 86_400) + 86_400) % 86_400
        let clock = String(format: "%02d:%02d", day / 3600, day % 3600 / 60)
        return showsSeconds ? clock + String(format: ":%02d", day % 60) : clock
    }

    private static func day(_ seconds: Double, in zone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.timeZone = zone
        return Date(timeIntervalSince1970: seconds).formatted(style)
    }

    // A mark on the time axis. Marks a day or more apart name the day, and marks closer
    // than a minute carry the seconds.
    static func tick(_ number: Double, isTime: Bool, step: Double, span: Double,
                     in zone: TimeZone = .current) -> String {
        guard isTime else { return compact(number) }
        if step >= 86_400 { return day(number, in: zone) }
        return clock(number, seconds: step < 60, in: zone)
    }

    // One moment, as the strip and the flags write it. Across more than a day the day is
    // part of it, and inside a few minutes the seconds are.
    static func moment(_ number: Double, isTime: Bool, span: Double, in zone: TimeZone = .current) -> String {
        guard isTime else { return compact(number) }
        let time = clock(number, seconds: span <= 600, in: zone)
        return span > 86_400 ? "\(day(number, in: zone)) \(time)" : time
    }

    // How long a stretch of time is, in the largest two units that fit.
    static func span(_ seconds: Double) -> String {
        if seconds < 120 { return "\(Int(seconds.rounded())) s" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 2880 { return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min" }
        return "\(minutes / 1440) d"
    }

    // The clock the times are written in, named beside them so "10:52" is never
    // mistaken for another zone's.
    static var zone: String {
        let zone = TimeZone.current
        return zone.secondsFromGMT() == 0 ? "UTC" : zone.abbreviation() ?? zone.identifier
    }

    private static func trimmed(_ number: Double) -> String {
        let rounded = (number * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded)
    }
}
