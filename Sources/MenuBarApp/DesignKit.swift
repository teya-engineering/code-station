import SwiftUI

// The pieces every screen repeats. A session has to read the same in the sidebar, on its
// project and on Home, so the state light, the diff counter and the row buttons are built
// once here rather than restated on each screen with slightly different numbers.

// MARK: - State

// What a session is doing, as the one word and colour the whole app agrees on. Waiting is
// its own state rather than a kind of running: the turn is alive and will pick itself up,
// but nothing is being worked on, and a row that says RUNNING for an hour of that is the
// row that sends someone looking for a hang.
//
// A wait only reads as live while it can still end by itself. Once it has gone stale the
// task holding the turn open is never going to report, so the row joins the ones asking
// for someone rather than sitting on a green light for the rest of the day.
enum SessionTone {
    case running, waiting, needsYou, idle

    init(busy: Bool, needsInput: Bool = false, finished: Bool = false,
         waiting: Bool = false, waitIsStale: Bool = false) {
        if needsInput || finished || (waiting && waitIsStale) {
            self = .needsYou
        } else if waiting {
            self = .waiting
        } else if busy {
            self = .running
        } else {
            self = .idle
        }
    }

    var word: String {
        switch self {
        case .running: "RUNNING"
        case .waiting: "WAITING"
        case .needsYou: "NEEDS YOU"
        case .idle: "IDLE"
        }
    }

    // Waiting shares the live colour with running and is told apart by its light, which
    // does not breathe. Colour says the session is alive; the pulse says it is moving.
    var colour: Color {
        switch self {
        case .running, .waiting: Theme.dotOn
        case .needsYou: Theme.attention
        case .idle: Color.secondary
        }
    }

    // A card carries its state as a ring rather than a fill, so a column of them reads as
    // one column with a few live rows in it.
    var ring: Color {
        switch self {
        case .running: Theme.dotOn.opacity(0.45)
        case .waiting: Theme.dotOn.opacity(0.3)
        case .needsYou: Theme.attention.opacity(0.5)
        case .idle: Theme.border
        }
    }

    var ringWidth: CGFloat { self == .idle ? 1 : 1.3 }
}

// The state light beside the state word. The avatar already carries motion while a
// session runs, so this stays still and gives the renderer no second animation to drive.
struct StateLight: View {
    let tone: SessionTone
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(tone.colour)
            .frame(width: size, height: size)
    }
}

// A green dot for the places that mark "something is running" without naming which
// session. The active avatar is the single moving status indicator.
struct RunningDot: View {
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(Theme.dotOn)
            .frame(width: size, height: size)
    }
}

// A slow swing from 0 to 1 and back, taken off the clock.
//
// Read off the clock rather than animated, because a `repeatForever` animation is never
// finished, and an animation that is still running is the animation in force for
// everything inside it. A dot whose row then moves - the transcript scrolls, a sibling
// resizes - does not travel to its new place and stop. It takes the swinging curve with
// it and rocks between the old place and the new one for as long as it is on screen. The
// clock drives nothing but the numbers asked for here, so a view that moves simply lands.
//
// Everything breathing at once shares a phase, since they all read the same clock.
enum Breath {
    static let period: TimeInterval = 1.6

    // A cosine, so each end of the swing turns as softly as an ease would take it.
    static func phase(at date: Date, period: TimeInterval = period) -> Double {
        let turn = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        return (1 - cos(2 * .pi * turn)) / 2
    }
}

// Hands its content a breathing phase to draw itself with. Held at rest under Reduce
// Motion, which is the setting that exists to stop exactly this.
//
// Resting pauses the clock rather than dropping the timeline, so content that is
// expensive to build - artwork that has to be fetched and drawn - keeps its place in the
// view tree and is not made again each time its session picks work up or puts it down.
struct Breathing<Content: View>: View {
    var active = true
    var period: TimeInterval = Breath.period
    @ViewBuilder let content: (Double) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var moving: Bool { active && !reduceMotion }

    var body: some View {
        TimelineView(.animation(paused: !moving)) { context in
            content(moving ? Breath.phase(at: context.date, period: period) : 0)
        }
    }
}

