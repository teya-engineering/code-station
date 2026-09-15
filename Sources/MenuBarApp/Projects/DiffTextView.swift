import AppKit
import SwiftUI

// The diff itself, drawn by AppKit. SwiftUI's selectable Text only covers what is
// laid out on screen, so Select All in a tall diff would copy the visible lines and
// drop the rest. An NSTextView owns the whole document, which makes Cmd+A, copy,
// and drag selection behave like they do in an editor.
struct DiffTextView: NSViewRepresentable {
    // Where the pane looks once the text has changed.
    enum Scroll {
        // A diff that was just opened starts at the top.
        case top
        // The same diff showing more of itself, below what is on screen: the rows
        // already up there keep their place.
        case hold
        // The same diff showing more of itself, above what is on screen: the view moves
        // down by as much as the document grew, so the pressed row stays under the
        // pointer and the new lines fill in above it.
        case follow
    }

    let text: NSAttributedString
    var scroll: Scroll = .top
    // The gap row a press landed on, named by DiffGap.key, and the end of it to open.
    var onExpand: ((String, DiffExpandDirection) -> Void)?

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
        textView.onExpand = onExpand
        // The string is built once per loaded diff, so identity is enough to tell the
        // same document from a newly opened file.
        guard context.coordinator.shown !== text else { return }
        context.coordinator.shown = text
        let heightBefore = textView.frame.height
        let origin = scrollView.contentView.bounds.origin
        textView.textStorage?.setAttributedString(text)
        textView.sizeToFit()
        switch scroll {
        case .top:
            scrollView.contentView.scroll(to: .zero)
        case .hold:
            scrollView.contentView.scroll(to: origin)
        case .follow:
            let grew = textView.frame.height - heightBefore
            scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: max(0, origin.y + grew)))
        }
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
    var onExpand: ((String, DiffExpandDirection) -> Void)?
    // The gap row under the pointer, which is drawn a shade stronger so it reads as
    // something to press.
    private var hovered: String?
    private var hoverTracking: NSTrackingArea?

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

    // MARK: - Opening a gap

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseDown(with event: NSEvent) {
        // A held modifier means the click is about the selection, not the row.
        let plain = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        if plain, let onExpand, let target = target(at: event), let direction = target.direction {
            onExpand(target.key, direction)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let target = target(at: event)
        if target?.direction != nil { NSCursor.pointingHand.set() }
        guard target?.key != hovered else { return }
        hovered = target?.key
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard hovered != nil else { return }
        hovered = nil
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        if target(at: event)?.direction != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    private func target(at event: NSEvent) -> DiffGapHit? {
        guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        return DiffGapHit.at(NSPoint(x: point.x - origin.x, y: point.y - origin.y),
                             layoutManager: layoutManager, container: textContainer,
                             storage: storage)
    }

    // A hovered row sits a shade stronger than its usual band. Mixing towards the text
    // colour works in either appearance: it darkens on a light pane and lightens on a
    // dark one.
    private func hoverFill(_ band: NSColor) -> NSColor {
        guard let base = band.usingColorSpace(.sRGB),
              let ink = NSColor.labelColor.usingColorSpace(.sRGB),
              let mixed = base.blended(withFraction: 0.12, of: ink) else { return band }
        return mixed
    }

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
            let isHovered = self.hovered != nil
                && storage.attribute(.diffGap, at: index, effectiveRange: nil) as? String == self.hovered
            (isHovered ? self.hoverFill(band) : band).setFill()
            NSRect(x: 0, y: fragment.minY + origin.y,
                   width: self.bounds.width, height: fragment.height).fill()
        }
    }
}

// What a point in a laid out diff lands on: the gap row it is over, and the control
// there if it is on one. A point anywhere along the row names the row, so the band can
// light up as the pointer arrives, but only the characters of a control open anything.
struct DiffGapHit: Equatable {
    var key: String
    var direction: DiffExpandDirection?

