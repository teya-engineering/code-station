import AppKit
import SwiftUI

// Character offsets where each line starts, so the gutter can name a line and the
// highlighter can find one without counting newlines from the top of the file each time.
// Offsets are UTF-16, which is the unit the text view counts in.
struct LineIndex: Equatable {
    private var starts: [Int]

    init(_ text: NSString) {
        var starts = [0]
        var from = 0
        while from < text.length {
            let found = text.range(of: "\n", options: .literal,
                                   range: NSRange(location: from, length: text.length - from))
            guard found.location != NSNotFound else { break }
            from = found.location + 1
            starts.append(from)
        }
        self.starts = starts
    }

    // A file that ends in a newline has an empty last line. The text view draws it, so it
    // is counted and numbered here too.
    var count: Int { starts.count }

    func start(of line: Int) -> Int { starts[min(max(line, 0), starts.count - 1)] }

    // The line an offset falls on, clamped at both ends so a stale offset cannot trap.
    func line(at offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    // One whole line including its newline, which is the unit the highlighter works in: a
    // token can only be read from the start of the line that holds it.
    func range(of line: Int, length: Int) -> NSRange {
        guard line >= 0, line < count else { return NSRange(location: length, length: 0) }
        let from = start(of: line)
        let to = line + 1 < count ? start(of: line + 1) : length
        return NSRange(location: from, length: max(0, min(to, length) - from))
    }
}

// The Explorer's file pane: one text view, always editable, with line numbers beside it
// and syntax colour on whatever is on screen.
//
// SwiftUI can do either half of that but not both at once. A Text draws colour and can sit
// next to a gutter but cannot be typed into; a TextEditor can be typed into but draws
// neither. AppKit provides both in one pane.
struct CodeEditorView: NSViewRepresentable {
    // Which file is in the pane. A change swaps the document outright: new text, scrolled
    // back to the top, nothing treated as something the user typed.
    let documentID: String
    @Binding var text: String
    let language: CodeLanguage?
    let matches: [NSRange]
    let currentMatch: Int?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CodeEditorPane {
        context.coordinator.makePane()
    }

    func updateNSView(_ pane: CodeEditorPane, context: Context) {
        context.coordinator.apply(self)
    }

    static func dismantleNSView(_ pane: CodeEditorPane, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        private var parent: CodeEditorView
        private weak var textView: CodeDocumentView?
        private weak var gutter: LineNumberGutter?

        private var documentID: String?
        private var language: CodeLanguage?
        private var lineIndex = LineIndex("")
        private var matches: [NSRange] = []
        private var currentMatch: Int?
        // Which match the pane has already been scrolled to. Following the match's range
        // instead would drag the pane back to it on every keystroke before it, since
        // typing above a match moves it.
        private var revealed: Int?

        // The state each line starts in, read as far down the file as the highlighter has
        // got. An edit drops everything from that line on, so the tail is read again only
        // when it is scrolled back into view.
        private var states: [CodeHighlight.State] = [.normal]

        // Where the earliest change since the last pass landed. The caret is not enough:
        // a paste or an undo moves it to the end of what changed.
        private var changedFrom: Int?

        // Colouring writes attributes, which comes back round as another change to react
        // to. One pass at a time keeps that from feeding itself.
        private var colouring = false

        // Whether a viewport pass is already waiting to run. However many notifications
        // arrive before it does, they all want the same thing, so one pass covers them.
        private var colourQueued = false

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        // The whole pane, built here rather than in makeNSView so it can be stood up
        // without a SwiftUI context behind it.
        func makePane() -> CodeEditorPane {
            // The text system is built by hand so the view starts on TextKit 1: the gutter
            // walks the layout manager, and asking a TextKit 2 view for one mid-life
            // throws its layout away.
            let storage = NSTextStorage()
            storage.delegate = self
            let layoutManager = NSLayoutManager()
            // Only what is on screen is laid out. Without this a long file is measured end
            // to end before its first line can appear.
            layoutManager.allowsNonContiguousLayout = true
            storage.addLayoutManager(layoutManager)
            let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                         height: CGFloat.greatestFiniteMagnitude))
            container.widthTracksTextView = false
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)

            let textView = CodeDocumentView(frame: .zero, textContainer: container)
            textView.delegate = self
            textView.isEditable = true
            textView.isRichText = false
            textView.importsGraphics = false
            textView.allowsUndo = true
            textView.drawsBackground = false
            textView.insertionPointColor = NSColor(Theme.accent)
            textView.textContainerInset = NSSize(width: 10, height: 8)
            textView.typingAttributes = CodeEditorStyle.base
            // None of the prose helpers belong in code: they rewrite quotes and dashes as
            // you type, and the rewrite is what would land in the file on save.
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.isGrammarCheckingEnabled = false
            // Height follows the text on its own. Width does not: a non-wrapping view
            // would have to lay the whole file out to find its widest line, so it is
            // measured instead and set from there.
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
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

