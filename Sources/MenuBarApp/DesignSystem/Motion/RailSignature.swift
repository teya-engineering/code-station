import AppKit
import QuartzCore
import SwiftUI

// MARK: - Rail signatures

// Each shortcut on the session header rail has a colour of its own and a short act its
// glyph plays while it is pointed at. The rail is grey and still at rest, so nothing asks
// for the eye until a hand reaches for it. An open seat keeps the accent, since green
// means chosen and the tool colour only says which tool.
enum RailTool: Equatable {
    case opinion, preview, terminal, find, export, recap, ask, more

    var tint: Theme.RailTint {
        switch self {
        case .opinion: .opinion
        case .preview: .preview
        case .terminal: .terminal
        case .find: .find
        case .export: .export
        case .recap: .recap
        case .ask: .ask
        case .more: .plain
        }
    }

    // The symbol the drawn glyph stands in for. A button showing anything else, such as
    // an hourglass while it works, keeps that symbol and plays no act.
    var symbol: String? {
        switch self {
        case .opinion: nil
        case .preview: "globe"
        case .terminal: "terminal"
        case .find: "magnifyingglass"
        case .export: "doc.zipper"
        case .recap: "lightbulb"
        case .ask: "questionmark.bubble"
        case .more: "ellipsis"
        }
    }

    func draws(_ icon: String) -> Bool { symbol == icon }

    // The colour the tool's glyph takes in the panel it opens, so the panel reads as the
    // one that shortcut opened. The terminal's ink is made for its dark wash, so its panel
    // takes the tool's own colour instead.
    var mark: Color {
        if self == .terminal, let colour = tint.colour { return colour }
        return tint.ink
    }

    // The terminal's caret lights in the brand's lime, as the shell's caret does.
    var caret: Color? { self == .terminal ? Theme.brand : nil }
}

// MARK: - The glyph

// A rail glyph drawn as layers, so each part can move on its own: the globe's meridians
// turn, the prompt is typed, the zip's teeth close. SF Symbol effects can only move a
// symbol whole. Core Animation plays every act and loop, so a hovered glyph costs the app
// nothing between frames.
struct RailGlyph: View {
    static let side: CGFloat = 17

    let tool: RailTool
    let colour: Color
    // The bulb's glow, while the recap is pointed at or open.
    var lit = false
    var playing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RailGlyphLayer(tool: tool, colour: colour, lit: lit, playing: playing && !reduceMotion)
            .frame(width: Self.side, height: Self.side)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct RailGlyphLayer: NSViewRepresentable {
    let tool: RailTool
    let colour: Color
    let lit: Bool
    let playing: Bool

    func makeNSView(context: Context) -> RailGlyphView { RailGlyphView(tool: tool) }

    func updateNSView(_ view: RailGlyphView, context: Context) {
        let environment = context.environment
        view.update(colour: colour.resolve(in: environment).cgColor,
                    caret: tool.caret.map { $0.resolve(in: environment).cgColor },
                    glow: Theme.brand.resolve(in: environment).cgColor,
                    lit: lit, playing: playing)
    }
}

// Drawn on a 20 point grid and scaled to the view, with strokes as thick as the rail's
// semibold symbols.
final class RailGlyphView: LoopLayerView {
    private static let grid: CGFloat = 20
    private static let stroke: CGFloat = 1.7

    let tool: RailTool
    private let art = CALayer()
    private var inks: [CAShapeLayer] = []
    private var fills: [CAShapeLayer] = []
    private var caretLine: CAShapeLayer?
    private var glowLayer: CAShapeLayer?
    // The parts an act moves, each as a layer turning about its own centre.
    private var parts: [String: CALayer] = [:]
    private(set) var playing = false
    private var drawn = false

