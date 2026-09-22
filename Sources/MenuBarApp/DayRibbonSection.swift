import SwiftUI

// Where the day went: every session's turns laid on one band at the time they really
// happened, so the shape of the day - when it started, every switch, how big the gaps
// were - can be read without opening anything. The legend under the band carries the
// numbers, because a band is good at sequence and bad at comparing two totals by eye.
struct DayRibbonSection: View {
    let ribbon: DayRibbon
    // Whether every session in the window has been read off disk yet. Without it the
    // card claims an empty day for the moment between opening Home and the first scan
    // landing, which is the one moment the claim is most likely to be wrong.
    let scanned: Bool
    @Binding var range: RibbonRange
    let onOpen: (UUID) -> Void

    // The project the pointer picked out of the legend, which is how the same colour is
    // proved to mean the same project everywhere on the page. Nil means show everything.
    @State private var focused: String?

    private static let dayBandHeight: CGFloat = 30
    private static let weekBandHeight: CGFloat = 18
    private static let dayLabelWidth: CGFloat = 58
    private static let dayTotalWidth: CGFloat = 52
    private static let rowSpacing: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionRule(title: "WHERE THE DAY WENT") {
                HStack(spacing: 10) {
                    if !ribbon.isEmpty { headline }
                    HStack(spacing: 6) {
                        ForEach(RibbonRange.allCases) { option in
                            ChoicePill(title: option.title, selected: range == option) {
                                range = option
                            }
                        }
                    }
                }
            }
            card
        }
        .onChange(of: range) { focused = nil }
    }

    private var headline: some View {
        (Text(DayRibbon.duration(ribbon.spent))
            .font(.mono(11.5, .semibold))
            .foregroundStyle(Color.primary)
            + Text(verbatim: " of session time · \(counted(ribbon.legend.count, "project"))")
            .font(.mono(11))
            .foregroundStyle(.tertiary))
            .lineLimit(1)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch range {
            case .day: dayBand
            case .week: weekBands
            }
            if !ribbon.isEmpty {
                legend
            } else if scanned {
                emptyNote
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .cardSurface(cornerRadius: 12)
    }

    // MARK: - Bands

    @ViewBuilder private var dayBand: some View {
        if let band = ribbon.bands.first {
            VStack(alignment: .leading, spacing: 6) {
                track(band, height: Self.dayBandHeight)
                RibbonAxis(axis: band.axis, step: 3, namesDays: true, endsAtNow: true)
            }
        }
    }

    private var weekBands: some View {
        VStack(spacing: 5) {
            ForEach(ribbon.bands) { band in
                HStack(spacing: Self.rowSpacing) {
                    dayLabel(band)
                    track(band, height: Self.weekBandHeight)
                    Text(DayRibbon.total(band.spent))
                        .font(.mono(10.5))
                        .foregroundStyle(band.spent > 0 ? .secondary : .tertiary)
                        .frame(width: Self.dayTotalWidth, alignment: .trailing)
                }
            }
            // One axis under the stack rather than one per row: every row is a calendar
            // day, so they all read against the same hours.
            if let today = ribbon.bands.last {
                HStack(spacing: Self.rowSpacing) {
                    Color.clear.frame(width: Self.dayLabelWidth, height: 1)
                    RibbonAxis(axis: today.axis, step: 4, namesDays: false, endsAtNow: false)
                    Color.clear.frame(width: Self.dayTotalWidth, height: 1)
                }
            }
        }
    }

    private func dayLabel(_ band: DayRibbon.Band) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(band.axis.start.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.mono(10, .semibold))
                .kerning(0.6)
                .foregroundStyle(band.isToday ? Color.primary : .secondary)
            Text(band.axis.start.formatted(.dateTime.day().month(.abbreviated)))
                .font(.mono(10))
                .foregroundStyle(.tertiary)
        }
        .lineLimit(1)
        .frame(width: Self.dayLabelWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(band.axis.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
                            + ", " + spokenTotal(band.spent))
    }

    private func track(_ band: DayRibbon.Band, height: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if band.isToday, range == .day {
                    dayBreak(in: band, width: geometry.size.width, height: height)
                }
                ForEach(band.blocks) { block in
                    RibbonBlock(block: block,
                                axis: band.axis,
                                width: geometry.size.width,
                                height: height,
                                showsDay: range == .week,
                                dimmed: dimmed(block.subject.name),
                                open: { onOpen(block.sessionID) })
                }
            }
            .frame(width: geometry.size.width, height: height, alignment: .topLeading)
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.sunken))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // Midnight inside a rolling 24 hours, so the half of the band that belongs to
    // yesterday is not read as part of today.
    @ViewBuilder private func dayBreak(in band: DayRibbon.Band, width: CGFloat,
                                       height: CGFloat) -> some View {
        let midnight = Calendar.current.startOfDay(for: band.axis.end)
        if band.axis.contains(midnight) {
            let scale = width / max(band.axis.duration, 1)
            Rectangle()
                .fill(Theme.chartGrid)
                .frame(width: 1, height: height)
                .offset(x: midnight.timeIntervalSince(band.axis.start) * scale)
        }
    }

    // MARK: - Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 13) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            FlowRow(spacing: 6) {
                ForEach(ribbon.legend) { total in
                    RibbonChip(total: total,
                               dimmed: dimmed(total.subject.name),
                               focus: { focus(total.subject.name) })
                }
            }
        }
        .padding(.top, 13)
    }

    private var emptyNote: some View {
        Text(range.emptyLine)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.top, 13)
    }

    // MARK: - Focus

    private func dimmed(_ name: String) -> Bool {
        guard let focused else { return false }
        return focused != name
    }

    private func focus(_ name: String) {
        focused = focused == name ? nil : name
    }

    private func spokenTotal(_ seconds: TimeInterval) -> String {
        seconds > 0 ? DayRibbon.duration(seconds) : "nothing ran"
    }
}

