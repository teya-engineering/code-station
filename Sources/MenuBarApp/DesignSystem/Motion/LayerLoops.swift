import AppKit
import QuartzCore
import SwiftUI
import CodeStationCore

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