    init(tool: RailTool) {
        self.tool = tool
        super.init(frame: .zero)
        art.bounds = CGRect(x: 0, y: 0, width: Self.grid, height: Self.grid)
        art.anchorPoint = .zero
        layer?.addSublayer(art)
        LayerLoop.still { build() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var acts: [String] { parts.values.flatMap { $0.animationKeys() ?? [] } }

    // `lit` is the tool's own light: the bulb's glow, the terminal's lime caret.
    func update(colour: CGColor, caret: CGColor?, glow: CGColor, lit: Bool, playing: Bool) {
        CATransaction.begin()
        // The first drawing is how the glyph starts, so it does not fade in from nothing.
        CATransaction.setDisableActions(!drawn)
        CATransaction.setAnimationDuration(Motion.hoverDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        // A see-through colour such as `.secondary` is drawn solid and faded as a whole,
        // so the spots where two strokes cross do not come out darker.
        let solid = colour.copy(alpha: 1) ?? colour
        art.opacity = Float(colour.alpha)
        inks.forEach { $0.strokeColor = solid }
        fills.forEach { $0.fillColor = solid }
        caretLine?.strokeColor = lit ? caret ?? solid : solid
        glowLayer?.fillColor = glow
        glowLayer?.opacity = lit ? 1 : 0
        CATransaction.commit()
        drawn = true

        guard playing != self.playing else { return }
        self.playing = playing
        if playing { play() } else { settle() }
    }

    override func layoutLayers() {
        let scale = bounds.width / Self.grid
        art.position = .zero
        art.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
    }

    // A loop lost while the window was away comes back on the beat. The act itself is not
    // played again, since the pointer did not arrive anew.
    override func restartLoops() {
        guard playing, acts.isEmpty else { return }
        play()
    }

    // MARK: Drawing

    private func build() {
        switch tool {
        case .preview: buildGlobe()
        case .terminal: buildTerminal()
        case .find: buildFind()
        case .export: buildZip()
        case .recap: buildBulb()
        case .ask: buildBubble()
        case .more: buildMore()
        case .opinion: break
        }
    }

    // A layer the size of the grid that turns and scales about `centre`.
    private func group(_ name: String, centre: CGPoint, in parent: CALayer? = nil) -> CALayer {
        let group = CALayer()
        group.bounds = CGRect(x: 0, y: 0, width: Self.grid, height: Self.grid)
        group.anchorPoint = CGPoint(x: centre.x / Self.grid, y: centre.y / Self.grid)
        group.position = centre
        (parent ?? art).addSublayer(group)
        parts[name] = group
        return group
    }

    @discardableResult
    private func ink(_ path: CGPath, in parent: CALayer, width: CGFloat = stroke) -> CAShapeLayer {
        let shape = shapeLayer(path, in: parent)
        shape.fillColor = nil
        shape.lineWidth = width
        inks.append(shape)
        return shape
    }

    @discardableResult
    private func fill(_ path: CGPath, in parent: CALayer) -> CAShapeLayer {
        let shape = shapeLayer(path, in: parent)
        fills.append(shape)
        return shape
    }

    private func shapeLayer(_ path: CGPath, in parent: CALayer) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.frame = parent.bounds
        shape.path = path
        shape.lineCap = .round
        shape.lineJoin = .round
        parent.addSublayer(shape)
        return shape
    }

    private func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2), transform: nil)
    }

    private func line(_ points: [(CGFloat, CGFloat)]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
        return path
    }

    private func buildGlobe() {
        let globe = group("globe", centre: CGPoint(x: 10, y: 10))
        ink(circle(10, 10, 7.3), in: globe)
        ink(line([(2.7, 10), (17.3, 10)]), in: globe)
        // Two meridians, half a turn apart. At rest one shows, pressed into an oval.
        let front = group("meridian", centre: CGPoint(x: 10, y: 10), in: globe)
        front.setAffineTransform(CGAffineTransform(scaleX: 0.45, y: 1))
        ink(circle(10, 10, 7.3), in: front)
        let back = group("meridianBack", centre: CGPoint(x: 10, y: 10), in: globe)
        back.setAffineTransform(CGAffineTransform(scaleX: 0.45, y: 1))
        back.opacity = 0
        ink(circle(10, 10, 7.3), in: back)
    }

    private func buildTerminal() {
        let body = group("terminal", centre: CGPoint(x: 10, y: 10))
        ink(CGPath(roundedRect: CGRect(x: 2.4, y: 3.8, width: 15.2, height: 12.4),
                   cornerWidth: 3, cornerHeight: 3, transform: nil), in: body)
        let chevron = group("chevron", centre: CGPoint(x: 7.25, y: 10), in: body)
        ink(line([(6, 7.8), (8.5, 10), (6, 12.2)]), in: chevron)
        let caret = group("caret", centre: CGPoint(x: 12.1, y: 12.4), in: body)
        caretLine = ink(line([(10.4, 12.4), (13.8, 12.4)]), in: caret)
        inks.removeLast()
    }

