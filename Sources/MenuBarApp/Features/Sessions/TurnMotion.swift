import SwiftUI
import CodeStationCore

// The two moments of a turn: the click that starts it and the moment it ends. People
// start a turn and look elsewhere, so the end is told in two places. The sidebar rail
// speaks for sessions that are not open: the session's dot takes the work, circles while
// the agent runs, and closes into a tick or a warning. The open session speaks in its
// composer and transcript: the prompt lifts into the conversation, Send turns into Stop,
// and a seal says what the turn took.
//
// Every effect plays only when the change happens in front of a view that is already
// drawn. A row scrolled out of the rail, or a session opened later, is built straight
// into its resting look.
enum TurnMotion {
    // When the finish sound plays, counted from the end of the turn. It is the moment the
    // tick starts to draw on the rail, so the sound and the sight land together.
    static let soundBeat: Duration = .milliseconds(420)

    // Slow on purpose. Ten running sessions are ten orbits, and a column of them must not
    // shimmer. No loop here turns faster than once every 1.2 seconds.
    static let orbitPeriod: TimeInterval = 1.4
    static let arcPeriod: TimeInterval = 2.8

    static let fill = Animation.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.24)
    static let flight = Animation.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.52)
    static let swap = Animation.timingCurve(0.3, 0.7, 0.4, 1, duration: 0.26)

    // How far up the rail the bead starts and the pulse climbs: about one card.
    static let dropHeight: CGFloat = 34
    static let climbHeight: CGFloat = 56

    // The share of the ring the arc covers. It swells and shrinks once an arc period, so
    // the orbit reads as something working rather than a spinner. Under Reduce Motion it
    // stands still at its resting length.
    static let arcShortest: CGFloat = 0.22
    static let arcLongest: CGFloat = 0.48
    static let arcResting: CGFloat = 0.3

    // An effect that can play again is driven by a counter: each run adds one, and the
    // effect reads only the part of the current run covered so far. A fresh run then
    // starts from where the last one rested, with no reset that SwiftUI would fold into
    // the same update and never draw.
    static func stage(_ progress: CGFloat) -> CGFloat {
        progress - progress.rounded(.down)
    }

    // A shake that dies away: left, right, and settling where it began.
    static func shake(_ progress: CGFloat) -> CGFloat {
        let stops: [CGFloat] = [0, -4, 4, -3, 2, 0]
        guard progress > 0, progress < 1 else { return 0 }
        let position = progress * CGFloat(stops.count - 1)
        let index = Int(position)
        let within = position - CGFloat(index)
        return stops[index] + (stops[index + 1] - stops[index]) * within
    }

    // Where a dropped bead is, as a share of the drop, at a point in its run. It appears
    // at the top for the first beat, then falls with an ease-in so it reads as weight.
    static func fall(_ progress: CGFloat) -> CGFloat {
        let appear = 0.1 / 0.52
        guard progress > appear else { return 0 }
        let falling = min(1, (progress - appear) / (1 - appear))
        return UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.55, y: 0),
                                endControlPoint: UnitPoint(x: 0.85, y: 0.35))
            .value(at: falling)
    }
}

// Hands its content the in-between values of an animated progress. Plain modifiers only
// see the end value and tween their own output, which cannot express an effect that
// rises and falls within one run.
nonisolated struct Tweened<Content: View>: View, Animatable {
    var progress: CGFloat
    @ViewBuilder let content: (CGFloat) -> Content

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View { content(progress) }
}

@MainActor
private func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(seconds))
        work()
    }
}

// MARK: - Thread

// Where a session's turn stands, as its dot on the rail shows it. Failure outranks an
// unread finish, since a failed turn is also left unread.
enum ThreadPhase: Equatable {
    case idle
    case running
    case finished
    case failed

    init(busy: Bool, failed: Bool, finished: Bool) {
        if busy {
            self = .running
        } else if failed {
            self = .failed
        } else if finished {
            self = .finished
        } else {
            self = .idle
        }
    }
}

