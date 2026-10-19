import SwiftUI
import CodeStationCore

// A rolling day of summed session activity. Each bar opens the sessions behind it, and
// resting on one shows which projects filled it.
struct DayRibbonSection: View {
    let ribbon: DayRibbon
    // Whether every session in the window has been read off disk yet. Without it the
    // chart claims an empty day for the moment between opening Home and the first scan
    // landing, which is the one moment the claim is most likely to be wrong.
    let scanned: Bool
    let onOpen: (UUID) -> Void

    @Environment(TooltipPresenter.self) private var tooltips
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // One owner for every bar, so moving between bars hands the card along instead of
    // closing one and waiting to open the next.
    @State private var cardOwner = UUID()
    @State private var card = CardState()
    @State private var trackAnchor = FrameAnchor()
    @State private var sectionAnchor = FrameAnchor()

    @State private var entrance = Entrance.waiting
    @State private var settling: Task<Void, Never>?
    // Where the total starts and lands, in the section's own coordinates.
    @State private var sectionWidth: CGFloat = 0
    @State private var trackFrame: CGRect = .zero
    @State private var numberFrame: CGRect = .zero
    @State private var rollSize: CGSize = .zero

    private static let bandHeight: CGFloat = 132
    private static let barSpacing: CGFloat = 3
    // Room above the band for the "now" label, and how far its line rises past the band.
    private static let markerRoom: CGFloat = 21
    private static let markerOverhang: CGFloat = 6
    private static let axisGap: CGFloat = 8
    private static let cardWidth: CGFloat = 290
    nonisolated private static let space = "dayRibbon"
    // Resting on a bar answers almost at once. It is just long enough that a pointer
    // passing straight over the chart does not flash a card up.
    private static let hoverDelay = Duration.milliseconds(80)
    // Crossing the gap between two bars ends one hover just before the next begins, so
    // the card waits this long before going, in case the pointer is only passing over.
    private static let hideGrace = Duration.milliseconds(140)
    // The card and the dimming of the other bars keep pace with the short hover delay.
    fileprivate static let quick = Animation.easeOut(duration: 0.1)
    private static let fade: TimeInterval = 0.18

    private enum Entrance {
        case waiting
        case fading(since: Date)
        case playing(RibbonEntrance, since: Date)
        case settled
    }

    // One frame of whatever the chart is doing.
    private struct Moment {
        var play: RibbonEntrance?
        var time: TimeInterval = 0
        var chartOpacity: Double = 1
    }

    private var peeking: Bool { tooltips.isShowing(owner: cardOwner) }

    private var isMoving: Bool {
        switch entrance {
        case .fading, .playing: true
        case .waiting, .settled: false
        }
    }