    private func buildFind() {
        let ping = group("ping", centre: CGPoint(x: 8.6, y: 8.6))
        ping.opacity = 0
        ink(circle(8.6, 8.6, 5.3), in: ping, width: 1)
        let glass = group("glass", centre: CGPoint(x: 10.15, y: 10.15))
        ink(circle(8.6, 8.6, 5.3), in: glass)
        ink(line([(12.5, 12.5), (17, 17)]), in: glass)
        let hit = group("hit", centre: CGPoint(x: 8.6, y: 8.6))
        hit.opacity = 0
        fill(circle(8.6, 8.6, 1.7), in: hit)
    }

    private func buildZip() {
        let body = group("page", centre: CGPoint(x: 9.6, y: 10))
        let page = CGMutablePath()
        page.move(to: CGPoint(x: 5.8, y: 2.6))
        page.addLine(to: CGPoint(x: 11.2, y: 2.6))
        page.addLine(to: CGPoint(x: 15.2, y: 6.6))
        page.addLine(to: CGPoint(x: 15.2, y: 15.6))
        page.addCurve(to: CGPoint(x: 13.4, y: 17.4), control1: CGPoint(x: 15.2, y: 16.6),
                      control2: CGPoint(x: 14.4, y: 17.4))
        page.addLine(to: CGPoint(x: 5.8, y: 17.4))
        page.addCurve(to: CGPoint(x: 4, y: 15.6), control1: CGPoint(x: 4.8, y: 17.4),
                      control2: CGPoint(x: 4, y: 16.6))
        page.addLine(to: CGPoint(x: 4, y: 4.4))
        page.addCurve(to: CGPoint(x: 5.8, y: 2.6), control1: CGPoint(x: 4, y: 3.4),
                      control2: CGPoint(x: 4.8, y: 2.6))
        page.closeSubpath()
        ink(page, in: body)
        ink(line([(11.2, 2.8), (11.2, 6.6), (15, 6.6)]), in: body)
        let teeth: [(CGFloat, CGFloat)] = [(7, 5.6), (8.4, 7.4), (7, 9.2), (8.4, 11)]
        for (index, tooth) in teeth.enumerated() {
            let layer = group("tooth\(index)", centre: CGPoint(x: tooth.0 + 0.7, y: tooth.1))
            ink(line([tooth, (tooth.0 + 1.4, tooth.1)]), in: layer)
        }
        let pull = group("pull", centre: CGPoint(x: 8.4, y: 14))
        fill(CGPath(roundedRect: CGRect(x: 7.1, y: 12.6, width: 2.6, height: 2.8),
                    cornerWidth: 0.8, cornerHeight: 0.8, transform: nil), in: pull)
    }

    private func buildBulb() {
        let rays = group("rays", centre: CGPoint(x: 10, y: 5))
        let lines: [[(CGFloat, CGFloat)]] = [
            [(10, 0.9), (10, -1.1)],
            [(15.9, 3.9), (17.5, 2.7)], [(4.1, 3.9), (2.5, 2.7)],
            [(17.3, 8.4), (19.3, 8.4)], [(2.7, 8.4), (0.7, 8.4)]
        ]
        for (index, points) in lines.enumerated() {
            let ray = ink(line(points), in: rays)
            ray.strokeEnd = 0
            parts["ray\(index)"] = ray
        }
        let body = group("bulb", centre: CGPoint(x: 10, y: 10.5))
        // The glass: an arc round a centre at (10, 8), pinched into the neck either side.
        let glass = CGMutablePath()
        let centre = CGPoint(x: 10, y: 8)
        glass.addArc(center: centre, radius: 5.2, startAngle: -.pi / 2,
                     endAngle: atan2(4.1, -3.2), clockwise: true)
        glass.addCurve(to: CGPoint(x: 7.7, y: 13.9), control1: CGPoint(x: 7.4, y: 12.6),
                       control2: CGPoint(x: 7.7, y: 13.2))
        glass.addLine(to: CGPoint(x: 7.7, y: 14.2))
        glass.addLine(to: CGPoint(x: 12.3, y: 14.2))
        glass.addLine(to: CGPoint(x: 12.3, y: 13.9))
        glass.addCurve(to: CGPoint(x: 13.2, y: 12.1), control1: CGPoint(x: 12.3, y: 13.2),
                       control2: CGPoint(x: 12.6, y: 12.6))
        glass.addArc(center: centre, radius: 5.2, startAngle: atan2(4.1, 3.2),
                     endAngle: -.pi / 2, clockwise: true)
        glass.closeSubpath()
        let glow = shapeLayer(glass, in: body)
        glow.opacity = 0
        glowLayer = glow
        ink(glass, in: body)
        let base = CGMutablePath()
        base.addLines(between: [CGPoint(x: 8, y: 16.3), CGPoint(x: 12, y: 16.3)])
        base.addLines(between: [CGPoint(x: 8.8, y: 18.2), CGPoint(x: 11.2, y: 18.2)])
        ink(base, in: body)
    }

