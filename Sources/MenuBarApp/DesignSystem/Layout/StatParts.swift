import Charts
import SwiftUI

// The parts Stats is drawn from: numbers, shares, charts and badges. Each takes its colour
// from the thing it measures, so a reading keeps one colour wherever it appears.

// MARK: - Surfaces and marks

extension View {
    // A note set apart inside a card, such as a tip: a faint wash of its colour and an
    // edge in the same colour.
    func washSurface(tint: Color, cornerRadius: CGFloat = Radius.control) -> some View {
        surface(tint.opacity(0.08), cornerRadius: cornerRadius, border: tint.opacity(0.22))
    }
}

// A symbol on a soft square of its own colour, naming what a number measures.
struct IconBadge: View {
    let icon: String
    var tint: Color = Theme.accent
    var side: CGFloat = ControlHeight.sm
    var round = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: side * 0.48, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .background {
                if round {
                    Circle().fill(tint.opacity(0.14))
                } else {
                    RoundedRectangle(cornerRadius: side * 0.3).fill(tint.opacity(0.14))
                }
            }
            .accessibilityHidden(true)
    }
}

// How a number moved against the stretch before, as a small coloured figure with an
// arrow. Green when the move is the good way, amber when it is not.
struct ChangeFigure: View {
    let change: Double
    var lowerIsBetter = false

    // A move that rounds to 0% says nothing, so it is left out.
    static func isWorthSaying(_ change: Double?) -> Bool {
        guard let change, change.isFinite else { return false }
        return abs(change) >= 0.005
    }

    static func tint(_ change: Double, lowerIsBetter: Bool) -> Color {
        (change < 0) == lowerIsBetter ? Theme.dotOnText : Theme.attentionText
    }

    // The move in words, such as "18% less", for a sentence that names what it is against.
    static func words(_ change: Double) -> String {
        let size = abs(change).formatted(.percent.precision(.fractionLength(0)))
        return "\(size) \(change < 0 ? "less" : "more")"
    }

    var body: some View {
        HStack(spacing: Space.xxs) {
            Image(systemName: change > 0 ? "arrow.up.right" : "arrow.down.right")
                .font(Typography.micro)
            Text(abs(change).formatted(.percent.precision(.fractionLength(0))))
                .font(Typography.micro)
                .monospacedDigit()
                .contentTransition(.numericText(value: change))
        }
        .foregroundStyle(Self.tint(change, lowerIsBetter: lowerIsBetter))
        .fixedSize()
    }
}

// MARK: - Numbers

// A small card that says more about one reading from a slim row of them: what it is, the
// number, how it moved in words, and the run of readings behind it. It is the content of
// a hanging `Tooltip`, so it arrives and leaves with the tooltip. The line draws itself
// out from the left when the card opens.
struct ReadingPeek: View {
    let title: String
    let value: String
    var tint: Color = Theme.accent
    var change: Double? = nil
    var lowerIsBetter = false
    // What a change is against, such as "yesterday".
    var versus = ""
    // Said in place of the change when there is none to say.
    var note = ""
    var spark: [Double] = []
    var footnote: String? = nil

    static let width: CGFloat = 248
    private static let sparkHeight: CGFloat = 40

    @State private var drawn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                Circle().fill(tint).frame(width: Space.sm, height: Space.sm)
                Text(title).font(Typography.label)
            }
            Text(value)
                .font(Typography.display)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.top, Space.sm)
            comparison
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if spark.contains(where: { $0 > 0 }) {
                Sparkline(values: Sparkline.thinned(spark), tint: tint)
                    .frame(height: Self.sparkHeight)
                    .mask(alignment: .leading) {
                        Rectangle().frame(maxWidth: drawn ? .infinity : 0)
                    }
                    .motion(Motion.draw, value: drawn)
                    .padding(.top, Space.md)
            }
            if let footnote {
                Text(footnote)
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, Space.md)
            }
        }
        .padding(Space.lg)
        .onAppear { drawn = true }
        .accessibilityElement(children: .combine)
    }

    private var comparison: Text {
        guard let change, ChangeFigure.isWorthSaying(change) else { return Text(note) }
        return Text(ChangeFigure.words(change))
            .fontWeight(.semibold)
            .foregroundStyle(ChangeFigure.tint(change, lowerIsBetter: lowerIsBetter))
            + Text(" than \(versus)")
    }
}