    var body: some View {
        TimelineView(.animation(paused: !isMoving)) { context in
            content(moment(at: context.date))
        }
        .background(FrameAnchorView(anchor: sectionAnchor))
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16)
        .onAppear { begin() }
        .onChange(of: scanned) { begin() }
        .onDisappear {
            card.pendingShow?.cancel()
            card.pendingHide?.cancel()
            settling?.cancel()
            entrance = .waiting
            tooltips.hide(owner: cardOwner, immediately: true)
        }
    }

    private func content(_ moment: Moment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    title.fixedSize()
                    Spacer()
                    headline(moment).fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    title
                    headline(moment)
                }
            }
            chart(moment)
        }
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sectionWidth = $0 }
        .overlay(alignment: .topLeading) {
            if let play = moment.play {
                roll(play, at: moment.time)
            }
        }
    }

    private var title: some View {
        Text("Your day, at a glance")
            .font(.serif(20))
            .accessibilityAddTraits(.isHeader)
    }

    private func headline(_ moment: Moment) -> some View {
        let total = DayRibbon.duration(ribbon.spent)
        let number = moment.play?.numberOpacity(at: moment.time) ?? 1
        let rest = moment.play?.restOpacity(at: moment.time) ?? 1
        return (Text(scanned ? total : "Counting session time…")
            .font(.mono(RibbonEntrance.headlineSize, .semibold))
            .foregroundStyle(Color.primary.opacity(number))
            + Text(verbatim: scanned ? " of session time in the last 24 hours" : "")
            .font(.mono(11))
            .foregroundStyle(HierarchicalShapeStyle.tertiary.opacity(rest)))
            .fixedSize(horizontal: false, vertical: true)
            // The total leads the line, so a copy of it laid over the start of the line
            // marks where the rolling total has to land.
            .overlay(alignment: .topLeading) {
                Text(total)
                    .font(.mono(RibbonEntrance.headlineSize, .semibold))
                    .hidden()
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .named(Self.space))
                    } action: { numberFrame = $0 }
            }
    }

    private func chart(_ moment: Moment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            track(moment)
            if scanned && ribbon.isEmpty {
                emptyNote
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 11)
        .opacity(moment.chartOpacity)
        .contentShape(Rectangle())
        .gesture(TapGesture().onEnded { skip() },
                 including: moment.play == nil ? .subviews : .all)
    }

    // MARK: - Entrance

    private func moment(at date: Date) -> Moment {
        switch entrance {
        case .waiting, .settled:
            return Moment()
        case .fading(let since):
            let progress = max(0, min(1, date.timeIntervalSince(since) / Self.fade))
            return Moment(chartOpacity: 0.35 + 0.65 * (1 - (1 - progress) * (1 - progress)))
        case .playing(let play, let since):
            return Moment(play: play, time: max(0, date.timeIntervalSince(since)))
        }
    }

    // The chart makes its entrance once the scan lands, every time Home opens. A full
    // day plays the whole entrance; anything else fades in.
    private func begin() {
        guard case .waiting = entrance, scanned else { return }
        if !reduceMotion && RibbonEntrance.isDeserved(by: ribbon) {
            let play = RibbonEntrance(total: DayRibbon.duration(ribbon.spent))
            entrance = .playing(play, since: Date())
            settle(after: play.duration)
        } else {
            entrance = .fading(since: Date())
            settle(after: Self.fade)
        }
    }

    private func settle(after seconds: TimeInterval) {
        settling?.cancel()
        settling = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            entrance = .settled
        }
    }

    private func skip() {
        settling?.cancel()
        entrance = .settled
    }

    // The total, large over the chart, rolling up and then flying into the headline.
    // Only this plain text is ever scaled; the bars sit inside menu buttons.
    private func roll(_ play: RibbonEntrance, at time: TimeInterval) -> some View {
        let flight = play.flight(at: time)
        let landed = RibbonEntrance.headlineSize / RibbonEntrance.rollSize
        let start = CGPoint(x: (sectionWidth - rollSize.width) / 2,
                            y: trackFrame.midY - rollSize.height / 2 - 4)
        let end = CGPoint(x: numberFrame.minX,
                          y: numberFrame.midY - rollSize.height * landed / 2)
        return RollingTotal(play: play, time: time)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { rollSize = $0 }
            .scaleEffect(1 + (landed - 1) * flight, anchor: .topLeading)
            .offset(x: start.x + (end.x - start.x) * flight,
                    y: start.y + (end.y - start.y) * flight)
            .opacity(play.rollOpacity(at: time))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - Band

    private func track(_ moment: Moment) -> some View {
        VStack(spacing: Self.axisGap) {
            ZStack(alignment: .bottomTrailing) {
                band(moment)
                nowMarker
            }
            .frame(height: Self.markerRoom + Self.bandHeight)
            .opacity(moment.play?.chartOpacity(at: moment.time) ?? 1)
            axis
        }
    }

    private func band(_ moment: Moment) -> some View {
        GeometryReader { geometry in
            let count = max(1, min(64, Int(geometry.size.width / 7)))
            let activity = ribbon.activity(bucketCount: count)
            let peak = max(activity.map(\.spent).max() ?? 0, 1)
            let rank = ribbon.rank
            let barWidth = (geometry.size.width - Self.barSpacing * Double(count - 1)) / Double(count)
            HStack(alignment: .bottom, spacing: Self.barSpacing) {
                ForEach(Array(activity.enumerated()), id: \.offset) { index, bucket in
                    let live = scanned && bucket.spent > 0
                    let face = face(bucket, index: index, of: count, peak: peak,
                                    rank: rank, moment: moment)
                    if live {
                        let place = BarPlace(index: index, bucket: bucket,
                                             x: Double(index) * (barWidth + Self.barSpacing),
                                             width: barWidth)
                        face
                            .onFocusChange { focused in focus(place, focused) }
                            .appMenu {
                                [.searchable(bucket.sessions.map { block in
                                    MenuItem(label: block.title, projectTint: block.subject.tint,
                                             subtitle: block.subject.name,
                                             handler: { onOpen(block.sessionID) })
                                }, prompt: "Find a session", noResults: "No sessions match your search.")]
                            }
                            .onPointerHover { inside in hover(place, inside) }
                            .accessibilityLabel(activityLabel(bucket))
                            .accessibilityHint("Shows sessions active during this time")
                    } else {
                        face.accessibilityHidden(true)
                    }
                }
            }
            .allowsHitTesting(moment.play == nil)
            .background(FrameAnchorView(anchor: trackAnchor))
        }
        .frame(height: Self.bandHeight)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(Self.space))
        } action: { trackFrame = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(scanned
            ? "Session activity over the last 24 hours. Taller bars mean more session time."
            : "Counting session activity")
    }

    // A bar at rest, or where the entrance has it. Only masks and opacity move, never a
    // transform, since the bar sits inside a menu button.
    private func face(_ bucket: DayRibbon.Activity, index: Int, of count: Int,
                      peak: TimeInterval, rank: [String: Int], moment: Moment) -> RibbonBar {
        guard scanned && bucket.spent > 0 else {
            return RibbonBar(segments: [], dimmed: false, shown: false)
        }
        var bar = RibbonBar(segments: bucket.segments(height: Self.bandHeight * bucket.spent / peak,
                                                      rank: rank),
                            dimmed: peeking && card.shown != index,
                            shown: peeking && card.shown == index)
        if let play = moment.play {
            bar.grown = play.grow(ofBar: index, of: count, at: moment.time)
            bar.drained = play.drain(ofBar: index, of: count, at: moment.time)
        }
        return bar
    }

    // The right edge of the band is now, so the marker stands there above the last bar.
    private var nowMarker: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(verbatim: "NOW")
                .font(.mono(9.5, .semibold))
                .foregroundStyle(Theme.accent)
                .fixedSize()
            Spacer(minLength: 0)
            Path { path in
                path.move(to: CGPoint(x: 0.75, y: 0))
                path.addLine(to: CGPoint(x: 0.75, y: Self.bandHeight + Self.markerOverhang))
            }
            .stroke(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            .frame(width: 1.5, height: Self.bandHeight + Self.markerOverhang)
        }
        .frame(maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // Every three hours along the window, read from the window's own times rather than
    // from the bars, so the labels stay true at any width.
    private var axis: some View {
        HStack(spacing: 0) {
            ForEach(0..<9, id: \.self) { step in
                if step > 0 { Spacer(minLength: 4) }
                Text(verbatim: step == 8 ? "now" : hour(ribbon.axis.start.addingTimeInterval(
                    Double(step) * 3 * 3_600)))
                    .font(.mono(10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityHidden(true)
    }

    private func hour(_ date: Date) -> String {
        String(format: "%02d:00", Calendar.current.component(.hour, from: date))
    }

    private func activityLabel(_ bucket: DayRibbon.Activity) -> String {
        let start = bucket.interval.start.formatted(date: .omitted, time: .shortened)
        let end = bucket.interval.end.formatted(date: .omitted, time: .shortened)
        let projects = bucket.projects
            .map { "\($0.subject.name) \(DayRibbon.duration($0.spent))" }
            .joined(separator: ", ")
        return "\(start) to \(end), \(DayRibbon.duration(bucket.spent)): \(projects)"
    }

    private var emptyNote: some View {
        Text("No sessions ran in the last 24 hours")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.top, 13)
    }

    // MARK: - Card

    private struct BarPlace {
        let index: Int
        let bucket: DayRibbon.Activity
        let x: CGFloat
        let width: CGFloat
    }

    private func hover(_ place: BarPlace, _ inside: Bool) {
        guard !isMoving else { return }
        if inside {
            card.pendingShow?.cancel()
            card.pendingHide?.cancel()
            card.hovered = place.index
            if peeking {
                showCard(place)
                return
            }
            card.pendingShow = Task {
                try? await Task.sleep(for: Self.hoverDelay)
                guard !Task.isCancelled else { return }
                showCard(place)
            }
        } else if card.hovered == place.index {
            // Moving to the next bar can report the new bar's hover before this one
            // ends, so only the bar still under the pointer may cancel what is pending.
            card.pendingShow?.cancel()
            card.hovered = nil
            hideCard()
        }
    }

    // A keyboard user has no pointer to rest, so focus shows the card straight away.
    private func focus(_ place: BarPlace, _ focused: Bool) {
        guard !isMoving else { return }
        if focused {
            card.pendingShow?.cancel()
            card.pendingHide?.cancel()
            showCard(place)
        } else if card.hovered == nil && card.shown == place.index {
            hideCard()
        }
    }

    private func hideCard() {
        card.pendingHide?.cancel()
        card.pendingHide = Task {
            try? await Task.sleep(for: Self.hideGrace)
            guard !Task.isCancelled else { return }
            tooltips.hide(owner: cardOwner, immediately: true)
        }
    }

    private func showCard(_ place: BarPlace) {
        guard let track = trackAnchor.frame(), let section = sectionAnchor.frame() else { return }
        let bar = CGRect(x: track.minX + place.x, y: track.minY,
                         width: place.width, height: track.height)
        card.shown = place.index
        tooltips.show(Tooltip(title: "",
                              hanging: Tooltip.Hanging(
                                  width: Self.cardWidth,
                                  edges: section.minX...max(section.maxX, section.minX + Self.cardWidth),
                                  content: AnyView(RibbonCard(bucket: place.bucket)),
                                  arrival: Self.quick)),
                      from: bar, owner: cardOwner)
    }
}

// Which bar has its card up and which one the pointer is on. SwiftUI can report a hover
// in the middle of an update, and a change to view state made then is lost while the
// card still moves on, so the chart would light a different bar from the one the card
// describes. A change to an observable object is not lost that way.
@MainActor
@Observable
private final class CardState {
    var shown: Int?
    @ObservationIgnored var hovered: Int?
    @ObservationIgnored var pendingShow: Task<Void, Never>?
    @ObservationIgnored var pendingHide: Task<Void, Never>?
}

// MARK: - Bar

private struct RibbonBar: View {
    // Bottom first. Empty for a slot with nothing to show, which is drawn as a stub.
    let segments: [DayRibbon.Activity.Segment]
    let dimmed: Bool
    // The bar whose card is up shows its project mix in place of the green.
    let shown: Bool
    // During the entrance the bar grows up from the baseline in its project mix, and the
    // mix then drains away from the top to show the green underneath.
    var grown: Double?
    var drained: Double?

    @Environment(\.colorScheme) private var colorScheme

    private static let radius: CGFloat = 2
    private static let stubHeight: CGFloat = 3

    private var height: CGFloat {
        segments.reduce(0) { $0 + $1.height }
            + DayRibbon.Activity.segmentGap * Double(max(0, segments.count - 1))
    }

    private var segmentOpacity: Double { colorScheme == .dark ? 0.86 : 0.78 }

    var body: some View {
        ZStack(alignment: .bottom) {
            if segments.isEmpty || grown != nil {
                RoundedRectangle(cornerRadius: Self.radius)
                    .fill(Theme.field)
                    .frame(height: Self.stubHeight)
            }
            if !segments.isEmpty {
                bar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .opacity(dimmed ? 0.35 : 1)
        .motion(Motion.reveal, value: dimmed)
        .contentShape(Rectangle())
    }

    private var bar: some View {
        let height = height
        let drained = drained ?? 0
        return ZStack(alignment: .bottom) {
            layer { _ in Theme.accent }
                .mask(alignment: .top) {
                    Rectangle().frame(height: height * (self.drained == nil ? 1 : drained))
                }
                .opacity(shown && self.drained == nil ? 0 : 1)
                .motion(DayRibbonSection.quick, value: shown)
            layer { $0.subject.tint.colour }
                .mask(alignment: .bottom) {
                    Rectangle().frame(height: height * (1 - drained))
                }
                .opacity(shown || self.drained != nil ? 1 : 0)
                .motion(DayRibbonSection.quick, value: shown)
        }
        .frame(height: height)
        .mask(alignment: .bottom) {
            Rectangle().frame(height: height * (grown ?? 1))
        }
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.sunken)
                .padding(.horizontal, -2)
                .padding(.vertical, -4)
                .opacity(shown ? 1 : 0)
                .motion(Motion.reveal, value: shown)
        }
    }

    private func layer(_ colour: @escaping (DayRibbon.Activity.Segment) -> Color) -> some View {
        VStack(spacing: DayRibbon.Activity.segmentGap) {
            ForEach(segments.reversed()) { segment in
                RoundedRectangle(cornerRadius: Self.radius)
                    .fill(colour(segment).opacity(segmentOpacity))
                    .frame(height: segment.height)
            }
        }
    }

    // The bar sits inside the menu button, so it learns of the button's focus from the
    // environment the button sets.
    func onFocusChange(_ handler: @escaping (Bool) -> Void) -> some View {
        FocusReader(handler: handler) { self }
    }
}

// MARK: - Rolling total

// The day's total as an odometer: each digit is a strip of numbers turning behind a
// one-digit window, and the strips come to rest left to right.
private struct RollingTotal: View {
    let play: RibbonEntrance
    let time: TimeInterval

    private enum Piece {
        case digit(column: Int)
        case unit(String, last: Bool)
    }

    private static let line: CGFloat = 52

    private var pieces: [Piece] {
        var pieces: [Piece] = []
        var column = 0
        let characters = Array(play.total.filter { $0 != " " })
        for (index, character) in characters.enumerated() {
            if character.isWholeNumber {
                pieces.append(.digit(column: column))
                column += 1
            } else {
                pieces.append(.unit(String(character), last: index == characters.count - 1))
            }
        }
        return pieces
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .digit(let column):
                    digit(column)
                case .unit(let unit, let last):
                    Text(verbatim: unit)
                        .font(.mono(18, .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 3)
                        .padding(.trailing, last ? 0 : 10)
                }
            }
        }
    }

    private func digit(_ column: Int) -> some View {
        let turned = play.turn(ofDigit: column, at: time).truncatingRemainder(dividingBy: 10)
        return numeral("0")
            .hidden()
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    ForEach(0...10, id: \.self) { value in
                        numeral("\(value % 10)")
                    }
                }
                .offset(y: -turned * Self.line)
            }
            .clipped()
    }

    private func numeral(_ value: String) -> some View {
        Text(verbatim: value)
            .font(.serif(RibbonEntrance.rollSize, .medium))
            .monospacedDigit()
            .frame(height: Self.line)
    }
}

