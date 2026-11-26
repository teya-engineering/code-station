import SwiftUI

// A line or area chart read as evidence: one lane per unit on a shared time axis, the
// moments that matter named in a rail above it, and the numbers in a strip over the plot
// rather than in a card that covers the data.
struct TranscriptLineChart: View {
    let spec: TranscriptChartSpec
    // Whether the lines draw themselves in. A chart that streamed into a reply stands
    // complete instead, since nothing plays for text the reader did not ask to see move.
    let arrives: Bool

    private let model: ChartLanes
    // The widest value each series ever shows, which holds its place in the strip so the
    // names beside it do not shuffle as the pointer moves.
    private let widest: [Int: String]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.textScale) private var textScale
    @Environment(\.askAgent) private var askAgent

    @State private var window = 0
    @State private var zoomed: TranscriptChartSpec.Window?
    @State private var previous: ChartFrame
    @State private var shown: ChartFrame
    @State private var phase = 0.0
    @State private var drawn: Double
    @State private var solo: Int?
    @State private var dim = 0.0
    @State private var hover: Double?
    @State private var selection: Selection?
    @State private var dragging = false
    @State private var showsValues = false
    @State private var stripHeight: CGFloat = 0
    @State private var pillWidth: CGFloat = 0
    @Namespace private var thumb
    @FocusState private var focused: Bool

    private struct Selection: Equatable {
        var anchor: Double
        var end: Double
        var from: Double { min(anchor, end) }
        var to: Double { max(anchor, end) }
    }

    init(spec: TranscriptChartSpec, arrives: Bool = true) {
        self.spec = spec
        self.arrives = arrives
        let model = ChartLanes(spec)
        self.model = model
        widest = Dictionary(uniqueKeysWithValues: model.solidLines.map { line in
            let values = line.readings + (model.projection(of: line)?.readings ?? [])
            let longest = values.map { TranscriptChartFormat.compact($0.y) }.max { $0.count < $1.count }
            return (line.id, longest ?? "")
        })
        let whole = model.windows[0]
        let frame = model.frame(from: whole.from, to: whole.to)
        _previous = State(initialValue: frame)
        _shown = State(initialValue: frame)
        _drawn = State(initialValue: arrives ? 0 : 1)
    }

    private var windows: [TranscriptChartSpec.Window] { model.windows + (zoomed.map { [$0] } ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            heading
            strip
            plot
            footer
            if showsValues {
                table.transition(reduceMotion ? AnyTransition.opacity.animation(Motion.reveal) : .fold)
            }
        }
        .smoothlyResizes(when: showsValues)
        .onAppear(perform: arrive)
    }

    // MARK: - Heading and views

    private var heading: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Space.xl) {
                ChartHeading(title: spec.title, caption: spec.caption)
                if windows.count > 1 { track.fixedSize() }
            }
            VStack(alignment: .leading, spacing: Space.md) {
                ChartHeading(title: spec.title, caption: spec.caption)
                if windows.count > 1 {
                    // The track hugs its pills, and wraps them when the card is too
                    // narrow to hold them on one line.
                    ViewThatFits(in: .horizontal) {
                        track.fixedSize()
                        track
                    }
                }
            }
        }
    }

    private var track: some View {
        FlowRow(spacing: Space.xxs) {
            ForEach(Array(windows.enumerated()), id: \.offset) { index, one in
                ChoicePill(title: one.label, selected: index == window, thumb: thumb) { show(index) }
            }
        }
        .padding(Space.xxs)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.field))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Time window")
    }

    private func show(_ index: Int) {
        let one = windows[index]
        window = index
        hover = nil
        selection = nil
        let next = model.frame(from: one.from, to: one.to)
        guard next != shown else { return }
        previous = shown
        shown = next
        // The axis and every lane's scale move as one, so the lines stay attached to
        // their numbers on the way. Under Reduce Motion the new view is simply there.
        withAnimation(reduceMotion ? nil : ChartMotion.zoom) { phase += 1 }
    }

    private func arrive() {
        guard drawn < 1 else { return }
        guard !reduceMotion else {
            drawn = 1
            return
        }
        withAnimation(ChartMotion.lineDraw) { drawn = 1 }
    }

    // MARK: - Readout strip

    // The legend is the readout: each series is named once, with its key and what it
    // reads. At rest that is the latest reading, under the pointer the reading at that
    // moment, and across a marked window the first, the last and the change.
    private var strip: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            FlowRow(spacing: Space.lg) {
                ForEach(model.solidLines) { line in
                    read(line)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stripHeight = max(stripHeight, $0) }
            // Holds the tallest the strip has been, so a longer reading that wraps it once
            // does not move the plot under the pointer a second time.
            .frame(minHeight: stripHeight, alignment: .topLeading)
            // Each reading is padded for its hover fill, so the row is pulled back to
            // start on the same line as the title.
            .padding(.leading, -Space.sm)
            Text(whenText)
                .scaledMono(Typography.Size.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
                .padding(.vertical, Space.xxs)
        }
    }

    private func read(_ line: ChartLanes.Line) -> some View {
        let unit = model.lanes[model.lane(of: line)].unit
        return HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Capsule()
                .fill(TranscriptChartPalette.colour(line.slot))
                .frame(width: ChartMetrics.keyWidth, height: ChartMetrics.keyHeight)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + Space.xs }
            Text(line.label)
                .scaledText(Typography.Size.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: ChartMetrics.nameWidth * textScale)
            value(line)
            if let unit {
                Text(unit)
                    .scaledText(Typography.Size.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xxs)
        .background(RoundedRectangle(cornerRadius: Radius.inset)
            .fill(solo == line.slot && dim > 0 ? Theme.field : Color.clear))
        .onPointerHover { inside in
            if inside { solo = line.slot }
            guard inside || solo == line.slot else { return }
            withAnimation(reduceMotion ? nil : Motion.hover) { dim = inside ? 1 : 0 }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func value(_ line: ChartLanes.Line) -> some View {
        if let selection {
            if let first = model.readout(line, at: selection.from),
               let last = model.readout(line, at: selection.to) {
                let change = last.value - first.value
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    figure(TranscriptChartFormat.compact(first.value))
                    Text("→").scaledMono(Typography.Size.body).foregroundStyle(.tertiary)
                    figure(TranscriptChartFormat.compact(last.value))
                    Text(TranscriptChartFormat.signed(change))
                        .scaledMono(Typography.Size.caption, .semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Space.xs)
                        .background(RoundedRectangle(cornerRadius: Radius.tag).fill(Theme.field))
                }
            } else {
                noReading
            }
        } else if let reading = hover.map({ model.readout(line, at: $0) }) ?? model.latestReadout(line) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                ZStack(alignment: .leading) {
                    figure(widest[line.id] ?? "").hidden()
                    figure(TranscriptChartFormat.compact(reading.value))
                }
                if reading.isProjected {
                    Text("PROJECTED")
                        .capsText()
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Space.xs)
                        .overlay(RoundedRectangle(cornerRadius: Radius.tag)
                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .foregroundStyle(.tertiary))
                }
            }
        } else {
            noReading
        }
    }

    private func figure(_ text: String) -> some View {
        Text(text).scaledMono(Typography.Size.body, .semibold).lineLimit(1)
    }

    private var noReading: some View {
        Text("no reading").scaledMono(Typography.Size.body).foregroundStyle(.tertiary)
    }

    private func moment(_ time: Double) -> String {
        TranscriptChartFormat.moment(time, isTime: spec.isTime, span: shown.to - shown.from)
    }

    private var whenText: String {
        let zone = spec.isTime ? " " + TranscriptChartFormat.zone : ""
        if let selection {
            let length = spec.isTime ? TranscriptChartFormat.span(selection.to - selection.from) + " window, " : ""
            return "\(length)\(moment(selection.from)) to \(moment(selection.to))\(zone)"
        }
        if let hover { return moment(hover) + zone }
        return spec.isTime ? "latest \(moment(model.latest))\(zone)" : ""
    }

    // MARK: - Plot

    private var plot: some View {
        let height = ChartGeometry(lanes: model.lanes.count, width: 0, hasMarkers: model.hasMarkers,
                                   textScale: textScale).height
        return GeometryReader { proxy in
            let geometry = ChartGeometry(lanes: model.lanes.count, width: proxy.size.width,
                                         hasMarkers: model.hasMarkers, textScale: textScale)
            ZStack(alignment: .topLeading) {
                ChartPlotCanvas(drawing: ChartDrawing(
                    model: model, washes: spec.kind == .area, isTime: spec.isTime, geometry: geometry,
                    solo: solo, hover: selection == nil ? hover : nil,
                    selection: selection.map { $0.from...$0.to }, textScale: textScale),
                    previous: previous, shown: shown, target: phase,
                    phase: phase, drawn: drawn, dim: dim)
                    .accessibilityHidden(true)
                surface(geometry)
                if let selection, !dragging, selection.from < selection.to {
                    measurePill(selection)
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pillWidth = $0 }
                        .position(x: pillCentre(selection, geometry), y: geometry.rail + ControlHeight.md)
                        .transition(.popover(reduceMotion: reduceMotion))
                }
            }
            .motion(Motion.reveal, value: dragging || selection == nil)
            // A card that changes width lays its strip out afresh, so the height the
            // strip held at the old width no longer applies.
            .onChange(of: proxy.size.width) { stripHeight = 0 }
        }
        .frame(height: height)
        .overlay { FocusRingStroke(focused: focused) }
    }

    private func pillCentre(_ selection: Selection, _ geometry: ChartGeometry) -> CGFloat {
        let middle = (geometry.x(selection.from, in: shown) + geometry.x(selection.to, in: shown)) / 2
        let half = pillWidth / 2
        return min(max(middle, half), max(geometry.width - half, half))
    }

    // What takes the pointer and the keys. It sits over the drawing, which is one image,
    // and speaks for it: the plot is named, and its value is whatever the strip reads.
    private func surface(_ geometry: ChartGeometry) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard !dragging, selection == nil else { return }
                switch phase {
                case .active(let point):
                    let inside = point.x >= geometry.leading - Space.xs
                        && point.x <= geometry.width - geometry.trailing + Space.xs
                    hover = inside ? model.snapped(geometry.time(at: point.x, in: shown), in: shown) : nil
                case .ended:
                    if !focused { hover = nil }
                }
            }
            .gesture(DragGesture(minimumDistance: 5)
                .onChanged { drag in
                    func snap(_ x: CGFloat) -> Double? {
                        let held = min(max(x, geometry.leading), geometry.width - geometry.trailing)
                        return model.snapped(geometry.time(at: held, in: shown), in: shown)
                    }
                    guard let end = snap(drag.location.x) else { return }
                    if !dragging {
                        dragging = true
                        hover = nil
                        selection = Selection(anchor: snap(drag.startLocation.x) ?? end, end: end)
                    } else {
                        selection?.end = end
                    }
                }
                .onEnded { _ in
                    dragging = false
                    if let selection, selection.from == selection.to { self.selection = nil }
                })
            .onTapGesture(count: 2) { show(0) }
            .onTapGesture {
                selection = nil
                focused = true
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .escape]) { press in
                if press.key == .escape {
                    guard selection != nil || hover != nil else { return .ignored }
                    selection = nil
                    hover = nil
                } else {
                    step(press.key == .leftArrow ? -1 : 1)
                }
                return .handled
            }
            .onChange(of: focused) { _, now in
                if !now { hover = nil }
            }
            .accessibilityElement()
            .accessibilityLabel(spokenLabel)
            .accessibilityValue(spokenValue)
            .accessibilityHint("Use the left and right arrow keys to read values.")
            .accessibilityAdjustableAction { direction in
                step(direction == .increment ? 1 : -1)
            }
    }

    // Moves the reading one measurement along. The first press lands on the nearest end.
    private func step(_ direction: Int) {
        let visible = model.times.filter { $0 >= shown.from && $0 <= shown.to }
        guard !visible.isEmpty else { return }
        selection = nil
        let current = hover.flatMap { visible.firstIndex(of: $0) }
        let next = current.map { $0 + direction } ?? (direction < 0 ? visible.count - 1 : 0)
        hover = visible[min(max(next, 0), visible.count - 1)]
    }

    private var spokenLabel: String {
        let series = model.solidLines.map(\.label).joined(separator: ", ")
        let marked = model.markers(in: shown).map { "\($0.label) at \(moment($0.time))" }.joined(separator: ", ")
        return [spec.title ?? "Chart", series, marked.isEmpty ? nil : "Marked: \(marked)"]
            .compactMap { $0 }.joined(separator: ". ")
    }

    private var spokenValue: String {
        let time = hover ?? model.latest
        let readings = model.solidLines.compactMap { line -> String? in
            guard let reading = hover.map({ model.readout(line, at: $0) }) ?? model.latestReadout(line) else {
                return nil
            }
            let unit = model.lanes[model.lane(of: line)].unit
            return "\(line.label) \(TranscriptChartFormat.value(reading.value, unit: unit))"
                + (reading.isProjected ? ", projected" : "")
        }
        return ([moment(time)] + readings).joined(separator: ", ")
    }

    // MARK: - Measure

    // Offered once a window is marked: look closer here, or hand the window to the agent.
    private func measurePill(_ selection: Selection) -> some View {
        HStack(spacing: Space.xxs) {
            ActionButton(title: "Zoom in", tone: .outlined, height: ControlHeight.sm,
                         size: Typography.Size.caption) {
                let label = "\(moment(selection.from)) to \(moment(selection.to))"
                zoomed = .init(label: label, from: selection.from, to: selection.to)
                show(model.windows.count)
            }
            if let askAgent {
                ActionButton(title: "Ask about this window", tone: .green, height: ControlHeight.sm,
                             size: Typography.Size.caption) {
                    askAgent(question(selection))
                    self.selection = nil
                }
            }
            GlyphButton(icon: "xmark", side: ControlHeight.sm) { self.selection = nil }
                .accessibilityLabel("Clear the window")
        }
        .padding(Space.xxs)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.border))
        .elevation(.floating)
    }

    private func question(_ selection: Selection) -> String {
        let zone = spec.isTime ? " " + TranscriptChartFormat.zone : ""
        let change = model.solidLines.first.flatMap { line -> String? in
            guard let first = model.readout(line, at: selection.from),
                  let last = model.readout(line, at: selection.to) else { return nil }
            return "\(line.label) went from \(TranscriptChartFormat.compact(first.value)) to "
                + "\(TranscriptChartFormat.compact(last.value))."
        }
        return ChartFollowUp.window(title: spec.title, from: moment(selection.from),
                                    to: moment(selection.to) + zone, change: change)
    }

    // MARK: - Footer and values

    private var footer: some View {
        HStack(spacing: Space.lg) {
            if spec.source != nil || spec.server != nil {
                HStack(spacing: Space.sm) {
                    if let source = spec.source {
                        Text(source.uppercased()).scaledMono(Typography.Size.caption, .bold)
                    }
                    if let server = spec.server {
                        Text(server).scaledMono(Typography.Size.caption)
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            if spec.omittedSeriesCount > 0 {
                Text("\(counted(spec.omittedSeriesCount, "more series")) not shown.")
                    .scaledText(Typography.Size.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ViewThatFits(in: .horizontal) {
                Text("Drag across the chart to measure a window")
                    .scaledText(Typography.Size.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 0)
            }
            InlineAskButton(title: showsValues ? "Hide values" : "Values", arrow: false) {
                showsValues.toggle()
            }
            .fixedSize()
        }
    }

    // First, low, high and last for the stretch in view. What the pointer shows, without
    // needing one.
    private var table: some View {
        Grid(alignment: .trailing, horizontalSpacing: Space.xl, verticalSpacing: 0) {
            GridRow {
                Text("SERIES").gridColumnAlignment(.leading)
                ForEach(["FIRST", "LOW", "HIGH", "LAST"], id: \.self) { Text($0) }
            }
            .capsText()
            .foregroundStyle(.secondary)
            .padding(.vertical, Space.xs)
            ForEach(model.solidLines) { line in
                Rectangle().fill(Theme.hairline).frame(height: 1)
                GridRow {
                    HStack(spacing: Space.sm) {
                        Capsule()
                            .fill(TranscriptChartPalette.colour(line.slot))
                            .frame(width: ChartMetrics.keyWidth, height: ChartMetrics.keyHeight)
                        Text(line.label)
                            .scaledText(Typography.Size.detail)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let summary = model.summary(line, in: shown) {
                        ForEach(Array([summary.first, summary.low, summary.high, summary.last].enumerated()),
                                id: \.offset) { _, number in
                            Text(TranscriptChartFormat.compact(number)).scaledMono(Typography.Size.detail)
                        }
                    } else {
                        Text("no readings in this window")
                            .scaledText(Typography.Size.detail)
                            .foregroundStyle(.tertiary)
                            .gridCellColumns(4)
                    }
                }
                .padding(.vertical, Space.sm)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// The title of a chart and the sentence that says what it shows.
struct ChartHeading: View {
    let title: String?
    let caption: String?

    var body: some View {
        if title != nil || caption != nil {
            VStack(alignment: .leading, spacing: Space.xxs) {
                if let title {
                    Text(title)
                        .scaledText(Typography.Size.body, .semibold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let caption {
                    Text(caption)
                        .scaledText(Typography.Size.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Drawing

// The plot as one drawing. The numbers that move are animatable: the view in flight
// between two frames, how much of each line has drawn, and how far the series not
// pointed at have faded.
nonisolated struct ChartPlotCanvas: View, Animatable {
    let drawing: ChartDrawing
    let previous: ChartFrame
    let shown: ChartFrame
    // The whole number `phase` is heading for. One step of phase is one change of view.
    let target: Double
    var phase: Double
    var drawn: Double
    var dim: Double

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { .init(.init(phase, drawn), dim) }
        set {
            phase = newValue.first.first
            drawn = newValue.first.second
            dim = newValue.second
        }
    }

    var body: some View {
        let drawing = drawing
        let frame = previous.mixed(with: shown, min(max(phase - (target - 1), 0), 1))
        let (drawn, dim) = (drawn, dim)
        Canvas { context, _ in
            drawing.draw(in: &context, frame: frame, drawn: drawn, dim: dim)
        }
    }
}

struct ChartDrawing: Sendable {
    let model: ChartLanes
    // An area chart washes under every line. A lane with one line gets a wash as well,
    // since there is nothing else in it for the wash to hide.
    let washes: Bool
    let isTime: Bool
    let geometry: ChartGeometry
    let solo: Int?
    let hover: Double?
    let selection: ClosedRange<Double>?
    let textScale: CGFloat

    private var micro: Font { .system(size: Typography.Size.micro * textScale) }
    private var caption: Font { .system(size: Typography.Size.caption * textScale, weight: .medium) }
    private var data: Font { .system(size: Typography.Size.micro * textScale, weight: .semibold, design: .monospaced) }

    func draw(in context: inout GraphicsContext, frame: ChartFrame, drawn: Double, dim: Double) {
        guard geometry.width > geometry.leading + geometry.trailing + 1 else { return }
        grid(&context, frame)
        bands(&context, frame, drawn)
        levels(&context, frame, drawn)
        let flags = flags(&context, frame)
        stems(&context, flags, drawn)
        series(&context, frame, drawn: drawn, dots: ChartMotion.endDot(drawn: drawn), dim: dim)
        pointer(&context, frame)
        labels(&context, flags, drawn)
    }

    private var left: CGFloat { geometry.leading }
    private var right: CGFloat { geometry.width - geometry.trailing }

    // MARK: Grid

    private func grid(_ context: inout GraphicsContext, _ frame: ChartFrame) {
        let limit = max(2, Int(geometry.plotWidth / (ChartMetrics.tickSpacing * textScale)))
        let ticks = ChartLanes.ticks(from: frame.from, to: frame.to, limit: limit, isTime: isTime)
        for tick in ticks.values {
            let x = geometry.x(tick, in: frame)
            var line = Path()
            line.move(to: CGPoint(x: x, y: geometry.rail))
            line.addLine(to: CGPoint(x: x, y: geometry.bottom))
            context.stroke(line, with: .color(Theme.chartGrid), style: StrokeStyle(lineWidth: 1, dash: [1, 4]))
            let text = context.resolve(Text(TranscriptChartFormat.tick(tick, isTime: isTime, step: ticks.step,
                                                                       span: frame.to - frame.from))
                .font(micro).foregroundStyle(.secondary))
            let half = text.measure(in: CGSize(width: 400, height: 40)).width / 2
            context.draw(text, at: CGPoint(x: min(max(x, half), geometry.width - half),
                                           y: geometry.bottom + (geometry.height - geometry.bottom) * 0.6),
                         anchor: .center)
        }
        for (index, lane) in model.lanes.enumerated() {
            for value in ChartLanes.gridValues(frame.scales[index], steps: ChartLanes.steps(lane: index)) {
                let y = geometry.y(value, lane: index, in: frame)
                var line = Path()
                line.move(to: CGPoint(x: left, y: y))
                line.addLine(to: CGPoint(x: right, y: y))
                context.stroke(line, with: .color(Theme.chartGrid), lineWidth: 1)
                context.draw(Text(TranscriptChartFormat.compact(value)).font(micro.monospacedDigit())
                    .foregroundStyle(.secondary), at: CGPoint(x: left - Space.md, y: y), anchor: .trailing)
            }
            if let unit = lane.unit {
                context.draw(Text(unit).font(micro).foregroundStyle(.tertiary),
                             at: CGPoint(x: left, y: geometry.laneTops[index] - Space.md * textScale),
                             anchor: .bottomLeading)
            }
        }
    }

    // MARK: Bands and levels

    private func bands(_ context: inout GraphicsContext, _ frame: ChartFrame, _ drawn: Double) {
        for band in model.bands {
            let from = max(band.from, frame.from)
            let to = min(band.to ?? model.latest, frame.to)
            guard to > from else { continue }
            let rect = CGRect(x: geometry.x(from, in: frame), y: geometry.rail,
                              width: geometry.x(to, in: frame) - geometry.x(from, in: frame),
                              height: geometry.bottom - geometry.rail)
            var layer = context
            layer.opacity = ChartMotion.landed(share(band.from, frame), drawn: drawn)
            layer.fill(Path(rect), with: .color(band.tone.wash.opacity(0.5)))
            layer.clip(to: Path(rect))
            layer.translateBy(x: rect.minX, y: rect.minY)
            layer.fill(Stripes.path(in: rect.size, period: Space.md), with: .color(band.tone.mark.opacity(0.15)))
        }
    }

    private func levels(_ context: inout GraphicsContext, _ frame: ChartFrame, _ drawn: Double) {
        for (index, lane) in model.lanes.enumerated() {
            let top = geometry.laneTops[index]
            let floor = top + geometry.laneHeights[index]
            for level in lane.levels {
                let y = geometry.y(level.value, lane: index, in: frame)
                guard y >= top - 1, y <= floor + 1 else { continue }
                var layer = context
                layer.opacity = ChartMotion.landed(0.6, drawn: drawn)
                // The wrong side of the level is tinted, so a line there reads as a
                // breach before its colour is noticed.
                if let breach = level.breach {
                    let side = breach == .below ? CGRect(x: left, y: y, width: geometry.plotWidth, height: floor - y)
                                                : CGRect(x: left, y: top, width: geometry.plotWidth, height: y - top)
                    layer.fill(Path(side), with: .color(Theme.deletion.opacity(0.08)))
                }
                let tone = level.tone ?? .warn
                var line = Path()
                line.move(to: CGPoint(x: left, y: y))
                line.addLine(to: CGPoint(x: right, y: y))
                layer.stroke(line, with: .color(tone.ink), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))

                let name = level.label ?? TranscriptChartFormat.compact(level.value)
                let text = layer.resolve(Text(name).font(micro.weight(.semibold)).foregroundStyle(tone.ink))
                let size = text.measure(in: CGSize(width: geometry.plotWidth, height: 40))
                let above = y - size.height - Space.xxs >= top
                let box = CGRect(x: right - size.width - Space.md, y: above ? y - size.height - Space.xxs : y + Space.xxs,
                                 width: size.width + Space.md, height: size.height)
                layer.fill(Path(roundedRect: box, cornerRadius: Radius.tag), with: .color(Theme.card))
                layer.draw(text, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
            }
        }
    }

    // MARK: Flags

    private struct Flag {
        let x: CGFloat
        let share: Double
        let tone: TranscriptChartSpec.Tone
        let text: GraphicsContext.ResolvedText
        let size: CGSize
        let place: ChartGeometry.FlagPlace
    }

    private func share(_ time: Double, _ frame: ChartFrame) -> Double {
        min(max((time - frame.from) / max(frame.to - frame.from, .ulpOfOne), 0), 1)
    }

    private func flags(_ context: inout GraphicsContext, _ frame: ChartFrame) -> [Flag] {
        let markers = model.markers(in: frame)
        let measured = markers.map { marker -> (GraphicsContext.ResolvedText, CGSize) in
            let time = Text(TranscriptChartFormat.moment(marker.time, isTime: isTime, span: frame.to - frame.from) + "  ")
                .font(.system(size: Typography.Size.micro * textScale, design: .monospaced))
            let text = context.resolve((time + Text(marker.label).font(caption)).foregroundStyle(marker.tone.ink))
            let size = text.measure(in: CGSize(width: 2000, height: 40))
            return (text, CGSize(width: size.width + Space.lg + ChartMetrics.flagEdge, height: size.height))
        }
        let xs = markers.map { geometry.x($0.time, in: frame) }
        let places = ChartGeometry.place(flags: zip(xs, measured).map { ($0, $1.1.width) }, within: geometry.width)
        return markers.indices.map {
            Flag(x: xs[$0], share: share(markers[$0].time, frame), tone: markers[$0].tone,
                 text: measured[$0].0, size: measured[$0].1, place: places[$0])
        }
    }

    private func flagTop(_ row: Int) -> CGFloat {
        geometry.rail - (ChartMetrics.flagStep * CGFloat(row + 1) - Space.xxs) * textScale
    }

    private func stems(_ context: inout GraphicsContext, _ flags: [Flag], _ drawn: Double) {
        for flag in flags {
            var layer = context
            layer.opacity = ChartMotion.landed(flag.share, drawn: drawn)
            var stem = Path()
            stem.move(to: CGPoint(x: flag.x, y: flag.place.row.map(flagTop) ?? geometry.rail - Space.md))
            stem.addLine(to: CGPoint(x: flag.x, y: geometry.bottom))
            layer.stroke(stem, with: .color(flag.tone.ink), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func labels(_ context: inout GraphicsContext, _ flags: [Flag], _ drawn: Double) {
        for flag in flags {
            guard let row = flag.place.row else { continue }
            let landed = ChartMotion.landed(flag.share, drawn: drawn)
            var layer = context
            layer.opacity = landed
            // Lands by rising the last few points, the way a panel opened from a button does.
            layer.translateBy(x: 0, y: (1 - landed) * HeaderMotion.popoverLift)
            let height = ChartMetrics.flagHeight * textScale
            let box = CGRect(x: flag.place.flipped ? flag.x - flag.size.width : flag.x, y: flagTop(row),
                             width: flag.size.width, height: height)
            layer.fill(Path(roundedRect: box, cornerRadius: Radius.tag), with: .color(Theme.card))
            layer.fill(Path(roundedRect: box, cornerRadius: Radius.tag), with: .color(flag.tone.wash))
            let edge = CGRect(x: flag.x - (flag.place.flipped ? ChartMetrics.flagEdge : 0), y: box.minY,
                              width: ChartMetrics.flagEdge, height: height)
            layer.fill(Path(edge), with: .color(flag.tone.ink))
            let inset = flag.place.flipped ? -ChartMetrics.flagEdge / 2 : ChartMetrics.flagEdge / 2
            layer.draw(flag.text, at: CGPoint(x: box.midX + inset, y: box.midY), anchor: .center)
        }
    }

    // MARK: Series

    private func series(_ context: inout GraphicsContext, _ frame: ChartFrame,
                        drawn: Double, dots: Double, dim: Double) {
        for (index, lane) in model.lanes.enumerated() {
            let top = geometry.laneTops[index]
            let floor = top + geometry.laneHeights[index]
            let window = CGRect(x: left, y: top - 3, width: geometry.plotWidth, height: floor - top + 6)
            let washed = washes || lane.lines.filter { !$0.isProjection }.count == 1
            // Where the level cuts the lane, so the line can change colour as it crosses.
            let cut = lane.breach.map { min(max(geometry.y($0.value, lane: index, in: frame), window.minY), window.maxY) }
            let wrongSide = cut.map { cut in
                lane.breach?.breach == .below
                    ? CGRect(x: 0, y: cut, width: geometry.width, height: window.maxY - cut)
                    : CGRect(x: 0, y: window.minY, width: geometry.width, height: cut - window.minY)
            }

            for line in lane.lines where !line.readings.isEmpty {
                let colour = TranscriptChartPalette.colour(line.slot)
                let points = line.readings.map {
                    CGPoint(x: geometry.x($0.x, in: frame), y: geometry.y($0.y, lane: index, in: frame))
                }
                var path = Path()
                path.addLines(points)

                var layer = context
                layer.clip(to: Path(window))
                if let solo, solo != line.slot { layer.opacity = 1 - (1 - ChartMetrics.dimmed) * dim }

                // A projection is never a solid line: it is dotted, in its parent's
                // colour, and arrives after the measurements it carries on from.
                let style = line.isProjection
                    ? StrokeStyle(lineWidth: ChartMetrics.lineWidth, lineCap: .round, dash: [1, 5])
                    : StrokeStyle(lineWidth: ChartMetrics.lineWidth, lineCap: .round, lineJoin: .round)
                var stroke = layer
                if line.isProjection { stroke.opacity *= ChartMotion.landed(0.92, drawn: drawn) }
                let visible = line.isProjection || drawn >= 1 ? path : path.trimmedPath(from: 0, to: drawn)

                if washed, !line.isProjection, let first = points.first, let last = points.last {
                    var area = path
                    area.addLine(to: CGPoint(x: last.x, y: floor))
                    area.addLine(to: CGPoint(x: first.x, y: floor))
                    area.closeSubpath()
                    var wash = layer
                    // The wash fades in behind the line and never runs ahead of it.
                    wash.opacity *= min(drawn * 1.5, 1)
                    if drawn < 1 {
                        wash.clip(to: Path(CGRect(x: 0, y: window.minY, width: visible.boundingRect.maxX,
                                                  height: window.height)))
                    }
                    wash.fill(area, with: .linearGradient(
                        Gradient(colors: [colour.opacity(0.2), colour.opacity(0)]),
                        startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: floor)))
                }

                stroke.stroke(visible, with: .color(colour), style: style)
                if let wrongSide {
                    var breach = stroke
                    breach.clip(to: Path(wrongSide))
                    // Painted over rather than beside the series colour, so the join has no gap.
                    breach.stroke(visible, with: .color(Theme.card), style: style)
                    breach.stroke(visible, with: .color(Theme.deletion), style: style)
                }

                if !line.isProjection, let end = line.readings.last, let point = points.last,
                   end.x >= frame.from, end.x <= frame.to, dots > 0 {
                    // Outside the lane's clip, which would cut a dot at the last reading in half.
                    var mark = context
                    mark.opacity = layer.opacity
                    dot(&mark, at: point, radius: ChartMetrics.endDot * dots,
                        colour: lane.isBreach(end.y) ? Theme.deletion : colour)
                }
            }
        }
    }

    private func dot(_ context: inout GraphicsContext, at point: CGPoint, radius: CGFloat, colour: Color) {
        let ring = Path(ellipseIn: CGRect(x: point.x - radius - 1, y: point.y - radius - 1,
                                          width: (radius + 1) * 2, height: (radius + 1) * 2))
        context.fill(ring, with: .color(Theme.card))
        context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                            width: radius * 2, height: radius * 2)), with: .color(colour))
    }

    // MARK: Pointer

    private func pointer(_ context: inout GraphicsContext, _ frame: ChartFrame) {
        if let selection {
            let from = geometry.x(selection.lowerBound, in: frame)
            let to = geometry.x(selection.upperBound, in: frame)
            context.fill(Path(CGRect(x: from, y: geometry.rail, width: to - from, height: geometry.bottom - geometry.rail)),
                         with: .color(.primary.opacity(0.07)))
            for (x, time) in [(from, selection.lowerBound), (to, selection.upperBound)] {
                var edge = Path()
                edge.move(to: CGPoint(x: x, y: geometry.rail - Space.sm))
                edge.addLine(to: CGPoint(x: x, y: geometry.bottom))
                context.stroke(edge, with: .color(.primary), lineWidth: 1)
                chip(&context, time, at: x, frame)
            }
        } else if let hover {
            let x = geometry.x(hover, in: frame)
            var guide = Path()
            guide.move(to: CGPoint(x: x, y: geometry.rail))
            guide.addLine(to: CGPoint(x: x, y: geometry.bottom))
            context.stroke(guide, with: .color(.primary.opacity(0.45)), lineWidth: 1)
            for (index, lane) in model.lanes.enumerated() {
                for line in lane.lines {
                    guard let reading = line.reading(at: hover) else { continue }
                    var layer = context
                    dot(&layer, at: CGPoint(x: geometry.x(reading.x, in: frame),
                                            y: geometry.y(reading.y, lane: index, in: frame)),
                        radius: ChartMetrics.hoverDot,
                        colour: lane.isBreach(reading.y) ? Theme.deletion : TranscriptChartPalette.colour(line.slot))
                }
            }
            chip(&context, hover, at: x, frame)
        }
    }

    // The moment under the pointer, written over the time axis where it belongs.
    private func chip(_ context: inout GraphicsContext, _ time: Double, at x: CGFloat, _ frame: ChartFrame) {
        let text = context.resolve(Text(TranscriptChartFormat.moment(time, isTime: isTime, span: frame.to - frame.from))
            .font(data).foregroundStyle(Theme.card))
        let size = text.measure(in: CGSize(width: 400, height: 40))
        let width = size.width + Space.lg
        let box = CGRect(x: min(max(x - width / 2, 0), geometry.width - width), y: geometry.bottom + Space.xs,
                         width: width, height: size.height + Space.xs)
        context.fill(Path(roundedRect: box, cornerRadius: Radius.tag), with: .color(.primary))
        context.draw(text, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }
}

// The colours a tone is drawn in: the ink of its line and name, the wash behind a flag,
// and the stripes of a band. Red is kept for what went wrong.
extension TranscriptChartSpec.Tone {
    var ink: Color {
        switch self {
        case .warn: Theme.attentionText
        case .bad: Theme.warningText
        case .good: Theme.addition
        case .note: .secondary
        }
    }

    var wash: Color {
        switch self {
        case .warn: Theme.attention.opacity(0.17)
        case .bad: Theme.warningBackground
        case .good: Theme.addition.opacity(0.13)
        case .note: Theme.background
        }
    }

    var mark: Color {
        switch self {
        case .warn: Theme.attention
        case .bad: Theme.deletion
        case .good: Theme.addition
        case .note: .secondary
        }
    }
}