    // The point is in text container coordinates.
    static func at(_ point: NSPoint, layoutManager: NSLayoutManager,
                   container: NSTextContainer, storage: NSTextStorage) -> DiffGapHit? {
        guard storage.length > 0, point.x >= 0, point.y >= 0 else { return nil }
        let index = layoutManager.characterIndex(for: point, in: container,
                                                 fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < storage.length else { return nil }
        // The lookup above snaps to the nearest row and to the nearest character on it,
        // so a point past the text would answer with whatever is closest. Only a point
        // inside the row, and on a character of it, is on that character.
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard point.y >= fragment.minY, point.y < fragment.maxY else { return nil }
        guard let key = storage.attribute(.diffGap, at: index, effectiveRange: nil) as? String
        else { return nil }
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        guard point.x < used.maxX else { return DiffGapHit(key: key) }
        let action = storage.attribute(.diffGapAction, at: index, effectiveRange: nil) as? String
        return DiffGapHit(key: key, direction: action.flatMap(DiffExpandDirection.init(rawValue:)))
    }
}

// One attributed string for a whole diff.
@MainActor
enum DiffText {
    static func attributed(_ lines: [DiffLine],
                           language: CodeLanguage? = nil,
                           scale: CGFloat = 1) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11 * scale, weight: .regular)
        // Colouring is for a diff a person reads; a huge one is scrolled, not read, and
        // plain text is much cheaper to build.
        let size = lines.reduce(0) { $0 + $1.text.utf8.count }
        let withinLimit = size <= CodeHighlight.sizeLimit
        // A single-file diff names its language up front. A commit diff spans many
        // files instead, and each section heading names the file the following lines
        // belong to, so the language follows the headings.
        var activeLanguage = withinLimit ? language : nil
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if line.kind == .section {
                activeLanguage = withinLimit
                    ? CodeLanguage(fileExtension: (line.text as NSString).pathExtension)
                    : nil
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color(line.kind)
            ]
            if let band = band(line.kind) {
                attributes[.diffRowBackground] = band
            }
            if let gap = line.gap {
                attributes[.diffGap] = gap.key
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
            if let gap = line.gap {
                result.append(controls(gap, attributes: attributes))
            } else if let activeLanguage, isCode {
                result.append(codeLine(line, language: activeLanguage, attributes: attributes))
            } else {
                result.append(NSAttributedString(string: line.text, attributes: attributes))
            }
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        return result
    }

    // What a gap row offers. A gap too long to open in one go opens from either end, so
    // it carries an arrow for each: down carries on from the code above the row, up reads
    // back from the code below it. The count in the middle always opens the lot, and a
    // gap short enough to open whole is nothing but that count.
    private static func controls(_ gap: DiffGap,
                                 attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var plain = attributes
        plain[.foregroundColor] = NSColor.tertiaryLabelColor
        let result = NSMutableAttributedString()
        func add(_ text: String, _ direction: DiffExpandDirection? = nil) {
            var run = plain
            if let direction { run[.diffGapAction] = direction.rawValue }
            result.append(NSAttributedString(string: text, attributes: run))
        }

        guard let count = gap.count else {
            add(" ↓ ", .down)
            add("the rest of the file", .all)
            return result
        }
        if count > GitInspector.gapExpandWhole {
            add(" ↑ ", .up)
            add(counted(count, "line"), .all)
            add(" ↓ ", .down)
        } else {
            add(" " + counted(count, "line"), .all)
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
        case .hunk, .meta, .section, .gap: .secondaryLabelColor
        case .context: .labelColor
        }
    }

    private static func band(_ kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .addition: NSColor(Theme.dotOn).withAlphaComponent(0.14)
        case .deletion: NSColor(Theme.deletion).withAlphaComponent(0.10)
        case .hunk, .section, .gap: NSColor(Theme.field)
        case .meta, .context: nil
        }
    }
}

extension NSAttributedString.Key {
    // The colour of the band behind a diff row. Painted by the view rather than through
    // .backgroundColor, which stops at the last glyph instead of the pane's edge.
    static let diffRowBackground = NSAttributedString.Key("codeStationDiffRowBackground")

    // Marks a row standing in for unchanged lines, named by DiffGap.key.
    static let diffGap = NSAttributedString.Key("codeStationDiffGap")

    // Marks one control on such a row, holding the DiffExpandDirection it opens. Only
    // characters carrying it answer a press.
    static let diffGapAction = NSAttributedString.Key("codeStationDiffGapAction")
}
