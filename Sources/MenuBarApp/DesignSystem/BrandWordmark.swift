import AppKit
import QuartzCore
import SwiftUI

struct BrandWordmark: View {
    var hovered = false
    var pointer = CGPoint.zero

    @Environment(\.textScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = Typography.Size.wordmark * max(1, textScale)
        Text("Code Station")
            .font(.logo(size))
            .kerning(Typography.wordmarkKerning)
            .foregroundStyle(.clear)
            .overlay {
                WordmarkLayer(font: .logo(size), input: .init(hovered: hovered, reducedMotion: reduceMotion),
                              pointer: pointer)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct WordmarkLayer: NSViewRepresentable {
    let font: NSFont
    let input: BrandHover.Input
    let pointer: CGPoint

    func makeNSView(context: Context) -> BrandWordmarkView { BrandWordmarkView() }

    func updateNSView(_ view: BrandWordmarkView, context: Context) {
        view.update(font: font, accent: Theme.accent.resolve(in: context.environment).cgColor,
                    colours: Theme.wordmarkColours.map { $0.resolve(in: context.environment).cgColor },
                    input: input, pointer: pointer)
    }

    static func dismantleNSView(_ view: BrandWordmarkView, coordinator: ()) { view.stop() }
}

// Only masked colour layers move. The Sora mask keeps the same size, kerning and
// position through entry, pointer travel and exit.
final class BrandWordmarkView: BrandLayerView {
    private let ink = CALayer()
    private let colour = CALayer()
    private let gradient = CAGradientLayer()
    private let gleam = CAGradientLayer()
    private let letters = CATextLayer()
    private var font: NSFont?
    private var colours: [CGColor] = []
    private var pointer = CGPoint.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(ink)
        ink.addSublayer(colour)
        colour.addSublayer(gradient)
        colour.addSublayer(gleam)
        ink.mask = letters
        colour.opacity = 0
        gradient.locations = [0, 0.33, 0.66, 1]
        gleam.locations = [0, 0.45, 0.55, 1]
        gleam.startPoint = CGPoint(x: 0, y: 0.8)
        gleam.endPoint = CGPoint(x: 1, y: 0.2)
        gleam.opacity = 0
        setAccessibilityElement(false)
    }

    func update(font: NSFont, accent: CGColor, colours: [CGColor], input: BrandHover.Input,
                pointer: CGPoint = .zero) {
        let paletteChanged = self.colours != colours
        self.colours = colours
        self.pointer = pointer
        LayerLoop.still {
            ink.backgroundColor = accent
            if paletteChanged {
                gradient.colors = colours + [colours[0]]
                gleam.colors = [colours[2].copy(alpha: 0)!, colours[2], colours[1], colours[1].copy(alpha: 0)!]
            }
            if font != self.font {
                self.font = font
                letters.string = NSAttributedString(string: "Code Station", attributes: [
                    .font: font, .kern: Typography.wordmarkKerning, .foregroundColor: NSColor.white
                ])
                layoutLayers()
            }
        }
        let previous = hover.style
        updateHover(input)
        if hover.style == .moving {
            if paletteChanged && previous == .moving { startFlow() }
            steer(animated: previous == .moving)
        }
    }

    override func layoutLayers() {
        ink.frame = bounds
        colour.frame = bounds
        gradient.frame = bounds
        gleam.frame = bounds
        let height = (letters.string as? NSAttributedString)?.size().height ?? bounds.height
        letters.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        letters.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        LayerLoop.still { letters.contentsScale = window?.backingScaleFactor ?? 2 }
    }

    override func hoverChanged(from previous: BrandHover.Style) {
        let opacity = colour.presentation()?.opacity ?? colour.opacity
        let heldColours = gradient.presentation()?.colors ?? gradient.colors
        let start = gradient.presentation()?.startPoint ?? gradient.startPoint
        let end = gradient.presentation()?.endPoint ?? gradient.endPoint
        colour.removeAllAnimations()
        gradient.removeAllAnimations()
        gleam.removeAllAnimations()
        LayerLoop.still {
            colour.opacity = hover.style == .rest ? 0 : 1
            gradient.colors = hover.style == .rest ? heldColours : colours + [colours[0]]
            gradient.startPoint = start
            gradient.endPoint = end
        }
        switch hover.style {
        case .moving:
            steer(animated: false)
            startFlow()
            let sweep = CAAnimationGroup()
            let travel = CABasicAnimation(keyPath: "position.x")
            travel.fromValue = -bounds.width
            travel.toValue = bounds.width * 2
            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values = [0, 0.88, 0.88, 0]
            flash.keyTimes = [0, 0.15, 0.65, 1]
            for animation in [travel, flash] { animation.duration = Motion.brandGleamDuration }
            sweep.animations = [travel, flash]
            sweep.duration = Motion.brandGleamDuration
            sweep.timingFunction = Motion.drawCurve
            gleam.add(sweep, forKey: "entry")
            fade(from: opacity, duration: Motion.hoverDuration)
        case .still:
            steer(animated: false)
        case .rest:
            if hover.input.visible && !hover.input.reducedMotion && previous == .moving {
                fade(from: opacity, duration: Motion.leaveDuration)
            }
        }
    }

    override func stop() {
        super.stop()
        colour.removeAllAnimations()
        gradient.removeAllAnimations()
        gleam.removeAllAnimations()
        LayerLoop.still { colour.opacity = 0 }
    }

    private func startFlow() {
        let flow = CAKeyframeAnimation(keyPath: "colors")
        flow.values = (0...3).map { offset in (0...3).map { colours[($0 + offset) % colours.count] } }
        flow.duration = Motion.wordmarkPeriod
        flow.calculationMode = .linear
        let loop = LayerLoop.repeating(flow, period: Motion.wordmarkPeriod)
        loop.timeOffset = 0
        gradient.add(loop, forKey: "flow")
    }

    private func steer(animated: Bool) {
        let point = hover.style == .moving ? pointer : .zero
        let angle = (105 + min(1, max(-1, point.x)) * 24 + min(1, max(-1, point.y)) * 12) * .pi / 180
        let dx = sin(angle) / 2
        let dy = -cos(angle) / 2
        let start = CGPoint(x: 0.5 - dx, y: 0.5 - dy)
        let end = CGPoint(x: 0.5 + dx, y: 0.5 + dy)
        guard start != gradient.startPoint || end != gradient.endPoint else { return }
        let oldStart = gradient.presentation()?.startPoint ?? gradient.startPoint
        let oldEnd = gradient.presentation()?.endPoint ?? gradient.endPoint
        LayerLoop.still {
            gradient.startPoint = start
            gradient.endPoint = end
        }
        if animated {
            for (key, from, to) in [("startPoint", oldStart, start), ("endPoint", oldEnd, end)] {
                let follow = CABasicAnimation(keyPath: key)
                follow.fromValue = from
                follow.toValue = to
                follow.duration = Motion.hoverDuration
                follow.timingFunction = CAMediaTimingFunction(name: .easeOut)
                gradient.add(follow, forKey: key)
            }
        }
    }

    private func fade(from opacity: Float, duration: TimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = colour.opacity
        fade.duration = duration
        colour.add(fade, forKey: "fade")
    }
}