// The same dot, breathing, for the one thing that is happening right now rather than
// merely recently.
//
// The halo behind it carries all of the motion and the dot itself never changes. A dot
// this small has only a couple of whole pixels to grow into, so scaling the dot pops it
// between two sizes rather than breathing. The halo is wide enough to have somewhere to
// go, and it stays out of the layout, so the row around it never shifts.
struct PulsingDot: View {
    var colour: Color = Theme.dotOn
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: size, height: size)
            .background {
                Breathing { phase in
                    Circle()
                        .fill(colour)
                        .frame(width: size * 2.2, height: size * 2.2)
                        .scaleEffect(0.45 + 0.55 * phase)
                        .opacity(0.5 * (1 - phase))
                }
            }
    }
}

// Counts up while something runs. The reading has to keep ticking when nothing arrives to
// redraw it, which is the case a live clock exists for. Sidebar type stays a fixed size;
// transcript type follows the size the user picked, which is what `scaled` asks for.
struct ElapsedTime: View {
    let since: Date
    var size: CGFloat = 8.5
    var scaled = false

    @Environment(\.textScale) private var textScale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.reading(context.date.timeIntervalSince(since)))
                .font(.mono(size * (scaled ? textScale : 1)))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    // A clock still going: whole seconds, since the tenths would only flicker.
    static func reading(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds))
        guard whole >= 60 else { return "\(whole)s" }
        return "\(whole / 60)m \(whole % 60)s"
    }

    // A span that is over. Most tool calls are done in well under a second, and "0s" would
    // make every one of them read as the same instant, so short spans keep their tenths.
    static func duration(_ seconds: TimeInterval) -> String {
        let span = max(0, seconds)
        guard span >= 10 else { return String(format: "%.1fs", span) }
        return reading(span)
    }
}

// MARK: - Warnings

// A surface that carries a warning: a failed turn, a stalled agent, a configuration that
// could not be read. Drawn once here so every warning in the app reads as the same kind of
// interruption, and so the pair of adaptive colours WarningContrastTests measures is the
// pair everything actually uses.
private struct WarningCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.warningText)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warningBackground))
            .transition(.fadeIn)
    }
}

extension View {
    func warningCard() -> some View { modifier(WarningCard()) }
}

// The same warning as a band across the full width of a sheet or a pane, for a state
// that belongs to the whole screen rather than to one card on it. Whatever it offers,
// a retry or a reload, sits at its trailing end.
struct WarningStrip<Trailing: View>: View {
    let text: String
    var icon = "exclamationmark.triangle.fill"
    @ViewBuilder let trailing: Trailing

    init(_ text: String, icon: String = "exclamationmark.triangle.fill",
         @ViewBuilder trailing: () -> Trailing) {
        self.text = text
        self.icon = icon
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.warningText)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.warningBackground)
        .transition(.fadeIn)
    }
}

extension WarningStrip where Trailing == EmptyView {
    init(_ text: String, icon: String = "exclamationmark.triangle.fill") {
        self.init(text, icon: icon) { EmptyView() }
    }
}

// MARK: - Identity

// A project wherever it is not the subject of the screen: a small square of its colour
// ahead of its name. Square rather than round, so it never reads as a state light.
struct ProjectDot: View {
    let tint: Theme.ProjectTint
    var size: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4)
            .fill(tint.colour)
            .frame(width: size, height: size)
    }
}

// The initial on its tinted tile. Everything about it scales from the side, so the same
// tile serves the 26pt sidebar row and the 36pt workspace lead. Stacked draws a second
// tile peeking out behind, which is what a workspace is: a pile of projects.
struct ProjectTileView: View {
    let name: String
    let tint: Theme.ProjectTint
    var side: CGFloat = 26
    var dashed = false
    var stacked = false

    private var radius: CGFloat { side * 0.27 }

    var body: some View {
        face
            // The stack rides behind without taking room, so the front tile keeps the
            // place a plain project tile would have and a column of them stays aligned.
            .background(alignment: .center) { if stacked { backTile } }
    }

    private var face: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(tint.fill)
            .frame(width: side, height: side)
            .overlay {
                if dashed {
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(tint.colour.opacity(0.65),
                                style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                    Image(systemName: "bolt.fill")
                        .font(.system(size: side * 0.4, weight: .semibold))
                        .foregroundStyle(tint.ink)
                } else {
                    RoundedRectangle(cornerRadius: radius).stroke(tint.ring)
                    Text(String(name.prefix(1)).uppercased())
                        .font(.mono(side * 0.42, .semibold))
                        .foregroundStyle(tint.ink)
                }
            }
    }

