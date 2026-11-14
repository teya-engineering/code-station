import SwiftUI

// A trace drawn as one card a reader takes in at a glance: how long it took, what failed
// and where the time went, above a waterfall with a row per span, indented under its
// caller, with a bar placed on the trace's own time axis. A row opens below itself to
// show everything the span carries.
struct TraceWaterfallView: View {
    enum Lens: Equatable {
        case all
        // The failed spans and the callers above them.
        case failed
        // Every span still shows, and those off the slowest path fade.
        case slowest
    }

    @Environment(\.textScale) private var textScale
    @Environment(\.askAgent) private var askAgent

    let trace: Trace
    var title: String?
    // The MCP server the trace was read from.
    var server: String?
    // Spans left out of a capped trace. The card says so, because a trace that looks
    // whole but is not would hide where the rest of the time went.
    var omittedSpans: Int
    // In Chat the waterfall sits among other calls, so it scrolls in a box of its own
    // rather than growing the transcript.
    var maxHeight: CGFloat?

    // Starts on the way down to each failure rather than on every span.
    @State private var collapsed: Set<String>
    @State private var openGroups: Set<String> = []
    @State private var lens: Lens = .all
    @State private var focusedService: String?
    @State private var previewedService: String?
    @State private var selected: String?
    @State private var opened: String?
    @State private var window: ClosedRange<Int64>?
    @State private var zooming = false
    @State private var attributeFilter = ""
    @State private var showsResources = false
    @State private var asked: Set<String> = []
    @State private var copiedValue: String?
    @State private var copiedID = false
    @State private var hoverFraction: CGFloat?
    @State private var listWidth: CGFloat = 0
    @FocusState private var keyboardFocus: Bool
    @Namespace private var lensTrack
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let hiddenCounts: [String: Int]

    // Wide enough for nearly every operation once the service is named beside the bar.
    private static let labelWidth: CGFloat = 360
    private static let trailingInset: CGFloat = 16
    // A trace this short is read straight off its rows.
    private static let overviewMinimum = 10

    init(trace: Trace, title: String? = nil, server: String? = nil, omittedSpans: Int = 0,
         maxHeight: CGFloat? = nil) {
        self.trace = trace
        self.title = title
        self.server = server
        self.omittedSpans = omittedSpans
        self.maxHeight = maxHeight
        _collapsed = State(initialValue: trace.initiallyFolded)
        hiddenCounts = trace.descendantCounts
    }

    private var view: ClosedRange<Int64> { window ?? trace.wholeWindow }
    private var labelWidth: CGFloat { Self.labelWidth * textScale }
    private var activeService: String? { focusedService ?? previewedService }

    private var displayRows: [Trace.DisplayRow] {
        trace.displayRows(collapsed: collapsed, openGroups: openGroups,
                          keep: lens == .failed ? trace.failurePath : nil, window: window)
    }