// What the node shows once any motion has settled.
struct ThreadLook: Equatable {
    // How much of the dot wears the project's full colour rather than the resting tint.
    var lit: Double = 0
    var core: CGFloat = 1
    // The orbit's track and arc.
    var ring: Double = 0
    // How far the arc has closed into a whole ring.
    var closed: CGFloat = 0
    var tick: CGFloat = 0
    var bang: CGFloat = 0
    // How much of the dot wears the error colour.
    var alarm: Double = 0

    static func resting(_ phase: ThreadPhase) -> ThreadLook {
        switch phase {
        case .idle: ThreadLook()
        case .running: ThreadLook(lit: 1, core: 1.1, ring: 1)
        case .finished: ThreadLook(lit: 1, core: 2.05, closed: 1, tick: 1)
        case .failed: ThreadLook(lit: 1, core: 2.05, bang: 1, alarm: 1)
        }
    }
}

// The session's dot on the rail. A bead drops down the rail into it when a turn starts,
// an arc orbits it while the agent works, and it fills with a tick when the turn is done
// or turns red with a mark when it failed. A finished turn the user has already seen
// plays the same close and then goes back to the plain dot.
struct ThreadNode: View {
    let phase: ThreadPhase
    // Whether the last turn ended on its own, as opposed to being stopped. Only read when
    // a run ends while the session is open, which is the one case the phase cannot tell.
    let endedCleanly: Bool
    let colour: Color
    let restingFill: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var look: ThreadLook
    @State private var spinning: Bool
    @State private var shown: ThreadPhase
    @State private var drop: CGFloat = 0
    @State private var bloom: CGFloat = 0
    @State private var pulse: CGFloat = 0

    init(phase: ThreadPhase, endedCleanly: Bool, colour: Color, restingFill: Color) {
        self.phase = phase
        self.endedCleanly = endedCleanly
        self.colour = colour
        self.restingFill = restingFill
        _look = State(initialValue: .resting(phase))
        _spinning = State(initialValue: phase == .running)
        _shown = State(initialValue: phase)
    }