// A run of readings as a line with a wash fading out under it, scaled to its own peak.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = Theme.accent

    // A long run of readings is summed into this many points, so the line keeps its shape
    // instead of turning into noise at the size of a small card.
    static let points = 16

    static func thinned(_ values: [Double]) -> [Double] {
        guard values.count > points + 4 else { return values }
        let group = Int((Double(values.count) / Double(points)).rounded(.up))
        return stride(from: 0, to: values.count, by: group).map { start in
            values[start..<min(start + group, values.count)].reduce(0, +)
        }
    }

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("Step", index), y: .value("Value", value))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Step", index), y: .value("Value", value))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXScale(range: .plotDimension(padding: 0))
        .chartYScale(domain: 0...max((values.max() ?? 0) * 1.15, 0.0001))
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
    var icon: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            if let icon { IconBadge(icon: icon, tint: tint ?? Theme.accent) }
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(label)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(Typography.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(icon == nil ? (tint ?? Color.primary) : Color.primary)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// A record worth a badge: a mark on a round of its colour, what it is, and the reading.
struct RecordBadge: View {
    let icon: String
    let label: String
    let value: String
    var detail: String? = nil
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: Space.lg) {
            IconBadge(icon: icon, tint: tint, side: ControlHeight.xl, round: true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(label)
                    .capsText()
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(Typography.title)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
                if let detail {
                    Text(detail)
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(tint.opacity(0.06), cornerRadius: Radius.card, border: tint.opacity(0.18))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shares

// One thing's share of a whole as a bar: its mark, its name, the bar on a scale shared by
// every row in the list, and the reading. The bar draws out from nothing on arrival.
struct ShareBarRow: View {
    let name: String
    var dot: Theme.ProjectTint? = nil
    // Draws the thing's tile, the way the sidebar draws it, instead of a dot.
    var tile = false
    var tint: Color = Theme.accent
    let value: Double
    // The value that fills the whole bar, shared by every row in one list.
    let scale: Double
    let reading: String
    var detail: String? = nil

    @State private var drawn = false

    static let nameWidth: CGFloat = 156
    static let readingWidth: CGFloat = 64
    static let barHeight: CGFloat = 8
    static let tileSide: CGFloat = 22

    var body: some View {
        let colour = dot?.colour ?? tint
        HStack(spacing: Space.md) {
            HStack(spacing: Space.sm) {
                if let dot {
                    if tile {
                        ProjectTileView(name: name, tint: dot, side: Self.tileSide)
                    } else {
                        ProjectDot(tint: dot)
                    }
                }
                Text(name)
                    .font(Typography.body.weight(tile ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: Self.nameWidth, alignment: .leading)
            GeometryReader { proxy in
                let fraction = scale > 0 ? min(1, max(0, value / scale)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.field)
                    Capsule()
                        .fill(LinearGradient(colors: [colour.opacity(0.75), colour],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: drawn ? max(fraction > 0 ? Self.barHeight : 0, proxy.size.width * fraction) : 0)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: Self.barHeight)
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

// A whole split into its parts along one bar, with a key under it.
struct ShareStrip: View {
    struct Part: Identifiable, Equatable {
        let name: String
        let value: Double
        let tint: Color
        var id: String { name }
    }

    let parts: [Part]
    var format: (Double) -> String = { $0.formatted() }

    @State private var drawn = false

    static let height: CGFloat = 12

    var body: some View {
        let total = max(parts.reduce(0) { $0 + $1.value }, 0.0001)
        VStack(alignment: .leading, spacing: Space.md) {
            GeometryReader { proxy in
                HStack(spacing: Space.xxs) {
                    ForEach(parts) { part in
                        RoundedRectangle(cornerRadius: Radius.tag / 2)
                            .fill(part.tint)
                            .frame(width: max(0, (proxy.size.width - Space.xxs * CGFloat(parts.count - 1))
                                             * part.value / total * (drawn ? 1 : 0)))
                    }
                }
            }
            .frame(height: Self.height)
            .clipShape(Capsule())
            FlowKey(parts: parts, total: total, format: format)
        }
        .motion(Motion.draw, value: drawn)
        .motion(Motion.draw, value: parts)
        .onAppear { drawn = true }
    }

    private struct FlowKey: View {
        let parts: [Part]
        let total: Double
        let format: (Double) -> String

        var body: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Space.md, alignment: .leading)],
                      alignment: .leading, spacing: Space.sm) {
                ForEach(parts) { part in
                    HStack(spacing: Space.xs) {
                        RoundedRectangle(cornerRadius: Radius.tag / 2).fill(part.tint)
                            .frame(width: Space.md, height: Space.md)
                        Text(part.name).font(Typography.caption)
                        Text(format(part.value))
                            .font(Typography.caption.weight(.semibold))
                            .monospacedDigit()
                        Text((part.value / total).formatted(.percent.precision(.fractionLength(0))))
                            .font(Typography.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}

// A whole as a ring of its parts, with the leading part named in the middle.
struct ShareDonut: View {
    let parts: [ShareStrip.Part]
    var format: (Double) -> String = { $0.formatted() }

    @State private var drawn = false

    static let side: CGFloat = 112

    var body: some View {
        let total = max(parts.reduce(0) { $0 + $1.value }, 0.0001)
        HStack(spacing: Space.xl) {
            Chart(parts) { part in
                SectorMark(angle: .value("Share", drawn ? part.value : 0.0001),
                           innerRadius: .ratio(0.64), angularInset: 1.5)
                    .cornerRadius(Radius.tag / 2)
                    .foregroundStyle(part.tint)
            }
            .chartLegend(.hidden)
            .frame(width: Self.side, height: Self.side)
            .overlay {
                // The key beside the ring names every part, so the middle only has to
                // say how much the leading one holds, in that part's own colour.
                if let lead = parts.first {
                    VStack(spacing: 0) {
                        Text((lead.value / total).formatted(.percent.precision(.fractionLength(0))))
                            .font(Typography.title)
                            .monospacedDigit()
                            .foregroundStyle(lead.tint)
                        Text("of the time")
                            .font(Typography.micro.weight(.regular))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(parts) { part in
                    HStack(spacing: Space.sm) {
                        Circle().fill(part.tint).frame(width: Space.md, height: Space.md)
                        Text(part.name).font(Typography.detail).lineLimit(1)
                        Spacer(minLength: Space.sm)
                        Text(format(part.value))
                            .font(Typography.detail.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }
        }
        .motion(Motion.draw, value: drawn)
        .onAppear { drawn = true }
    }
}

// MARK: - Charts

// A week as seven rows of hours, each cell as deep as its count, with a key from less to
// more. Hovering a cell says what it holds on the line under the grid.
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

    static let cellHeight: CGFloat = 16
    static let rowLabelWidth: CGFloat = 32
    static let keySteps: [Double] = [0, 0.25, 0.5, 0.75, 1]

    private func fill(_ value: Int, peak: Int) -> Color {
        value == 0 ? Theme.sunken : tint.opacity(0.2 + 0.8 * Double(value) / Double(peak))
    }

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
                        RoundedRectangle(cornerRadius: Radius.tag)
                            .fill(fill(value, peak: peak))
                            .overlay {
                                if hovered == cell {
                                    RoundedRectangle(cornerRadius: Radius.tag).stroke(Color.primary.opacity(0.55), lineWidth: 1.5)
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
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: Space.xs) {
                Text(hovered.map { describe($0.row, $0.column, values[$0.row][$0.column]) }
                     ?? "Point at a square to see what it holds")
                    .font(Typography.caption)
                    .foregroundStyle(hovered == nil ? .tertiary : .secondary)
                    .contentTransition(.opacity)
                Spacer(minLength: Space.md)
                Text("Less").font(Typography.caption).foregroundStyle(.tertiary)
                ForEach(Self.keySteps, id: \.self) { step in
                    RoundedRectangle(cornerRadius: Radius.tag / 2)
                        .fill(step == 0 ? Theme.sunken : tint.opacity(0.2 + 0.8 * step))
                        .frame(width: Space.md + Space.xxs, height: Space.md + Space.xxs)
                }
                Text("More").font(Typography.caption).foregroundStyle(.tertiary)
            }
            .padding(.top, Space.sm)
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