    var body: some View {
        let rows = displayRows
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.lg)
                .padding(.bottom, Space.lg)
            if trace.rows.count >= Self.overviewMinimum {
                TraceOverview(trace: trace, window: $window, dragging: $zooming, colour: colour)
                    .padding(.horizontal, Space.xl)
                    .padding(.bottom, Space.lg)
            }
            if trace.services.count > 1 || trace.errorCount > 0 {
                rule
                tools
            }
            rule
            axis
            rule
            waterfall(rows)
            rule
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.card, cornerRadius: Radius.floating)
        .clipShape(RoundedRectangle(cornerRadius: Radius.floating))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trace \(titleText)")
        // A view reused for another trace starts that trace afresh: what was folded or
        // opened in the last one means nothing in it.
        .onChange(of: trace.traceID) {
            collapsed = trace.initiallyFolded
            openGroups = []
            lens = .all
            focusedService = nil
            selected = nil
            opened = nil
            window = nil
            asked = []
        }
    }

    private var rule: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    // MARK: - Header

    private var titleText: String { title ?? trace.root?.operation ?? "Trace" }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(alignment: .top, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(titleText)
                        .scaledText(Typography.Size.body, .semibold)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if trace.root != nil {
                        Text(Self.startLine(trace))
                            .scaledText(Typography.Size.detail)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: Space.sm) {
                    if let server {
                        Text(server)
                            .scaledText(Typography.Size.detail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .modifier(TraceChip())
                            .appTooltip("Read through this MCP server")
                    }
                    if !trace.traceID.isEmpty { traceIDChip }
                }
            }
            stats
        }
    }

    // "Starts in checkout-api at 14:02:08.240". A trace timed only from its own start has
    // no clock time to show.
    static func startLine(_ trace: Trace) -> AttributedString {
        var line = AttributedString("Starts in ")
        line += AttributedString(trace.root?.service ?? "")
        if trace.startNanos > 0 {
            line += AttributedString(" at " + GrafanaResultView.clock(
                Date(timeIntervalSince1970: Double(trace.startNanos) / 1_000_000_000)))
        }
        if let range = line.range(of: trace.root?.service ?? "") {
            line[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return line
    }

    private var traceIDChip: some View {
        Button {
            Pasteboard.copy(trace.traceID)
            copiedID = true
            Task {
                try? await Task.sleep(for: .milliseconds(1_200))
                copiedID = false
            }
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: copiedID ? "checkmark" : "doc.on.doc")
                    .font(.system(size: Typography.Size.micro * textScale, weight: .semibold))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                Text(copiedID ? "Copied" : String(trace.traceID.prefix(8)))
                    .scaledMono(Typography.Size.caption)
                    .contentTransition(.opacity)
            }
            .foregroundStyle(copiedID ? Theme.addition : Color.secondary)
            .modifier(TraceChip())
            .contentShape(Rectangle())
            .hoverLift()
        }
        .buttonStyle(.plain)
        .motion(Motion.pop, value: copiedID)
        .appTooltip("Copy trace ID")
        .accessibilityLabel("Copy trace ID \(trace.traceID)")
    }

    private var stats: some View {
        HStack(alignment: .top, spacing: 0) {
            stat("Duration") {
                Text(Trace.spacedDuration(trace.durationNanos))
            }
            statRule
            stat("Spans") {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text(Trace.grouped(Int64(trace.rows.count)))
                    if omittedSpans > 0 {
                        Text("of \(Trace.grouped(Int64(trace.rows.count + omittedSpans)))")
                            .scaledText(Typography.Size.detail)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            statRule
            stat("Services") { Text("\(trace.services.count)") }
            statRule
            stat("Failed spans") {
                if trace.errorCount > 0 {
                    Button { choose(lens == .failed ? .all : .failed) } label: {
                        Text("\(trace.errorCount)")
                            .foregroundStyle(Theme.deletion)
                            .underline(lens == .failed)
                            .contentShape(Rectangle())
                            .hoverLift()
                    }
                    .buttonStyle(.plain)
                    .appTooltip(lens == .failed ? "Show all spans" : "Show only failed spans")
                    .accessibilityLabel("\(trace.errorCount) failed spans")
                    .accessibilityHint("Shows only the failed spans and their callers")
                } else {
                    Text("None").foregroundStyle(Theme.addition)
                }
            }
        }
    }

    private func stat(_ title: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title)
                .scaledText(Typography.Size.detail)
                .foregroundStyle(.secondary)
            value()
                .scaledText(18, .semibold)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var statRule: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1, height: 34 * textScale)
            .padding(.horizontal, Space.xl)
    }

    // MARK: - Legend and views

    private var tools: some View {
        HStack(alignment: .center, spacing: Space.lg) {
            if trace.services.count > 1 {
                FlowRow(spacing: Space.xxs) {
                    ForEach(trace.services, id: \.self) { service in
                        legendItem(service)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Services")
            }
            Spacer(minLength: 8)
            HStack(spacing: Space.xxs) {
                ChoicePill(title: "All spans", selected: lens == .all, thumb: lensTrack) {
                    choose(.all)
                }
                ChoicePill(title: trace.errorCount > 0 ? "Failed \(trace.errorCount)" : "Failed",
                           selected: lens == .failed, enabled: trace.errorCount > 0,
                           thumb: lensTrack) {
                    choose(.failed)
                }
                ChoicePill(title: "Slowest path", selected: lens == .slowest, thumb: lensTrack) {
                    choose(.slowest)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    private func legendItem(_ service: String) -> some View {
        let focused = focusedService == service
        return Button {
            focusedService = focused ? nil : service
        } label: {
            HStack(spacing: Space.sm) {
                Circle().fill(colour(service)).frame(width: 7, height: 7)
                Text(service)
                    .scaledText(Typography.Size.detail)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(Trace.spacedDuration(trace.ownTime[service] ?? 0))
                    .scaledText(Typography.Size.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .fixedSize()
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xxs)
            .background(RoundedRectangle(cornerRadius: Radius.inset).fill(focused ? Theme.field : .clear))
            .opacity(focusedService == nil || focused ? 1 : 0.5)
            .contentShape(Rectangle())
            .hoverLift(previewedService == service)
        }
        .buttonStyle(.plain)
        .onPointerHover { inside in
            if inside {
                previewedService = service
            } else if previewedService == service {
                previewedService = nil
            }
        }
        .appTooltip(focused ? "Show every service" : "Show only \(service)")
        .accessibilityLabel("\(service), own time \(Trace.spacedDuration(trace.ownTime[service] ?? 0))")
        .accessibilityAddTraits(focused ? .isSelected : [])
        .motion(Motion.hover, value: focusedService)
    }

    private func choose(_ next: Lens) {
        lens = next
        opened = nil
        switch next {
        case .all:
            break
        case .failed:
            for row in trace.rows where row.span.isError {
                var current = trace.parentIDs[row.id]
                while let id = current {
                    collapsed.remove(id)
                    current = trace.parentIDs[id]
                }
            }
        case .slowest:
            collapsed.subtract(trace.criticalPath)
        }
    }

    // MARK: - Axis

    private var axis: some View {
        HStack(spacing: 0) {
            HStack {
                Text("Span")
                Spacer()
                Text("Took")
            }
            .scaledText(Typography.Size.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, Space.xl)
            .padding(.trailing, Space.md)
            .frame(width: labelWidth)
            GeometryReader { proxy in
                axisTicks(width: proxy.size.width, height: proxy.size.height)
            }
            .padding(.trailing, Self.trailingInset)
        }
        .frame(height: 26 * textScale)
        .accessibilityHidden(true)
    }

    private func axisTicks(width: CGFloat, height: CGFloat) -> some View {
        let ticks = trace.ticks(in: view)
        return ZStack(alignment: .leading) {
            ForEach(ticks.offsets, id: \.self) { offset in
                let x = fraction(trace.startNanos + offset) * width
                // Marks near the end would run into the end's own label.
                if x <= width * 0.88 {
                    Text(Trace.tickText(offset, step: ticks.step))
                        .scaledMono(Typography.Size.micro)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .offset(x: x + 3)
                }
            }
            Text(Trace.spacedDuration(view.upperBound - trace.startNanos))
                .scaledMono(Typography.Size.micro)
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(width: width, alignment: .trailing)
            if let hoverFraction {
                Text(Trace.offsetText(view.lowerBound - trace.startNanos
                    + Int64(Double(hoverFraction) * Double(view.upperBound - view.lowerBound))))
                    .scaledMono(Typography.Size.micro, .semibold)
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
                    .padding(.horizontal, Space.xs)
                    .background(RoundedRectangle(cornerRadius: Radius.tag).fill(Theme.card))
                    .offset(x: min(hoverFraction * width + 3, max(width - 70, 0)))
            }
        }
        .frame(width: width, height: height, alignment: .leading)
    }

    private func fraction(_ nanos: Int64) -> CGFloat {
        let range = Double(max(view.upperBound - view.lowerBound, 1))
        return CGFloat(Double(nanos - view.lowerBound) / range)
    }

    // MARK: - Waterfall

    @ViewBuilder
    private func waterfall(_ rows: [Trace.DisplayRow]) -> some View {
        if let maxHeight {
            ScrollViewReader { proxy in
                ScrollView { rowList(rows) }
                    .frame(maxHeight: maxHeight * textScale)
                    .onChange(of: selected) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id)
                    }
            }
        } else {
            rowList(rows)
        }
    }

    private func rowList(_ rows: [Trace.DisplayRow]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                HStack(spacing: Space.sm) {
                    Text("No spans match.")
                        .scaledText(Typography.Size.detail)
                        .foregroundStyle(.secondary)
                    InlineLink(title: "Show all spans", size: Typography.Size.detail) {
                        lens = .all
                        window = nil
                        focusedService = nil
                    }
                }
                .padding(Space.xl)
            }
            ForEach(rows) { row in
                rowView(row)
                    .id(row.id)
                if opened == row.id {
                    drawer(row)
                        .transition(.opacity)
                }
            }
        }
        .background { gridlines }
        .overlay(alignment: .topLeading) { crosshair }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let trackWidth = listWidth - labelWidth - Self.trailingInset
                let x = point.x - labelWidth
                hoverFraction = trackWidth > 0 && x >= 0 && x <= trackWidth ? x / trackWidth : nil
            case .ended:
                hoverFraction = nil
            }
        }
        .focusable()
        .focused($keyboardFocus)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .escape]) { press in
            key(press.key, rows: rows)
        }
        .motion(Motion.reveal, value: zooming ? [] : rows.map(\.id))
        .motion(Motion.reveal, value: opened)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spans")
        .accessibilityHint("Use the arrow keys to move, Return to open.")
    }

    private var gridlines: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth)
            GeometryReader { proxy in
                let width = proxy.size.width
                ForEach(trace.ticks(in: view).offsets, id: \.self) { offset in
                    Rectangle()
                        .fill(Theme.chartGrid)
                        .frame(width: 1)
                        .offset(x: fraction(trace.startNanos + offset) * width)
                }
            }
            .padding(.trailing, Self.trailingInset)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var crosshair: some View {
        if let hoverFraction {
            let trackWidth = listWidth - labelWidth - Self.trailingInset
            Rectangle()
                .fill(Theme.accent.opacity(0.4))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .offset(x: labelWidth + hoverFraction * trackWidth)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func key(_ key: KeyEquivalent, rows: [Trace.DisplayRow]) -> KeyPress.Result {
        let ids = rows.map(\.id)
        let index = selected.flatMap { ids.firstIndex(of: $0) }
        switch key {
        case .downArrow:
            selected = index.map { ids[min($0 + 1, ids.count - 1)] } ?? ids.first
        case .upArrow:
            selected = index.map { ids[max($0 - 1, 0)] } ?? ids.first
        case .rightArrow:
            guard let index else { return .ignored }
            switch rows[index] {
            case .span(let row) where row.hasChildren: collapsed.remove(row.id)
            case .group(let group): openGroups.insert(group.key)
            default: break
            }
        case .leftArrow:
            guard let index else { return .ignored }
            switch rows[index] {
            case .span(let row) where row.hasChildren && !collapsed.contains(row.id):
                collapsed.insert(row.id)
            case .span(let row):
                if let parent = trace.parentIDs[row.id] { selected = parent }
            case .group(let group):
                selected = group.parent.id
            }
        case .return:
            guard let selected else { return .ignored }
            toggleDrawer(selected)
        case .escape:
            guard opened != nil else { return .ignored }
            opened = nil
        default:
            return .ignored
        }
        return .handled
    }

    private func toggleDrawer(_ id: String) {
        opened = opened == id ? nil : id
        attributeFilter = ""
        showsResources = false
    }

    // MARK: - Rows

    private func rowView(_ row: Trace.DisplayRow) -> some View {
        let isOpen = opened == row.id
        return HStack(spacing: 0) {
            label(row)
                .frame(width: labelWidth, alignment: .leading)
            GeometryReader { proxy in
                track(row, width: proxy.size.width)
                    .frame(maxHeight: .infinity)
            }
            .padding(.trailing, Self.trailingInset)
        }
        .frame(height: 28 * textScale)
        .background(selected == row.id || isOpen ? Theme.field : Color.clear)
        .hoverFill(cornerRadius: 0)
        .contentShape(Rectangle())
        .onTapGesture {
            selected = row.id
            toggleDrawer(row.id)
            keyboardFocus = true
        }
        .opacity(dimmed(row) ? 0.3 : 1)
        .appTooltip { tooltip(row) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(row))
        .accessibilityValue(accessibilityValue(row))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected == row.id ? .isSelected : [])
        .accessibilityAction { toggleDrawer(row.id) }
        .accessibilityActions { foldActions(row) }
    }

    @ViewBuilder
    private func foldActions(_ row: Trace.DisplayRow) -> some View {
        switch row {
        case .span(let span) where span.hasChildren:
            Button(collapsed.contains(span.id) ? "Unfold" : "Fold") { toggleFold(span.id) }
        case .group(let group):
            Button("List each span") { openGroups.insert(group.key) }
        default:
            EmptyView()
        }
    }

    private func accessibilityLabel(_ row: Trace.DisplayRow) -> String {
        switch row {
        case .span(let row):
            let span = row.span
            return "\(span.operation), \(span.service), \(Trace.durationText(span.durationNanos))"
                + (span.isError ? ", failed" : "") + ", level \(row.depth + 1)"
        case .group(let group):
            let failed = group.failures.count
            return "\(group.spans.count) \(group.spans[0].operation) spans, \(group.spans[0].service)"
                + (failed > 0 ? ", \(failed) failed" : "") + ", level \(group.depth + 1)"
        }
    }

    private func accessibilityValue(_ row: Trace.DisplayRow) -> String {
        guard case .span(let span) = row, span.hasChildren else { return "" }
        return collapsed.contains(span.id) ? "Folded, \(hiddenCounts[span.id] ?? 0) below" : "Unfolded"
    }

    private func dimmed(_ row: Trace.DisplayRow) -> Bool {
        let (service, onPath): (String, Bool) = switch row {
        case .span(let row): (row.span.service, trace.criticalPath.contains(row.id))
        case .group(let group):
            (group.spans[0].service, group.spans.contains { trace.criticalPath.contains($0.id) })
        }
        if let activeService, activeService != service { return true }
        return lens == .slowest && !onPath
    }

    private func toggleFold(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        selected = id
    }

    // The callers above the selected row, whose guide lines are drawn darker so the way
    // up from it can be followed.
    private var selectedCallers: Set<String> {
        guard let selected else { return [] }
        // A grouped row's id names its caller first: "g:<caller>:<service>:<operation>".
        var current: String? = selected.hasPrefix("g:")
            ? selected.dropFirst(2).split(separator: ":").first.map(String.init)
            : trace.parentIDs[selected]
        var callers = Set<String>()
        while let id = current, callers.insert(id).inserted { current = trace.parentIDs[id] }
        return callers
    }

    private func label(_ row: Trace.DisplayRow) -> some View {
        HStack(spacing: 0) {
            guides(row)
            switch row {
            case .span(let row): spanLabel(row)
            case .group(let group): groupLabel(group)
            }
        }
        .padding(.leading, Space.lg)
        .padding(.trailing, Space.md)
    }

    private func guides(_ row: Trace.DisplayRow) -> some View {
        var callers: [String] = []
        var current: String? = switch row {
        case .span(let row): trace.parentIDs[row.id]
        case .group(let group): group.parent.id
        }
        while let id = current {
            callers.insert(id, at: 0)
            current = trace.parentIDs[id]
        }
        let hot = selectedCallers
        return HStack(spacing: 0) {
            ForEach(Array(callers.suffix(24).enumerated()), id: \.offset) { _, caller in
                Rectangle()
                    .fill(hot.contains(caller) ? Theme.secondaryText.opacity(0.5) : Theme.hairline)
                    .frame(width: 1)
                    .frame(width: 14)
            }
        }
    }

    private func spanLabel(_ row: Trace.Row) -> some View {
        let span = row.span
        let folded = collapsed.contains(span.id)
        return HStack(spacing: Space.xs) {
            if row.hasChildren {
                Button { toggleFold(span.id) } label: {
                    chevron(open: !folded, failureInside: folded && (trace.failuresBelow[span.id] ?? 0) > 0)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(folded ? "Unfold" : "Fold")
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
            operation(span.operation, failed: span.isError)
            if folded, let hidden = hiddenCounts[span.id], hidden > 0 {
                Text("+\(hidden)")
                    .scaledMono(Typography.Size.micro)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            if row.parentMissing {
                Text("parent not in trace")
                    .scaledText(Typography.Size.caption)
                    .foregroundStyle(Theme.attentionText)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 6)
            duration(span.durationNanos, failed: span.isError)
        }
    }

    private func groupLabel(_ group: Trace.Group) -> some View {
        HStack(spacing: Space.xs) {
            Button { openGroups.insert(group.key) } label: {
                chevron(open: false, failureInside: false)
            }
            .buttonStyle(.plain)
            .appTooltip("List each of the \(group.spans.count) spans")
            operation(group.spans[0].operation, failed: !group.failures.isEmpty)
            Text("×\(group.spans.count)")
                .scaledMono(Typography.Size.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: 6)
            duration(group.endNanos - group.startNanos, failed: !group.failures.isEmpty)
        }
    }

    private func chevron(open: Bool, failureInside: Bool) -> some View {
        Image(systemName: open ? "chevron.down" : "chevron.right")
            .font(.system(size: Typography.Size.micro * textScale, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 14, height: 14)
            .overlay(alignment: .topTrailing) {
                if failureInside {
                    Circle()
                        .fill(Theme.deletion)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("A failed span is folded inside")
                }
            }
            .contentShape(Rectangle())
    }

    private func operation(_ operation: String, failed: Bool) -> some View {
        let parts = Trace.verb(of: operation)
        return HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            if let verb = parts.verb {
                Text(verb)
                    .scaledMono(Typography.Size.micro, .medium)
                    .foregroundStyle(failed ? Theme.deletion : Color.secondary)
                    .fixedSize()
            }
            Text(parts.rest)
                .scaledText(Typography.Size.body)
                .foregroundStyle(failed ? Theme.deletion : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func duration(_ nanos: Int64, failed: Bool) -> some View {
        Text(Trace.durationText(nanos))
            .scaledMono(Typography.Size.caption)
            .monospacedDigit()
            .foregroundStyle(failed ? Theme.deletion : Color.secondary)
            .fixedSize()
    }

    // MARK: - Bars

    @ViewBuilder
    private func track(_ row: Trace.DisplayRow, width: CGFloat) -> some View {
        switch row {
        case .span(let row):
            spanTrack(row, width: width)
        case .group(let group):
            ZStack(alignment: .leading) {
                ForEach(group.spans) { span in
                    if span.endNanos >= view.lowerBound && span.startNanos <= view.upperBound {
                        Rectangle()
                            .fill(span.isError ? Theme.deletion : colour(span.service))
                            .frame(width: 1.5, height: 12)
                            .offset(x: max(fraction(span.startNanos), 0) * width)
                    }
                }
                if group.spans[0].service != group.parent.service {
                    serviceTag(group.spans[0].service, from: group.startNanos, to: group.endNanos,
                               width: width)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    @ViewBuilder
    private func spanTrack(_ row: Trace.Row, width: CGFloat) -> some View {
        let span = row.span
        let from = max(span.startNanos, view.lowerBound)
        let to = min(span.endNanos, view.upperBound)
        if to < view.lowerBound || from > view.upperBound {
            let offset = Trace.offsetText(span.startNanos - trace.startNanos)
            Text(span.endNanos < view.lowerBound ? "← \(offset)" : "\(offset) →")
                .scaledMono(Typography.Size.micro)
                .foregroundStyle(.tertiary)
                .frame(width: width, alignment: span.endNanos < view.lowerBound ? .leading : .trailing)
        } else {
            let left = fraction(from) * width
            let barWidth = max((fraction(to) - fraction(from)) * width, 1.5)
            let tint = span.isError ? Theme.deletion : colour(span.service)
            let caller = trace.parentIDs[span.id].flatMap(trace.span)
            ZStack(alignment: .leading) {
                bar(span, from: from, to: to, width: barWidth, tint: tint)
                    .offset(x: left)
                // Too thin to see, so a failure is marked where it would be.
                if span.isError && barWidth < 3 {
                    Diamond()
                        .fill(Theme.deletion)
                        .frame(width: 8, height: 8)
                        .offset(x: left - 4 + barWidth / 2)
                }
                if caller?.service != span.service {
                    serviceTag(span.service, from: from, to: to, width: width)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    // A span with spans below it is drawn as a light tint with solid stretches where
    // something below was running, so time spent waiting on nothing shows as the gaps.
    @ViewBuilder
    private func bar(_ span: Trace.Span, from: Int64, to: Int64, width: CGFloat,
                     tint: Color) -> some View {
        let stretches = trace.busy[span.id] ?? []
        if stretches.isEmpty {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(tint)
                .frame(width: width, height: 12)
        } else {
            let range = Double(max(to - from, 1))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5).fill(tint.opacity(0.26))
                ForEach(Array(stretches.enumerated()), id: \.offset) { _, stretch in
                    let start = max(stretch.lowerBound, from)
                    let end = min(stretch.upperBound, to)
                    if end > start {
                        Rectangle()
                            .fill(tint)
                            .frame(width: max(CGFloat(Double(end - start) / range) * width, 1.5))
                            .offset(x: CGFloat(Double(start - from) / range) * width)
                    }
                }
            }
            .frame(width: width, height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 2.5))
        }
    }

    // The service is named once, beside the bar where the work crosses into it. It sits
    // after a bar that ends early, before one that starts late, and is left off a bar
    // that fills the row.
    @ViewBuilder
    private func serviceTag(_ service: String, from: Int64, to: Int64, width: CGFloat) -> some View {
        let start = fraction(max(from, view.lowerBound))
        let end = fraction(min(to, view.upperBound))
        let tag = HStack(spacing: Space.xs) {
            Circle().fill(colour(service)).frame(width: 5, height: 5)
            Text(service).scaledText(Typography.Size.caption)
        }
        .foregroundStyle(colour(service))
        .lineLimit(1)
        .fixedSize()
        .allowsHitTesting(false)
        if end < 0.7 {
            tag.offset(x: end * width + 8)
        } else if start >= 0.3 {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                tag
            }
            .frame(width: start * width - 8)
        }
    }

    private func tooltip(_ row: Trace.DisplayRow) -> Tooltip {
        switch row {
        case .span(let row):
            let span = row.span
            var rows = [Tooltip.Row(label: "Started", value: Trace.offsetText(span.startNanos - trace.startNanos)),
                        Tooltip.Row(label: "Took", value: Trace.spacedDuration(span.durationNanos))]
            if row.hasChildren {
                let below = trace.busyNanos(span)
                rows.append(Tooltip.Row(label: "Work below", value: Trace.spacedDuration(below)))
                rows.append(Tooltip.Row(label: "Waiting",
                                        value: Trace.spacedDuration(span.durationNanos - below)))
            }
            return Tooltip(title: span.operation, subtitle: span.service,
                           note: span.isError ? span.statusMessage ?? "Failed" : nil, rows: rows)
        case .group(let group):
            let durations = group.spans.map(\.durationNanos)
            return Tooltip(
                title: "\(group.spans.count) × \(group.spans[0].operation)",
                subtitle: "\(group.spans[0].service), side by side",
                note: group.failures.first.map { $0.statusMessage ?? "Failed" },
                rows: [Tooltip.Row(label: "Started",
                                   value: Trace.offsetText(group.startNanos - trace.startNanos)),
                       Tooltip.Row(label: "Each took",
                                   value: "\(Trace.durationText(durations.min() ?? 0)) to "
                                       + Trace.durationText(durations.max() ?? 0))])
        }
    }

    // MARK: - Drawer

    @ViewBuilder
    private func drawer(_ row: Trace.DisplayRow) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            switch row {
            case .span(let row): spanDrawer(row.span)
            case .group(let group): groupDrawer(group)
            }
        }
        .padding(.leading, Space.xl)
        .padding(.trailing, Space.xl)
        .padding(.vertical, Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sunken)
        .overlay(alignment: .top) { rule }
        .overlay(alignment: .bottom) { rule }
    }

    @ViewBuilder
    private func spanDrawer(_ span: Trace.Span) -> some View {
        let caller = trace.parentIDs[span.id].flatMap(trace.span)
        drawerHead(title: span.operation, service: span.service,
                   note: Self.kindWord(span.kind) + (caller.map { ", called by \($0.operation)" } ?? "")) {
            ActionButton(title: "Zoom to span", tone: .outlined, height: ControlHeight.md, size: Typography.Size.detail,
                         icon: "plus.magnifyingglass") {
                window = trace.zoomWindow(around: span)
            }
            askButton(for: span, key: span.id)
        }
        FlowRow(spacing: Space.xxxl) {
            fact("Started", Trace.offsetText(span.startNanos - trace.startNanos))
            fact("Took", Trace.spacedDuration(span.durationNanos))
            fact("Span ID", span.id)
            fact("Status", span.isError ? span.statusMessage ?? "Failed" : "OK",
                 tint: span.isError ? Theme.deletion : Theme.addition)
            within(span, caller: caller)
        }
        .textSelection(.enabled)
        attributes(span)
        events(span)
    }

    @ViewBuilder
    private func groupDrawer(_ group: Trace.Group) -> some View {
        let first = group.spans[0]
        let durations = group.spans.map(\.durationNanos).sorted()
        let failures = group.failures
        drawerHead(title: "\(group.spans.count) × \(first.operation)", service: first.service,
                   note: "ran these side by side under \(group.parent.operation)") {
            ActionButton(title: "List each span", tone: .outlined, height: ControlHeight.md, size: Typography.Size.detail) {
                openGroups.insert(group.key)
                opened = nil
            }
            askButton(for: failures.first ?? first, key: group.id)
        }
        FlowRow(spacing: Space.xxxl) {
            fact("Started", Trace.offsetText(group.startNanos - trace.startNanos))
            fact("Shortest", Trace.spacedDuration(durations.first ?? 0))
            fact("Longest", Trace.spacedDuration(durations.last ?? 0))
            if let failure = failures.first {
                fact("Status", "\(failures.count) of \(group.spans.count): "
                         + (failure.statusMessage ?? "failed"), tint: Theme.deletion)
            } else {
                fact("Status", "All OK", tint: Theme.addition)
            }
            fact("Spread", "\(Trace.spacedDuration(group.endNanos - group.startNanos)) from first to last")
        }
        .textSelection(.enabled)
    }

    private func drawerHead(title: String, service: String, note: String,
                            @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .top, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title)
                    .scaledText(Typography.Size.body, .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: Space.xs) {
                    Circle().fill(colour(service)).frame(width: 6, height: 6)
                    Text(service).foregroundStyle(colour(service))
                    Text(note).foregroundStyle(.secondary).lineLimit(1)
                }
                .scaledText(Typography.Size.detail)
            }
            Spacer(minLength: 8)
            HStack(spacing: Space.md) { actions() }
        }
    }

    @ViewBuilder
    private func askButton(for span: Trace.Span, key: String) -> some View {
        if let askAgent {
            if asked.contains(key) {
                ActionButton(title: "Asked the agent", tone: .outlined, height: ControlHeight.md, size: Typography.Size.detail,
                             icon: "checkmark")
                    .disabled(true)
            } else {
                ActionButton(title: "Ask for \(span.service) logs", tone: .dark, height: ControlHeight.md,
                             size: Typography.Size.detail, icon: "text.alignleft") {
                    askAgent(TraceFollowUp.spanLogs(span, traceID: trace.traceID))
                    asked.insert(key)
                }
            }
        }
    }

    static func kindWord(_ kind: String) -> String {
        switch kind {
        case "client": "calls out"
        case "server": "serves"
        case "producer": "publishes"
        case "consumer": "consumes"
        default: "internal"
        }
    }

    private func fact(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title)
                .scaledText(Typography.Size.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .scaledMono(Typography.Size.detail)
                .foregroundStyle(tint)
                .lineLimit(3)
                .frame(maxWidth: 360 * textScale, alignment: .leading)
                .fixedSize(horizontal: true, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // Where the span sat inside its caller, as a strip the width of the caller.
    private func within(_ span: Trace.Span, caller: Trace.Span?) -> some View {
        let from = caller?.startNanos ?? trace.startNanos
        let to = caller?.endNanos ?? trace.endNanos
        let range = Double(max(to - from, 1))
        let stripWidth: CGFloat = 120
        let left = CGFloat(Double(span.startNanos - from) / range) * stripWidth
        let width = max(CGFloat(Double(span.durationNanos) / range) * stripWidth, 2)
        return VStack(alignment: .leading, spacing: Space.sm) {
            Text(caller == nil ? "Within the trace" : "Within its caller")
                .scaledText(Typography.Size.caption)
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.field)
                Capsule()
                    .fill(span.isError ? Theme.deletion : colour(span.service))
                    .frame(width: min(width, stripWidth))
                    .offset(x: min(max(left, 0), stripWidth - min(width, stripWidth)))
            }
            .frame(width: stripWidth, height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Starts \(Int((Double(span.startNanos - from) / range * 100).rounded())) percent into its caller")
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: Space.xs) {
            Text(title).scaledText(Typography.Size.detail, .semibold)
            Text("\(count)").scaledMono(Typography.Size.caption).foregroundStyle(.tertiary)
        }
    }

    private func attributes(_ span: Trace.Span) -> some View {
        let filter = attributeFilter.trimmed.lowercased()
        let shown = span.attributes.filter { attribute in
            filter.isEmpty || attribute.key.lowercased().contains(filter)
                || attribute.value.lowercased().contains(filter)
        }
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.md) {
                sectionTitle("Attributes", count: span.attributes.count)
                Spacer(minLength: 8)
                if span.attributes.count > 1 {
                    TextField("Filter", text: $attributeFilter)
                        .textFieldStyle(.plain)
                        .scaledText(Typography.Size.detail)
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, Space.xs)
                        .frame(width: 170 * textScale)
                        .surface(Theme.field, cornerRadius: Radius.inset)
                        .accessibilityLabel("Filter attributes")
                }
            }
            if span.attributes.isEmpty {
                quiet("This span carries no attributes.")
            } else if shown.isEmpty {
                quiet("Nothing matches \u{201C}\(attributeFilter)\u{201D}.")
            } else {
                attributeRows(shown, filter: filter)
            }
            if !span.resourceAttributes.isEmpty {
                InlineLink(title: "\(showsResources ? "Hide" : "Show") the "
                               + counted(span.resourceAttributes.count, "resource attribute"),
                           size: Typography.Size.detail) {
                    showsResources.toggle()
                }
                .padding(.top, Space.xxs)
                if showsResources {
                    attributeRows(span.resourceAttributes, filter: "")
                }
            }
        }
    }

    private func attributeRows(_ attributes: [Trace.Attribute], filter: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            ForEach(Array(attributes.enumerated()), id: \.offset) { _, attribute in
                let id = attribute.key + "\u{0}" + attribute.value
                HStack(alignment: .firstTextBaseline, spacing: Space.lg) {
                    Text(Self.highlighted(attribute.key, filter))
                        .scaledMono(Typography.Size.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 240 * textScale, alignment: .leading)
                        .textSelection(.enabled)
                    Button {
                        Pasteboard.copy(attribute.value)
                        copiedValue = id
                        Task {
                            try? await Task.sleep(for: .milliseconds(1_100))
                            if copiedValue == id { copiedValue = nil }
                        }
                    } label: {
                        Text(copiedValue == id ? AttributedString("Copied")
                                               : Self.highlighted(attribute.value, filter))
                            .scaledMono(Typography.Size.caption)
                            .foregroundStyle(copiedValue == id ? Theme.addition : Color.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .motion(Motion.hover, value: copiedValue == id)
                    .appTooltip("Copy value")
                    .accessibilityLabel("\(attribute.key): \(attribute.value)")
                    .accessibilityHint("Copies the value")
                }
            }
        }
    }

    static func highlighted(_ text: String, _ filter: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !filter.isEmpty,
              let range = attributed.range(of: filter, options: .caseInsensitive) else {
            return attributed
        }
        attributed[range].backgroundColor = Theme.attention.opacity(0.32)
        return attributed
    }

    private func events(_ span: Trace.Span) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            sectionTitle("Events", count: span.events.count)
            if span.events.isEmpty {
                quiet("No events were recorded on this span.")
            } else {
                let duration = Double(max(span.durationNanos, 1))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.field).frame(height: 4)
                        ForEach(Array(span.events.enumerated()), id: \.offset) { _, event in
                            Circle()
                                .fill(Self.isException(event) ? Theme.deletion : Theme.secondaryText)
                                .frame(width: 7, height: 7)
                                .offset(x: min(max(CGFloat(Double(event.offsetNanos) / duration), 0), 1)
                                    * (proxy.size.width - 7))
                        }
                    }
                }
                .frame(width: 240 * textScale, height: 8)
                .accessibilityHidden(true)
                ForEach(Array(span.events.enumerated()), id: \.offset) { _, event in
                    Text(TraceWaterfallView.eventLine(event))
                        .scaledMono(Typography.Size.caption)
                        .foregroundStyle(Self.isException(event) ? Theme.deletion : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private static func isException(_ event: Trace.Event) -> Bool { event.name == "exception" }

    static func eventLine(_ event: Trace.Event) -> String {
        var line = "+\(Trace.durationText(event.offsetNanos))  \(event.name)"
        if !event.attributes.isEmpty {
            line += "  " + event.attributes.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
        return line
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .scaledText(Typography.Size.detail)
            .foregroundStyle(.secondary)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.lg) {
            if omittedSpans > 0 {
                Text("Showing \(trace.rows.count) of \(Trace.grouped(Int64(trace.rows.count + omittedSpans))) spans: every failure, the calls above it, and the slowest work.")
                    .scaledText(Typography.Size.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let askAgent, !trace.traceID.isEmpty {
                    if asked.contains("whole") {
                        Text("Asked the agent to fetch it")
                            .scaledText(Typography.Size.detail, .semibold)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    } else {
                        InlineLink(title: "Fetch the whole trace", size: Typography.Size.detail) {
                            askAgent(TraceFollowUp.fullTrace(trace.traceID, server: server))
                            asked.insert("whole")
                        }
                    }
                }
            } else {
                Text("All \(counted(trace.rows.count, "span")) in this trace.")
                    .scaledText(Typography.Size.detail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: Space.md) {
                keyHint(["↑", "↓"], "move")
                keyHint(["←", "→"], "fold")
                keyHint(["↩"], "details")
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.md)
        .background(Theme.sunken.opacity(0.6))
    }

    private func keyHint(_ keys: [String], _ word: String) -> some View {
        HStack(spacing: Space.xxs) {
            ForEach(keys, id: \.self) { KeyCap(key: $0) }
            Text(word)
                .scaledText(Typography.Size.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private func colour(_ service: String) -> Color {
        let index = trace.services.firstIndex(of: service) ?? 0
        return Theme.chartSeries[index % Theme.chartSeries.count]
    }
}

private struct TraceChip: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xs)
            .surface(.clear, cornerRadius: Radius.control)
    }
}

private struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
    }
}

// The whole trace in a strip, a lane per depth, with the part the waterfall shows marked
// on it. Dragging across it zooms the waterfall in; dragging the marked part or its edges
// moves it; a double click shows the whole trace again.
struct TraceOverview: View {
    let trace: Trace
    @Binding var window: ClosedRange<Int64>?
    @Binding var dragging: Bool
    let colour: (String) -> Color

    private enum Drag {
        case new(anchor: Int64)
        case left
        case right
        case move(grab: Int64, start: ClosedRange<Int64>)
    }

    @State private var drag: Drag?
    private static let height: CGFloat = 48
    private static let lanes = 8

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    lanes
                    if let window { marks(window, width: width) }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in dragged(value, width: width) }
                    .onEnded { _ in
                        drag = nil
                        dragging = false
                    })
                .onTapGesture(count: 2) { window = nil }
            }
            .frame(height: Self.height)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.sunken))
            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Trace overview")
            .accessibilityValue(caption)
            .accessibilityAction(named: "Show whole trace") { window = nil }
            HStack(spacing: Space.md) {
                Text(caption)
                    .scaledText(Typography.Size.detail)
                    .foregroundStyle(.secondary)
                if window != nil {
                    InlineLink(title: "Show whole trace", size: Typography.Size.detail) { window = nil }
                }
            }
        }
        .appTooltip("Drag to zoom into part of the trace")
    }

    var caption: String {
        guard let window else { return "Whole trace. Drag across it to zoom in." }
        return "\(Trace.offsetText(window.lowerBound - trace.startNanos)) to "
            + "\(Trace.offsetText(window.upperBound - trace.startNanos)), "
            + "\(counted(trace.spanCount(in: window), "span")) in view"
    }

    private var lanes: some View {
        let depth = min((trace.rows.map(\.depth).max() ?? 0) + 1, Self.lanes)
        let total = Double(max(trace.durationNanos, 1))
        return Canvas { context, size in
            let laneHeight = (size.height - 10) / CGFloat(depth)
            for row in trace.rows {
                let span = row.span
                let x = CGFloat(Double(span.startNanos - trace.startNanos) / total) * size.width
                let width = max(CGFloat(Double(span.durationNanos) / total) * size.width, 1.2)
                let y = 5 + CGFloat(min(row.depth, depth - 1)) * laneHeight
                let tint = span.isError ? Theme.deletion : colour(span.service)
                context.fill(Path(roundedRect: CGRect(x: x, y: y, width: width,
                                                      height: laneHeight * 0.62),
                                  cornerRadius: 1),
                             with: .color(tint.opacity(row.hasChildren ? 0.38 : 1)))
            }
        }
    }

    private func marks(_ window: ClosedRange<Int64>, width: CGFloat) -> some View {
        let left = x(window.lowerBound, width)
        let right = x(window.upperBound, width)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.card.opacity(0.7)).frame(width: max(left, 0))
            Rectangle().fill(Theme.card.opacity(0.7))
                .frame(width: max(width - right, 0))
                .offset(x: right)
            RoundedRectangle(cornerRadius: Radius.tag)
                .stroke(Theme.accent, lineWidth: 1.5)
                .frame(width: max(right - left, 2))
                .offset(x: left)
            ForEach([left, right], id: \.self) { edge in
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 4, height: 18)
                    .offset(x: edge - 2, y: Self.height / 2 - 9)
            }
        }
        .frame(height: Self.height)
        .allowsHitTesting(false)
    }

    private func x(_ nanos: Int64, _ width: CGFloat) -> CGFloat {
        CGFloat(Double(nanos - trace.startNanos) / Double(max(trace.durationNanos, 1))) * width
    }

    private func time(_ x: CGFloat, _ width: CGFloat) -> Int64 {
        let share = min(max(Double(x / max(width, 1)), 0), 1)
        return trace.startNanos + Int64(share * Double(trace.durationNanos))
    }

    private func dragged(_ value: DragGesture.Value, width: CGFloat) {
        dragging = true
        if drag == nil {
            let start = value.startLocation.x
            if let window {
                let left = x(window.lowerBound, width)
                let right = x(window.upperBound, width)
                if abs(start - left) <= 6 {
                    drag = .left
                } else if abs(start - right) <= 6 {
                    drag = .right
                } else if start > left && start < right {
                    drag = .move(grab: time(start, width), start: window)
                } else {
                    drag = .new(anchor: time(start, width))
                }
            } else {
                drag = .new(anchor: time(start, width))
            }
        }
        let now = time(value.location.x, width)
        let current = window ?? trace.wholeWindow
        switch drag {
        case .new(let anchor):
            window = trace.zoomWindow(anchor, now)
        case .left:
            window = trace.zoomWindow(min(now, current.upperBound), current.upperBound)
        case .right:
            window = trace.zoomWindow(current.lowerBound, max(now, current.lowerBound))
        case .move(let grab, let start):
            let span = start.upperBound - start.lowerBound
            let lower = min(max(start.lowerBound + now - grab, trace.startNanos), trace.endNanos - span)
            window = trace.zoomWindow(lower, lower + span)
        case nil:
            break
        }
    }
}