private struct FocusReader<Content: View>: View {
    let handler: (Bool) -> Void
    @ViewBuilder let content: Content

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        content.onChange(of: isFocused) { _, focused in handler(focused) }
    }
}

// What a time slot held: when it was, how long, and the projects that filled it.
private struct RibbonCard: View {
    let bucket: DayRibbon.Activity

    private static let maxRows = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(clock(bucket.interval.start)) - \(clock(bucket.interval.end))")
                        .font(.serif(15))
                    Text(verbatim: "\(day) · \(counted(bucket.projects.count, "project"))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(DayRibbon.duration(bucket.spent))
                    .font(.mono(13, .semibold))
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 10)

            mix
                .padding(.horizontal, 14)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(bucket.projects.prefix(Self.maxRows)) { share in
                    HStack(spacing: 9) {
                        ProjectTileView(name: share.subject.name, tint: share.subject.tint, side: 22)
                        Text(share.subject.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        Text(DayRibbon.duration(share.spent))
                            .font(.mono(10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
                let rest = bucket.projects.count - Self.maxRows
                if rest > 0 {
                    Text(verbatim: "and \(rest) more")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 39)
                        .padding(.trailing, 8)
                        .padding(.top, 2)
                        .padding(.bottom, 4)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text("Click to open one of these sessions")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 9)
        }
    }

    private var mix: some View {
        GeometryReader { geometry in
            let gaps = Double(max(0, bucket.projects.count - 1))
            let width = max(0, geometry.size.width - gaps)
            HStack(spacing: 1) {
                ForEach(bucket.projects) { share in
                    Rectangle()
                        .fill(share.subject.tint.colour)
                        .frame(width: width * share.spent / max(bucket.spent, 1))
                }
            }
        }
        .frame(height: 6)
        .background(Theme.field)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var day: String {
        Calendar.current.isDateInToday(bucket.interval.start) ? "Today" : "Yesterday"
    }

    private func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