    private func buildBubble() {
        let bubble = group("bubble", centre: CGPoint(x: 10, y: 9.9))
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: 4.6, y: 3.4))
        outline.addArc(tangent1End: CGPoint(x: 17.4, y: 3.4), tangent2End: CGPoint(x: 17.4, y: 5.4), radius: 2)
        outline.addArc(tangent1End: CGPoint(x: 17.4, y: 13.4), tangent2End: CGPoint(x: 15.4, y: 13.4), radius: 2)
        outline.addLine(to: CGPoint(x: 9.8, y: 13.4))
        outline.addLine(to: CGPoint(x: 6.4, y: 16.4))
        outline.addLine(to: CGPoint(x: 6.4, y: 13.4))
        outline.addArc(tangent1End: CGPoint(x: 2.6, y: 13.4), tangent2End: CGPoint(x: 2.6, y: 11.4), radius: 2)
        outline.addArc(tangent1End: CGPoint(x: 2.6, y: 3.4), tangent2End: CGPoint(x: 4.6, y: 3.4), radius: 2)
        outline.closeSubpath()
        ink(outline, in: bubble)

        let question = group("question", centre: CGPoint(x: 9.65, y: 8.6), in: bubble)
        let hook = CGMutablePath()
        hook.addArc(center: CGPoint(x: 10.1, y: 7.085), radius: 1.9, startAngle: .pi,
                    endAngle: 2 * .pi + atan2(1.615, 1.0), clockwise: false)
        hook.addCurve(to: CGPoint(x: 10, y: 10.1), control1: CGPoint(x: 10.4, y: 9.1),
                      control2: CGPoint(x: 10, y: 9.5))
        ink(hook, in: question)
        fill(circle(10, 11.5, 0.7), in: question)

        for (index, x) in [6.9, 10, 13.1].enumerated() {
            let dot = group("dot\(index)", centre: CGPoint(x: x, y: 8.5), in: bubble)
            dot.opacity = 0
            fill(circle(x, 8.5, 1), in: dot)
        }
    }

    private func buildMore() {
        let dots = group("dots", centre: CGPoint(x: 10, y: 10))
        for x in [4.5, 10, 15.5] {
            fill(circle(x, 10, 1.4), in: dots)
        }
    }

    // MARK: Acting

    private func play() {
        switch tool {
        case .preview:
            run("globe", "transform.rotation.z", [0, -14 * CGFloat.pi / 180],
                duration: Motion.railHopDuration, curve: Motion.popCurve)
            let half = Motion.railGlobePeriod / 2
            for (name, phase) in [("meridian", 0.55), ("meridianBack", 1.35)] {
                let turn = CABasicAnimation(keyPath: "transform.scale.x")
                turn.fromValue = 1
                turn.toValue = -1
                turn.duration = half
                turn.autoreverses = true
                turn.repeatCount = .infinity
                turn.timeOffset = phase
                turn.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.55, 1)
                parts[name]?.add(turn, forKey: "act.turn")
            }
            run("meridianBack", "opacity", [0, 1], duration: Motion.revealDuration,
                curve: CAMediaTimingFunction(name: .easeOut))
        case .terminal:
            run("chevron", "transform.translation.x", [-3, 0], duration: 0.26, curve: Motion.controlCurve)
            run("chevron", "opacity", [0, 1], duration: 0.26, curve: Motion.controlCurve)
            run("caret", "transform.translation.x", [-3, 0], duration: Motion.railHopDuration,
                curve: Motion.drawCurve)
            run("caret", "transform.scale.x", [0.2, 1], duration: Motion.railHopDuration,
                curve: Motion.drawCurve)
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1, 0]
            blink.keyTimes = [0, 0.5, 1]
            blink.calculationMode = .discrete
            blink.duration = Motion.railCaretPeriod
            blink.repeatCount = .infinity
            blink.beginTime = now(in: "caret") + 0.45
            parts["caret"]?.add(blink, forKey: "act.blink")
        case .find:
            let sweep = CAKeyframeAnimation(keyPath: "transform")
            sweep.values = [CATransform3DIdentity, turn(-16, by: (-1.6, 1.2)),
                            turn(11, by: (1.5, -0.8)), CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
            sweep.keyTimes = [0, 0.35, 0.72, 1]
            sweep.timingFunctions = Array(repeating: CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1), count: 3)
            sweep.duration = 0.7
            parts["glass"]?.add(sweep, forKey: "act.sweep")
            land("hit", delay: 0.55, duration: Motion.railHopDuration, curve: Motion.popCurve)
            // The ring goes out last, ending the act.
            let ring = Motion.railFindDuration - Motion.ringDuration
            run("ping", "opacity", [0.8, 0], duration: Motion.ringDuration, delay: ring,
                curve: Motion.drawCurve, holdsBefore: false)
            run("ping", "transform.scale", [1, 1.9], duration: Motion.ringDuration, delay: ring,
                curve: Motion.drawCurve, holdsBefore: false)
        case .export:
            run("pull", "transform.translation.y", [-7.6, 0], duration: 0.5, curve: Motion.drawCurve)
            for index in 0..<4 {
                land("tooth\(index)", delay: 0.06 + 0.1 * Double(index), duration: 0.18,
                     curve: CAMediaTimingFunction(name: .easeOut))
            }
            run("page", "transform.scale.x", [1, 0.9, 1], times: [0, 0.4, 1],
                duration: Motion.railHopDuration, delay: Motion.railZipDuration - Motion.railHopDuration,
                curve: Motion.popCurve)
        case .recap:
            hop("bulb")
            for (index, delay) in [0, 0.05, 0.05, 0.1, 0.1].enumerated() {
                run("ray\(index)", "strokeEnd", [0, 1], duration: 0.28, delay: delay, curve: Motion.drawCurve)
            }
            let breathe = LayerLoop.swing("opacity", from: 1, to: 0.35, period: Motion.railBulbPeriod)
            breathe.repeatCount = .infinity
            breathe.beginTime = now(in: "rays") + Motion.railBulbDuration
            parts["rays"]?.add(breathe, forKey: "act.breathe")
        case .ask:
            run("bubble", "transform.rotation.z", [0, -7 * CGFloat.pi / 180],
                duration: Motion.railHopDuration, curve: Motion.popCurve)
            run("bubble", "transform.translation.y", [0, -0.6],
                duration: Motion.railHopDuration, curve: Motion.popCurve)
            run("question", "opacity", [1, 0], duration: Motion.leaveDuration,
                curve: CAMediaTimingFunction(name: .easeIn))
            run("question", "transform.scale", [1, 0.6], duration: Motion.leaveDuration,
                curve: CAMediaTimingFunction(name: .easeIn))
            for (index, delay) in [0.12, 0.27, 0.42].enumerated() {
                let typing = CAAnimationGroup()
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0.35, 1, 0.35, 0.35]
                let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
                rise.values = [0, -1.8, 0, 0]
                for part in [fade, rise] {
                    part.keyTimes = [0, 0.3, 0.6, 1]
                    part.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
                }
                typing.animations = [fade, rise]
                typing.duration = Motion.railTypingPeriod
                typing.repeatCount = .infinity
                typing.beginTime = now(in: "dot\(index)") + delay
                typing.fillMode = .backwards
                parts["dot\(index)"]?.add(typing, forKey: "act.typing")
            }
        case .more:
            hop("dots")
        case .opinion:
            break
        }
    }

    // The pointer has gone: every part eases back to rest on the leaving curve from
    // wherever its act had reached, rather than snapping there.
    private func settle() {
        for part in parts.values {
            guard let keys = part.animationKeys(), !keys.isEmpty else { continue }
            let shown = part.presentation()
            let transform = shown?.transform ?? part.transform
            let opacity = shown?.opacity ?? part.opacity
            let strokeEnd = (shown as? CAShapeLayer)?.strokeEnd
            part.removeAllAnimations()

            let back = CAAnimationGroup()
            var animations: [CAAnimation] = []
            let ease = CABasicAnimation(keyPath: "transform")
            ease.fromValue = NSValue(caTransform3D: transform)
            animations.append(ease)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacity
            animations.append(fade)
            if let strokeEnd {
                let undraw = CABasicAnimation(keyPath: "strokeEnd")
                undraw.fromValue = strokeEnd
                animations.append(undraw)
            }
            back.animations = animations
            back.duration = Motion.leaveDuration
            back.timingFunction = CAMediaTimingFunction(name: .easeIn)
            part.add(back, forKey: "settle")
        }
    }

    // MARK: Helpers

    private func now(in name: String) -> CFTimeInterval {
        parts[name]?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime()
    }

    // One move that holds where it ends for as long as the pointer stays.
    private func run(_ name: String, _ keyPath: String, _ values: [CGFloat], times: [NSNumber]? = nil,
                     duration: CFTimeInterval, delay: CFTimeInterval = 0,
                     curve: CAMediaTimingFunction, holdsBefore: Bool = true) {
        guard let part = parts[name] else { return }
        let move = CAKeyframeAnimation(keyPath: keyPath)
        move.values = values
        move.keyTimes = times
        move.timingFunction = curve
        move.duration = duration
        move.beginTime = part.convertTime(CACurrentMediaTime(), from: nil) + delay
        move.fillMode = holdsBefore ? .both : .forwards
        move.isRemovedOnCompletion = false
        part.add(move, forKey: "act.\(keyPath)")
    }

    // A mark landing: it grows in from a third of its size as it fades in.
    private func land(_ name: String, delay: CFTimeInterval, duration: CFTimeInterval,
                      curve: CAMediaTimingFunction) {
        run(name, "opacity", [0, 1], duration: duration, delay: delay, curve: curve)
        run(name, "transform.scale", [0.3, 1], duration: duration, delay: delay, curve: curve)
    }

    private func hop(_ name: String) {
        run(name, "transform.translation.y", [0, -2.2, 0], times: [0, 0.45, 1],
            duration: Motion.railHopDuration, curve: Motion.popCurve)
    }

    private func turn(_ degrees: CGFloat, by offset: (CGFloat, CGFloat)) -> CATransform3D {
        CATransform3DRotate(CATransform3DMakeTranslation(offset.0, offset.1, 0),
                            degrees * .pi / 180, 0, 0, 1)
    }
}

