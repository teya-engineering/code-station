import AppKit
import QuartzCore
import SwiftUI

struct BrandWordmark: View {
    @Environment(\.textScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = Typography.Size.wordmark * max(1, textScale)
        Text("Code Station")
            .font(.logo(size))
            .kerning(Typography.wordmarkKerning)
            .foregroundStyle(.clear)
            .overlay {
                WordmarkLayer(font: .logo(size), moving: !reduceMotion)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct WordmarkLayer: NSViewRepresentable {
    let font: NSFont
    let moving: Bool

    func makeNSView(context: Context) -> BrandWordmarkView { BrandWordmarkView() }

    func updateNSView(_ view: BrandWordmarkView, context: Context) {
        view.update(font: font,
                    colours: Theme.wordmarkColours.map { $0.resolve(in: context.environment).cgColor },
                    moving: moving)
    }

    static func dismantleNSView(_ view: BrandWordmarkView, coordinator: ()) {
        view.stop()
    }
}

// Only the colour moves. The text mask stays sharp and the surrounding header never
// needs a frame clock or a fresh layout for the animation.
final class BrandWordmarkView: LoopLayerView {
    private let ink = CALayer()
    private let gradient = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let letters = CATextLayer()
    private var font: NSFont?
    private var moving = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(ink)
        ink.addSublayer(gradient)
        ink.addSublayer(glow)
        ink.mask = letters
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        gradient.locations = [0, 0.3, 0.6, 1]
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.locations = [0, 1]
        setAccessibilityElement(false)
    }

    func update(font: NSFont, colours: [CGColor], moving: Bool) {
        LayerLoop.still {
            gradient.colors = colours + [colours[0]]
            glow.colors = [colours[1], colours[1].copy(alpha: 0)!]
            if font != self.font {
                self.font = font
                letters.string = NSAttributedString(string: "Code Station", attributes: [
                    .font: font, .kern: Typography.wordmarkKerning, .foregroundColor: NSColor.white
                ])
                layoutLayers()
            }
        }
        guard moving != self.moving else { return }
        self.moving = moving
        restartLoops()
    }

    override func layoutLayers() {
        ink.frame = bounds
        gradient.frame = bounds.insetBy(dx: -bounds.width * 0.3, dy: -bounds.height)
        glow.frame = bounds.insetBy(dx: -bounds.width * 0.1, dy: -bounds.height * 2)
        let height = (letters.string as? NSAttributedString)?.size().height ?? bounds.height
        letters.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        letters.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        LayerLoop.still { letters.contentsScale = window?.backingScaleFactor ?? 2 }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stop()
        super.viewWillMove(toWindow: newWindow)
    }

    override func restartLoops() {
        stop()
        guard moving, window != nil else { return }
        let period = Motion.wordmarkPeriod
        let flow = CAAnimationGroup()
        flow.animations = [
            LayerLoop.swing("startPoint", from: CGPoint(x: 0, y: 1), to: CGPoint(x: 0.3, y: 0), period: period),
            LayerLoop.swing("endPoint", from: CGPoint(x: 1, y: 0), to: CGPoint(x: 0.8, y: 1), period: period)
        ]
        flow.duration = period
        gradient.add(LayerLoop.repeating(flow, period: period), forKey: "flow")
        let drift = CAAnimationGroup()
        drift.animations = [
            LayerLoop.swing("startPoint", from: CGPoint(x: 0.1, y: 0.3), to: CGPoint(x: 0.9, y: 0.7), period: period),
            LayerLoop.swing("endPoint", from: CGPoint(x: 0.6, y: 0.8), to: CGPoint(x: 1.4, y: 1.2), period: period)
        ]
        drift.duration = period
        glow.add(LayerLoop.repeating(drift, period: period), forKey: "drift")
    }

    func stop() {
        gradient.removeAllAnimations()
        glow.removeAllAnimations()
    }
}
