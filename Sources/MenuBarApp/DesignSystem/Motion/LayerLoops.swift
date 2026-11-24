import AppKit
import QuartzCore
import SwiftUI

// Loops that run for as long as something is working are played by Core Animation, not
// by a SwiftUI clock. A clock asks for a new frame on every screen refresh, and SwiftUI
// lays the whole window out again for each one, so a dot the size of a letter could keep
// a whole core busy. A layer animation runs in the render server and costs the app
// nothing between frames.
//
// Every loop reads its phase off the media clock, so loops of the same length move in
// step wherever they are on screen, and a view that is built again picks up the beat
// instead of starting over.
enum LayerLoop {
    // The ease of a sine wave, so each end of a swing turns as softly as a cosine would.
    static var swingCurve: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.37, 0, 0.63, 1)
    }

    static func repeating<A: CAAnimation>(_ animation: A, period: CFTimeInterval) -> A {
        animation.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: period)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    // A swing from one value to another and back, once per period.
    static func swing(_ keyPath: String, from: Any, to: Any,
                      period: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = period / 2
        animation.autoreverses = true
        animation.timingFunction = swingCurve
        return animation
    }

    // Changes a layer without the fade Core Animation adds to a property change.
    static func still(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}

// A layer-backed view for a loop to play in. It never takes the pointer, so the SwiftUI
// control under it still gets every click and hover.
class LoopLayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        LayerLoop.still { layoutLayers() }
    }

    override func layout() {
        super.layout()
        LayerLoop.still { layoutLayers() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    // A layer can lose its animations while it is out of a window, so they are added
    // again each time the view comes back. The media clock keeps them on the beat.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        LayerLoop.still { syncScale() }
        syncPause()
        restartLoops()
    }

    // The render server keeps drawing a loop in a window nobody can see, which costs the
    // whole machine for nothing. A layer at speed zero holds still and is not redrawn.
    // Its loops are added again when it shows, so they rejoin the beat of the media clock.
    @objc private func occlusionChanged() {
        let wasPaused = isPaused
        syncPause()
        if wasPaused && !isPaused { restartLoops() }
    }

    var isPaused: Bool { layer?.speed == 0 }

    private func syncPause() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        LayerLoop.still { layer?.speed = visible ? 1 : 0 }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        LayerLoop.still { syncScale() }
    }

    // Places the sublayers in the view's bounds.
    func layoutLayers() {}

    // Adds or removes the loop animations to match what the view should show now.
    func restartLoops() {}

    private func syncScale() {
        let scale = window?.backingScaleFactor ?? 2
        layer?.sublayers?.forEach { setScale(scale, on: $0) }
    }

    private func setScale(_ scale: CGFloat, on layer: CALayer) {
        layer.contentsScale = scale
        layer.sublayers?.forEach { setScale(scale, on: $0) }
    }
}

