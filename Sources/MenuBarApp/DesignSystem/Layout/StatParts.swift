import Charts
import SwiftUI

// MARK: - Numbers

// One headline number: what it counts, the number, how it moved against the stretch
// before, and a line under it showing how it got there.
struct StatTile: View {
    let title: String
    let value: String
    // The raw reading behind `value`, so the figures roll rather than swap when it moves.
    var reading: Double
    var change: Double? = nil
    // Some numbers are better when they fall, such as the time spent waiting.
    var lowerIsBetter = false
    var comparison: String? = nil
    var spark: [Double] = []
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title)
                .capsText()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(Typography.display)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText(value: reading))
            changeLine
            Sparkline(values: spark, tint: tint)
                .frame(height: Self.sparkHeight)
        }
        .padding(Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .motion(Motion.control, value: reading)
        .accessibilityElement(children: .combine)
    }

    static let sparkHeight: CGFloat = 24

    @ViewBuilder private var changeLine: some View {
        HStack(spacing: Space.xs) {
            if let change, change.isFinite, abs(change) >= 0.005 {
                let good = (change < 0) == lowerIsBetter
                Image(systemName: change > 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(Typography.micro)
                Text(change.formatted(.percent.precision(.fractionLength(0))))
                    .font(Typography.caption.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: change))
                    .foregroundStyle(good ? Theme.dotOnText : Theme.attentionText)
            } else if comparison != nil {
                Text("No change")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
            if let comparison {
                Text(comparison)
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(change.map { ($0 < 0) == lowerIsBetter ? Theme.dotOnText : Theme.attentionText } ?? .secondary)
        .frame(height: ControlHeight.xs * 0.7, alignment: .leading)
    }
}

// A run of readings as a line with a wash under it, scaled to its own peak.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = Theme.accent

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("Step", index), y: .value("Value", value))
                    .foregroundStyle(tint.opacity(0.12))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Step", index), y: .value("Value", value))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: 0...max(values.max() ?? 0, 0.0001))
        .motion(Motion.draw, value: values)
        .accessibilityHidden(true)
    }
}

// A small fact in a grid of them: what it is, the reading, and what it means.
struct StatFact: View {
    let label: String
    let value: String
    var detail: String? = nil
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(Typography.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint ?? Color.primary)
                .lineLimit(1)
                .contentTransition(.numericText())
            if let detail {
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shares

// One thing's share of a whole as a bar: its name, the bar on a scale shared by every
// row in the list, and the reading. The bar draws out from nothing when the row arrives.
struct ShareBarRow: View {
    let name: String
    var dot: Theme.ProjectTint? = nil
    var tint: Color = Theme.accent
    let value: Double
    // The value that fills the whole bar, shared by every row in one list.
    let scale: Double
    let reading: String
    var detail: String? = nil

    @State private var drawn = false

    static let nameWidth: CGFloat = 168
    static let readingWidth: CGFloat = 64

    var body: some View {
        HStack(spacing: Space.md) {
            HStack(spacing: Space.sm) {
                if let dot { ProjectDot(tint: dot) }
                Text(name)
                    .font(Typography.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: Self.nameWidth, alignment: .leading)
            GeometryReader { proxy in
                let fraction = scale > 0 ? min(1, max(0, value / scale)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border)
                    Capsule().fill(dot?.colour ?? tint)
                        .frame(width: drawn ? max(fraction > 0 ? 4 : 0, proxy.size.width * fraction) : 0)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: Space.sm)
            Text(reading)
                .font(Typography.detail.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: value))
                .frame(width: Self.readingWidth, alignment: .trailing)
            if let detail {
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: Self.readingWidth * 1.6, alignment: .trailing)
            }
        }
        .motion(Motion.draw, value: drawn)
        .motion(Motion.draw, value: value)
        .onAppear { drawn = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, reading, detail].compactMap { $0 }.joined(separator: ", "))
    }
}

// The key to a chart's colours: a dot, a name and its total.
struct LegendItem: View {
    let name: String
    let tint: Theme.ProjectTint
    var value: String? = nil