// What draws while the agent is still writing the block out, so the space it will take
// is held rather than the reply jumping when it lands.
struct TraceArrivingCard: View {
    var body: some View {
        Breathing(period: 1.8) { skeleton }
            .surface(Theme.card, cornerRadius: Radius.floating)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Trace arriving")
            .accessibilityValue("The agent is writing out the trace")
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            line(width: 0.46, height: 13)
            line(width: 0.22, height: 9)
            VStack(alignment: .leading, spacing: Space.md) {
                ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, bar in
                    GeometryReader { proxy in
                        HStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: Radius.tag)
                                .fill(Theme.field)
                                .frame(width: proxy.size.width * 0.3 * bar.label, height: 9)
                            Spacer(minLength: 0)
                        }
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: Radius.tag)
                                .fill(Theme.field)
                                .frame(width: max(proxy.size.width * 0.6 * bar.width, 4), height: 9)
                                .offset(x: proxy.size.width * (0.38 + 0.6 * bar.offset))
                        }
                    }
                    .frame(height: 9)
                }
            }
            .padding(.top, Space.md)
            Text("The agent is writing out the trace. It draws once the block is complete.")
                .scaledText(Typography.Size.detail)
                .foregroundStyle(.secondary)
                .padding(.top, Space.xs)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let bars: [(label: CGFloat, offset: CGFloat, width: CGFloat)] = [
        (1, 0, 1), (0.8, 0.03, 0.08), (0.66, 0.05, 0.04), (0.66, 0.33, 0.03),
        (0.8, 0.68, 0.04), (0.6, 0.96, 0.01),
    ]

    private func line(width: CGFloat, height: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: Radius.tag)
                .fill(Theme.field)
                .frame(width: proxy.size.width * width, height: height)
        }
        .frame(height: height)
    }
}

