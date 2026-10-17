import SwiftUI

// A trace drawn the way Grafana draws one: a row per span, indented under its caller, with
// a bar placed on the trace's own time axis. A row opens in place to show everything the
// span carries, and whatever the caller adds for it below that.
struct TraceWaterfallView<Accessory: View>: View {
    @Environment(\.textScale) private var textScale

    let trace: Trace
    // In Chat the waterfall sits among other calls, so it scrolls in a box of its own
    // rather than growing the transcript.
    let maxHeight: CGFloat?
    let accessory: (Trace.Span) -> Accessory

    // Starts on the way down to each failure rather than on every span.
    @State private var collapsed: Set<String>
    @State private var expanded: Set<String> = []
    @State private var dimmed: Set<String> = []

    private let labelWidth: CGFloat = 300
    private let hiddenCounts: [String: Int]

    init(trace: Trace, maxHeight: CGFloat? = nil,
         @ViewBuilder accessory: @escaping (Trace.Span) -> Accessory) {
        self.trace = trace
        self.maxHeight = maxHeight
        self.accessory = accessory
        _collapsed = State(initialValue: trace.initiallyFolded)
        hiddenCounts = trace.descendantCounts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if trace.services.count > 1 { serviceFilter }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            axis
            if let maxHeight {
                ScrollView { rows }.frame(maxHeight: maxHeight * textScale)
            } else {
                rows
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.sunken, cornerRadius: 8, border: Theme.border)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // The Trace tab draws the next trace it looks up in the same place, and what was
        // folded or opened in the last one means nothing in it.
        .onChange(of: trace.traceID) {
            collapsed = trace.initiallyFolded
            expanded = []
            dimmed = []
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            if let root = trace.root {
                Text(root.service).scaledMono(11.5, .semibold)
                Text(root.operation).scaledMono(11.5).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(Self.facts(trace))
                .scaledMono(10.5)
                .foregroundStyle(trace.errorCount > 0 ? AnyShapeStyle(Theme.deletion)
                                                      : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    static func facts(_ trace: Trace) -> String {
        var parts = [Trace.durationText(trace.durationNanos),
                     counted(trace.rows.count, "span"),
                     counted(trace.services.count, "service")]
        if trace.errorCount > 0 { parts.append(counted(trace.errorCount, "error")) }
        parts.append(GrafanaResultView.clock(
            Date(timeIntervalSince1970: Double(trace.startNanos) / 1_000_000_000)))
        return parts.joined(separator: " · ")
    }

    // A pill per service, to fade out the ones not being looked at.
    private var serviceFilter: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(trace.services, id: \.self) { service in
                    ChoicePill(title: service, selected: !dimmed.contains(service)) {
                        toggle(&dimmed, service)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }

    private var axis: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth * textScale, height: 1)
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { tick in
                    if tick > 0 { Spacer(minLength: 4) }
                    Text(Trace.durationText(trace.durationNanos * Int64(tick) / 4))
                        .scaledMono(9.5)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.trailing, 12)
        }
        .padding(.vertical, 5)
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(trace.visibleRows(collapsed: collapsed)) { row in
                rowView(row)
            }
        }
    }

    private func rowView(_ row: Trace.Row) -> some View {
        let span = row.span
        let open = expanded.contains(span.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                label(row)
                    .frame(width: labelWidth * textScale, alignment: .leading)
                GeometryReader { proxy in
                    let bar = trace.bar(for: span)
                    let width = proxy.size.width
                    RoundedRectangle(cornerRadius: 2)
                        .fill(span.isError ? Theme.deletion : colour(span.service))
                        .frame(width: max(bar.width * width, 2), height: 10)
                        .offset(x: bar.offset * width)
                        .frame(maxHeight: .infinity)
                }
                .padding(.trailing, 12)
            }
            .frame(height: 24 * textScale)
            .contentShape(Rectangle())
            .onTapGesture { toggle(&expanded, span.id) }
            .background(open ? Theme.hairline.opacity(0.5) : Color.clear)
            .opacity(dimmed.contains(span.service) ? 0.3 : 1)
            if open { details(span) }
        }
    }

    private func label(_ row: Trace.Row) -> some View {
        let span = row.span
        return HStack(spacing: 5) {
            Color.clear.frame(width: CGFloat(min(row.depth, 24)) * 12, height: 1)
            if row.hasChildren {
                Button { toggle(&collapsed, span.id) } label: {
                    Image(systemName: collapsed.contains(span.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(collapsed.contains(span.id) ? "Unfold" : "Fold")
            } else {
                Color.clear.frame(width: 12, height: 12)
            }
            RoundedRectangle(cornerRadius: 2)
                .fill(colour(span.service))
                .frame(width: 8, height: 8)
            if span.isError {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.deletion)
                    .accessibilityLabel("Failed")
            }
            Text(span.service).scaledMono(11, .semibold).lineLimit(1)
            Text(span.operation)
                .scaledMono(11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if collapsed.contains(span.id), let hidden = hiddenCounts[span.id], hidden > 0 {
                Text("\(hidden) below")
                    .scaledMono(9.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if row.parentMissing {
                Text("parent not in trace")
                    .scaledMono(9.5)
                    .foregroundStyle(Theme.attentionText)
                    .lineLimit(1)
            }
            // In the label rather than beside the bar, where a span that fills the trace
            // leaves no room for it.
            Spacer(minLength: 6)
            Text(Trace.durationText(span.durationNanos))
                .scaledMono(10)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
    }

    private func details(_ span: Trace.Span) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                fact("SPAN", span.id)
                fact("KIND", span.kind)
                fact("START", "+" + Trace.durationText(span.startNanos - trace.startNanos))
                fact("DURATION", Trace.durationText(span.durationNanos))
                fact("STATUS", span.isError ? "error" : "ok")
            }
            if let message = span.statusMessage { fact("MESSAGE", message) }
            attributeList("ATTRIBUTES", span.attributes)
            attributeList("RESOURCE", span.resourceAttributes)
            if !span.events.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("EVENTS").scaledMono(10, .bold).foregroundStyle(.secondary)
                    ForEach(Array(span.events.enumerated()), id: \.offset) { _, event in
                        Text(Self.eventLine(event))
                            .scaledMono(11)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            accessory(span)
        }
        .textSelection(.enabled)
        .padding(.leading, 34)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
    }

    static func eventLine(_ event: Trace.Event) -> String {
        var line = "+\(Trace.durationText(event.offsetNanos))  \(event.name)"
        if !event.attributes.isEmpty {
            line += "  " + event.attributes.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
        return line
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).scaledMono(10, .bold).foregroundStyle(.secondary)
            Text(value).scaledMono(11).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func attributeList(_ title: String, _ attributes: [Trace.Attribute]) -> some View {
        if !attributes.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).scaledMono(10, .bold).foregroundStyle(.secondary)
                ForEach(Array(attributes.enumerated()), id: \.offset) { _, attribute in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(attribute.key)
                            .scaledMono(11)
                            .foregroundStyle(.secondary)
                            .frame(width: 220 * textScale, alignment: .leading)
                        Text(attribute.value)
                            .scaledMono(11)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func colour(_ service: String) -> Color {
        let index = trace.services.firstIndex(of: service) ?? 0
        return Theme.chartSeries[index % Theme.chartSeries.count]
    }

    private func toggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }
}

extension TraceWaterfallView where Accessory == EmptyView {
    init(trace: Trace, maxHeight: CGFloat? = nil) {
        self.init(trace: trace, maxHeight: maxHeight) { _ in EmptyView() }
    }
}