    var body: some View {
        HStack(spacing: Space.xs) {
            ProjectDot(tint: tint)
            Text(name).font(Typography.caption).lineLimit(1)
            if let value {
                Text(value).font(Typography.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

// MARK: - Charts

// Totals over time, each bar split into the things it is made of. Hovering a bar picks
// it out and says what it holds.
struct StackedBarChart: View {
    struct Piece: Identifiable, Equatable {
        let id: String
        let name: String
        let value: Double
        let tint: Color
    }

    struct Bar: Identifiable, Equatable {
        // Unique along the axis, and what the axis writes under the bar.
        let id: String
        // The longer name the readout uses.
        let title: String
        let pieces: [Piece]

        var total: Double { pieces.reduce(0) { $0 + $1.value } }
    }

    let bars: [Bar]
    // The bars whose names are written under the axis, so a month does not crowd it.
    var labelled: [String]? = nil
    let format: (Double) -> String

    @State private var selected: String?
    @State private var drawn = false

    static let height: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            readout
            Chart {
                ForEach(bars) { bar in
                    ForEach(bar.pieces) { piece in
                        BarMark(x: .value("When", bar.id),
                                y: .value("Value", drawn ? piece.value : 0),
                                width: .ratio(0.72))
                            .foregroundStyle(piece.tint)
                            .opacity(selected == nil || selected == bar.id ? 1 : 0.35)
                            .cornerRadius(Radius.tag / 2)
                    }
                }
            }
            .chartLegend(.hidden)
            // Every bar keeps its place on the axis, so an empty day or hour shows as a
            // gap rather than dropping out and closing the days either side together.
            .chartXScale(domain: bars.map(\.id))
            .chartXSelection(value: $selected)
            .chartXAxis {
                // Every bar has a mark, but only the labelled ones write their name, so a
                // month does not run thirty dates into one another under the axis.
                let named = Set(labelled ?? bars.map(\.id))
                AxisMarks(values: bars.map(\.id)) { value in
                    if let id = value.as(String.self), named.contains(id) {
                        AxisValueLabel(collisionResolution: .disabled)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        if let reading = value.as(Double.self) {
                            Text(format(reading))
                                .font(Typography.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
            .frame(height: Self.height)
            .motion(Motion.draw, value: drawn)
            .motion(Motion.hover, value: selected)
        }
        .onAppear { drawn = true }
    }

    // Says what the bar under the pointer holds, or the whole when there is none.
    private var readout: some View {
        let bar = selected.flatMap { id in bars.first { $0.id == id } }
        let text: String = if let bar {
            ([bar.title + " · " + format(bar.total)]
                + bar.pieces.prefix(3).map { "\($0.name) \(format($0.value))" })
                .joined(separator: "   ")
        } else {
            "Point at a bar to see what it holds"
        }
        return Text(text)
            .font(Typography.caption)
            .foregroundStyle(bar == nil ? .tertiary : .secondary)
            .monospacedDigit()
            .lineLimit(1)
            .contentTransition(.opacity)
            .motion(Motion.hover, value: selected)
    }
}

// A week as seven rows of hours, each cell as deep as its count. Hovering a cell says
// what it holds on the line under the grid.
struct HeatGrid: View {
    let rows: [String]
    let values: [[Int]]
    // The hours written under the grid.
    var columnLabels: [Int: String] = [:]
    var tint: Color = Theme.accent
    let describe: (_ row: Int, _ column: Int, _ value: Int) -> String

    @State private var hovered: Cell?

    private struct Cell: Equatable {
        let row: Int
        let column: Int
    }

    static let cellHeight: CGFloat = 14
    static let rowLabelWidth: CGFloat = 32

    var body: some View {
        let peak = max(values.flatMap { $0 }.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: Space.xxs) {
                    Text(rows[row])
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.rowLabelWidth, alignment: .leading)
                    ForEach(values[row].indices, id: \.self) { column in
                        let value = values[row][column]
                        let cell = Cell(row: row, column: column)
                        RoundedRectangle(cornerRadius: Radius.tag / 2)
                            .fill(value == 0 ? Theme.sunken : tint.opacity(0.18 + 0.82 * Double(value) / Double(peak)))
                            .overlay {
                                if hovered == cell {
                                    RoundedRectangle(cornerRadius: Radius.tag / 2).stroke(Color.primary.opacity(0.5))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: Self.cellHeight)
                            .onPointerHover { inside in
                                if inside { hovered = cell } else if hovered == cell { hovered = nil }
                            }
                    }
                }
            }
            HStack(spacing: Space.xxs) {
                Color.clear.frame(width: Self.rowLabelWidth, height: 1)
                ForEach(0..<(values.first?.count ?? 0), id: \.self) { column in
                    Text(columnLabels[column] ?? "")
                        .font(Typography.micro.weight(.regular))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(hovered.map { describe($0.row, $0.column, values[$0.row][$0.column]) }
                 ?? "Point at a square to see what it holds")
                .font(Typography.caption)
                .foregroundStyle(hovered == nil ? .tertiary : .secondary)
                .contentTransition(.opacity)
                .padding(.top, Space.xs)
        }
        .motion(Motion.hover, value: hovered)
    }
}

// MARK: - Progress

// Work the person is waiting on, with how far it has got. On its own (`compact: false`)
// it stands in the middle of an empty pane for a first load; compact, it is a strip over
// content already on screen, saying that more is still arriving. With no total yet it
// shows the spinner and words without a bar.
struct ProgressCard: View {
    let title: String
    let detail: String
    var done = 0
    var total = 0
    // What is being counted, such as "sessions".
    var unit = "items"
    var compact = false

    static let width: CGFloat = 440
    static let compactBarWidth: CGFloat = 160

    private var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    var body: some View {
        Group {
            if compact { strip } else { card }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(total > 0 ? "\(done) of \(total) \(unit)" : "")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                LoopSpinner(colour: Theme.accent, size: Typography.Size.title)
                Text(title).font(Typography.title)
            }
            Text(detail)
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if total > 0 {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Meter(fraction: fraction, colour: Theme.accent)
                        .motion(Motion.draw, value: fraction)
                    HStack {
                        Text("\(done) of \(total) \(unit)")
                            .contentTransition(.numericText(value: Double(done)))
                        Spacer()
                        Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                            .contentTransition(.numericText(value: fraction))
                    }
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                .padding(.top, Space.xs)
                .transition(.fadeIn)
            }
        }
        .padding(Space.xl)
        .frame(width: Self.width, alignment: .leading)
        .cardSurface(cornerRadius: Radius.floating)
        .motion(Motion.reveal, value: total > 0)
    }

    private var strip: some View {
        HStack(spacing: Space.md) {
            LoopSpinner(colour: Theme.accent, size: Typography.Size.body)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(total > 0 ? "\(title) · \(done) of \(total)" : title)
                    .font(Typography.body.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(done)))
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.md)
            if total > 0 {
                Meter(fraction: fraction, colour: Theme.accent)
                    .frame(width: Self.compactBarWidth)
                    .motion(Motion.draw, value: fraction)
            }
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, Space.md)
        .surface(Theme.accent.opacity(0.08), cornerRadius: Radius.card, border: Theme.accent.opacity(0.25))
    }
}