    // The tile underneath, shifted up and to the right. The part it would share with the
    // front tile is cut away: both fills are translucent, so left whole it would darken
    // the face instead of sitting behind it.
    private var backTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(tint.fill)
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(tint.ring))
                .offset(x: side * 0.15, y: -side * 0.15)
            RoundedRectangle(cornerRadius: radius)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: side, height: side)
    }
}

// MARK: - Data

// Always "+n" then "−n", in that order and those two colours, so a diff is recognised
// before it is read.
struct DiffPair: View {
    let added: Int
    let removed: Int
    var size: CGFloat = 11
    var spacing: CGFloat = 5
    var weight: Font.Weight = .semibold

    var body: some View {
        HStack(spacing: spacing) {
            // Verbatim, or a four-figure count is read as a localised number and comes
            // out grouped: +1,234 beside −86.
            Text(verbatim: "+\(added)").foregroundStyle(Theme.addition)
            Text(verbatim: "−\(removed)").foregroundStyle(Theme.deletion)
        }
        .font(.mono(size, weight))
    }
}

// A small run of mono capitals on a quiet fill: a worktree badge, a git summary, the
// kind of thing that qualifies the name beside it. Its room and corners grow with the
// type, so the same chip carries a 13pt command part as well as a 9pt badge. A bordered
// one reads as a value rather than a state, which is what a command or an argument is.
struct MonoChip: View {
    let text: String
    var size: CGFloat = 10
    var tint: Color? = nil
    var bordered = false
    var mono = true

    var body: some View {
        Text(text)
            .font(mono ? .mono(size, .semibold) : .system(size: size, weight: .semibold))
            .kerning(mono ? 0.6 : 0)
            .foregroundStyle(tint ?? Color.secondary)
            .padding(.horizontal, size * 0.6)
            .padding(.vertical, size * 0.3)
            .surface(tint?.opacity(0.16) ?? Theme.field, cornerRadius: size * 0.5,
                     border: bordered ? Theme.border : .clear)
            .fixedSize()
    }
}

// MARK: - Status strip

// The thin line under a header, and the pieces every one of them is made of. A screen
// names itself on the band above and describes itself here, always in the same order and
// the same type: what it is, what state it is in, what it can run. Building the parts
// once is what keeps the project, workspace, task and session strips reading as one line
// with different readings on it rather than as four lines.

// A reading that names a state: mono capitals, tinted only when the state is worth
// noticing.
struct StatusCaps: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(.mono(10.5, .semibold))
            .kerning(0.6)
            .foregroundStyle(tint ?? Color.secondary)
            .fixedSize()
    }
}

// A reading that carries a value rather than a state: the same size in plain mono, so a
// branch or a commit subject sits under the words of the header without competing.
struct StatusValue: View {
    let text: String
    var tint: Color? = nil
    var truncation: Text.TruncationMode = .tail

    var body: some View {
        Text(text)
            .font(.mono(10.5))
            .foregroundStyle(tint ?? Color.secondary)
            .lineLimit(1)
            .truncationMode(truncation)
    }
}

// The separator between two readings that belong to the same item.
struct StatusDot: View {
    var body: some View {
        Text("·").font(.mono(10.5)).foregroundStyle(.tertiary)
    }
}

// The separator between readings about different things. A rule rather than more space,
// which a strip this thin does not have to give.
struct StatusRule: View {
    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 1, height: 14)
    }
}

// "2m", "3h", "2d": short enough to sit at the end of a narrow row.
enum RelativeTime {
    // The rungs a reading climbs: how many seconds each unit holds and the letter it is
    // written with. A reading takes the largest unit it has at least one of.
    private static let units: [(seconds: TimeInterval, letter: String)] = [
        (1, "s"), (60, "m"), (3_600, "h"), (86_400, "d"), (604_800, "w")
    ]

    private static func reading(_ seconds: TimeInterval, weeks: Bool) -> String {
        let rungs = weeks ? units[...] : units.dropLast()
        let unit = rungs.last { seconds >= $0.seconds } ?? units[0]
        return "\(Int(seconds / unit.seconds))\(unit.letter)"
    }

    static func short(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        return seconds < 60 ? "now" : reading(seconds, weeks: true)
    }

