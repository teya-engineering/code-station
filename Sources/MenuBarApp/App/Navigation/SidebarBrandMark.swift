import AppKit
import QuartzCore
import SwiftUI
import CodeStationCore

struct SidebarBrandMark: NSViewRepresentable {
    var input: AppMarkMotion.Input

    func makeNSView(context: Context) -> SidebarBrandMarkView { SidebarBrandMarkView() }

    func updateNSView(_ view: SidebarBrandMarkView, context: Context) {
        view.update(input, tile: AppMark.tile.resolve(in: context.environment).cgColor,
                    dot: AppMark.dot.resolve(in: context.environment),
                    accent: AppMark.accent.resolve(in: context.environment).cgColor)
    }

    static func dismantleNSView(_ view: SidebarBrandMarkView, coordinator: ()) {
        view.stop()
    }
}

// Finite keyframes run in the render server. Neither the mark nor its surrounding
// SwiftUI header needs a display timer, including while the pointer rests on it.
final class SidebarBrandMarkView: NSView {
    private let drawing = CATransformLayer()
    private let edge = CAShapeLayer()
    private let tile = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let brackets = CAShapeLayer()
    private let dots = (0..<9).map { _ in CAShapeLayer() }
    private var dotColour = AppMark.dot.resolve(in: EnvironmentValues())
    private var accentColour = AppMark.accent.resolve(in: EnvironmentValues()).cgColor
    private(set) var motion = AppMarkMotion()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = false
        layerContentsRedrawPolicy = .never
        layer?.addSublayer(drawing)
        drawing.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        drawing.addSublayer(edge)
        drawing.addSublayer(tile)
        drawing.addSublayer(ring)
        drawing.addSublayer(brackets)
        let inset = AppMark.margin * 100
        tile.path = CGPath(roundedRect: CGRect(x: inset, y: inset, width: 100 - inset * 2, height: 100 - inset * 2),
                           cornerWidth: AppMark.corner * 100, cornerHeight: AppMark.corner * 100, transform: nil)
        edge.path = tile.path
        edge.zPosition = -2
        edge.opacity = 0
        edge.fillColor = AppMark.edge.resolve(in: EnvironmentValues()).cgColor
        ring.fillColor = nil
        ring.lineWidth = 1.2
        brackets.fillColor = nil
        brackets.lineWidth = 5.7
        brackets.lineCap = .round
        brackets.lineJoin = .round
        brackets.strokeColor = NSColor(srgbRed: 112 / 255, green: 116 / 255, blue: 36 / 255, alpha: 1).cgColor
        let path = CGMutablePath()
        for points in [[CGPoint(x: 40, y: 29), CGPoint(x: 29, y: 43), CGPoint(x: 29, y: 57), CGPoint(x: 40, y: 71)],
                       [CGPoint(x: 60, y: 29), CGPoint(x: 71, y: 43), CGPoint(x: 71, y: 57), CGPoint(x: 60, y: 71)]] {
            path.addLines(between: points)
        }
        brackets.path = path
        for dot in dots {
            dot.path = CGPath(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2), transform: nil)
            drawing.addSublayer(dot)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        LayerLoop.still {
            drawing.position = CGPoint(x: bounds.midX, y: bounds.midY)
            render()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        stop()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        viewDidChangeBackingProperties()
        visibilityChanged()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        ([drawing] + [edge, tile, ring, brackets] + dots).forEach { $0.contentsScale = scale }
    }

    @objc private func visibilityChanged() {
        var input = motion.input
        input.visible = window?.occlusionState.contains(.visible) == true
        if motion.update(input, at: CACurrentMediaTime()) { render() }
    }

    func update(_ input: AppMarkMotion.Input, tile: CGColor, dot: Color.Resolved, accent: CGColor,
                choose: ([AppMarkGesture]) -> AppMarkGesture = { $0.randomElement()! }) {
        dotColour = dot
        accentColour = accent
        LayerLoop.still {
            self.tile.fillColor = tile
            ring.strokeColor = accent
        }
        var input = input
        input.visible = window?.occlusionState.contains(.visible) == true
        if motion.update(input, at: CACurrentMediaTime(), choose: choose) { render() }
        else if motion.playback == nil { paint(.rest) }
    }