// A trace block that could not be read. What can be made out of it is named, so asking
// for it again asks for the right trace.
struct TraceUnreadableCard: View {
    @Environment(\.askAgent) private var askAgent
    @State private var asked = false

    let traceID: String?
    let server: String?

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.warningText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("This trace could not be drawn")
                    .scaledText(Typography.Size.body, .semibold)
                Text(detail)
                    .scaledText(Typography.Size.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let askAgent {
                    Group {
                        if asked {
                            ActionButton(title: "Asked the agent", tone: .outlined, height: ControlHeight.md,
                                         size: Typography.Size.detail, icon: "checkmark")
                                .disabled(true)
                        } else {
                            ActionButton(title: "Ask the agent to fetch it again", tone: .dark,
                                         height: ControlHeight.md, size: Typography.Size.detail, icon: "arrow.clockwise") {
                                askAgent(TraceFollowUp.drawAgain(traceID, server: server))
                                asked = true
                            }
                        }
                    }
                    .padding(.top, Space.xs)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.card, cornerRadius: Radius.floating)
    }

    private var detail: String {
        var text = "The block the agent wrote could not be read, so there is nothing reliable to show."
        if let traceID {
            let short = traceID.count > 12 ? "\(traceID.prefix(8))…\(traceID.suffix(4))" : traceID
            text += " Trace \(short)" + (server.map { " from \($0)" } ?? "") + "."
        }
        return text
    }
}