    // "41s", "2m", "1h": a length of time rather than a point in it, for the rows that
    // count seconds. Seconds are kept because the first minute of a build is the part
    // being watched, which is exactly where `short` says only "now". It stops at days:
    // a run that has lasted weeks is stuck, and "16d" says so better than "2w".
    static func duration(since date: Date) -> String {
        reading(max(0, Date().timeIntervalSince(date)), weeks: false)
    }

    // "today 09:41", "yesterday 16:18", "3 Aug 11:02": what a row shows when the reader
    // is deciding which session to come back to rather than how fresh it is.
    static func stamp(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated)) + " " + time
    }
}

// A name that gets replaced rather than edited, most often the moment a session's first
// prompt takes "New session" over. The new name fades in where the old one was, so the
// replacement is clear without drawing both names together.
extension View {
    func changingName(_ name: String) -> some View {
        modifier(ChangingName(name: name))
    }
}

private struct ChangingName: ViewModifier {
    let name: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Slow for an animation, and deliberately so: this runs once in a session's life,
    // while the eye is still on the composer the name came from. Anything quicker is
    // over before it is looked at, and reads as the name having always been there.
    private static let duration = 0.7

    // The words change inside the one view instead of a new copy being stacked over the
    // old one. Stacking keys the view on the name itself, so a row the list hands to
    // another session counts as a name change and draws both names at once, and the old
    // one has no property left to animate away with: it stays until the row is rebuilt.
    func body(content: Content) -> some View {
        content
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: Self.duration), value: name)
    }
}

// MARK: - Motion

// The pace everything interactive moves at. A switch, a pill, a menu and a pane all move
// on one of these three curves, so the window reads as a single surface reacting rather
// than a set of parts each keeping its own time.
enum Motion {
    // A colour settling under the pointer: over almost before it is noticed.
    static let hover = Animation.easeOut(duration: 0.12)
    // A control taking a new state. The spring overshoots by a hair, which is what makes
    // a switch feel thrown rather than redrawn.
    static let control = Animation.spring(response: 0.26, dampingFraction: 0.78)
    // Something arriving or leaving: a menu unfolding, a pane swapped for another.
    static let reveal = Animation.easeOut(duration: 0.18)
}

extension View {
    // Runs one of the shared curves when `value` changes, and stands still for anyone who
    // has asked the system for less motion.
    func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

// Inserted content fades into its final place. Removed content leaves immediately, so it
// cannot linger over the view that replaces it while the surrounding layout changes.
extension AnyTransition {
    static var fadeIn: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .identity)
    }

    // For content that closes onto nothing rather than onto the view that replaces it: it
    // fades as the frame around it shrinks, so the close is seen out instead of cut.
    static var fold: AnyTransition { .opacity }
}

extension View {
    // Supplies the animation transaction that lets conditional content change the layout
    // around it. Keeping this shared makes cards, dialogs and menus resize at one pace.
    func smoothlyResizes<Value: Equatable>(when value: Value) -> some View {
        modifier(SmoothResizeModifier(value: value))
    }
}

private struct SmoothResizeModifier<Value: Equatable>: ViewModifier {
    let value: Value

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: value)
    }
}

// MARK: - Structure

// The label over a section: mono capitals, a hairline taking the rest of the width, and
// whatever the section wants to say or offer on the right.
struct SectionRule<Trailing: View>: View {
    let title: String
    var dot: Color? = nil
    // A section about work in flight breathes with it, the same way its rows do.
    var pulses = false
    var tint: Color? = nil
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 9) {
            if pulses {
                RunningDot()
            } else if let dot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            Text(title)
                .font(.mono(9.5, .semibold))
                .kerning(1.3)
                .foregroundStyle(tint ?? Color.secondary)
                .fixedSize()
            Rectangle().fill(Theme.border).frame(height: 1)
            trailing
        }
    }
}

extension SectionRule where Trailing == EmptyView {
    init(_ title: String, dot: Color? = nil, pulses: Bool = false, tint: Color? = nil) {
        self.init(title: title, dot: dot, pulses: pulses, tint: tint) { EmptyView() }
    }
}

// The label over a block of a form. A section, like COMMAND or ENVIRONMENT VARIABLES,
// is led by a dot, which is the only thing separating it from the last one in a plain
// scroll. A field label is smaller and quieter, since the field under it is the point.
struct SectionLabel: View {
    enum Style { case section, field }