    var body: some View {
        ZStack {
            Tweened(progress: bloom) { progress in
                let stage = TurnMotion.stage(progress)
                Circle()
                    .fill(colour)
                    .frame(width: 8, height: 8)
                    .scaleEffect(1 + 2.6 * stage)
                    .opacity(stage > 0 ? 0.5 * (1 - stage) : 0)
            }

            if spinning { orbit }

            Tweened(progress: bloom) { progress in
                let stage = TurnMotion.stage(progress)
                // The dot swells as the bead lands in it, then settles a little larger
                // than at rest. Over by the time the bloom around it has faded.
                let pop = stage > 0 ? 0.6 * sin(.pi * min(1, stage * 1.47)) : 0
                Circle()
                    .fill(restingFill)
                    .overlay(Circle().fill(colour).opacity(look.lit))
                    .overlay(Circle().fill(Theme.deletion).opacity(look.alarm))
                    .frame(width: 8, height: 8)
                    .scaleEffect(look.core * (1 + pop))
            }

            ThreadMark.tick
                .trim(from: 0, to: look.tick)
                .stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round,
                                                   lineJoin: .round))
            ThreadMark.bang
                .trim(from: 0, to: look.bang)
                .stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            Tweened(progress: drop) { progress in
                ThreadBead(colour: colour, progress: TurnMotion.stage(progress))
            }
            Tweened(progress: pulse) { progress in
                ThreadPulse(colour: colour, progress: TurnMotion.stage(progress))
            }
        }
        .frame(width: 20, height: 20)
        .allowsHitTesting(false)
        .onChange(of: phase) { old, new in play(from: old, to: new) }
    }

    private var orbit: some View {
        ZStack {
            Circle()
                .stroke(colour.opacity(0.22), lineWidth: 1.6)
            OrbitArc(colour: colour, moving: !reduceMotion, closed: look.closed > 0)
        }
        .frame(width: 14, height: 14)
        .opacity(look.ring)
    }

    private func play(from old: ThreadPhase, to new: ThreadPhase) {
        shown = new
        // Reduce Motion keeps the meaning and drops the movement: the node takes its new
        // look at once, and the orbit stands still.
        guard !reduceMotion else {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                look = .resting(new)
                spinning = new == .running
            }
            return
        }
        switch (old, new) {
        case (_, .running):
            start()
        case (.running, .finished):
            finish(settling: false)
        case (.running, .idle) where endedCleanly:
            finish(settling: true)
        case (.running, .failed):
            fail()
        default:
            withAnimation(.easeOut(duration: 0.25)) { look = .resting(new) }
            spinning = new == .running
        }
    }

    // The bead falls for 520 ms, the dot blooms as it lands, and the orbit fades in
    // behind the bloom.
    private func start() {
        spinning = true
        withAnimation(.linear(duration: 0.52)) { drop += 1 }
        withAnimation(.linear(duration: 0.56).delay(0.52)) { bloom += 1 }
        withAnimation(.easeOut(duration: 0.15).delay(0.52)) {
            look.lit = 1
            look.core = 1.1
            look.tick = 0
            look.bang = 0
            look.alarm = 0
            look.closed = 0
        }
        withAnimation(.easeOut(duration: 0.26).delay(0.64)) { look.ring = 1 }
    }

    // The arc closes the ring, the dot fills, and the tick draws on the sound's beat.
    // Then a pulse climbs the rail to the project.
    private func finish(settling: Bool) {
        withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.36)) { look.closed = 1 }
        withAnimation(TurnMotion.fill.delay(0.32)) { look.core = 2.05 }
        withAnimation(.timingCurve(0.3, 0.7, 0.4, 1, duration: 0.26).delay(0.42)) {
            look.tick = 1
        }
        withAnimation(.linear(duration: 0.12).delay(0.56)) { look.ring = 0 }
        withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.38).delay(0.52)) {
            pulse += 1
        }
        after(0.7) {
            guard shown != .running else { return }
            spinning = false
        }
        // A finish the user watched has nothing left to come back for, so once it has
        // been seen through, the dot returns to rest.
        if settling {
            after(1.6) {
                guard shown == .idle else { return }
                withAnimation(.easeOut(duration: 0.3)) { look = .resting(.idle) }
            }
        }
    }

    private func fail() {
        withAnimation(.linear(duration: 0.2)) { look.ring = 0 }
        withAnimation(TurnMotion.fill) {
            look.core = 2.05
            look.alarm = 1
        }
        withAnimation(.easeOut(duration: 0.2).delay(0.16)) { look.bang = 1 }
        after(0.25) {
            guard shown != .running else { return }
            spinning = false
        }
    }
}

// The arc that circles a running dot, played by Core Animation: it turns once every orbit
// period and swells and shrinks once every arc period. Closing sweeps it round into a
// whole ring.
private struct OrbitArc: NSViewRepresentable {
    let colour: Color
    let moving: Bool
    let closed: Bool

    func makeNSView(context: Context) -> OrbitArcView { OrbitArcView() }

    func updateNSView(_ view: OrbitArcView, context: Context) {
        view.update(colour: colour.resolve(in: context.environment).cgColor,
                    moving: moving, closed: closed)
    }
}

final class OrbitArcView: LoopLayerView {
    private let turner = CALayer()
    private let arc = CAShapeLayer()
    private(set) var moving = false
    private(set) var closed = false

