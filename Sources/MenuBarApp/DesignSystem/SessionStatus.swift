import AppKit
import SwiftUI
import CodeStationCore

// MARK: - State

// The colour the GUI draws each session tone in. The tone itself, and its word, live in
// the core, so every front end agrees on what a session is doing.
extension SessionTone {
    // Waiting shares the live colour with running and is told apart by its light, which
    // does not breathe. Colour says the session is alive; the pulse says it is moving.
    var colour: Color {
        switch self {
        case .running, .waiting: Theme.dotOn
        case .needsYou: Theme.attention
        case .idle: Color.secondary
        }
    }

    // The same colour read as words, or as a thin mark that stands in for them. The light
    // colours sink into a pale card, so these are the ones measured as ink.
    var wordColour: Color {
        switch self {
        case .running, .waiting: Theme.dotOnText
        case .needsYou: Theme.attentionText
        // The system's secondary grey falls short of text contrast on the pale card at
        // the small sizes a state word is set in, so idle is a step darker.
        case .idle: Color(nsColor: .labelColor).opacity(0.72)
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
    // A failed turn shares its tone with anything else that needs the user, and is told
    // apart by wearing the error colour instead.
    var colour: Color?

    var body: some View {
        Circle()
            .fill(colour ?? tone.colour)
            .frame(width: size, height: size)
    }
}

// The state line of a sidebar card, laid as a band across the top of the card so the
// state can be found down a long rail without reading the word. Needs you is striped and
// still, running is striped and drifts, waiting is a plain band. Idle has none, which is
// what makes the other three stand out. The light and the word stay on the band, so the
// state is never carried by colour or pattern alone.
struct StateBand: Equatable {
    let fill: Color
    let stripe: Color?
    let drifts: Bool
    let word: Color
}

extension SessionTone {
    var band: StateBand? {
        switch self {
        case .needsYou:
            StateBand(fill: Theme.attention.opacity(0.14), stripe: Theme.attention.opacity(0.3),
                      drifts: false, word: Theme.attentionText)
        case .running:
            StateBand(fill: Theme.dotOn.opacity(0.1), stripe: Theme.dotOn.opacity(0.16),
                      drifts: true, word: Theme.dotOnText)
        case .waiting:
            StateBand(fill: Theme.dotOn.opacity(0.09), stripe: nil, drifts: false,
                      word: Theme.dotOnText)
        case .idle:
            nil
        }
    }
}

enum Stripes {
    static let period: CGFloat = 14
    // The time the pattern takes to move one whole stripe along. It then starts over,
    // which looks the same since the pattern repeats once a period.
    static let driftPeriod: TimeInterval = 1.4

    // Starts far enough to the left that the first stripe still covers the corner when
    // the pattern has moved `lead` along.
    static func path(in size: CGSize, period: CGFloat = period, lead: CGFloat = 0) -> Path {
        var path = Path()
        let rise = size.height
        var x = -(rise / period).rounded(.up) * period - period - lead
        while x < size.width {
            path.move(to: CGPoint(x: x, y: rise))
            path.addLine(to: CGPoint(x: x + period / 2, y: rise))
            path.addLine(to: CGPoint(x: x + period / 2 + rise, y: 0))
            path.addLine(to: CGPoint(x: x + rise, y: 0))
            path.closeSubpath()
            x += period
        }
        return path
    }
}

// Diagonal stripes, rising to the right, half of each period painted. One drawing serves
// the card band and the count chip so the two read as the same mark.
//
// The drift stops under Reduce Motion. Standing still, the stripes still say the same
// thing.
struct StripeFill: View {
    let colour: Color
    var period: CGFloat = Stripes.period
    var drifts = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if drifts && !reduceMotion {
                DriftingStripes(colour: colour, period: period)
            } else {
                Canvas { canvas, size in
                    canvas.fill(Stripes.path(in: size, period: period), with: .color(colour))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct DriftingStripes: NSViewRepresentable {
    let colour: Color
    let period: CGFloat

    func makeNSView(context: Context) -> DriftingStripesView { DriftingStripesView() }

    func updateNSView(_ view: DriftingStripesView, context: Context) {
        view.update(colour: colour.resolve(in: context.environment).cgColor, period: period)
    }
}

final class DriftingStripesView: LoopLayerView {
    private let stripes = CAShapeLayer()
    private var period: CGFloat = Stripes.period

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = true
        layer?.addSublayer(stripes)
    }

    func update(colour: CGColor, period: CGFloat) {
        LayerLoop.still { stripes.fillColor = colour }
        guard period != self.period else { return }
        self.period = period
        LayerLoop.still { layoutLayers() }
        restartLoops()
    }

    // The path carries one stripe more on the left than the view needs, so sliding it a
    // whole stripe to the right never shows a gap.
    override func layoutLayers() {
        stripes.frame = bounds
        stripes.path = Stripes.path(in: bounds.size, period: period, lead: period).cgPath
    }

    override func restartLoops() {
        let drift = CABasicAnimation(keyPath: "transform.translation.x")
        drift.fromValue = 0
        drift.toValue = period
        drift.duration = Stripes.driftPeriod
        stripes.add(LayerLoop.repeating(drift, period: Stripes.driftPeriod), forKey: "drift")
    }
}

// How many sessions under a folded row want the user. Once the row is open the cards say
// it themselves, so the row drops it.
struct NeedsYouChip: View {
    let count: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        Text(verbatim: "\(count)")
            .font(.mono(9.5, .bold))
            .foregroundStyle(Theme.attentionText)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 16)
            .background {
                ZStack {
                    shape.fill(Theme.attention.opacity(0.16))
                    StripeFill(colour: Theme.attention.opacity(0.34), period: 8)
                        .clipShape(shape)
                }
            }
            .overlay(shape.strokeBorder(Theme.attention.opacity(0.5), lineWidth: 1))
            .fixedSize()
            .appTooltip(Self.label(count))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.label(count))
    }

    static func label(_ count: Int) -> String { "\(count) waiting for you" }
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

// The slow swing of everything that breathes while it works. Each loop of this length
// reads the same media clock, so everything breathing at once shares a phase.
enum Breath {
    static let period: TimeInterval = 1.6
}

// Content that fades a little and comes back once per period while it is active. Held at
// rest under Reduce Motion, which is the setting that exists to stop exactly this.
//
// Core Animation can only move what sits in a layer it owns, so the fade plays on a copy
// of the content laid over the original. The original stays in place underneath, hidden,
// so content that is expensive to build - artwork that has to be fetched and drawn - is
// not made again each time its session picks work up or puts it down, and the row
// around it never shifts.
struct Breathing<Content: View>: View {
    var active = true
    var period: TimeInterval = Breath.period
    // How far the content fades at the bottom of each breath.
    var depth: Double = 0.45
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var moving: Bool { active && !reduceMotion }

    var body: some View {
        content
            .opacity(moving ? 0 : 1)
            .overlay {
                if moving {
                    BreathingCopy(content: content, period: period, depth: depth)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

private struct BreathingCopy<Content: View>: NSViewRepresentable {
    let content: Content
    let period: TimeInterval
    let depth: Double

    func makeNSView(context: Context) -> BreathingCopyView { BreathingCopyView() }

    // The copy lives in a hosting view of its own, which starts from a blank environment,
    // so it is handed the one the original is drawn with.
    func updateNSView(_ view: BreathingCopyView, context: Context) {
        view.show(AnyView(content.environment(\.self, context.environment)),
                  period: period, depth: depth)
    }
}

final class BreathingCopyView: LoopLayerView {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var period = Breath.period
    private var depth = 0.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        host.sizingOptions = []
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    func show(_ content: AnyView, period: TimeInterval, depth: Double) {
        host.rootView = content
        guard period != self.period || depth != self.depth else { return }
        self.period = period
        self.depth = depth
        restartLoops()
    }

    override func restartLoops() {
        guard let layer, depth > 0 else { return }
        let fade = LayerLoop.swing("opacity", from: 1, to: 1 - depth, period: period)
        layer.add(LayerLoop.repeating(fade, period: period), forKey: "breath")
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
                BreathingCircle(colour: colour,
                                restingScale: 0.45, fullScale: 1,
                                restingOpacity: 0.5, fullOpacity: 0)
                    .frame(width: size * 2.2, height: size * 2.2)
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
