import AppKit
import SwiftUI

// A one-line field for text the machine reads, where some of the words mean something
// and are tinted to say so, such as the {{property}} and :name parts of an address. It
// stays plain text to edit: the tint is painted over what is typed and is never part of
// the value. Return submits, Tab moves on, and a line break that is pasted in is dropped.
struct TintedLineField: NSViewRepresentable {
    struct Mark: Equatable {
        let range: NSRange
        let ink: NSColor
        // A wash behind the words, in this colour.
        var wash: NSColor? = nil
        // A word that will not work as written, underlined the way a misspelling is.
        var problem = false
    }

    @Binding var text: String
    var placeholder = ""
    var size: CGFloat = Typography.Size.detail
    var marks: [Mark] = []
    // One stretch to light up for a moment, such as the :name a hovered row belongs to.
    var lit: NSRange? = nil
    var label = ""
    var onFocusChange: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    static let washOpacity: CGFloat = 0.12
    static let litOpacity: CGFloat = 0.34

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> LineScrollView {
        let textView = LineTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isFieldEditor = true
        textView.turnOffProseHelpers()
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.maximumNumberOfLines = 1
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.insertionPointColor = .labelColor
        textView.font = context.coordinator.font
        textView.string = text
        textView.onFocusChange = { [coordinator = context.coordinator] focused in
            coordinator.parent.onFocusChange(focused)
        }
        textView.onAppearanceChange = { [coordinator = context.coordinator] in
            coordinator.paint()
        }
        context.coordinator.textView = textView

        let scroll = LineScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: LineScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.string != text, !textView.hasMarkedText() {
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(label)
        coordinator.paint()
        textView.light(lit, reduceMotion: context.environment.accessibilityReduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LineScrollView, context: Context) -> CGSize? {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let height = ceil(NSLayoutManager().defaultLineHeight(for: font))
        return CGSize(width: proposal.width ?? 200, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TintedLineField
        weak var textView: LineTextView?

        init(_ parent: TintedLineField) { self.parent = parent }

        var font: NSFont { .monospacedSystemFont(ofSize: parent.size, weight: .regular) }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            textView.needsDisplay = true
            if parent.text != textView.string { parent.text = textView.string }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
                      replacementString: String?) -> Bool {
            guard let replacementString, replacementString.contains(where: \.isNewline) else { return true }
            let oneLine = replacementString.components(separatedBy: .newlines).joined()
            textView.insertText(oneLine, replacementRange: range)
            return false
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onSubmit()
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(textView)
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(textView)
            // Escape arrives as cancelOperation:, which a text view turns into complete:
            // on the way, so both spellings are taken.
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }

        // Lays the tint over the text as it stands. The words are painted in whichever
        // appearance the view is in, since a colour with its strength changed is fixed
        // at the moment it is made.
        func paint() {
            guard let textView, let storage = textView.textStorage, !textView.hasMarkedText() else { return }
            let font = font
            let marks = parent.marks
            textView.effectiveAppearance.performAsCurrentDrawingAppearance {
                let whole = NSRange(location: 0, length: storage.length)
                let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
                storage.beginEditing()
                storage.setAttributes(base, range: whole)
                for mark in marks where NSMaxRange(mark.range) <= storage.length {
                    storage.addAttribute(.foregroundColor, value: mark.ink, range: mark.range)
                    if let wash = mark.wash {
                        storage.addAttribute(.backgroundColor,
                                             value: wash.withAlphaComponent(TintedLineField.washOpacity),
                                             range: mark.range)
                    }
                    if mark.problem {
                        storage.addAttribute(.underlineStyle,
                                             value: NSUnderlineStyle.patternDot.union(.single).rawValue,
                                             range: mark.range)
                        storage.addAttribute(.underlineColor, value: mark.ink, range: mark.range)
                    }
                }
                storage.endEditing()
                textView.typingAttributes = base
            }
        }
    }
}

// Keeps the text at least as wide as the field, so a click anywhere on the line lands in
// the text and not on empty ground beside it.
final class LineScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        let room = contentSize
        if textView.minSize != room {
            textView.minSize = room
            textView.sizeToFit()
        }
    }

    // The line is too short to scroll up or down, so a vertical scroll belongs to whatever
    // the field sits in.
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

final class LineTextView: NSTextView {
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }
    var onFocusChange: (Bool) -> Void = { _ in }
    var onAppearanceChange: () -> Void = {}
    private var litMark: NSView?
    private var litRange: NSRange?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange(false) }
        return resigned
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font else { return }
        NSAttributedString(string: placeholder, attributes: [
            .font: font, .foregroundColor: NSColor.tertiaryLabelColor
        ]).draw(at: textContainerOrigin)
    }

    // Lights one stretch of the line and lets the last one go, each on the hover curve.
    func light(_ range: NSRange?, reduceMotion: Bool) {
        guard range != litRange else { return }
        litRange = range
        let duration = reduceMotion ? 0 : Motion.hoverDuration
        if let old = litMark {
            litMark = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                old.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { old.removeFromSuperview() }
            }
        }
        guard let range, NSMaxRange(range) <= (string as NSString).length,
              let layoutManager, let textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            .insetBy(dx: -Space.xxs, dy: 0)
        let mark = LitMark(frame: rect)
        mark.alphaValue = 0
        addSubview(mark)
        litMark = mark
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            mark.animator().alphaValue = 1
        }
    }
}

private final class LitMark: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Radius.tag
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = NSColor(Theme.attention)
            .withAlphaComponent(TintedLineField.litOpacity).cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}