    // The arc starts at the top of the ring rather than on its right.
    private static let top = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        arc.fillColor = nil
        arc.lineWidth = 1.7
        arc.lineCap = .round
        arc.strokeEnd = TurnMotion.arcResting
        turner.transform = Self.top
        turner.addSublayer(arc)
        layer?.addSublayer(turner)
    }

    var arcEnd: CGFloat { arc.strokeEnd }
    var loops: [String] { (arc.animationKeys() ?? []) + (turner.animationKeys() ?? []) }

    func update(colour: CGColor, moving: Bool, closed: Bool) {
        LayerLoop.still { arc.strokeColor = colour }
        guard moving != self.moving || closed != self.closed else { return }
        let closing = closed && !self.closed
        self.moving = moving
        self.closed = closed
        if closing && moving {
            close()
        } else {
            restartLoops()
        }
    }

    override func layoutLayers() {
        turner.bounds = bounds
        turner.position = CGPoint(x: bounds.midX, y: bounds.midY)
        arc.frame = bounds
        arc.path = CGPath(ellipseIn: bounds, transform: nil)
    }

    override func restartLoops() {
        LayerLoop.still {
            arc.strokeEnd = closed ? 1 : TurnMotion.arcResting
        }
        arc.removeAnimation(forKey: "swell")
        arc.removeAnimation(forKey: "close")
        turner.removeAnimation(forKey: "turn")
        guard moving else { return }

        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = -CGFloat.pi / 2
        turn.toValue = CGFloat.pi * 3 / 2
        turn.duration = TurnMotion.orbitPeriod
        turner.add(LayerLoop.repeating(turn, period: TurnMotion.orbitPeriod), forKey: "turn")

        guard !closed else { return }
        let swell = LayerLoop.swing("strokeEnd", from: TurnMotion.arcShortest,
                                    to: TurnMotion.arcLongest, period: TurnMotion.arcPeriod)
        arc.add(LayerLoop.repeating(swell, period: TurnMotion.arcPeriod), forKey: "swell")
    }

    // Sweeps from wherever the swell has got to, so the arc never jumps before it closes.
    private func close() {
        let from = arc.presentation()?.strokeEnd ?? arc.strokeEnd
        arc.removeAnimation(forKey: "swell")
        LayerLoop.still { arc.strokeEnd = 1 }
        let sweep = CABasicAnimation(keyPath: "strokeEnd")
        sweep.fromValue = from
        sweep.toValue = 1
        sweep.duration = 0.36
        sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
        arc.add(sweep, forKey: "close")
    }
}

// The marks drawn inside the full dot, on the node's 20 point square.
private enum ThreadMark {
    static var tick: Path {
        var path = Path()
        path.move(to: CGPoint(x: 6.9, y: 10.2))
        path.addLine(to: CGPoint(x: 9, y: 12.3))
        path.addLine(to: CGPoint(x: 13.2, y: 7.8))
        return path
    }

    static var bang: Path {
        var path = Path()
        path.move(to: CGPoint(x: 10, y: 6.4))
        path.addLine(to: CGPoint(x: 10, y: 10.4))
        path.move(to: CGPoint(x: 10, y: 13.3))
        path.addLine(to: CGPoint(x: 10, y: 13.4))
        return path
    }
}

// Drawn only while it is moving. A scale of zero is a transform with no inverse, which
// AppKit turns into a frame it cannot place, so nothing here is ever scaled to nothing.
private struct ThreadBead: View {
    let colour: Color
    let progress: CGFloat

    var body: some View {
        if progress > 0, progress < 1 { bead }
    }

    @ViewBuilder private var bead: some View {
        let fall = TurnMotion.fall(progress)
        let appear = max(0.01, min(1, progress / 0.23))
        // Stretched as it falls, squashed as it lands.
        let squash: CGSize = fall < 0.86
            ? CGSize(width: 1 - 0.15 * fall / 0.86, height: 1 + 0.3 * fall / 0.86)
            : CGSize(width: 0.85 - 0.35 * (fall - 0.86) / 0.14,
                     height: 1.3 - 0.8 * (fall - 0.86) / 0.14)
        let tail = fall < 0.85 ? 1.2 * fall / 0.85 : 1.2 * (1 - fall) / 0.15
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [colour.opacity(0), colour],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 3, height: 30)
                .scaleEffect(x: 1, y: max(0.01, tail), anchor: .bottom)
                .offset(y: -15)
            Circle()
                .fill(colour.opacity(0.22))
                .frame(width: 15, height: 15)
            Circle()
                .fill(colour)
                .frame(width: 9, height: 9)
        }
        .scaleEffect(x: appear * squash.width, y: appear * squash.height)
        .offset(y: -TurnMotion.dropHeight * (1 - fall))
    }
}