// MARK: - Block

// One stretch of one session, placed at the time it happened. It is a button because
// what it stands for is a conversation, and the block is the shortest way back to it.
private struct RibbonBlock: View {
    let block: DayRibbon.Block
    let axis: DateInterval
    let width: CGFloat
    let height: CGFloat
    let showsDay: Bool
    let dimmed: Bool
    let open: () -> Void

    // Below this a run disappears from the band entirely. Two neighbours can merge
    // visually at this size, which is why the totals are read from the legend.
    private static let floor: CGFloat = 2

    @State private var hovering = false

    private var scale: CGFloat { width / max(axis.duration, 1) }

    private var span: CGFloat { max(Self.floor, block.seconds * scale) }

    private var offset: CGFloat {
        let placed = block.start.timeIntervalSince(axis.start) * scale
        return min(max(0, placed), max(0, width - span))
    }

    var body: some View {
        Button(action: open) {
            RoundedRectangle(cornerRadius: 3)
                .fill(block.subject.tint.colour)
                .frame(width: span, height: height)
                .brightness(hovering && !dimmed ? 0.06 : 0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.16 : 1)
        .offset(x: offset)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .motion(Motion.reveal, value: dimmed)
        .appTooltip(delay: .milliseconds(120)) { tooltip }
        .accessibilityLabel(spoken)
        .accessibilityHint("Opens this session")
    }

    private var tooltip: Tooltip {
        Tooltip(title: block.title,
                subtitle: block.subject.name,
                rows: [.init(label: "Spent",
                             value: DayRibbon.duration(block.seconds)
                                 + (block.isOpen ? " so far" : "")),
                       .init(label: "When", value: clock)])
    }

    private var clock: String {
        let from = block.start.formatted(date: .omitted, time: .shortened)
        let to = block.isOpen ? "now" : block.end.formatted(date: .omitted, time: .shortened)
        let day = showsDay
            ? block.start.formatted(.dateTime.weekday(.abbreviated).day()) + ", "
            : ""
        return day + from + " - " + to
    }

    private var spoken: String {
        "\(block.subject.name), \(block.title), \(clock), \(DayRibbon.duration(block.seconds))"
    }
}

// MARK: - Legend chip

private struct RibbonChip: View {
    let total: DayRibbon.Total
    let dimmed: Bool
    let focus: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: focus) {
            HStack(spacing: 7) {
                ProjectDot(tint: total.subject.tint, size: 8)
                Text(total.subject.name)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Text(DayRibbon.duration(total.spent))
                    .font(.mono(10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .surface(hovering ? Theme.field : .clear, cornerRadius: 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.35 : 1)
        .hoverLift(hovering)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .motion(Motion.reveal, value: dimmed)
        .accessibilityLabel("\(total.subject.name), \(DayRibbon.duration(total.spent))")
        .accessibilityHint("Dims every other project on the band")
    }
}

// MARK: - Axis

// The hours under a band. Labels are centred on their tick and pulled back inside the
// band at either end, so the first and last readings are not half cut off by the card.
private struct RibbonAxis: View {
    let axis: DateInterval
    let step: Int
    // Midnight is named by its date rather than by "00:00", which is the only thing
    // saying which half of a rolling day a block sits in.
    let namesDays: Bool
    let endsAtNow: Bool

    private static let height: CGFloat = 15
    private static let labelWidth: CGFloat = 72
    // Room the NOW stamp needs at the right edge. A tick whose reading would run into
    // it is dropped: NOW is the one of the two with something to say.
    private static let nowRoom: CGFloat = 58

    private struct Tick: Identifiable {
        let date: Date
        let label: String
        let isDayBreak: Bool

        var id: Date { date }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let scale = width / max(axis.duration, 1)
            ZStack(alignment: .topLeading) {
                ForEach(ticks) { tick in
                    let position = tick.date.timeIntervalSince(axis.start) * scale
                    let crowded = endsAtNow && position > width - Self.nowRoom
                    if tick.isDayBreak {
                        Rectangle()
                            .fill(Theme.chartGrid)
                            .frame(width: 1, height: Self.height)
                            .offset(x: position)
                    }
                    if !crowded {
                        Text(tick.label)
                            .font(.mono(9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .frame(width: Self.labelWidth, alignment: .center)
                            .offset(x: clamp(position - Self.labelWidth / 2, in: width))
                    }
                }
                if endsAtNow {
                    Text("NOW")
                        .font(.mono(9.5))
                        .kerning(0.6)
                        .foregroundStyle(.tertiary)
                        .frame(width: Self.labelWidth, alignment: .trailing)
                        .offset(x: max(0, width - Self.labelWidth))
                }
            }
            .frame(width: width, height: Self.height, alignment: .topLeading)
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }

    private func clamp(_ x: CGFloat, in width: CGFloat) -> CGFloat {
        min(max(0, x), max(0, width - Self.labelWidth))
    }

    private var ticks: [Tick] {
        let calendar = Calendar.current
        var result: [Tick] = []
        var cursor = calendar.date(bySetting: .minute, value: 0, of: axis.start)
            .map { calendar.date(bySetting: .second, value: 0, of: $0) ?? $0 }
            ?? axis.start
        while cursor <= axis.start { cursor.addTimeInterval(3_600) }
        while calendar.component(.hour, from: cursor) % step != 0 {
            cursor.addTimeInterval(3_600)
        }
        while cursor < axis.end {
            let midnight = calendar.component(.hour, from: cursor) == 0
            result.append(Tick(date: cursor,
                               label: midnight && namesDays
                                   ? cursor.formatted(.dateTime.weekday(.abbreviated).day()).uppercased()
                                   : cursor.formatted(date: .omitted, time: .shortened),
                               isDayBreak: midnight && namesDays))
            cursor.addTimeInterval(TimeInterval(step) * 3_600)
        }
        // A band that opens mid-hour carries no reading at its left edge, which is where
        // the day starts being read from. It only gets one when there is room: a stamp
        // pressed up against the first tick is two readings and neither is legible.
        let room = TimeInterval(step) * 3_600
        if result.first.map({ $0.date.timeIntervalSince(axis.start) >= room }) ?? true {
            result.insert(Tick(date: axis.start,
                               label: axis.start.formatted(date: .omitted, time: .shortened),
                               isDayBreak: false),
                          at: 0)
        }
        return result
    }
}