            let gutter = LineNumberGutter(textView: textView)
            textView.textContainerInset.width = gutter.thickness + 10
            let pane = CodeEditorPane(scrollView: scrollView, gutter: gutter)

            self.textView = textView
            self.gutter = gutter

            // The gutter and the colouring both follow the viewport, so both are redone
            // whenever the pane scrolls under the text or changes size around it. Without
            // the second, a pane that is laid out after its text arrives never colours
            // more than the sliver it was first measured at.
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(viewportMoved), name: name, object: clip)
            }
            return pane
        }

        // MARK: - From SwiftUI

        func apply(_ parent: CodeEditorView) {
            self.parent = parent
            guard let textView else { return }

            if documentID != parent.documentID {
                documentID = parent.documentID
                language = parent.language
                load(parent.text, into: textView)
                textView.scrollToTop()
            } else if textView.string != parent.text {
                // The pane's own text moved under the view, which means a revert. The same
                // file is still open, so it is left where the reader had it.
                load(parent.text, into: textView)
            } else if language != parent.language {
                language = parent.language
                states = [.normal]
            }

            matches = parent.matches
            currentMatch = parent.currentMatch
            if currentMatch != revealed {
                revealed = currentMatch
                if let index = currentMatch, matches.indices.contains(index) {
                    textView.scrollRangeToVisible(matches[index])
                }
            }
            colourViewport()
        }

        private func load(_ text: String, into textView: CodeDocumentView) {
            textView.string = text
            textView.typingAttributes = CodeEditorStyle.base
            // The one place the type and the spacing are set. Everything typed afterwards
            // arrives carrying them, so colouring never has to put them back.
            textView.textStorage?.setAttributes(
                CodeEditorStyle.base,
                range: NSRange(location: 0, length: (text as NSString).length))
            textView.undoManager?.removeAllActions()
            textView.setContentWidth(MonoMetrics.width(ofLongestIn: text))
            reindex(text)
            states = [.normal]
            changedFrom = nil
            revealed = nil
        }

        private func reindex(_ text: String) {
            lineIndex = LineIndex(text as NSString)
            gutter?.index = lineIndex
        }

        // MARK: - Typing

        func textStorage(_ storage: NSTextStorage, didProcessEditing edited: NSTextStorageEditActions,
                         range: NSRange, changeInLength delta: Int) {
            guard edited.contains(.editedCharacters) else { return }
            changedFrom = min(changedFrom ?? range.location, range.location)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let text = textView.string
            reindex(text)

            let line = lineIndex.line(at: changedFrom ?? 0)
            changedFrom = nil
            // The start of the line the change landed on is the last thing the highlighter
            // can still be sure of, so everything after it goes.
            states = Array(states.prefix(line + 1))

            // The pane only ever gets wider while a file is open. Shrinking it back would
            // mean measuring every line again on every keystroke to find the new longest.
            textView.growContentWidth(to: MonoMetrics.width(of: editedLine(of: textView)))
            parent.text = text
            colourViewport()
        }

        // The line the caret is on, which is the only one an edit can have made longer.
        private func editedLine(of textView: NSTextView) -> String {
            let text = textView.string as NSString
            let line = lineIndex.line(at: textView.selectedRange().location)
            return text.substring(with: lineIndex.range(of: line, length: text.length))
        }

        // AppKit posts the bounds change from inside its own layout pass, which is reading
        // the storage this would write to. Colouring on the next turn of the run loop keeps
        // the two apart: writing mid-pass leaves work behind that the pass then has to redo,
        // and it scrolls to keep up, which posts another bounds change and never settles.
        @objc func viewportMoved() {
            gutter?.needsDisplay = true
            guard !colourQueued else { return }
            colourQueued = true
            Task { @MainActor in
                self.colourQueued = false
                self.colourViewport()
            }
        }

        // MARK: - Colour

        // Only the lines on screen are coloured, and only when asked. A file is scrolled
        // far more often than it is edited, and a screenful is small enough to redo every
        // time rather than keep track of what was already done.
        private func colourViewport() {
            guard !colouring, let textView, let storage = textView.textStorage,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            colouring = true
            defer { colouring = false }

            let viewport = textView.visibleRect.insetBy(dx: 0, dy: -screenfulMargin)
            let glyphs = layoutManager.glyphRange(forBoundingRect: viewport, in: container)
            let characters = layoutManager.characterRange(forGlyphRange: glyphs,
                                                          actualGlyphRange: nil)
            let first = lineIndex.line(at: characters.location)
            let last = lineIndex.line(at: max(characters.location, NSMaxRange(characters) - 1))
            let range = NSRange(location: lineIndex.start(of: first),
                                length: NSMaxRange(lineIndex.range(of: last, length: storage.length))
                                    - lineIndex.start(of: first))
            guard range.length > 0 else { return }

            // Only the colours are rewritten. The type and the spacing are set once when the
            // file is loaded and left alone, because changing either is a layout change: it
            // moves the glyphs, which resizes the pane around them, which scrolls, which asks
            // for another pass. Colour on its own changes nothing the layout has to measure.
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: range)
            storage.addAttribute(.foregroundColor, value: CodeEditorStyle.plain, range: range)
            if let language { colour(first...last, language: language, in: storage) }
            highlightMatches(within: range, in: storage)
            storage.endEditing()
        }

        private func colour(_ lines: ClosedRange<Int>, language: CodeLanguage,
                            in storage: NSTextStorage) {
            let text = storage.string as NSString
            readStates(upTo: lines.upperBound, language: language, in: text)

            for line in lines where line < lineIndex.count {
                let lineRange = lineIndex.range(of: line, length: text.length)
                let code = text.substring(with: lineRange).withoutNewline
                guard code.utf8.count <= CodeHighlight.sizeLimit else { continue }
                var state = states[min(line, states.count - 1)]
                for token in CodeHighlight.tokens(in: code, language: language, state: &state) {
                    let offset = NSRange(token.range, in: code)
                    storage.addAttribute(
                        .foregroundColor,
                        value: CodeStyle.nsColor(for: token.kind),
                        range: NSRange(location: lineRange.location + offset.location,
                                       length: offset.length))
                }
            }
        }

        // Reading a line is what tells you the state the next one starts in, so getting to
        // a line the highlighter has not seen means reading everything between. Scrolling
        // down pays for one screenful at a time; jumping to the end of a long file pays
        // for the gap once and then picks up from there.
        private func readStates(upTo line: Int, language: CodeLanguage, in text: NSString) {
            while states.count <= line, states.count < lineIndex.count {
                let known = states.count - 1
                var state = states[known]
                let code = text.substring(with: lineIndex.range(of: known, length: text.length))
                    .withoutNewline
                if code.utf8.count <= CodeHighlight.sizeLimit {
                    _ = CodeHighlight.tokens(in: code, language: language, state: &state)
                }
                states.append(state)
            }
        }

        private func highlightMatches(within range: NSRange, in storage: NSTextStorage) {
            for (index, match) in matches.enumerated() {
                let visible = NSIntersectionRange(match, range)
                guard visible.length > 0 else { continue }
                storage.addAttribute(.backgroundColor,
                                     value: index == currentMatch
                                        ? CodeEditorStyle.currentMatch : CodeEditorStyle.match,
                                     range: visible)
            }
        }
    }
}