// MARK: - A hop for a picture

// One small hop for an image that cannot be drawn as layers, such as an app's own icon.
// It moves by an offset only, since the button around it carries AppKit-backed parts.
private struct RailHop: ViewModifier {
    let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, rise in
                view.offset(y: rise)
            } keyframes: { _ in
                CubicKeyframe(-2.2, duration: Motion.railHopDuration * 0.45)
                CubicKeyframe(0, duration: Motion.railHopDuration * 0.55)
            }
        }
    }
}

extension View {
    func railHop(trigger: Int) -> some View {
        modifier(RailHop(trigger: trigger))
    }
}

// MARK: - The wash

// One wash per rail, moved between the seats rather than one per seat, so pointing along
// the rail carries the colour from tool to tool instead of blinking it off and on. It is
// drawn behind the rail: the dock's track is faint enough for it to show through.
@Observable @MainActor
final class RailWash {
    struct Seat: Equatable {
        let id: String
        let tool: RailTool
        let radius: CGFloat
    }

    private(set) var seat: Seat?
    // Where the pointer last was over the rail, in the rail's own space. It is only read
    // when the wash arrives, so it is not watched.
    @ObservationIgnored var pointer: CGPoint?
    @ObservationIgnored private var clearing: Task<Void, Never>?

    func point(at seat: Seat, _ inside: Bool) {
        if inside {
            clearing?.cancel()
            clearing = nil
            self.seat = seat
        } else if self.seat?.id == seat.id {
            clearing?.cancel()
            clearing = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Motion.railHandoff))
                guard !Task.isCancelled else { return }
                self?.seat = nil
            }
        }
    }
}