private struct ThreadPulse: View {
    let colour: Color
    let progress: CGFloat

    var body: some View {
        if progress > 0, progress < 1 { pulse }
    }

    private var pulse: some View {
        let opacity: Double = switch progress {
        case ..<0.15: progress / 0.15
        case ..<0.75: 1
        default: (1 - progress) / 0.25
        }
        return Capsule()
            .fill(LinearGradient(colors: [colour, colour.opacity(0)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 2, height: 34)
            .shadow(color: colour, radius: 3)
            .offset(y: -17 - TurnMotion.climbHeight * progress)
            .opacity(opacity)
    }
}

// What the card beside the node does as a turn ends: a clean finish washes it green for
// a moment, a failure shakes it once.
struct ThreadRowEffects: ViewModifier {
    let phase: ThreadPhase
    let endedCleanly: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wash: CGFloat = 0
    @State private var shake: CGFloat = 0

    func body(content: Content) -> some View {
        Tweened(progress: shake) { progress in
            content
                .overlay {
                    Tweened(progress: wash) { progress in
                        let stage = TurnMotion.stage(progress)
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Theme.dotOn.opacity(0.16))
                            .opacity(stage < 0.14 ? stage / 0.14 : 1 - (stage - 0.14) / 0.86)
                            .opacity(stage > 0 ? 1 : 0)
                    }
                    .allowsHitTesting(false)
                }
                .offset(x: TurnMotion.shake(TurnMotion.stage(progress)))
        }
        .onChange(of: phase) { old, new in
            guard !reduceMotion, old == .running else { return }
            switch new {
            case .finished:
                withAnimation(.easeOut(duration: 1).delay(0.3)) { wash += 1 }
            case .idle where endedCleanly:
                withAnimation(.easeOut(duration: 1).delay(0.3)) { wash += 1 }
            case .failed:
                withAnimation(.easeOut(duration: 0.42)) { shake += 1 }
            default:
                break
            }
        }
    }
}

// The project's tile nods when one of its sessions stops running, as the pulse climbing
// the rail reaches it.
private struct ThreadNod: ViewModifier {
    let running: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nod: CGFloat = 0

    func body(content: Content) -> some View {
        Tweened(progress: nod) { progress in
            content.scaleEffect(1 + 0.16 * abs(sin(.pi * progress)))
        }
        .onChange(of: running) { old, new in
            guard new < old, !reduceMotion else { return }
            withAnimation(.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.26).delay(0.86)) {
                nod += 1
            }
        }
    }
}

extension View {
    func threadNod(running: Int) -> some View {
        modifier(ThreadNod(running: running))
    }
}

// MARK: - Hand-off

// Send and Stop trade places by turning: the leaving glyph spins away as it shrinks, and
// the arriving one turns in and overshoots a little.
extension AnyTransition {
    static var buttonSwap: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: SwapTurn(scale: 0.2, degrees: -45, opacity: 0),
                                 identity: SwapTurn(scale: 1, degrees: 0, opacity: 1)),
            removal: .modifier(active: SwapTurn(scale: 0.3, degrees: 90, opacity: 0),
                               identity: SwapTurn(scale: 1, degrees: 0, opacity: 1)))
    }
}

private struct SwapTurn: ViewModifier {
    let scale: CGFloat
    let degrees: Double
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(degrees))
            .scaleEffect(scale)
            .opacity(opacity)
    }
}

// The prompt just sent lifts out of the composer below and settles into its bubble, which
// rings once as it lands. Only the prompt sent from this view plays it; a transcript read
// back draws its bubbles where they are.
struct PromptArrival<Outline: Shape>: ViewModifier {
    let active: Bool
    let ringColour: Color
    let outline: Outline

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flight: CGFloat
    @State private var ring: CGFloat = 0