// Colouring reaches beyond the pane so a short scroll lands on lines that already have
// their colour, instead of flashing plain for a frame.
private let screenfulMargin: CGFloat = 400

private extension String {
    // The highlighter reads one line at a time, and the newline that ends it is not part
    // of the line.
    var withoutNewline: Substring {
        hasSuffix("\n") ? dropLast() : self[...]
    }
}

// The type and colours every line starts from, before the highlighter puts its tokens
// back on top.
@MainActor
enum CodeEditorStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let rulerFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    // The colour of anything the highlighter has no token for.
    static let plain = NSColor.labelColor

    static let base: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: plain,
        .paragraphStyle: paragraphStyle
    ]

    static let match = NSColor(Theme.secret).withAlphaComponent(0.24)
    static let currentMatch = NSColor(Theme.secret).withAlphaComponent(0.52)

    // A tab is four columns wide, which is how most of the code this app opens is written.
    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = 4 * font.maximumAdvancement.width
        style.lineBreakMode = .byClipping
        return style
    }()
}

// The document itself. Its width is set from measured text rather than from layout, and
// never falls below the pane, so a click to the right of a short line still lands on that
// line and the caret has somewhere to sit.
final class CodeDocumentView: NSTextView {
    private var contentWidth: CGFloat = 0

    func setContentWidth(_ width: CGFloat) {
        contentWidth = width
        setFrameSize(frame.size)
    }

    func growContentWidth(to width: CGFloat) {
        guard width > contentWidth else { return }
        setContentWidth(width)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let pane = enclosingScrollView?.contentSize.width ?? 0
        let wanted = contentWidth + textContainerInset.width * 2 + 4
        super.setFrameSize(NSSize(width: max(wanted, pane), height: newSize.height))
    }