// A circle that breathes: it swings once per period between its resting look and its
// full one. With `active` off, or under Reduce Motion, it holds its resting look.
struct BreathingCircle: View {
    let colour: Color
    var active = true
    var period: TimeInterval = Breath.period
    var restingScale: CGFloat = 1
    var fullScale: CGFloat = 1
    var restingOpacity: Double = 1
    var fullOpacity: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BreathingCircleLayer(colour: colour, moving: active && !reduceMotion, period: period,
                             scale: (restingScale, fullScale),
                             opacity: (Float(restingOpacity), Float(fullOpacity)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct BreathingCircleLayer: NSViewRepresentable {
    let colour: Color
    let moving: Bool
    let period: TimeInterval
    let scale: (resting: CGFloat, full: CGFloat)
    let opacity: (resting: Float, full: Float)

    func makeNSView(context: Context) -> BreathingCircleView { BreathingCircleView() }

    func updateNSView(_ view: BreathingCircleView, context: Context) {
        view.update(colour: colour.resolve(in: context.environment).cgColor,
                    look: .init(moving: moving, period: period,
                                scale: [scale.resting, scale.full],
                                opacity: [opacity.resting, opacity.full]))
    }
}

final class BreathingCircleView: LoopLayerView {
    struct Look: Equatable {
        var moving = false
        var period: TimeInterval = Breath.period
        var scale: [CGFloat] = [1, 1]
        var opacity: [Float] = [1, 1]
    }

    private let circle = CAShapeLayer()
    private var look = Look()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(circle)
    }

    var loops: [String] { circle.animationKeys() ?? [] }
    var restingOpacity: Float { circle.opacity }

    func update(colour: CGColor, look: Look) {
        LayerLoop.still {
            circle.fillColor = colour
            circle.setAffineTransform(CGAffineTransform(scaleX: look.scale[0], y: look.scale[0]))
            circle.opacity = look.opacity[0]
        }
        guard look != self.look else { return }
        self.look = look
        restartLoops()
    }

    override func layoutLayers() {
        circle.bounds = bounds
        circle.position = CGPoint(x: bounds.midX, y: bounds.midY)
        circle.path = CGPath(ellipseIn: bounds, transform: nil)
    }

    override func restartLoops() {
        circle.removeAnimation(forKey: "breath")
        guard look.moving else { return }
        let group = CAAnimationGroup()
        group.animations = [
            LayerLoop.swing("transform.scale", from: look.scale[0], to: look.scale[1],
                            period: look.period),
            LayerLoop.swing("opacity", from: look.opacity[0], to: look.opacity[1],
                            period: look.period),
        ]
        group.duration = look.period
        circle.add(LayerLoop.repeating(group, period: look.period), forKey: "breath")
    }
}

// A small arc turning while docker or git is at work on something. Under Reduce Motion it
// holds still as a three-quarter ring, which still reads as "busy".
struct LoopSpinner: View {
    var colour: Color = Theme.secondaryText
    var size: CGFloat = 11

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LoopSpinnerLayer(colour: colour, moving: !reduceMotion)
            .frame(width: size, height: size)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct LoopSpinnerLayer: NSViewRepresentable {
    let colour: Color
    let moving: Bool

    func makeNSView(context: Context) -> LoopSpinnerView { LoopSpinnerView() }

    func updateNSView(_ view: LoopSpinnerView, context: Context) {
        view.update(colour: colour.resolve(in: context.environment).cgColor, moving: moving)
    }
}

final class LoopSpinnerView: LoopLayerView {
    static let period: CFTimeInterval = 0.8

    private let turner = CALayer()
    private let arc = CAShapeLayer()
    private(set) var moving = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        arc.fillColor = nil
        arc.lineWidth = 1.6
        arc.lineCap = .round
        arc.strokeEnd = 0.75
        turner.addSublayer(arc)
        layer?.addSublayer(turner)
    }

    var loops: [String] { turner.animationKeys() ?? [] }

    func update(colour: CGColor, moving: Bool) {
        LayerLoop.still { arc.strokeColor = colour }
        guard moving != self.moving else { return }
        self.moving = moving
        restartLoops()
    }

    override func layoutLayers() {
        turner.bounds = bounds
        turner.position = CGPoint(x: bounds.midX, y: bounds.midY)
        arc.frame = bounds
        arc.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
    }

    override func restartLoops() {
        turner.removeAnimation(forKey: "turn")
        guard moving else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = CGFloat.pi * 2
        turn.duration = Self.period
        turner.add(LayerLoop.repeating(turn, period: Self.period), forKey: "turn")
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

// Content that dips a little and comes back once per period while it is active, the way
// a head nods while it reads. A delay puts it later in the beat, so a row of them can
// nod in turn. Held at rest under Reduce Motion.
//
// It moves a copy laid over the original, the same way `Breathing` does. Never put a
// rotation or scale outside it: the copy is an AppKit view, and AppKit cannot lay one
// out under a transform. Turn the content inside it instead.
struct Nodding<Content: View>: View {
    var active = true
    var period: TimeInterval = Breath.period
    var delay: TimeInterval = 0
    // How far down the content dips, in points.
    var depth: CGFloat
    // How much of the period the dip takes. The content rests for the remainder.
    var dip: TimeInterval = 0.34
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var moving: Bool { active && !reduceMotion }

    var body: some View {
        content
            .opacity(moving ? 0 : 1)
            .overlay {
                if moving {
                    NoddingCopy(content: content,
                                look: .init(period: period, delay: delay, depth: depth, dip: dip))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

private struct NoddingCopy<Content: View>: NSViewRepresentable {
    let content: Content
    let look: NoddingCopyView.Look

    func makeNSView(context: Context) -> NoddingCopyView { NoddingCopyView() }

    func updateNSView(_ view: NoddingCopyView, context: Context) {
        view.show(AnyView(content.environment(\.self, context.environment)), look: look)
    }
}

final class NoddingCopyView: LoopLayerView {
    struct Look: Equatable {
        var period: TimeInterval = Breath.period
        var delay: TimeInterval = 0
        var depth: CGFloat = 0
        var dip: TimeInterval = 0.34
    }

    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var look = Look()

    override init(frame: NSRect) {
        super.init(frame: frame)
        host.sizingOptions = []
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    var loops: [String] { host.layer?.animationKeys() ?? [] }

    func show(_ content: AnyView, look: Look) {
        host.rootView = content
        guard look != self.look else { return }
        self.look = look
        restartLoops()
    }

    // The dip is half a sine wave: down softly and back up softly, then a rest. Inside
    // this view a layer's y runs downwards, the same way SwiftUI's offset does.
    override func restartLoops() {
        guard let layer = host.layer else { return }
        layer.removeAnimation(forKey: "nod")
        guard look.depth != 0, look.period > 0 else { return }
        let share = min(1, look.dip / look.period)
        let nod = CAKeyframeAnimation(keyPath: "transform.translation.y")
        nod.values = [0, look.depth, 0, 0]
        nod.keyTimes = [0, NSNumber(value: share / 2), NSNumber(value: share), 1]
        nod.timingFunctions = [CAMediaTimingFunction(name: .easeOut),
                               CAMediaTimingFunction(name: .easeIn),
                               CAMediaTimingFunction(name: .linear)]
        nod.duration = look.period
        let looped = LayerLoop.repeating(nod, period: look.period)
        let shifted = (CACurrentMediaTime() - look.delay).truncatingRemainder(dividingBy: look.period)
        looped.timeOffset = shifted < 0 ? shifted + look.period : shifted
        layer.add(looped, forKey: "nod")
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