    init(active: Bool, ringColour: Color, outline: Outline) {
        self.active = active
        self.ringColour = ringColour
        self.outline = outline
        _flight = State(initialValue: active ? 0 : 1)
    }

    func body(content: Content) -> some View {
        Tweened(progress: flight) { progress in
            let moves = !reduceMotion
            content
                .background {
                    Tweened(progress: ring) { ring in
                        outline
                            .fill(ringColour)
                            .padding(-5 * (1 - ring))
                            .opacity(ring > 0 && ring < 1 ? 1 - ring : 0)
                    }
                }
                .scaleEffect(moves ? 0.94 + 0.06 * progress : 1, anchor: .bottomTrailing)
                .offset(y: moves ? 56 * (1 - progress) : 0)
                .opacity(min(1, progress * 2.5))
        }
        .onAppear {
            guard flight < 1 else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : TurnMotion.flight) {
                flight = 1
            }
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.5).delay(0.52)) { ring = 1 }
        }
    }
}

extension ChatMessage {
    // Whether this is the prompt a composer has just sent. A bubble drawn again later, or
    // one queued earlier and sent by the runner, is already where it belongs.
    func isArriving(sentAt: Date?, now: Date = Date()) -> Bool {
        guard role == .user, let sentAt else { return false }
        return date >= sentAt.addingTimeInterval(-0.5) && now.timeIntervalSince(sentAt) < 1.5
    }
}

// What the last turn changed, read off its calls: the lines each edit or measured
// command added and removed, and how many files that touched.
struct TurnReceipt: Equatable {
    var added = 0
    var removed = 0
    var files = 0

    var hasChanges: Bool { files > 0 || added > 0 || removed > 0 }

    init(added: Int = 0, removed: Int = 0, files: Int = 0) {
        self.added = added
        self.removed = removed
        self.files = files
    }

    // The messages after the last prompt are the turn. Nil when nothing has been asked.
    init?(lastTurnIn messages: [ChatMessage], projectPath: String) {
        guard let prompt = messages.lastIndex(where: { $0.role == .user }) else { return nil }
        var paths: Set<String> = []
        var unnamed = 0
        for message in messages[(prompt + 1)...] where message.role == .assistant {
            for tool in message.tools {
                let presentation = ToolPresentationCache.presentation(for: tool,
                                                                      projectPath: projectPath)
                added += presentation.added ?? 0
                removed += presentation.removed ?? 0
                guard presentation.changedFiles > 0 else { continue }
                // An edit names its file, which is what lets two edits to the same file
                // count once. A command's change names the files git saw it touch.
                if ToolUse.editTools.contains(tool.name), let path = presentation.filePath {
                    paths.insert(path)
                } else if !presentation.changes.isEmpty {
                    paths.formUnion(presentation.changes.map(\.name))
                } else {
                    unnamed += presentation.changedFiles
                }
            }
        }
        files = paths.count + unnamed
    }

    // A turn's length on a clock: 0:07, 12:40, 1:02:05.
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.down))
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let rest = whole % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    static func headline(_ ending: TurnEnding) -> String {
        switch ending.outcome {
        case .finished: "Finished in \(clock(ending.duration))"
        case .stopped, .failed: "Stopped after \(clock(ending.duration))"
        }
    }

    var filePhrase: String { files == 1 ? "1 file" : "\(files) files" }

    func summary(_ ending: TurnEnding) -> String {
        let headline = Self.headline(ending)
        guard hasChanges else { return headline }
        return "\(headline) · +\(added) \u{2212}\(removed) · \(filePhrase)"
    }

    func spokenSummary(_ ending: TurnEnding) -> String {
        let length = Duration.seconds(ending.duration.rounded(.down))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
        let headline = ending.outcome == .finished ? "Finished in \(length)" : "Stopped after \(length)"
        guard hasChanges else { return headline }
        return "\(headline). \(added) lines added, \(removed) removed, in \(filePhrase)."
    }
}