private struct RailSeatFrames: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    // Hosts the wash for every seat inside it. Put it on the row that holds a rail.
    func railWash() -> some View {
        modifier(RailWashHost())
    }

    // Marks a seat the rail's wash can land on. `active` is whether it should be there
    // now: pointed at or focused, and not already open.
    func railSeat(_ id: String, tool: RailTool, radius: CGFloat = Radius.control,
                  active: Bool) -> some View {
        modifier(RailSeatModifier(seat: .init(id: id, tool: tool, radius: radius), active: active))
    }
}

private struct RailWashHost: ViewModifier {
    @State private var wash = RailWash()

    func body(content: Content) -> some View {
        content
            .environment(wash)
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let point) = phase {
                    wash.pointer = point
                } else {
                    wash.pointer = nil
                }
            }
            .backgroundPreferenceValue(RailSeatFrames.self) { anchors in
                GeometryReader { proxy in
                    RailWashSurface(wash: wash, frames: anchors.mapValues { proxy[$0] })
                }
            }
    }
}

private struct RailSeatModifier: ViewModifier {
    let seat: RailWash.Seat
    let active: Bool

    @Environment(RailWash.self) private var wash: RailWash?

    func body(content: Content) -> some View {
        content
            .anchorPreference(key: RailSeatFrames.self, value: .bounds) { [seat.id: $0] }
            .onChange(of: active, initial: true) { _, active in
                wash?.point(at: seat, active)
            }
            .onDisappear { wash?.point(at: seat, false) }
    }
}