    let text: String
    var style: Style = .section

    init(_ text: String, style: Style = .section) {
        self.text = text
        self.style = style
    }

    var body: some View {
        switch style {
        case .section:
            HStack(spacing: 7) {
                RunningDot(size: 5)
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
            }
        case .field:
            Text(text)
                .font(.mono(10, .semibold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
        }
    }
}

// The connector under an expanded sidebar row stops at its last child. Each marker is
// anchored to its row so mixed row heights keep the line and dots aligned.
private struct SidebarRailMarkerKey: PreferenceKey {
    static let defaultValue: [Anchor<CGPoint>] = []

    static func reduce(value: inout [Anchor<CGPoint>],
                       nextValue: () -> [Anchor<CGPoint>]) {
        value.append(contentsOf: nextValue())
    }
}

struct SidebarRail<Content: View>: View {
    let colour: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) { content }
            .backgroundPreferenceValue(SidebarRailMarkerKey.self) { markers in
                GeometryReader { proxy in
                    if let lastMarker = markers.last {
                        Rectangle()
                            .fill(colour.opacity(0.42))
                            .frame(width: 1.5, height: proxy[lastMarker].y)
                            .offset(x: 5.25)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.leading, 20)
            .padding(.top, 5)
            .padding(.bottom, 4)
    }
}

struct SidebarRailRow<Content: View>: View {
    let colour: Color
    var selectedColour: Color? = nil
    var selected = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(selected ? selectedColour ?? colour : colour.opacity(0.72))
                    .anchorPreference(key: SidebarRailMarkerKey.self, value: .center) {
                        [$0]
                    }
            }
            .frame(width: 12, height: 8)
            .padding(.top, 10)
            .accessibilityHidden(true)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// The strip that closes a screen: what the defaults are, or what has gone stale, and the
// one link that leads to the screen where it can be changed.
struct FooterStrip<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize()
            Text(detail)
                .font(.mono(11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.sunken))
    }
}

// MARK: - Buttons

// The shapes a button takes. Which one a button wears says how much of the screen it
// owns, so the shape is chosen here rather than restated wherever a button is drawn.
enum ButtonTone {
    // The one action a card or a screen is really offering.
    case dark
    // The same weight, in the app's green, for starting work.
    case green
    // The same weight in the deletion red, for the action a section exists to warn about.
    // It wears the same colour as the destructive button in a dialog, so the click that
    // opens the dialog and the click that confirms it read as the same action.
    case danger
    // The amber the app uses for things that want a look, for an action that puts a
    // drifted setting right.
    case attention
    // The quieter amber used by an unread item whose action is to reveal it rather than
    // resolve it. Once read, it can return to the ordinary outlined treatment.
    case attentionOutlined
    // Beside a primary one, or on its own where the action is a choice rather than the
    // point of the row.
    case outlined
    // A control that has to stay quieter than the row it sits in.
    case sunken
}

struct ActionButton: View {
    let title: String
    var tone: ButtonTone = .dark
    var height: CGFloat = 32
    var size: CGFloat = 12.5
    var icon: String? = nil
    // The key that does the same thing, drawn as a cap on the button that names it. Only
    // worth carrying where the key is the faster answer and the button is how it is learnt.
    var shortcut: String? = nil
    var disclosure = false
    var fills = false
    var keyboardShortcut: KeyboardShortcut? = nil
    // Left out when the button opens a menu: `appMenu` brings a button of its own, and
    // one nested inside another swallows the click before the menu ever sees it.
    var action: (() -> Void)? = nil

