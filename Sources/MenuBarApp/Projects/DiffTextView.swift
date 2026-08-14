import AppKit
import SwiftUI

// The diff itself, drawn by AppKit. SwiftUI's selectable Text only covers what is
// laid out on screen, so Select All in a tall diff would copy the visible lines and
// drop the rest. An NSTextView owns the whole document, which makes Cmd+A, copy,
// and drag selection behave like they do in an editor.
struct DiffTextView: NSViewRepresentable {
    let text: NSAttributedString

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // The text system is built by hand so the view starts on TextKit 1:
        // drawBackground below walks the layout manager, and asking a TextKit 2
        // view for one mid-life throws its layout away.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = DiffDocumentView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 6)
        // Lines keep their length and the pane scrolls sideways instead of wrapping.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = []

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? DiffDocumentView else { return }
        // The string is built once per loaded diff, so identity is enough to tell the
        // same document from a newly opened file.
        guard context.coordinator.shown !== text else { return }
        context.coordinator.shown = text
        textView.textStorage?.setAttributedString(text)
        textView.sizeToFit()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    final class Coordinator {
        var shown: NSAttributedString?
    }
}

// NSTextView paints the background colour attribute behind the glyphs only. A diff row
// wants its band to run the full width of the pane, so the colour travels in a custom
// attribute and is painted here across the whole line fragment.
private final class DiffDocumentView: NSTextView {

    // Grow with the text, but never sit narrower than the pane, so the bands reach the
    // right edge even when every line is short.
    override func setFrameSize(_ newSize: NSSize) {
        let clipWidth = enclosingScrollView?.contentSize.width ?? 0
        super.setFrameSize(NSSize(width: max(newSize.width, clipWidth), height: newSize.height))
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification,
                                                  object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(paneResized),
                                               name: NSView.frameDidChangeNotification, object: clip)
    }

    // sizeToFit measures from the layout again, so a shrunk pane also lets go of any
    // width the text never needed.
    @objc private func paneResized() { sizeToFit() }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { return }
        let origin = textContainerOrigin
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y),
                                              in: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
            let index = layoutManager.characterIndexForGlyph(at: lineGlyphs.location)
            guard index < storage.length,
                  let band = storage.attribute(.diffRowBackground, at: index,
                                               effectiveRange: nil) as? NSColor else { return }
            band.setFill()
            NSRect(x: 0, y: fragment.minY + origin.y,
                   width: self.bounds.width, height: fragment.height).fill()
        }
    }
}

// One attributed string for a whole diff.
@MainActor
enum DiffText {
    static func attributed(_ lines: [DiffLine],
                           language: CodeLanguage? = nil) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        // Colouring is for a diff a person reads; a huge one is scrolled, not read, and
        // plain text is much cheaper to build.
        let size = lines.reduce(0) { $0 + $1.text.utf8.count }
        let language = size <= CodeHighlight.sizeLimit ? language : nil
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color(line.kind)
            ]
            if let band = band(line.kind) {
                attributes[.diffRowBackground] = band
            }
            if line.kind == .section {
                // A little air around a section title so one file's diff reads as
                // separate from the next.
                let style = NSMutableParagraphStyle()
                style.paragraphSpacingBefore = 4
                style.paragraphSpacing = 4
                attributes[.paragraphStyle] = style
            }
            let isCode = line.kind == .addition || line.kind == .deletion || line.kind == .context
            if let language, isCode {
                result.append(codeLine(line, language: language, attributes: attributes))
            } else {
                result.append(NSAttributedString(string: line.text, attributes: attributes))
            }
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        return result
    }

    // A changed line with its code in syntax colours. The sign keeps the diff colour and
    // the band runs behind the row, so added and removed still read at a glance while the
    // code itself reads like code. Each line is scanned on its own: a diff can start in
    // the middle of anything, so carrying string or comment state between its lines
    // would guess wrong as often as right.
    private static func codeLine(_ line: DiffLine, language: CodeLanguage,
                                 attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var code = Substring(line.text)
        if line.kind != .context, let sign = code.first {
            result.append(NSAttributedString(string: String(sign), attributes: attributes))
            code = code.dropFirst()
        }
        var plain = attributes
        plain[.foregroundColor] = NSColor.labelColor
        var state = CodeHighlight.State.normal
        let tokens = CodeHighlight.tokens(in: code, language: language, state: &state)
        var i = code.startIndex
        for token in tokens {
            if i < token.range.lowerBound {
                result.append(NSAttributedString(string: String(code[i..<token.range.lowerBound]),
                                                 attributes: plain))
            }
            var run = plain
            run[.foregroundColor] = CodeStyle.nsColor(for: token.kind)
            result.append(NSAttributedString(string: String(code[token.range]), attributes: run))
            i = token.range.upperBound
        }
        if i < code.endIndex {
            result.append(NSAttributedString(string: String(code[i...]), attributes: plain))
        }
        return result
    }

    private static func color(_ kind: DiffLine.Kind) -> NSColor {
        switch kind {
        case .addition: NSColor(Theme.addition)
        case .deletion: NSColor(Theme.deletion)
        case .hunk, .meta, .section: .secondaryLabelColor
        case .context: .labelColor
        }
    }

    private static func band(_ kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .addition: NSColor(Theme.dotOn).withAlphaComponent(0.14)
        case .deletion: NSColor(Theme.deletion).withAlphaComponent(0.10)
        case .hunk, .section: NSColor(Theme.field)
        case .meta, .context: nil
        }
    }
}

extension NSAttributedString.Key {
    // The colour of the band behind a diff row. Painted by the view rather than through
    // .backgroundColor, which stops at the last glyph instead of the pane's edge.
    static let diffRowBackground = NSAttributedString.Key("conductorDiffRowBackground")
}
