import SwiftUI

// What Home can say about today without Stats: it is read off the sessions themselves.
struct GlanceToday {
    var added = 0
    var removed = 0
    var sessions = 0
    var worktrees = 0
    var worktreeSessions = 0
    // Whether the scans behind the line counts have landed.
    var measured = false
    var changedNote = ""
}

// Where the time went, in one place on Home. A sentence says it, four lenses count it,
// and one chart shows it: the rolling day as a ribbon, or a longer stretch as stacked
// bars. The full breakdown opens in place under the card.
//
// The rolling day's agent time comes from the session scan, so it is there with Stats
// off. Everything else, and every longer stretch, comes from a Stats report.
struct GlanceSection: View {
    let timeline: [RibbonSession]
    let spans: (UUID) -> [TimeSpan]
    // Whether every session in the window has been read off disk yet. Without it the
    // chart claims an empty day for the moment between opening Home and the first scan
    // landing, which is the one moment the claim is most likely to be wrong.
    let scanned: Bool
    let today: GlanceToday
    let onOpen: (UUID) -> Void
    let openStatsSettings: () -> Void

    @Environment(StatsStore.self) private var stats
    @Environment(ProjectStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(TooltipPresenter.self) private var tooltips
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // What the person picked.
    @State private var range = StatsRange.today
    @State private var lens = StatsLens.time
    @State private var subject: UUID?
    // What is on screen. The stretch and the filter move only once the report for them
    // is built, so every number in the section changes in one go.
    @State private var shownRange = StatsRange.today
    @State private var shownSubject: UUID?
    @State private var report: StatsReport?
    @State private var subjects: [StatsSubject] = []
    @State private var showsWhy = false
    @State private var showsBreakdown = false
    @State private var zoom: Zoom?
    @State private var plotWidth: CGFloat = 0
    @FocusState private var focusedBar: Int?
    @Namespace private var rangeTrack
    @Namespace private var lensTrack

    // One owner for every bar, so moving between bars hands the card along instead of
    // closing one and waiting to open the next.
    @State private var cardOwner = UUID()
    @State private var card = CardState()
    @State private var trackAnchor = FrameAnchor()
    @State private var sectionAnchor = FrameAnchor()

    @State private var entrance = Entrance.waiting
    @State private var settling: Task<Void, Never>?
    // Where the total starts and lands, in the card's own coordinates.
    @State private var sectionWidth: CGFloat = 0
    @State private var trackFrame: CGRect = .zero
    @State private var numberFrame: CGRect = .zero
    @State private var rollSize: CGSize = .zero

    private static let bandHeight: CGFloat = 132
    private static let barSpacing: CGFloat = 3
    // A bar on a longer stretch takes this share of its slot, up to a width that still
    // reads as a bar rather than a block.
    private static let wideBarShare: CGFloat = 0.62
    private static let wideBarLimit: CGFloat = 44
    // Room above the band for the "now" label, and how far its line rises past the band.
    private static let markerRoom: CGFloat = 21
    private static let markerOverhang: CGFloat = 6
    private static let axisGap: CGFloat = 8
    private static let axisLabelWidth: CGFloat = 72
    private static let cardWidth: CGFloat = 290
    nonisolated private static let space = "glance"
    // Resting on a bar answers almost at once. It is just long enough that a pointer
    // passing straight over the chart does not flash a card up.
    private static let hoverDelay = Duration.milliseconds(80)
    // Crossing the gap between two bars ends one hover just before the next begins, so
    // the card waits this long before going, in case the pointer is only passing over.
    private static let hideGrace = Duration.milliseconds(140)
    // The card and the dimming of the other bars keep pace with the short hover delay.
    fileprivate static let quick = Animation.easeOut(duration: Motion.hoverDuration)
    private static let fade = Motion.revealDuration
    // Sessions keep working while Home is open, so Stats reads them again now and then.
    private static let rereadEvery = Duration.seconds(30)

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

    // The stretch being left, held while the axis moves from it to the new one.
    private struct Zoom {
        let outgoing: GlanceShape
        var domain: DateInterval
        var arrived = false
    }

    private struct BuildKey: Equatable {
        let revision: Int
        let range: StatsRange
        let subject: UUID?
        let enabled: Bool
    }

    private var statsOn: Bool { settings.statsEnabled }
    private var stretch: StatsRange { statsOn ? shownRange : .today }
    private var peeking: Bool { tooltips.isShowing(owner: cardOwner) }

    private var isMoving: Bool {
        switch entrance {
        case .fading, .playing: true
        case .waiting, .settled: false
        }
    }

    var body: some View {
        let ribbon = ribbon
        let shape = shape(ribbon)
        VStack(alignment: .leading, spacing: Space.lg) {
            // The "How Stats counts" panel hangs out of the title row over the card, so the
            // row has to draw above the card or the card hides the panel.
            titleRow
                .zIndex(1)
            TimelineView(.animation(paused: !isMoving)) { context in
                glanceCard(ribbon: ribbon, shape: shape, moment: moment(at: context.date))
            }
            if showsBreakdown, statsOn, let report {
                StatsBreakdown(report: report, subject: $subject, tint: tint(for:))
                    .padding(.top, Space.lg)
                    .transition(.asymmetric(insertion: .fadeIn, removal: .fold))
            }
        }
        .motion(Motion.reveal, value: showsBreakdown)
        .onAppear {
            if statsOn { stats.refresh(store) }
            begin(ribbon)
        }
        .onChange(of: scanned) { begin(self.ribbon) }
        .onChange(of: statsOn) { _, on in
            guard !on else { return }
            withAnimation(reduceMotion ? nil : Motion.control) {
                range = .today
                lens = .time
                subject = nil
                showsBreakdown = false
            }
        }
        .task(id: statsOn) {
            while statsOn, !Task.isCancelled {
                try? await Task.sleep(for: Self.rereadEvery)
                stats.refresh(store)
            }
        }
        .task(id: BuildKey(revision: stats.revision, range: range, subject: subject, enabled: statsOn)) {
            await rebuild()
        }
        .onDisappear {
            card.pendingShow?.cancel()
            card.pendingHide?.cancel()
            settling?.cancel()
            entrance = .waiting
            tooltips.hide(owner: cardOwner, immediately: true)
        }
    }

    // MARK: - Title row

    private var titleRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.lg) {
                title.fixedSize()
                Spacer(minLength: Space.lg)
                controls
            }
            VStack(alignment: .leading, spacing: Space.md) {
                title
                controls
            }
        }
    }

    // The lead words follow the stretch, so the title says what the section is about now.
    private var title: some View {
        Text("\(lead), at a glance")
            .font(Typography.display)
            .contentTransition(.opacity)
            .motion(Motion.reveal, value: range)
            .accessibilityAddTraits(.isHeader)
    }

    private var lead: String {
        switch statsOn ? range : .today {
        case .today: "Your day"
        case .week: "Your week"
        case .month: "Your month"
        }
    }

    private var controls: some View {
        HStack(spacing: Space.md) {
            HStack(spacing: Space.xs) {
                ForEach(StatsRange.allCases, id: \.self) { choice in
                    let enabled = statsOn || choice == .today
                    ChoicePill(title: choice.title, selected: (statsOn ? range : .today) == choice,
                               enabled: enabled, thumb: rangeTrack) { pick(choice) }
                        .appTooltip(enabled ? nil : "Turn on Stats to look back further")
                }
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                step(range: press.key == .rightArrow ? 1 : -1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Stretch of time")
            OptionMenu(value: subjectName, matchWidth: false, height: ControlHeight.md) { subjectEntries }
                .fixedSize()
            WhyButton(label: "How Stats counts", isOpen: $showsWhy) {
                VStack(alignment: .leading, spacing: Space.md) {
                    explanation("Agent time", "Only the stretches a turn was working. A session left open overnight is not twelve hours.")
                    explanation("Waiting on you", "From the moment an agent asked to the moment you answered. Counted from when Stats was turned on.")
                    explanation("Your reply", "From the end of a turn to your next prompt, when it came within half an hour.")
                    explanation("Cost", "What the agent reported. On a subscription, what the same use would cost on the API. Codex and Copilot report tokens only.")
                }
            }
            GlyphButton(icon: "gearshape", action: openStatsSettings)
                .appTooltip("Stats settings")
                .accessibilityLabel("Stats settings")
        }
    }

    private func explanation(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(Typography.detail.weight(.semibold))
            Text(detail)
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subjectEntries: [MenuEntry] {
        [.item("All projects and workspaces", checked: subject == nil) { pickSubject(nil) },
         .separator]
        + subjectChoices.map { choice in
            .item(choice.name, projectTint: choice.tint, checked: subject == choice.id) {
                pickSubject(choice.id)
            }
        }
    }

    private struct SubjectChoice {
        let id: UUID
        let name: String
        let tint: Theme.ProjectTint
    }

    // With Stats on, everything Stats has counted. With it off, whatever ran in the
    // rolling day, since that is all the chart can show.
    private var subjectChoices: [SubjectChoice] {
        if statsOn {
            return subjects.map { SubjectChoice(id: $0.id, name: $0.name, tint: tint(for: $0)) }
        }
        var seen: Set<UUID> = []
        return timeline.compactMap { session in
            guard let id = session.subject.subjectID, seen.insert(id).inserted else { return nil }
            return SubjectChoice(id: id, name: session.subject.name, tint: session.subject.tint)
        }
    }

    private var subjectName: String {
        guard let subject else { return "All projects and workspaces" }
        return subjectChoices.first { $0.id == subject }?.name ?? "One project"
    }

    // MARK: - Card

    private func glanceCard(ribbon: DayRibbon, shape: GlanceShape, moment: Moment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headline(ribbon: ribbon, moment: moment)
                .padding(Space.xxl)
            if statsOn && stats.isReading {
                ProgressCard(title: "Reading your sessions",
                             detail: "Numbers fill in as each one lands.",
                             done: stats.total - stats.pending, total: stats.total,
                             unit: "sessions", compact: true)
                    .padding(.horizontal, Space.xxl)
                    .padding(.bottom, Space.lg)
                    .transition(.asymmetric(insertion: .fadeIn, removal: .fold))
            }
            if let error = stats.loadError {
                WarningStrip(error, icon: "externaldrive.badge.exclamationmark") {
                    InlineLink(title: "Read again", tint: Theme.warningText) { stats.readAgain(store) }
                        .fixedSize()
                }
            }
            chart(shape, moment: moment)
                .padding(.horizontal, Space.xxl)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.xl)
            lenses(ribbon: ribbon, moment: moment)
            if !statsOn {
                statsOffNote
                    .padding(.horizontal, Space.xxl)
                    .padding(.vertical, Space.xl)
                    .transition(.asymmetric(insertion: .fadeIn, removal: .fold))
            }
            footer
                .opacity(moment.play?.restOpacity(at: moment.time) ?? 1)
        }
        .coordinateSpace(.named(Self.space))
        .background(FrameAnchorView(anchor: sectionAnchor))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sectionWidth = $0 }
        .overlay(alignment: .topLeading) {
            if let play = moment.play {
                roll(play, at: moment.time)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: Radius.floating)
        .motion(Motion.reveal, value: stats.isReading)
        .motion(Motion.reveal, value: statsOn)
        .motion(Motion.reveal, value: stats.loadError)
    }

    // MARK: - Headline

    private func headline(ribbon: DayRibbon, moment: Moment) -> some View {
        let rest = moment.play?.restOpacity(at: moment.time) ?? 1
        return HStack(alignment: .center, spacing: Space.xxl) {
            VStack(alignment: .leading, spacing: Space.xs) {
                sentence(ribbon: ribbon, moment: moment)
                Text(summary(ribbon))
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .opacity(rest)
            }
            Spacer(minLength: 0)
            if statsOn, let report {
                HStack(spacing: Space.xl) {
                    mark(icon: "flame.fill", tint: StatsBreakdown.Ink.waiting,
                         value: report.streak, label: "day streak")
                    mark(icon: "square.stack.3d.up.fill", tint: StatsBreakdown.Ink.prompts,
                         value: report.peakAtOnce, label: "at once, at most")
                }
                .opacity(rest)
                .transition(.fadeIn)
            }
        }
    }

    private var agentSeconds: TimeInterval {
        stretch == .today ? ribbon.spent : report?.agentTime.value ?? 0
    }

    // The stretch said as one sentence, so the card opens on what it means rather than on
    // four numbers to add up. The total leads, so the entrance has somewhere to land.
    private func sentence(ribbon: DayRibbon, moment: Moment) -> some View {
        let seconds = stretch == .today ? ribbon.spent : report?.agentTime.value ?? 0
        let total = StatsFormat.time(seconds)
        let number = moment.play?.numberOpacity(at: moment.time) ?? 1
        let rest = moment.play?.restOpacity(at: moment.time) ?? 1
        let ink = StatsBreakdown.Ink.time
        let lead = "Your agents worked "
        let text: Text
        if stretch == .today && !scanned {
            text = Text("Counting session time…")
        } else if seconds <= 0 {
            text = Text(stretch == .today ? "Nothing ran in the last 24 hours." : "Nothing ran in this stretch.")
        } else {
            let scope: Text = if let name = focusName(ribbon) {
                Text(" on ") + Text(name).foregroundStyle(ink.opacity(rest))
            } else {
                Text(" across ") + Text(counted(projectCount(ribbon), "project")).foregroundStyle(ink.opacity(rest))
            }
            text = Text(lead)
                + Text(total).foregroundStyle(ink.opacity(number))
                + (scope + Text(".")).foregroundStyle(Color.primary.opacity(rest))
        }
        return text
            .font(Typography.display)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.numericText(value: seconds))
            .motion(Motion.control, value: seconds)
            // A copy of the lead and the total laid over the start of the line marks where
            // the rolling total has to land.
            .overlay(alignment: .topLeading) {
                HStack(spacing: 0) {
                    Text(lead).hidden()
                    Text(total)
                        .hidden()
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .named(Self.space))
                        } action: { numberFrame = $0 }
                }
                .font(Typography.display)
                .fixedSize()
                .accessibilityHidden(true)
            }
    }

    private func focusName(_ ribbon: DayRibbon) -> String? {
        guard let shownSubject else { return nil }
        return subjectChoices.first { $0.id == shownSubject }?.name
            ?? ribbon.legend.first?.subject.name
    }

    private func projectCount(_ ribbon: DayRibbon) -> Int {
        stretch == .today
            ? ribbon.legend.count
            : report?.subjects.filter { $0.seconds > 0 }.count ?? 0
    }

    private func summary(_ ribbon: DayRibbon) -> String {
        if stretch == .today && !scanned { return " " }
        if agentSeconds <= 0 {
            if stretch == .today { return statsOn ? "Look back further to see the week." : " " }
            return stretch == .month ? " " : "Try a longer stretch."
        }
        var parts: [String] = []
        if shownSubject == nil {
            let lead = stretch == .today
                ? ribbon.legend.first?.subject.name
                : report?.subjects.first { $0.seconds > 0 }?.subject.name
            if let lead { parts.append("mostly on \(lead)") }
        }
        if statsOn, let report { parts.append(counted(Int(report.prompts.value), "prompt")) }
        if stretch == .today {
            let hours = ribbon.activity(bucketCount: 24)
            if let busiest = hours.max(by: { $0.spent < $1.spent }), busiest.spent > 0 {
                parts.append("busiest around " + String(format: "%02d:00",
                    Calendar.current.component(.hour, from: busiest.interval.start)))
            }
        } else if let day = report?.busiestDay {
            parts.append("busiest on \(day.name)")
        }
        guard let first = parts.first else { return " " }
        parts[0] = first.prefix(1).uppercased() + first.dropFirst()
        return parts.joined(separator: ", ") + "."
    }

    private func mark(icon: String, tint: Color, value: Int, label: String) -> some View {
        HStack(spacing: Space.md) {
            IconBadge(icon: icon, tint: tint, side: ControlHeight.xl, round: true)
            VStack(alignment: .leading, spacing: 0) {
                Text(value > 0 ? "\(value)" : "–")
                    .font(Typography.title)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(value)))
                    .motion(Motion.control, value: value)
                Text(label)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Lenses

    private struct Reading {
        var value: Double = 0
        var text = "–"
        var change: Double?
        var comparison: String?
        var spark: [Double] = []
    }

    // Four cells under the chart, split by hairlines. The one picked decides what the chart
    // measures, and a mark slides along their top edge to it, pointing up at the chart.
    // The footer draws the line underneath.
    private func lenses(ribbon: DayRibbon, moment: Moment) -> some View {
        let rest = moment.play?.restOpacity(at: moment.time) ?? 1
        return HStack(spacing: 0) {
            ForEach(Array(StatsLens.allCases.enumerated()), id: \.element) { index, choice in
                if index > 0 {
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                }
                lensCell(choice, reading: reading(choice, ribbon: ribbon))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .opacity(rest)
        .offset(y: (1 - rest) * Space.sm)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            step(lens: press.key == .rightArrow ? 1 : -1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What the chart measures")
    }

    private func lensCell(_ choice: StatsLens, reading: Reading) -> some View {
        let locked = !statsOn && choice != .time
        let picked = lens == choice
        return Button { pickLens(choice) } label: {
            StatTile(title: choice.caps, value: reading.text, reading: reading.value,
                     icon: choice.icon, change: reading.change, lowerIsBetter: choice.lowerIsBetter,
                     comparison: reading.comparison, spark: reading.spark, tint: choice.tint,
                     framed: false, locked: locked ? "Counted once Stats is on" : nil)
                .padding(.horizontal, Space.sm)
                .padding(.top, Space.xs)
                .background(picked ? Theme.sunken : Color.clear)
                .overlay(alignment: .top) {
                    if picked {
                        Rectangle()
                            .fill(choice.tint)
                            .frame(height: Space.xxs)
                            .matchedGeometryEffect(id: "underline", in: lensTrack)
                    }
                }
                .opacity(locked ? 0.55 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .hoverFill(cornerRadius: 0)
        .appTooltip(locked ? "Turn on Stats to count this" : nil)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityHint(locked ? "Turn on Stats to count this" : "Shows this on the chart")
        .motion(Motion.control, value: lens)
    }

    private func reading(_ choice: StatsLens, ribbon: DayRibbon) -> Reading {
        if stretch == .today && choice == .time {
            var reading = Reading(value: ribbon.spent,
                                  text: scanned ? StatsFormat.time(ribbon.spent) : "–",
                                  comparison: "in the last 24 hours",
                                  spark: ribbon.activity(bucketCount: StatTile.sparkPoints).map(\.spent))
            if statsOn, let previous = report?.agentTime.previous, previous > 0 {
                reading.change = (ribbon.spent - previous) / previous
                reading.comparison = StatsRange.today.comparison
            }
            return reading
        }
        guard statsOn, let report else { return Reading() }
        let tile = report.tile(choice)
        let compared = (tile.previous ?? 0) > 0
        return Reading(value: tile.value, text: choice.format(tile.value),
                       change: compared ? tile.change : nil,
                       comparison: compared ? stretch.comparison : " ",
                       spark: tile.spark)
    }

    // MARK: - Chart

    private func chart(_ shape: GlanceShape, moment: Moment) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            caption(shape)
            ZStack(alignment: .center) {
                VStack(spacing: Self.axisGap) {
                    ZStack(alignment: .bottomLeading) {
                        if let zoom {
                            band(zoom.outgoing, domain: zoom.domain, moment: Moment(), role: .leaving)
                        }
                        band(shape, domain: zoom?.domain ?? shape.domain, moment: moment, role: .shown)
                        if shape.wide && !shape.isEmpty {
                            averageLine(shape)
                        }
                        nowMarker
                            .opacity(stretch == .today && zoom == nil ? 1 : 0)
                            .motion(Motion.reveal, value: stretch)
                    }
                    .frame(height: Self.markerRoom + Self.bandHeight)
                    .opacity(moment.play?.chartOpacity(at: moment.time) ?? 1)
                    axis(shape)
                }
                if shape.isEmpty && (stretch != .today || scanned) && zoom == nil {
                    emptyNote(shape)
                        .transition(.fadeIn)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plotWidth = $0 }
            .opacity(moment.chartOpacity)
            .contentShape(Rectangle())
            .gesture(TapGesture().onEnded { skip() },
                     including: moment.play == nil ? .subviews : .all)
            // The bars cannot be read while the entrance plays, so a pointer that comes to
            // read them ends it rather than waiting it out.
            .onPointerHover { inside in
                if inside, case .playing = entrance { skip() }
            }
        }
    }

    private func caption(_ shape: GlanceShape) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(shape.lens.title)
                .font(Typography.detail.weight(.semibold))
                .foregroundStyle(shape.lens.tint)
                .contentTransition(.opacity)
            Text(phrase(shape))
                .font(Typography.detail)
                .foregroundStyle(.secondary)
            if shape.wide && !shape.isEmpty {
                Text("The dashed line is the average, \(shape.lens.format(shape.average)) a day")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText(value: shape.average))
            }
            Spacer(minLength: Space.md)
            if !shape.isEmpty {
                Text(shape.wide ? "Click a bar to zoom in to \(shape.stretch.zoomedIn.phrase)"
                                : "Click a bar to open its sessions")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .motion(Motion.reveal, value: shape.lens)
        .motion(Motion.reveal, value: shape.stretch)
    }

    private func phrase(_ shape: GlanceShape) -> String {
        switch shape.stretch {
        case .today: "over the last 24 hours"
        case .week: "by day, over the last 7 days"
        case .month: "by day, over the last 30 days"
        }
    }

    private enum BandRole { case shown, leaving }

    private func band(_ shape: GlanceShape, domain: DateInterval, moment: Moment,
                      role: BandRole) -> some View {
        let peak = shape.peak
        let count = shape.bars.count
        let restack = "\(shape.lens.rawValue)\(shownSubject?.uuidString ?? "")"
        // A zoom grows the new bars up from a quarter of their height as they fade in,
        // and fades the old ones out as they squeeze into place.
        let arriving = role == .shown && zoom != nil && zoom?.arrived == false
        let opacity: Double = switch role {
        case .shown: arriving ? 0 : 1
        case .leaving: zoom?.arrived == true ? 0 : 1
        }
        let growth = arriving ? ChartMotion.zoomGrowth : 1
        return ZStack(alignment: .bottomLeading) {
            ForEach(shape.bars.indices, id: \.self) { index in
                let bar = shape.bars[index]
                let slot = ChartMotion.place(bar.interval, in: domain, width: plotWidth)
                let width = shape.wide
                    ? min(slot.width * Self.wideBarShare, Self.wideBarLimit)
                    : max(0.5, slot.width - min(Self.barSpacing, slot.width * 0.17))
                let x = slot.x + (slot.width - width) / 2
                let face = face(bar, index: index, of: count, peak: peak, rank: shape.rank,
                                growth: growth, moment: moment, interactive: role == .shown)
                Group {
                    if role == .shown && bar.total > 0 && (stretch != .today || scanned) {
                        live(face, bar: bar, place: BarPlace(index: index, bar: bar, x: x, width: width),
                             shape: shape)
                    } else {
                        face.accessibilityHidden(true)
                    }
                }
                .frame(width: max(0, width), height: Self.bandHeight, alignment: .bottom)
                .offset(x: x)
                .motion(ChartMotion.restack(bar: index, of: count), value: restack)
            }
        }
        .frame(width: max(plotWidth, 0), height: Self.bandHeight, alignment: .bottomLeading)
        .animation(role == .shown ? ChartMotion.zoomArrive : ChartMotion.zoomLeave) {
            $0.opacity(opacity)
        }
        .allowsHitTesting(role == .shown && moment.play == nil && zoom == nil)
        .background {
            if role == .shown { FrameAnchorView(anchor: trackAnchor) }
        }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(Self.space))
        } action: { frame in
            if role == .shown { trackFrame = frame }
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            step(bar: press.key == .rightArrow ? 1 : -1, in: shape)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(bandLabel(shape))
        .accessibilityHidden(role == .leaving)
    }

    @ViewBuilder
    private func live(_ face: RibbonBar, bar: GlanceBar, place: BarPlace, shape: GlanceShape) -> some View {
        if shape.wide {
            Button { zoomIn(from: shape.stretch) } label: { face }
                .buttonStyle(.plain)
                .focused($focusedBar, equals: place.index)
                .onFocusChange { focused in focus(place, shape, focused) }
                .onPointerHover { inside in hover(place, shape, inside) }
                .accessibilityLabel(barLabel(bar, shape))
                .accessibilityHint("Zooms in to \(shape.stretch.zoomedIn.phrase)")
        } else if !bar.sessions.isEmpty {
            face
                .focused($focusedBar, equals: place.index)
                .onFocusChange { focused in focus(place, shape, focused) }
                .appMenu {
                    [.searchable(bar.sessions.map { block in
                        MenuItem(label: block.title, projectTint: block.subject.tint,
                                 subtitle: block.subject.name,
                                 handler: { onOpen(block.sessionID) })
                    }, prompt: "Find a session", noResults: "No sessions match your search.")]
                }
                .onPointerHover { inside in hover(place, shape, inside) }
                .accessibilityLabel(barLabel(bar, shape))
                .accessibilityHint("Shows sessions active during this time")
        } else {
            face
                .onPointerHover { inside in hover(place, shape, inside) }
                .accessibilityLabel(barLabel(bar, shape))
        }
    }

    // A bar at rest, or where the entrance has it. Only masks and opacity move, never a
    // transform, since the bar sits inside a menu button.
    private func face(_ bar: GlanceBar, index: Int, of count: Int, peak: Double,
                      rank: [String: Int], growth: CGFloat, moment: Moment,
                      interactive: Bool) -> RibbonBar {
        guard bar.total > 0, peak > 0, stretch != .today || scanned || !interactive else {
            return RibbonBar(segments: [], dimmed: false, shown: false)
        }
        let height = Self.bandHeight * bar.total / peak * growth
        var face = RibbonBar(segments: DayRibbon.Activity.segments(of: bar.pieces, total: bar.total,
                                                                  height: height, rank: rank),
                             dimmed: interactive && peeking && card.shown != index,
                             shown: interactive && peeking && card.shown == index)
        if let play = moment.play {
            face.grown = play.grow(ofBar: index, of: count, at: moment.time)
            face.tinted = play.tint(ofBar: index, of: count, at: moment.time)
        }
        return face
    }

    private func averageLine(_ shape: GlanceShape) -> some View {
        let height = shape.peak > 0 ? Self.bandHeight * shape.average / shape.peak : 0
        return Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: max(plotWidth, 0), y: 0))
        }
        .stroke(Theme.secondaryText.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .frame(height: 1)
        .offset(y: -height)
        .opacity(zoom == nil ? 1 : 0)
        .motion(ChartMotion.restack(bar: 0, of: 1), value: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // The right edge of the rolling day is now, so the marker stands there above the
    // last bar.
    private var nowMarker: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(verbatim: "NOW")
                .font(Typography.caps)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func axis(_ shape: GlanceShape) -> some View {
        Group {
            if shape.wide {
                ZStack(alignment: .topLeading) {
                    ForEach(axisLabels(shape), id: \.index) { label in
                        let slot = ChartMotion.place(shape.bars[label.index].interval,
                                                     in: shape.domain, width: plotWidth)
                        Text(verbatim: label.text)
                            .font(Typography.data)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(width: Self.axisLabelWidth)
                            .offset(x: slot.x + slot.width / 2 - Self.axisLabelWidth / 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Every three hours along the window, read from the window's own times
                // rather than from the bars, so the labels stay true at any width.
                HStack(spacing: 0) {
                    ForEach(0..<9, id: \.self) { step in
                        if step > 0 { Spacer(minLength: Space.xs) }
                        Text(verbatim: step == 8 ? "now" : hour(shape.domain.start.addingTimeInterval(
                            Double(step) * 3 * 3_600)))
                            .font(Typography.data)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
        .id(shape.stretch)
        .transition(.opacity)
        .motion(Motion.reveal, value: shape.stretch)
        .accessibilityHidden(true)
    }

    private struct AxisLabel {
        let index: Int
        let text: String
    }

    // A week names every day; a month names one bar in a few, so the dates do not run
    // into one another.
    private func axisLabels(_ shape: GlanceShape) -> [AxisLabel] {
        let calendar = Calendar.current
        let bars = shape.bars
        let (every, offset) = shape.stretch == .week ? (1, 0) : (5, 4)
        return bars.indices.filter { $0 % every == offset % every }.map { index in
            let start = bars[index].interval.start
            let text: String = if shape.stretch == .week {
                calendar.isDateInToday(start) ? "Today" : start.formatted(.dateTime.weekday(.abbreviated).day())
            } else {
                start.formatted(.dateTime.day().month(.abbreviated))
            }
            return AxisLabel(index: index, text: text)
        }
    }

    private func hour(_ date: Date) -> String {
        String(format: "%02d:00", Calendar.current.component(.hour, from: date))
    }

    private func emptyNote(_ shape: GlanceShape) -> some View {
        VStack(spacing: Space.md) {
            Text(shape.stretch == .today ? "No sessions ran in the last 24 hours" : "Nothing ran in this stretch")
                .font(Typography.detail)
                .foregroundStyle(.secondary)
            if statsOn, shape.stretch != .month {
                let longer: StatsRange = shape.stretch == .today ? .week : .month
                ActionButton(title: "Show \(longer.title)",
                             tone: .outlined, height: ControlHeight.md, size: Typography.Size.detail) {
                    pick(longer)
                }
            }
        }
        .padding(Space.lg)
    }

    private func bandLabel(_ shape: GlanceShape) -> String {
        if shape.stretch == .today && !scanned { return "Counting session activity" }
        return "\(shape.lens.title), \(phrase(shape)). Taller bars mean more. Use the arrow keys to move between bars."
    }

    private func barLabel(_ bar: GlanceBar, _ shape: GlanceShape) -> String {
        let parts = bar.pieces
            .map { "\($0.subject.name) \(shape.lens.format($0.spent))" }
            .joined(separator: ", ")
        return "\(GlanceCard.title(of: bar, in: shape)), \(shape.lens.format(bar.total)) of \(shape.lens.title.lowercased()): \(parts)"
    }

    // MARK: - Below the chart

    private var statsOffNote: some View {
        HStack(alignment: .center, spacing: Space.lg) {
            IconBadge(icon: "chart.bar.xaxis", tint: Theme.accent, side: ControlHeight.lg)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("See prompts, waits and cost, and look back further than a day")
                    .font(Typography.body.weight(.semibold))
                Text("Stats is off until you turn it on. Everything it counts stays on this Mac, and it never keeps what was written.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.md)
            ActionButton(title: "Turn on in Settings", tone: .green, height: ControlHeight.md,
                         icon: "gearshape", action: openStatsSettings)
                .fixedSize()
        }
        .padding(Space.lg)
        .washSurface(tint: Theme.accent)
    }

    private var footer: some View {
        HStack(spacing: Space.xxl) {
            if stretch == .today {
                HStack(spacing: Space.sm) {
                    if today.measured {
                        DiffPair(added: today.added, removed: today.removed, size: Typography.Size.body)
                    } else {
                        Text("Counting…").font(Typography.detail).foregroundStyle(.secondary)
                    }
                    Text("lines changed today").font(Typography.detail).foregroundStyle(.secondary)
                }
                .appTooltip(today.changedNote)
                fact(today.sessions, "sessions today")
                fact(today.worktrees, "worktrees")
                    .appTooltip("Across \(counted(today.worktreeSessions, "session"))")
            } else if let report {
                HStack(spacing: Space.sm) {
                    DiffPair(added: report.added, removed: report.removed, size: Typography.Size.body)
                    Text("lines changed \(stretchWords)").font(Typography.detail).foregroundStyle(.secondary)
                }
                fact(report.sessions, "sessions \(stretchWords)")
                fact(report.worktreeSessions, "in a worktree")
            }
            Spacer(minLength: Space.md)
            if statsOn {
                ActionButton(title: showsBreakdown ? "Hide the full breakdown" : "Show the full breakdown",
                             tone: .outlined, height: ControlHeight.md, size: Typography.Size.detail,
                             trailingIcon: showsBreakdown ? "chevron.up" : "chevron.down") {
                    showsBreakdown.toggle()
                }
                .accessibilityValue(showsBreakdown ? "Shown" : "Hidden")
            } else {
                Label("The full breakdown needs Stats", systemImage: "lock.fill")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .padding(.leading, Space.xxl)
        .padding(.trailing, Space.lg)
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.statusBand.opacity(0.55))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: Radius.floating,
                                          bottomTrailingRadius: Radius.floating))
    }

    private var stretchWords: String {
        switch stretch {
        case .today: "today"
        case .week: "in 7 days"
        case .month: "in 30 days"
        }
    }

    private func fact(_ value: Int, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(StatsFormat.count(value))
                .font(Typography.body.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
                .motion(Motion.control, value: value)
            Text(label).font(Typography.detail).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Picking

    private func pick(_ choice: StatsRange) {
        guard statsOn || choice == .today, choice != range else { return }
        skip()
        tooltips.hide(owner: cardOwner, immediately: true)
        withAnimation(reduceMotion ? nil : Motion.control) { range = choice }
    }

    private func pickLens(_ choice: StatsLens) {
        guard statsOn || choice == .time, choice != lens else { return }
        skip()
        tooltips.hide(owner: cardOwner, immediately: true)
        withAnimation(reduceMotion ? nil : Motion.control) { lens = choice }
    }

    private func pickSubject(_ id: UUID?) {
        skip()
        tooltips.hide(owner: cardOwner, immediately: true)
        subject = id
    }

    private func step(range offset: Int) -> KeyPress.Result {
        let all = StatsRange.allCases
        guard statsOn, let index = all.firstIndex(of: range),
              all.indices.contains(index + offset) else { return .ignored }
        pick(all[index + offset])
        return .handled
    }

    private func step(lens offset: Int) -> KeyPress.Result {
        let all = StatsLens.allCases
        guard statsOn, let index = all.firstIndex(of: lens),
              all.indices.contains(index + offset) else { return .ignored }
        pickLens(all[index + offset])
        return .handled
    }

    private func step(bar offset: Int, in shape: GlanceShape) -> KeyPress.Result {
        let live = shape.bars.indices.filter { shape.bars[$0].total > 0 }
        guard !live.isEmpty else { return .ignored }
        let current = focusedBar ?? (offset > 0 ? -1 : shape.bars.count)
        let next = offset > 0 ? live.first { $0 > current } : live.last { $0 < current }
        guard let next else { return .ignored }
        focusedBar = next
        return .handled
    }

    private func zoomIn(from stretch: StatsRange) {
        tooltips.hide(owner: cardOwner, immediately: true)
        pick(stretch.zoomedIn)
    }

    // MARK: - Building

    private var ribbon: DayRibbon {
        let sessions = shownSubject.map { id in timeline.filter { $0.subject.subjectID == id } } ?? timeline
        return DayRibbon.build(sessions, spans: spans, now: Date())
    }

    private func shape(_ ribbon: DayRibbon) -> GlanceShape {
        let count = GlanceShape.dayBars(width: plotWidth)
        guard statsOn, let report, stretch != .today || lens != .time else {
            return .ribbon(ribbon, bars: count)
        }
        let sessions = stretch == .today ? ribbon.activity(bucketCount: count).map(\.sessions) : []
        return .report(report, stretch: stretch, lens: lens, dayBars: count,
                       sessions: sessions, tint: tint(for:))
    }

    private func rebuild() async {
        guard statsOn else {
            shownRange = .today
            shownSubject = subject
            return
        }
        let digests = stats.digests
        let events = stats.archive.events
        let since = stats.archive.enabledAt
        let range = range
        let subject = subject
        let (built, listed) = await Task.detached(priority: .userInitiated) {
            (StatsReport.build(digests: digests, events: events, range: range,
                               subject: subject, waitsSince: since),
             StatsReport.subjects(of: digests))
        }.value
        guard !Task.isCancelled else { return }
        subjects = listed

        let zooms = range != shownRange && !reduceMotion && zoom == nil
        let refiltered = subject != shownSubject
        let outgoing = shape(ribbon)
        guard zooms else {
            withAnimation(refiltered && !reduceMotion ? Motion.control : nil) {
                report = built
                shownRange = range
                shownSubject = subject
            }
            return
        }
        // The new bars go down at once on the old axis, unseen, and then the axis moves.
        report = built
        shownRange = range
        shownSubject = subject
        zoom = Zoom(outgoing: outgoing, domain: outgoing.domain)
        let target = shape(ribbon).domain
        Task { @MainActor in
            await Task.yield()
            withAnimation(ChartMotion.zoom) {
                zoom?.domain = target
                zoom?.arrived = true
            } completion: {
                zoom = nil
            }
        }
    }

    // The colour a project or workspace wears in the sidebar and on the map, so the same
    // colour means the same thing here. One that has since been removed falls back to the
    // colour its name would give it.
    private func tint(for subject: StatsSubject) -> Theme.ProjectTint {
        let avatar: SidebarAvatar?
        let fallback: Theme.ProjectTint
        if subject.isWorkspace {
            avatar = store.workspace(subject.id)?.sidebarAvatar
            fallback = Theme.workspaceTint
        } else {
            avatar = store.project(subject.id)?.sidebarAvatar
            fallback = Theme.projectTint(for: subject.name)
        }
        guard let avatar else { return fallback }
        return avatar.identityTint(iconSet: settings.sidebarIconSet,
                                   style: settings.diceBearAvatarStyle,
                                   name: subject.name, monogramTint: fallback)
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
    private func begin(_ ribbon: DayRibbon) {
        guard case .waiting = entrance, scanned else { return }
        if !reduceMotion && stretch == .today && lens == .time
            && !(statsOn && stats.isReading) && RibbonEntrance.isDeserved(by: ribbon) {
            let play = RibbonEntrance(total: DayRibbon.duration(ribbon.spent))
            entrance = .playing(play, since: Date())
            settle(after: play.duration)
        } else {
            entrance = reduceMotion ? .settled : .fading(since: Date())
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
        guard isMoving else { return }
        settling?.cancel()
        entrance = .settled
    }

    // The total, large over the chart, rolling up and then flying into the sentence.
    // Only this plain text is ever scaled; the bars sit inside menu buttons.
    private func roll(_ play: RibbonEntrance, at time: TimeInterval) -> some View {
        let flight = play.flight(at: time)
        let landed = RibbonEntrance.headlineSize / RibbonEntrance.rollSize
        let start = CGPoint(x: (sectionWidth - rollSize.width) / 2,
                            y: trackFrame.midY - rollSize.height / 2 - Space.xs)
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

    // MARK: - Hover card

    private struct BarPlace {
        let index: Int
        let bar: GlanceBar
        let x: CGFloat
        let width: CGFloat
    }

    private func hover(_ place: BarPlace, _ shape: GlanceShape, _ inside: Bool) {
        guard !isMoving else { return }
        if inside {
            card.pendingShow?.cancel()
            card.pendingHide?.cancel()
            card.hovered = place.index
            if peeking {
                showCard(place, shape)
                return
            }
            card.pendingShow = Task {
                try? await Task.sleep(for: Self.hoverDelay)
                guard !Task.isCancelled else { return }
                showCard(place, shape)
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
    private func focus(_ place: BarPlace, _ shape: GlanceShape, _ focused: Bool) {
        guard !isMoving else { return }
        if focused {
            card.pendingShow?.cancel()
            card.pendingHide?.cancel()
            showCard(place, shape)
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

    private func showCard(_ place: BarPlace, _ shape: GlanceShape) {
        guard let track = trackAnchor.frame(), let section = sectionAnchor.frame() else { return }
        let bar = CGRect(x: track.minX + place.x, y: track.minY,
                         width: place.width, height: track.height)
        card.shown = place.index
        tooltips.show(Tooltip(title: "",
                              hanging: Tooltip.Hanging(
                                  width: Self.cardWidth,
                                  edges: section.minX...max(section.maxX, section.minX + Self.cardWidth),
                                  content: AnyView(GlanceCard(bar: place.bar, shape: shape)),
                                  arrival: Self.quick)),
                      from: bar, owner: cardOwner)
    }
}

// How each lens names itself, marks itself and writes its readings, wherever it appears.
extension StatsLens {
    var title: String {
        switch self {
        case .time: "Agent time"
        case .prompts: "Prompts"
        case .waiting: "Waiting on you"
        case .cost: "Cost"
        }
    }

    var caps: String { title.uppercased() }

    var icon: String {
        switch self {
        case .time: "timer"
        case .prompts: "text.bubble.fill"
        case .waiting: "hourglass"
        case .cost: "dollarsign"
        }
    }

    var tint: Color {
        switch self {
        case .time: StatsBreakdown.Ink.time
        case .prompts: StatsBreakdown.Ink.prompts
        case .waiting: StatsBreakdown.Ink.waiting
        case .cost: StatsBreakdown.Ink.cost
        }
    }

    // Waiting and spending are better when they fall.
    var lowerIsBetter: Bool { self == .waiting || self == .cost }

    func format(_ value: Double) -> String {
        switch self {
        case .time, .waiting: StatsFormat.time(value)
        case .prompts: StatsFormat.count(Int(value.rounded()))
        case .cost: StatsFormat.money(value)
        }
    }
}

extension StatsRange {
    // One step shorter, which is where clicking a bar of this stretch goes.
    var zoomedIn: StatsRange {
        switch self {
        case .today, .week: .today
        case .month: .week
        }
    }

    var phrase: String {
        switch self {
        case .today: "the last 24 hours"
        case .week: "the last 7 days"
        case .month: "the last 30 days"
        }
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
    // The bar whose card is up sits on a sunken background.
    let shown: Bool
    // During the entrance the bar grows up from the baseline in green, and its project
    // mix then rises from the bottom to cover the green.
    var grown: Double?
    var tinted: Double?

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
        let tinted = tinted ?? 1
        return ZStack(alignment: .bottom) {
            layer { _ in Theme.accent }
                .mask(alignment: .top) {
                    Rectangle().frame(height: height * (1 - tinted))
                }
            layer { $0.subject.tint.colour }
                .mask(alignment: .bottom) {
                    Rectangle().frame(height: height * tinted)
                }
        }
        .frame(height: height)
        .mask(alignment: .bottom) {
            Rectangle().frame(height: height * (grown ?? 1))
        }
        .background {
            RoundedRectangle(cornerRadius: Radius.tag)
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
}

extension View {
    // A bar sits inside a menu button, so it learns of the button's focus from the
    // environment the button sets.
    fileprivate func onFocusChange(_ handler: @escaping (Bool) -> Void) -> some View {
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
    private static let unitSize: CGFloat = 18

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
        HStack(alignment: .firstTextBaseline, spacing: Space.xxs) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .digit(let column):
                    digit(column)
                case .unit(let unit, let last):
                    Text(verbatim: unit)
                        .font(.mono(Self.unitSize, .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, Space.xxs)
                        .padding(.trailing, last ? 0 : Space.md)
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

// What a bar held: when it was, how much, and the projects that filled it.
private struct GlanceCard: View {
    let bar: GlanceBar
    let shape: GlanceShape

    private static let maxRows = 5
    private static let tileSide: CGFloat = 22
    private static let mixHeight: CGFloat = 6

    static func title(of bar: GlanceBar, in shape: GlanceShape) -> String {
        let start = bar.interval.start
        switch shape.stretch {
        case .today:
            return "\(clock(start)) - \(clock(bar.interval.end))"
        case .week, .month:
            return start.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        }
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(verbatim: Self.title(of: bar, in: shape))
                        .font(Typography.title)
                    Text(verbatim: subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(shape.lens.format(bar.total))
                    .font(Font.mono(Typography.Size.body, .semibold))
                    .fixedSize()
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)
            .padding(.bottom, Space.md)

            mix
                .padding(.horizontal, Space.lg)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(bar.pieces.prefix(Self.maxRows)) { share in
                    HStack(spacing: Space.md) {
                        ProjectTileView(name: share.subject.name, tint: share.subject.tint, side: Self.tileSide)
                        Text(share.subject.name)
                            .font(Typography.detail)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: Space.sm)
                        Text(shape.lens.format(share.spent))
                            .font(Typography.data)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.xs)
                }
                let rest = bar.pieces.count - Self.maxRows
                if rest > 0 {
                    Text(verbatim: "and \(rest) more")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, Self.tileSide + Space.md * 2)
                        .padding(.trailing, Space.md)
                        .padding(.top, Space.xxs)
                        .padding(.bottom, Space.xs)
                }
            }
            .padding(.horizontal, Space.sm)
            .padding(.top, Space.md)
            .padding(.bottom, Space.sm)

            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text(hint)
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
                .padding(Space.md)
                .padding(.horizontal, Space.xs)
        }
    }

    private var subtitle: String {
        let projects = counted(bar.pieces.count, "project")
        let start = bar.interval.start
        switch shape.stretch {
        case .today:
            return (Calendar.current.isDateInToday(start) ? "Today" : "Yesterday") + " · " + projects
        case .week, .month:
            return bar.interval.contains(Date()) ? "So far · " + projects : projects
        }
    }

    private var hint: String {
        if shape.wide { return "Click to zoom in to \(shape.stretch.zoomedIn.phrase)" }
        return bar.sessions.isEmpty ? "No session worked in this time" : "Click to open one of these sessions"
    }

    private var mix: some View {
        GeometryReader { geometry in
            let gaps = Double(max(0, bar.pieces.count - 1))
            let width = max(0, geometry.size.width - gaps)
            HStack(spacing: 1) {
                ForEach(bar.pieces) { share in
                    Rectangle()
                        .fill(share.subject.tint.colour)
                        .frame(width: width * share.spent / max(bar.total, .leastNonzeroMagnitude))
                }
            }
        }
        .frame(height: Self.mixHeight)
        .background(Theme.field)
        .clipShape(RoundedRectangle(cornerRadius: Radius.tag))
    }
}
