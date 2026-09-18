import Charts
import SwiftUI

// A chart drawn in the transcript from the data the reply carried. Everything here is the
// app's own palette and type, so a chart reads as part of the answer rather than as a
// picture pasted into it.
struct TranscriptChartView: View {
    let spec: TranscriptChartSpec

    @State private var hovered: Hover?
    @State private var readoutSize: CGSize = .zero
    @State private var showsSummary = false

    // Where the pointer is, kept alongside the reading it picked out so the readout can
    // ride the pointer while the marks stay snapped to real measurements.
    private struct Hover: Equatable {
        let value: Double
        let location: CGPoint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if spec.title != nil || spec.caption != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let title = spec.title {
                        Text(title)
                            .scaledText(12.5, .semibold)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let caption = spec.caption {
                        Text(caption)
                            .scaledText(11)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            switch spec.kind {
            case .stat:
                TranscriptStatTile(spec: spec)
            case .bar:
                bars
            case .line, .area:
                timeSeries
            }

            if spec.series.count > 1 {
                TranscriptChartLegend(spec: spec)
            }

            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }

    // MARK: - Lines and areas

    private var timeSeries: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.element.id) { index, series in
                ForEach(series.points.indices, id: \.self) { position in
                    let point = series.points[position]
                    // The wash is filled from the floor of the scale rather than from
                    // zero, which on a scale that starts at nine hundred would spill out
                    // of the plot and down the card.
                    if spec.kind == .area {
                        AreaMark(x: .value("x", point.x.number ?? 0),
                                 yStart: .value(spec.unit ?? "value", verticalDomain.lowerBound),
                                 yEnd: .value(spec.unit ?? "value", point.y))
                            .foregroundStyle(TranscriptChartPalette.colour(index).opacity(0.10))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("x", point.x.number ?? 0),
                             y: .value(spec.unit ?? "value", point.y),
                             series: .value("series", series.label))
                        .foregroundStyle(TranscriptChartPalette.colour(index))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }

                // The end of a line is where the eye lands, so the series is named there
                // when the lines have separated enough for the name to belong to one of
                // them. When they converge the legend carries identity instead.
                if labelsEnds, let last = series.points.last {
                    PointMark(x: .value("x", last.x.number ?? 0),
                              y: .value(spec.unit ?? "value", last.y))
                        .symbolSize(64)
                        .foregroundStyle(TranscriptChartPalette.colour(index))
                        .annotation(position: .trailing, spacing: 6) {
                            Text(series.label)
                                .scaledText(10, .medium)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                }
            }

            ForEach(spec.rules) { rule in
                if rule.axis == .y {
                    RuleMark(y: .value("", rule.value))
                        .foregroundStyle(Theme.attentionText)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, alignment: .trailing, spacing: 2) {
                            ruleLabel(rule)
                        }
                } else {
                    RuleMark(x: .value("", rule.value))
                        .foregroundStyle(Theme.attentionText)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            ruleLabel(rule)
                        }
                }
            }

