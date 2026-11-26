import AppKit
import QuartzCore
import SwiftUI

// A short streak of colour running along a thin line for as long as something is on its
// way, such as a request that has been sent and not yet answered. It takes the size it
// is given. Under Reduce Motion the whole line is lit and holds still, which still reads
// as "under way".
struct CometLine: View {
    let colour: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CometLineLayer(colour: colour, moving: !reduceMotion)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct CometLineLayer: NSViewRepresentable {
    let colour: Color
    let moving: Bool

    func makeNSView(context: Context) -> CometLineView { CometLineView() }

    func updateNSView(_ view: CometLineView, context: Context) {
        view.update(colour: colour.resolve(in: context.environment).cgColor, moving: moving)
    }
}

final class CometLineView: LoopLayerView {
    static let period: CFTimeInterval = 1.05
    // How much of the line the streak covers.
    static let share: CGFloat = 0.34
    static let stillOpacity: Float = 0.5

    private let streak = CAGradientLayer()
    private(set) var moving = false
    private var laidOutWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = true
        streak.startPoint = CGPoint(x: 0, y: 0.5)
        streak.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(streak)
    }

    var loops: [String] { streak.animationKeys() ?? [] }

    func update(colour: CGColor, moving: Bool) {
        let clear = colour.copy(alpha: 0) ?? colour
        LayerLoop.still {
            streak.colors = moving ? [clear, colour, colour, clear] : [colour, colour]
            streak.locations = moving ? [0, 0.45, 0.7, 1] : [0, 1]
            streak.opacity = moving ? 1 : Self.stillOpacity
        }
        guard moving != self.moving else { return }
        self.moving = moving
        LayerLoop.still { layoutLayers() }
        restartLoops()
    }

    override func layoutLayers() {
        layer?.cornerRadius = bounds.height / 2
        let width = moving ? bounds.width * Self.share : bounds.width
        streak.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        streak.position = CGPoint(x: moving ? -width / 2 : bounds.midX, y: bounds.midY)
        guard laidOutWidth != bounds.width else { return }
        laidOutWidth = bounds.width
        restartLoops()
    }

    override func restartLoops() {
        streak.removeAnimation(forKey: "run")
        guard moving, bounds.width > 0 else { return }
        let width = bounds.width * Self.share
        let run = CABasicAnimation(keyPath: "position.x")
        run.fromValue = -width / 2
        run.toValue = bounds.width + width / 2
        run.duration = Self.period
        run.timingFunction = LayerLoop.swingCurve
        streak.add(LayerLoop.repeating(run, period: Self.period), forKey: "run")
    }
}

// The same streak following a path instead of a straight line, over a dotted ghost of
// the path, for something that will be a line once it arrives, such as a chart still
// being written. The path is given in a unit square and stretched to the view. Under
// Reduce Motion the ghost is drawn and nothing runs along it.
struct CometPath: View {
    // The corners of the path, each from 0 to 1 across and down.
    let points: [CGPoint]
    let colour: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CometPathLayer(points: points, colour: colour, ghost: Theme.chartGrid, moving: !reduceMotion)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct CometPathLayer: NSViewRepresentable {
    let points: [CGPoint]
    let colour: Color
    let ghost: Color
    let moving: Bool

    func makeNSView(context: Context) -> CometPathView { CometPathView() }

    func updateNSView(_ view: CometPathView, context: Context) {
        view.update(points: points, colour: colour.resolve(in: context.environment).cgColor,
                    ghost: ghost.resolve(in: context.environment).cgColor, moving: moving)
    }
}

final class CometPathView: LoopLayerView {
    static let period: CFTimeInterval = 1.6
    // How much of the path the streak covers.
    static let share: CGFloat = 0.18

    private let ghost = CAShapeLayer()
    private let streak = CAShapeLayer()
    private var points: [CGPoint] = []
    private(set) var moving = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        for line in [ghost, streak] {
            line.fillColor = nil
            line.lineCap = .round
            line.lineJoin = .round
            layer?.addSublayer(line)
        }
        ghost.lineWidth = 1.5
        ghost.lineDashPattern = [2, 5]
        streak.lineWidth = 2
        // Nothing of the streak shows until the loop is running it along the path.
        streak.strokeEnd = 0
    }

    var loops: [String] { streak.animationKeys() ?? [] }

    func update(points: [CGPoint], colour: CGColor, ghost ghostColour: CGColor, moving: Bool) {
        LayerLoop.still {
            ghost.strokeColor = ghostColour
            streak.strokeColor = colour
            streak.isHidden = !moving
        }
        let changed = points != self.points || moving != self.moving
        self.points = points
        self.moving = moving
        guard changed else { return }
        LayerLoop.still { layoutLayers() }
        restartLoops()
    }

    override func layoutLayers() {
        let path = CGMutablePath()
        let inset = streak.lineWidth
        let area = bounds.insetBy(dx: inset, dy: inset)
        for (index, point) in points.enumerated() {
            let place = CGPoint(x: area.minX + point.x * area.width, y: area.minY + point.y * area.height)
            if index == 0 { path.move(to: place) } else { path.addLine(to: place) }
        }
        for line in [ghost, streak] {
            line.frame = bounds
            line.path = path
        }
    }

    // The streak runs on past the end of the path before it starts over, so its tail
    // leaves the line instead of vanishing from it.
    override func restartLoops() {
        streak.removeAnimation(forKey: "run")
        guard moving, bounds.width > 0 else { return }
        let head = CABasicAnimation(keyPath: "strokeEnd")
        head.fromValue = 0
        head.toValue = 1 + Self.share
        let tail = CABasicAnimation(keyPath: "strokeStart")
        tail.fromValue = -Self.share
        tail.toValue = 1
        let run = CAAnimationGroup()
        run.animations = [head, tail]
        run.duration = Self.period
        run.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
        streak.add(LayerLoop.repeating(run, period: Self.period), forKey: "run")
    }
}
