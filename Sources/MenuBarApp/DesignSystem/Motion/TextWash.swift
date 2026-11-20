import AppKit
import QuartzCore

// A short wash of colour over words that have just been put into a text view, fading as
// it goes, so words that land in the middle of a sentence show where they went. Core
// Animation plays it, so the text is not drawn again while it fades, and it never takes
// a click. Callers leave it out under Reduce Motion: the words are simply there.
@MainActor
enum TextWash {
    static func play(over range: NSRange, in textView: NSTextView, colour: NSColor) {
        clear(in: textView)
        guard range.length > 0, NSMaxRange(range) <= (textView.string as NSString).length,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let origin = textView.textContainerOrigin
        // One mark per line, for words that wrap.
        var lines: [NSRect] = []
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                              withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                              in: container) { rect, _ in lines.append(rect) }
        for line in lines {
            let mark = TextWashView(frame: line.offsetBy(dx: origin.x, dy: origin.y)
                .insetBy(dx: -Space.xxs, dy: 0))
            textView.addSubview(mark)
            mark.fade(colour)
        }
    }

    static func clear(in view: NSView) {
        for mark in view.subviews where mark is TextWashView {
            mark.removeFromSuperview()
        }
    }
}

private final class TextWashView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // A little stronger in dark mode, where the same share of the accent sinks into the
    // field behind it.
    func fade(_ colour: NSColor) {
        guard let layer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var fill = colour.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = colour.withAlphaComponent(dark ? 0.24 : 0.2).cgColor
        }
        LayerLoop.still {
            layer.backgroundColor = fill
            layer.cornerRadius = Radius.tag
            layer.opacity = 0
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Motion.washDuration
        fade.timingFunction = Motion.drawCurve
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        layer.add(fade, forKey: "wash")
        CATransaction.commit()
    }
}