            if let hovered, let x = snapped(hovered.value) {
                RuleMark(x: .value("", x))
                    .foregroundStyle(Theme.chartGrid)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: horizontalDomain)
        .chartYScale(domain: verticalDomain)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(preset: .aligned) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Theme.chartGrid)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(TranscriptChartFormat.axis(raw, isTime: spec.isTime))
                            .scaledText(10)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Theme.chartGrid)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(TranscriptChartFormat.compact(raw))
                            .scaledText(10)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        // The pointer aims at a moment, never at a two-point line, so the readout snaps to
        // the nearest reading and names every series at once. It then rides the pointer,
        // which keeps the numbers where the eye already is instead of asking it to travel
        // to a corner and back for every reading along the line.
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plot = proxy.plotFrame {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let inside = location.x - geometry[plot].origin.x
                                if let value = proxy.value(atX: inside, as: Double.self) {
                                    hovered = Hover(value: value, location: location)
                                } else {
                                    hovered = nil
                                }
                            case .ended:
                                hovered = nil
                            }
                        }

                    if let hovered, let x = snapped(hovered.value) {
                        TranscriptChartReadout(spec: spec, x: x)
                            .fixedSize()
                            .background(
                                GeometryReader { card in
                                    Color.clear.onChange(of: card.size, initial: true) {
                                        readoutSize = card.size
                                    }
                                }
                            )
                            .offset(TranscriptChartReadout.placement(
                                pointer: hovered.location, card: readoutSize,
                                within: geometry.size))
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(height: 200)
        // A moment marked on the x axis writes its name above the plot, which needs room
        // of its own or it crowds whatever the chart is captioned with.
        .padding(.top, spec.rules.contains { $0.axis == .x } ? 12 : 0)
    }

    private func ruleLabel(_ rule: TranscriptChartSpec.Rule) -> some View {
        Text(rule.label ?? TranscriptChartFormat.compact(rule.value))
            .scaledText(10, .medium)
            .foregroundStyle(Theme.attentionText)
            .lineLimit(1)
    }

    // Measurements rather than zero to the peak: an incident is read from the shape of
    // the change, and a queue that never drops below nine hundred would otherwise draw
    // itself flat along the top of the plot.
    private var verticalDomain: ClosedRange<Double> {
        let values = spec.series.flatMap(\.values)
            + spec.rules.filter { $0.axis == .y }.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        guard high > low else { return low...(low + 1) }
        let padding = (high - low) * 0.08
        return (low - padding)...(high + padding)
    }

    // A numeric scale left to itself reaches back to zero, which for unix seconds means
    // an hour of readings drawn as one stroke at the right hand edge.
    private var horizontalDomain: ClosedRange<Double> {
        let positions = spec.series.flatMap { $0.points.compactMap(\.x.number) }
            + spec.rules.filter { $0.axis == .x }.map(\.value)
        let low = positions.min() ?? 0
        let high = positions.max() ?? 1
        guard high > low else { return low...(low + 1) }
        // Room for the names that ride the ends, which would otherwise be drawn past the
        // edge of the plot and clipped.
        return low...(high + (labelsEnds ? (high - low) * 0.18 : 0))
    }

    // Names ride the lines only while the lines are apart at the right edge. Nudging
    // labels off converging lines detaches them from what they name.
    private var labelsEnds: Bool {
        guard (2...4).contains(spec.series.count) else { return spec.series.count == 1 }
        let ends = spec.series.compactMap(\.points.last?.y).sorted()
        guard ends.count == spec.series.count else { return false }
        let span = verticalDomain.upperBound - verticalDomain.lowerBound
        return zip(ends, ends.dropFirst()).allSatisfy { $1 - $0 >= span * 0.08 }
    }

    private func snapped(_ x: Double) -> Double? {
        let positions = spec.series.flatMap { $0.points.compactMap(\.x.number) }
        return positions.min { abs($0 - x) < abs($1 - x) }
    }

    // MARK: - Bars

    // Drawn along the x axis because the things being compared are named: endpoints, pods
    // and queues have long names, and a horizontal bar lets them be read straight.
    private var bars: some View {
        Chart {
            ForEach(Array(spec.series.enumerated()), id: \.element.id) { index, series in
                ForEach(series.points.indices, id: \.self) { position in
                    let point = series.points[position]
                    BarMark(x: .value(spec.unit ?? "value", point.y),
                            y: .value("category", point.x.category ?? ""),
                            height: .fixed(spec.series.count > 1 ? 14 : 22))
                        .foregroundStyle(TranscriptChartPalette.colour(index))
                        .position(by: .value("series", series.label))
                        .cornerRadius(4)
                        .annotation(position: .trailing, spacing: 6) {
                            if spec.series.count == 1 {
                                Text(TranscriptChartFormat.value(point.y, unit: spec.unit))
                                    .scaledText(10, .medium)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                }
            }

            ForEach(spec.rules.filter { $0.axis == .y }) { rule in
                RuleMark(x: .value("", rule.value))
                    .foregroundStyle(Theme.attentionText)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        ruleLabel(rule)
                    }
            }
        }
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(preset: .aligned) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Theme.chartGrid)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(TranscriptChartFormat.compact(raw))
                            .scaledText(10)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .leading) { value in
                AxisValueLabel(horizontalSpacing: 8) {
                    if let name = value.as(String.self) {
                        Text(name)
                            .scaledText(10)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: min(max(CGFloat(categoryCount) * rowHeight + 34, 96), 460))
    }

    private var categoryCount: Int {
        Set(spec.series.flatMap { $0.points.compactMap(\.x.category) }).count
    }

    private var rowHeight: CGFloat {
        spec.series.count > 1 ? CGFloat(spec.series.count) * 18 + 10 : 32
    }

    // MARK: - Footer

    @ViewBuilder private var footer: some View {
        let omitted = spec.omittedSeriesCount
        HStack(spacing: 10) {
            if omitted > 0 {
                Text("\(counted(omitted, "more series")) not shown.")
                    .scaledText(10.5)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if spec.kind != .stat {
                Button { showsSummary.toggle() } label: {
                    Text(showsSummary ? "Hide values" : "Values")
                        .scaledText(10.5, .medium)
                        .foregroundStyle(Theme.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }

        if showsSummary {
            TranscriptChartSummary(spec: spec)
        }
    }
}

// MARK: - Palette

enum TranscriptChartPalette {
    static func colour(_ index: Int) -> Color {
        Theme.chartSeries[index % Theme.chartSeries.count]
    }
}

// MARK: - Legend

// Always present once there are two series, so identity never rests on matching colours
// from memory. A line is keyed by a stroke and a fill by a swatch, mirroring the mark.
struct TranscriptChartLegend: View {
    let spec: TranscriptChartSpec

    var body: some View {
        FlowRow(spacing: 12) {
            ForEach(Array(spec.series.enumerated()), id: \.element.id) { index, series in
                HStack(spacing: 6) {
                    if spec.kind == .line {
                        Capsule()
                            .fill(TranscriptChartPalette.colour(index))
                            .frame(width: 14, height: 2)
                    } else {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(TranscriptChartPalette.colour(index))
                            .frame(width: 9, height: 9)
                    }
                    Text(series.label)
                        .scaledText(10.5)
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

// MARK: - Hover readout

// One card for every series at the hovered moment. The number leads and the name follows,
// because the reader already knows which series they are chasing and wants the value.
struct TranscriptChartReadout: View {
    let spec: TranscriptChartSpec
    let x: Double

    // Room between the pointer and the card, so the card never sits under the cursor and
    // hides the very reading it is naming.
    private static let gap: CGFloat = 16

    // The card follows the pointer, but it is the plot that decides where it can go: it
    // swaps to the other side of the pointer rather than run off the right edge, and it
    // is held inside the plot on both axes so no part of it is ever clipped away.
    static func placement(pointer: CGPoint, card: CGSize, within plot: CGSize) -> CGSize {
        let right = pointer.x + gap
        let left = pointer.x - gap - card.width
        let x = right + card.width <= plot.width || left < 0 ? right : left
        let y = pointer.y - card.height / 2
        return CGSize(width: min(max(0, x), max(0, plot.width - card.width)),
                      height: min(max(0, y), max(0, plot.height - card.height)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TranscriptChartFormat.axis(x, isTime: spec.isTime, long: true))
                .scaledText(10)
                .foregroundStyle(.secondary)
            ForEach(Array(spec.series.enumerated()), id: \.element.id) { index, series in
                if let point = nearest(in: series) {
                    HStack(spacing: 6) {
                        Capsule()
                            .fill(TranscriptChartPalette.colour(index))
                            .frame(width: 10, height: 2)
                        Text(TranscriptChartFormat.value(point.y, unit: spec.unit))
                            .scaledText(11, .semibold)
                            .monospacedDigit()
                        Text(series.label)
                            .scaledText(10)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.background))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
    }

    private func nearest(in series: TranscriptChartSpec.Series) -> TranscriptChartSpec.Point? {
        series.points.min { first, second in
            abs((first.x.number ?? 0) - x) < abs((second.x.number ?? 0) - x)
        }
    }
}

// MARK: - Summary

// What the hover shows, reachable without a pointer. A transcript chart is usually read
// for its extremes and where it ended up, so those are the columns.
struct TranscriptChartSummary: View {
    let spec: TranscriptChartSpec

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(spec.series.enumerated()), id: \.element.id) { index, series in
                if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(TranscriptChartPalette.colour(index))
                        .frame(width: 7, height: 7)
                    Text(series.label)
                        .scaledText(10.5)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    ForEach(columns(of: series), id: \.name) { column in
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(column.name)
                                .scaledText(9)
                                .foregroundStyle(.tertiary)
                            Text(column.value)
                                .scaledText(10.5, .medium)
                                .monospacedDigit()
                        }
                        .frame(minWidth: 52, alignment: .trailing)
                    }
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sunken))
    }

    private func columns(of series: TranscriptChartSpec.Series) -> [(name: String, value: String)] {
        let values = series.values
        guard let low = values.min(), let high = values.max(), let last = values.last else { return [] }
        return [("min", TranscriptChartFormat.value(low, unit: spec.unit)),
                ("max", TranscriptChartFormat.value(high, unit: spec.unit)),
                ("last", TranscriptChartFormat.value(last, unit: spec.unit))]
    }
}

// MARK: - Stat

// One number, at the size that says it is the finding. The sparkline underneath is the
// same series in the same colour, small enough to read as context rather than a chart.
struct TranscriptStatTile: View {
    let spec: TranscriptChartSpec

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(TranscriptChartFormat.value(spec.value ?? 0, unit: spec.unit))
                    .scaledText(30, .semibold)
                if let delta = spec.delta {
                    HStack(spacing: 5) {
                        Image(systemName: delta.value >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 9, weight: .bold))
                        Text(TranscriptChartFormat.value(abs(delta.value), unit: spec.unit))
                            .scaledText(11, .semibold)
                            .monospacedDigit()
                        if let label = delta.label {
                            Text(label)
                                .scaledText(10.5)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(isGood(delta) ? Theme.addition : Theme.deletion)
                }
            }
            .textSelection(.enabled)

            if let series = spec.series.first, series.points.count > 1 {
                Chart {
                    ForEach(series.points.indices, id: \.self) { position in
                        let point = series.points[position]
                        LineMark(x: .value("x", point.x.number ?? Double(position)),
                                 y: .value("value", point.y))
                            .foregroundStyle(TranscriptChartPalette.colour(0))
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 40)
                .frame(maxWidth: 200)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isGood(_ delta: TranscriptChartSpec.Delta) -> Bool {
        delta.value >= 0 ? delta.risingIsGood : !delta.risingIsGood
    }
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

    static func axis(_ number: Double, isTime: Bool, long: Bool = false) -> String {
        guard isTime else { return compact(number) }
        let date = Date(timeIntervalSince1970: number)
        return date.formatted(.dateTime.hour().minute().second(long ? .twoDigits : .omitted))
    }

    private static func trimmed(_ number: Double) -> String {
        let rounded = (number * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded)
    }
}