    // Set by `.disabled(...)` on the button, so a caller has nothing to dim by hand.
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { shape }
                    .buttonStyle(.plain)
                    .keyboardShortcut(keyboardShortcut)
            } else {
                shape
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }

    private var lit: Bool { hovering && isEnabled }

    private var shape: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: size - 1, weight: .semibold))
            }
            Text(title)
                .font(.system(size: size, weight: .semibold))
                .lineLimit(1)
                // A button's label is the button: it holds its width and lets whatever
                // shares the row give way, rather than truncating its own words.
                .fixedSize()
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: size - 1.5, weight: .semibold))
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(label.opacity(0.32)))
                    .opacity(0.75)
            }
            if disclosure {
                MenuChevron(size: size - 4, tint: label)
                    .opacity(0.65)
            }
        }
        .foregroundStyle(label)
        .padding(.horizontal, height * 0.4)
        .frame(height: height)
        .frame(maxWidth: fills ? .infinity : nil)
        .surface(fill, cornerRadius: height * 0.25, border: stroke)
        .contentShape(RoundedRectangle(cornerRadius: height * 0.25))
    }

    private var label: Color {
        switch tone {
        case .dark, .green, .danger, .attention: Color.white
        case .attentionOutlined: Theme.attentionText
        case .outlined, .sunken: Color.primary
        }
    }

    private var fill: Color {
        switch tone {
        case .dark: Color.black.opacity(lit ? 0.82 : 0.9)
        case .green: lit ? Theme.accentFill.opacity(0.86) : Theme.accentFill
        case .danger: lit ? Theme.deletion.opacity(0.86) : Theme.deletion
        case .attention: lit ? Theme.secret.opacity(0.86) : Theme.secret
        case .attentionOutlined:
            lit ? Theme.attention.opacity(0.14) : Theme.attention.opacity(0.08)
        case .outlined: lit ? Theme.field : .clear
        case .sunken: lit ? Theme.border : Theme.field
        }
    }

    private var stroke: Color {
        switch tone {
        case .dark, .green, .danger, .attention: .clear
        case .attentionOutlined: Theme.attention.opacity(0.38)
        case .outlined, .sunken: Theme.border
        }
    }
}

// The smallest way to offer an action: accent-coloured words, no shape at all. Used for
// the one link a section header or a footer strip carries.
struct InlineLink: View {
    let title: String
    var size: CGFloat = 12
    var tint: Color = Theme.accent
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .opacity(hovering ? 0.75 : 1)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

// A square button holding one glyph: the overflow menu at the end of a row, a close, a
// settings cog. Destructive actions live behind the overflow rather than in the row, so
// this is the only icon-only button the layouts use.
struct GlyphButton: View {
    let icon: String
    var side: CGFloat = 30
    // A toggle that is on wears the accent fill, the way a pressed tool does.
    var active = false
    var tint: Color? = nil
    var action: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { shape }
                    .buttonStyle(.plain)
            } else {
                shape
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }

    private var shape: some View {
        Image(systemName: icon)
            .font(.system(size: side * 0.42, weight: .semibold))
            .foregroundStyle(active ? Color.white : tint ?? Color.secondary)
            .frame(width: side, height: side)
            .surface(fill, cornerRadius: side * 0.27, border: active ? .clear : Theme.border)
            .contentShape(RoundedRectangle(cornerRadius: side * 0.27))
    }

    private var fill: Color {
        if active { return hovering ? Theme.accentFill.opacity(0.86) : Theme.accentFill }
        return hovering ? Theme.field : .clear
    }
}

// The dropdown: a pill showing the value in force, with the choices opening under it as
// the app's own menu. It takes the width its caption or row gives it, and the menu takes
// the same width by default so it reads as the pill unfolding.
struct OptionMenu: View {
    var caption: String? = nil
    let value: String
    var matchWidth = true
    let entries: () -> [MenuEntry]

    init(caption: String? = nil, value: String, matchWidth: Bool = true,
         entries: @escaping () -> [MenuEntry]) {
        self.caption = caption
        self.value = value
        self.matchWidth = matchWidth
        self.entries = entries
    }

    // The one-of-a-set form: each option says whether it is the one in force.
    init(caption: String? = nil, value: String,
         options: [(label: String, checked: Bool, choose: () -> Void)]) {
        self.init(caption: caption, value: value) {
            options.map { option in
                .item(option.label, checked: option.checked, action: option.choose)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caption {
                SectionLabel(caption, style: .field)
            }
            OptionMenuPill(value: value)
                .appMenu(matchWidth: matchWidth, entries)
        }
    }
}

// The pill itself, kept apart from the control around it so it can read whether its own
// menu is open: that state is set on the label by the menu button, which is a layer
// below where OptionMenu's body is built.
private struct OptionMenuPill: View {
    let value: String

    @Environment(\.menuIsOpen) private var open
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(value)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            MenuChevron()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .surface(open || hovering ? Theme.field : Theme.card, cornerRadius: 9,
                 border: open ? Theme.accent.opacity(0.5) : Theme.border)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .motion(Motion.reveal, value: open)
    }
}
