import AppKit
import QuartzCore
import SwiftUI

struct SidebarBrandMark: NSViewRepresentable {
    var input: BrandHover.Input

    func makeNSView(context: Context) -> SidebarBrandMarkView { SidebarBrandMarkView() }

    func updateNSView(_ view: SidebarBrandMarkView, context: Context) {
        view.update(input, tile: AppMark.tile.resolve(in: context.environment).cgColor,
                    dot: AppMark.dot.resolve(in: context.environment).cgColor,
                    accent: AppMark.accent.resolve(in: context.environment).cgColor)
    }

    static func dismantleNSView(_ view: SidebarBrandMarkView, coordinator: ()) { view.stop() }
}

// Finite dot keyframes run in the render server. The tile and its SwiftUI button
// stay anchored, and neither needs a display timer while the pointer rests on it.
final class SidebarBrandMarkView: BrandLayerView {
    private let drawing = CALayer()
    private let tile = CAShapeLayer()
    private let dots = (0..<9).map { _ in CAShapeLayer() }
    private(set) var motion = AppMarkMotion()

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = false
        layer?.addSublayer(drawing)
        drawing.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        drawing.addSublayer(tile)
        let inset = AppMark.margin * 100
        tile.path = CGPath(roundedRect: CGRect(x: inset, y: inset, width: 100 - inset * 2, height: 100 - inset * 2),
                           cornerWidth: AppMark.corner * 100, cornerHeight: AppMark.corner * 100, transform: nil)
        for dot in dots {
            dot.path = CGPath(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2), transform: nil)
            drawing.addSublayer(dot)
        }
        paintRest()
        setAccessibilityElement(false)
    }

    override func layoutLayers() {
        drawing.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let scale = min(bounds.width, bounds.height) / 100
        drawing.transform = CATransform3DMakeScale(scale, scale, 1)
    }

    func update(_ input: BrandHover.Input, tile: CGColor, dot: CGColor, accent: CGColor) {
        LayerLoop.still {
            self.tile.fillColor = tile
            for i in dots.indices { dots[i].fillColor = i == 2 ? accent : dot }
        }
        updateHover(input)
    }

    override func hoverChanged(from previous: BrandHover.Style) {
        let now = CACurrentMediaTime()
        if hover.style == .moving {
            motion.enter(at: now)
        } else if hover.input.visible && !hover.input.reducedMotion && previous == .moving {
            motion.leave(at: now)
        } else {
            motion.stop()
        }
        render()
    }

    override func stop() {
        super.stop()
        motion.stop()
        render()
    }

    private func render() {
        dots.forEach { $0.removeAllAnimations() }
        paintRest()
        let now = CACurrentMediaTime()
        guard let playback = motion.playback else { return }
        let remaining = max(0, playback.start + playback.duration - now)
        guard remaining > 0 else { return }
        let count = max(1, Int(ceil(remaining * 60)))
        let frames = (0...count).map { index in
            index == count ? AppMarkPose.rest : playback.pose(at: now + remaining * Double(index) / Double(count))
        }
        for i in dots.indices {
            animate(dots[i], "position", frames.map { NSValue(point: CGPoint(x: $0.dots[i].x * 100, y: $0.dots[i].y * 100)) }, duration: remaining)
            animate(dots[i], "transform.scale", frames.map { $0.dots[i].radius * 100 }, duration: remaining)
        }
    }

    private func paintRest() {
        LayerLoop.still {
            for (dot, pose) in zip(dots, AppMarkPose.rest.dots) {
                dot.position = CGPoint(x: pose.x * 100, y: pose.y * 100)
                dot.transform = CATransform3DMakeScale(pose.radius * 100, pose.radius * 100, 1)
            }
        }
    }

    private func animate(_ layer: CALayer, _ key: String, _ values: [Any], duration: TimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values
        animation.duration = duration
        layer.add(animation, forKey: key)
    }
}