    func scrollToTop() {
        guard let scrollView = enclosingScrollView else { return }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(paneResized),
                                               name: NSView.frameDidChangeNotification, object: clip)
    }

    // A widened pane has to reach the new edge; a narrowed one lets go of width the text
    // never needed.
    @objc private func paneResized() { setFrameSize(frame.size) }
}

// NSScrollView reserves parts of its surface for native rulers and scrollers. Keeping the
// gutter in a plain parent view avoids that machinery while still pinning it over the
// leading edge of the text.
final class CodeEditorPane: NSView {
    let scrollView: NSScrollView
    let gutter: LineNumberGutter

    init(scrollView: NSScrollView, gutter: LineNumberGutter) {
        self.scrollView = scrollView
        self.gutter = gutter
        super.init(frame: .zero)

        addSubview(scrollView)
        addSubview(gutter, positioned: .above, relativeTo: scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        gutter.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

// The line numbers sit above the scroll view rather than inside its document, so the
// gutter stays put when the pane is scrolled sideways.
final class LineNumberGutter: NSView {
    private weak var textView: NSTextView?

    private(set) var thickness: CGFloat = 30

    // Set by the pane whenever the document changes: the gutter cannot work out which line
    // a character belongs to on its own.
    var index = LineIndex("") {
        didSet {
            guard index != oldValue else { return }
            thickness = max(30, MonoMetrics.width(of: "\(index.count)",
                                                  font: CodeEditorStyle.rulerFont) + 16)
            invalidateIntrinsicContentSize()
            if let textView {
                var inset = textView.textContainerInset
                inset.width = thickness + 10
                textView.textContainerInset = inset
                textView.setFrameSize(textView.frame.size)
            }
            needsDisplay = true
        }
    }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: NSRect(x: 0, y: 0, width: thickness, height: 0))
        // A view is free to paint outside its own bounds, and this one fills the rect it is
        // handed. Left unclipped it covers the text, and everything else in the window with
        // it, on any redraw that asks for more than the gutter's own column.
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: thickness, height: NSView.noIntrinsicMetric)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // One number and where it goes. Which lines are showing is this view's own working
    // out, kept apart from the drawing so it can be checked without a screen.
    struct Label: Equatable {
        let number: Int
        let y: CGFloat
        let height: CGFloat
    }

    func visibleLabels() -> [Label] {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return [] }

        // The gutter and the text scroll together but are separate views, so every
        // fragment's position has to be brought back into this one's coordinates.
        let offset = convert(NSPoint.zero, from: textView).y + textView.textContainerInset.height
        // Layout is lazy, so the lines about to be numbered may not exist yet.
        layoutManager.ensureLayout(forBoundingRect: textView.visibleRect, in: container)
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)

        var labels: [Label] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let character = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let line = self.index.line(at: character)
            // Nothing wraps here, so a fragment that does not begin a line is a stray and
            // numbering it would repeat the number above.
            guard self.index.start(of: line) == character else { return }
            labels.append(Label(number: line + 1, y: offset + fragment.minY,
                                height: fragment.height))
        }

        // A file ending in a newline leaves an empty last line with no glyphs of its own,
        // so the loop above cannot reach it. It only gets a number when it is actually in
        // the viewport: on a long file scrolled to the middle it sits far below.
        let extra = layoutManager.extraLineFragmentRect
        if layoutManager.extraLineFragmentTextContainer != nil,
           textView.visibleRect.intersects(
               extra.offsetBy(dx: 0, dy: textView.textContainerInset.height)) {
            labels.append(Label(number: index.count, y: offset + extra.minY,
                                height: extra.height))
        }
        return labels
    }

    override func draw(_ rect: NSRect) {
        Theme.backgroundNSColor.setFill()
        rect.fill()
        NSColor(Theme.border).setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: CodeEditorStyle.rulerFont,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        for label in visibleLabels() {
            let text = "\(label.number)" as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.maxX - size.width - 9,
                                  y: label.y + (label.height - size.height) / 2),
                      withAttributes: attributes)
        }
    }

}

// Monospaced text is as wide as its longest line, so one measurement sizes a whole file
// without laying any of it out first.
@MainActor
enum MonoMetrics {
    // Measured with the pane's tab stops, so an indented line is as wide here as it is
    // once it is drawn.
    static func width(of text: String, font: NSFont = CodeEditorStyle.font) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [
            .font: font,
            .paragraphStyle: CodeEditorStyle.paragraphStyle
        ]).width)
    }

    static func width(ofLongestIn text: String) -> CGFloat {
        var longest: Substring = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false)
        where line.utf8.count > longest.utf8.count {
            longest = line
        }
        return width(of: String(longest))
    }
}
