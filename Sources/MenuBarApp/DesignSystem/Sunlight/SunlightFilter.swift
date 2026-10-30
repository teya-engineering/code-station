import AppKit
import QuartzCore

// Warms a whole window the way f.lux warms a whole display. A sheet of the light's
// colour lies over the window and multiplies into what is under it, so every channel is
// scaled by the light's gain: white under a 3400K lamp becomes the lamp's colour and
// black stays black. Core Animation does the blend, so nothing in the view tree is laid
// out or redrawn when the sun moves, and every pixel follows: terminal, images, avatars.
@MainActor
final class SunlightFilter {
    private let sheet = Sheet()
    private(set) var tint = SunlightTint.neutral

    // Lays the sheet over the whole window, title bar included. It is added beside the
    // content view rather than inside it, so the content's own layout never sees it. A
    // window with no frame of its own, such as one not yet shown, cannot be dressed.
    init?(window: NSWindow) {
        guard let content = window.contentView, let frame = content.superview else { return nil }
        sheet.frame = frame.bounds
        sheet.autoresizingMask = [.width, .height]
        frame.addSubview(sheet, positioned: .above, relativeTo: nil)
    }

    // Moves the window to a new tint. Animated, the change is a cross-fade the eye cannot
    // see move; otherwise it lands at once, which is what Reduce Motion asks for.
    func set(_ tint: SunlightTint, duration: TimeInterval) {
        guard tint != self.tint, let layer = sheet.layer else { return }
        let from = self.tint
        self.tint = tint
        if duration > 0 {
            let animation = CABasicAnimation(keyPath: "backgroundColor")
            animation.fromValue = Self.colour(from)
            animation.toValue = Self.colour(tint)
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: "sunlight")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = Self.colour(tint)
        CATransaction.commit()
    }

    func remove() {
        sheet.removeFromSuperview()
    }

    private static func colour(_ tint: SunlightTint) -> CGColor {
        CGColor(srgbRed: tint.red, green: tint.green, blue: tint.blue, alpha: 1)
    }

    // The sheet itself: never hit by the pointer, and blended by multiplication.
    private final class Sheet: NSView {
        init() {
            super.init(frame: .zero)
            layerUsesCoreImageFilters = true
            wantsLayer = true
            layer?.compositingFilter = CIFilter(name: "CIMultiplyBlendMode")
            layer?.backgroundColor = colour(.neutral)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }

        private func colour(_ tint: SunlightTint) -> CGColor {
            CGColor(srgbRed: tint.red, green: tint.green, blue: tint.blue, alpha: 1)
        }
    }
}
