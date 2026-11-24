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