private struct RailWashSurface: View {
    let wash: RailWash
    let frames: [String: CGRect]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: RailWash.Seat?
    @State private var visible = false
    @State private var flood: CGFloat = 0
    @State private var origin: CGPoint = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let shown, let frame = frames[shown.id] {
                let tint = shown.tool.tint
                let shape = RoundedRectangle(cornerRadius: shown.radius)
                shape.fill(tint.wash)
                    .overlay(shape.strokeBorder(tint.edge, lineWidth: 1))
                    .frame(width: frame.width, height: frame.height)
                    .mask {
                        FloodMask(origin: CGPoint(x: origin.x - frame.minX, y: origin.y - frame.minY),
                                  progress: flood)
                    }
                    .offset(x: frame.minX, y: frame.minY)
                    .opacity(visible ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: wash.seat) { _, seat in move(to: seat) }
    }

    private func move(to seat: RailWash.Seat?) {
        guard let seat else {
            withAnimation(Motion.leave) {
                visible = false
            } completion: {
                guard wash.seat == nil else { return }
                shown = nil
                flood = 0
            }
            return
        }
        if shown != nil {
            // From one seat to the next: the wash slides there and its colour blends.
            // Under Reduce Motion it is simply there.
            withAnimation(reduceMotion ? nil : Motion.control) {
                shown = seat
                visible = true
                flood = 1
            }
            return
        }
        // Arriving from outside: it floods out from where the pointer came in.
        if let frame = frames[seat.id] {
            origin = wash.pointer ?? CGPoint(x: frame.midX, y: frame.midY)
        }
        if reduceMotion {
            flood = 1
            shown = seat
            withAnimation(Motion.hover) { visible = true }
        } else {
            withAnimation(Motion.flood) {
                shown = seat
                visible = true
                flood = 1
            }
        }
    }
}

// A circle spreading from a point until it covers the whole seat.
private struct FloodMask: Shape {
    var origin: CGPoint
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: min(max(origin.x, rect.minX), rect.maxX),
                             y: min(max(origin.y, rect.minY), rect.maxY))
        let reach = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                     CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            .map { hypot($0.x - centre.x, $0.y - centre.y) }
            .max() ?? 0
        let radius = max(1, reach * progress)
        return Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                      width: radius * 2, height: radius * 2))
    }
}