    func stop() {
        motion.stop()
        render()
    }

    private func render() {
        ([drawing] + [edge, ring, brackets] + dots).forEach { $0.removeAllAnimations() }
        let now = CACurrentMediaTime()
        guard let playback = motion.playback else { paint(.rest); return }
        let remaining = max(0, playback.start + playback.duration - now)
        paint(playback.finalPose)
        guard remaining > 0 else { return }
        let count = max(1, Int(ceil(remaining * 60)))
        let frames = (0...count).map { index in
            index == count ? playback.finalPose : playback.pose(at: now + remaining * Double(index) / Double(count))
        }
        animate(drawing, "transform", frames.map { NSValue(caTransform3D: transform($0)) }, duration: remaining)
        animate(edge, "opacity", frames.map { $0.edgeOpacity }, duration: remaining)
        animate(ring, "path", frames.map { ringPath($0) }, duration: remaining)
        animate(ring, "opacity", frames.map { $0.ringOpacity }, duration: remaining)
        animate(brackets, "opacity", frames.map { $0.bracketsOpacity }, duration: remaining)
        for i in dots.indices {
            animate(dots[i], "position", frames.map { NSValue(point: CGPoint(x: $0.dots[i].x * 100, y: $0.dots[i].y * 100)) }, duration: remaining)
            animate(dots[i], "transform", frames.map { NSValue(caTransform3D: dotTransform($0.dots[i])) }, duration: remaining)
            if i != 2 { animate(dots[i], "fillColor", frames.map { colour($0.dots[i]) }, duration: remaining) }
        }
    }

    private func paint(_ pose: AppMarkPose) {
        LayerLoop.still {
            drawing.transform = transform(pose)
            edge.opacity = Float(pose.edgeOpacity)
            ring.path = ringPath(pose)
            ring.opacity = Float(pose.ringOpacity)
            brackets.opacity = Float(pose.bracketsOpacity)
            for i in dots.indices {
                dots[i].position = CGPoint(x: pose.dots[i].x * 100, y: pose.dots[i].y * 100)
                dots[i].transform = dotTransform(pose.dots[i])
                dots[i].fillColor = i == 2 ? accentColour : colour(pose.dots[i])
            }
        }
    }

    private func transform(_ pose: AppMarkPose) -> CATransform3D {
        let side = min(bounds.width, bounds.height)
        var transform = CATransform3DMakeTranslation(pose.x * side, pose.y * side, 0)
        if pose.tiltX != 0 || pose.tiltY != 0 { transform.m34 = -1 / 240 }
        transform = CATransform3DRotate(transform, pose.rotation * .pi / 180, 0, 0, 1)
        transform = CATransform3DRotate(transform, pose.tiltX * .pi / 180, 1, 0, 0)
        transform = CATransform3DRotate(transform, pose.tiltY * .pi / 180, 0, 1, 0)
        let scale = side / 100 * pose.scale
        return CATransform3DScale(transform, scale * pose.scaleX, scale * pose.scaleY, 1)
    }

    private func dotTransform(_ dot: AppMarkPose.Dot) -> CATransform3D {
        CATransform3DMakeScale(dot.radius * 100, dot.radius * dot.stretch * 100, 1)
    }

    private func ringPath(_ pose: AppMarkPose) -> CGPath {
        let radius = pose.ringRadius * 100
        return CGPath(ellipseIn: CGRect(x: AppMark.centres[2] * 100 - radius, y: AppMark.centres[0] * 100 - radius,
                                       width: radius * 2, height: radius * 2), transform: nil)
    }

    private func colour(_ dot: AppMarkPose.Dot) -> CGColor {
        let shade = CGFloat(dot.shade)
        return NSColor(srgbRed: CGFloat(dotColour.red) * (1 - shade) + 88 / 255 * shade,
                       green: CGFloat(dotColour.green) * (1 - shade) + 94 / 255 * shade,
                       blue: CGFloat(dotColour.blue) * (1 - shade) + 32 / 255 * shade, alpha: 1).cgColor
    }

    private func animate(_ layer: CALayer, _ key: String, _ values: [Any], duration: TimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values
        animation.duration = duration
        layer.add(animation, forKey: key)
    }
}
