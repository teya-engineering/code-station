import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The pane draws itself with AppKit, so what it puts on screen is only readable back off
// the text storage. These stand a real one up offscreen and look at the attributes it
// leaves behind: the colours a reader sees, and the highlights find puts under them.
@MainActor
struct CodeEditorTests {

    // A pane wide and tall enough that a short file is entirely inside the viewport, which
    // is the only part it colours.
    @MainActor
    private final class Pane {
        let view: CodeEditorPane
        let scrollView: NSScrollView
        let coordinator: CodeEditorView.Coordinator
        let window: NSWindow
        private var stored: String

        init(_ text: String, language: CodeLanguage? = .swift,
             matches: [NSRange] = [], currentMatch: Int? = nil) {
            stored = text
            let coordinator = CodeEditorView.Coordinator(
                CodeEditorView(documentID: "pane.swift", text: .constant(text),
                               language: language, matches: matches, currentMatch: currentMatch))
            self.coordinator = coordinator
            view = coordinator.makePane()
            scrollView = view.scrollView
            view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.contentView?.addSubview(view)
            view.layoutSubtreeIfNeeded()
            apply(text: text, language: language, matches: matches, currentMatch: currentMatch)
        }

        func apply(text: String, language: CodeLanguage? = .swift,
                   matches: [NSRange] = [], currentMatch: Int? = nil) {
            stored = text
            coordinator.apply(CodeEditorView(
                documentID: "pane.swift",
                text: Binding(get: { self.stored }, set: { self.stored = $0 }),
                language: language, matches: matches, currentMatch: currentMatch))
        }

        var textView: NSTextView { scrollView.documentView as! NSTextView }
        var storage: NSTextStorage { textView.textStorage! }
        var boundText: String { stored }

        // The colour a reader sees at the first occurrence of a piece of the file.
        func colour(of piece: String) -> NSColor? {
            let range = (storage.string as NSString).range(of: piece)
            guard range.location != NSNotFound else { return nil }
            return storage.attribute(.foregroundColor, at: range.location,
                                     effectiveRange: nil) as? NSColor
        }

        func background(of piece: String) -> NSColor? {
            let range = (storage.string as NSString).range(of: piece)
            guard range.location != NSNotFound else { return nil }
            return storage.attribute(.backgroundColor, at: range.location,
                                     effectiveRange: nil) as? NSColor
        }
    }

    @Test func theFileArrivesReadyToTypeInto() {
        let pane = Pane("let a = 1\n")

        #expect(pane.textView.isEditable)
        #expect(pane.textView.string == "let a = 1\n")
    }

    // Drawn through the whole pane rather than the text view on its own. The gutter is a
    // sibling laid over the text, and a gutter that paints past its own column hides
    // everything under it while still showing its numbers.
    @Test func theTextDrawsBesideTheGutter() throws {
        let pane = Pane("rendered text\n", language: nil)
        let visible = pane.view.bounds
        let image = try #require(pane.view.bitmapImageRepForCachingDisplay(in: visible))
        pane.view.cacheDisplay(in: visible, to: image)

        let scale = CGFloat(image.pixelsWide) / visible.width
        let firstTextPixel = Int(ceil(gutter(pane).thickness * scale)) + 1
        let lastTextPixel = min(image.pixelsWide - 1, Int(250 * scale))
        let hasTextPixel = (0..<image.pixelsHigh).contains { y in
            (firstTextPixel...lastTextPixel).contains { x in
                guard let colour = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    return false
                }
                return colour.alphaComponent > 0.5
                    && colour.redComponent < 0.5
                    && colour.greenComponent < 0.5
                    && colour.blueComponent < 0.5
            }
        }

        #expect(hasTextPixel)
    }

    @Test func theGutterStaysOutsideTheScrollViewSurface() {
        let pane = Pane("one\ntwo\n")

        #expect(pane.view.gutter.superview === pane.view)
        #expect(pane.scrollView.verticalRulerView == nil)
        #expect(!pane.scrollView.rulersVisible)
    }

    @Test func codeOnScreenIsColoured() {
        let pane = Pane("""
        // a note
        let name = "value"
        let count = 42
        """)

        #expect(pane.colour(of: "// a note") == CodeStyle.comment)
        #expect(pane.colour(of: "let") == CodeStyle.keyword)
        #expect(pane.colour(of: "\"value\"") == CodeStyle.string)
        #expect(pane.colour(of: "42") == CodeStyle.number)
        #expect(pane.colour(of: "name") == NSColor.labelColor)
    }

    @Test func aFileWithNoKnownLanguageStaysPlain() {
        let pane = Pane("let name = \"value\"\n", language: nil)

        #expect(pane.colour(of: "let") == NSColor.labelColor)
    }

    // The highlighter reads a line at a time and carries what a line leaves open into the
    // next, so a comment opened at the top has to still be a comment further down.
    @Test func aBlockCommentRunsPastTheLineThatOpensIt() {
        let pane = Pane("""
        /* opened here
        let notCode = 1
        */
        let code = 1
        """)

        #expect(pane.colour(of: "let notCode") == CodeStyle.comment)
        #expect(pane.colour(of: "let code") == CodeStyle.keyword)
    }

    @Test func findMarksItsMatchesAndPicksOutTheCurrentOne() {
        let text = "alpha\nbeta\nalpha\n"
        let matches = FileFind.search("alpha", in: text).matches
        let pane = Pane(text, matches: matches, currentMatch: 1)

        #expect(matches.count == 2)
        #expect(pane.storage.attribute(.backgroundColor, at: matches[0].location,
                                       effectiveRange: nil) as? NSColor == CodeEditorStyle.match)
        #expect(pane.storage.attribute(.backgroundColor, at: matches[1].location,
                                       effectiveRange: nil) as? NSColor == CodeEditorStyle.currentMatch)
        #expect(pane.background(of: "beta") == nil)
    }

    @Test func closingFindTakesItsHighlightsWithIt() {
        let text = "alpha\nbeta\n"
        let matches = FileFind.search("alpha", in: text).matches
        let pane = Pane(text, matches: matches, currentMatch: 0)
        #expect(pane.background(of: "alpha") != nil)

        pane.apply(text: text)

        #expect(pane.background(of: "alpha") == nil)
    }

    // Typing has to reach the pane's own text, or Save would write back what was loaded.
    @Test func typingReachesTheBoundText() {
        let pane = Pane("let a = 1\n")
        pane.textView.selectedRange = NSRange(location: 0, length: 0)
        pane.textView.insertText("var b = 2\n", replacementRange: NSRange(location: 0, length: 0))

        #expect(pane.boundText == "var b = 2\nlet a = 1\n")
        #expect(pane.colour(of: "var") == CodeStyle.keyword)
    }

    // An edit throws away what the highlighter knew from that line on. Everything after it
    // still has to come back coloured rather than plain.
    @Test func colourSurvivesAnEditAboveIt() {
        let pane = Pane("let a = 1\nlet b = 2\nlet c = 3\n")
        pane.textView.selectedRange = NSRange(location: 0, length: 0)
        pane.textView.insertText("// note\n", replacementRange: NSRange(location: 0, length: 0))

        #expect(pane.colour(of: "// note") == CodeStyle.comment)
        #expect(pane.colour(of: "let c") == CodeStyle.keyword)
    }

    // Opening another file must not leave the last one's text or colouring behind.
    @Test func switchingFileReplacesTheDocument() {
        let pane = Pane("let a = 1\n")
        pane.coordinator.apply(CodeEditorView(documentID: "other.swift",
                                              text: .constant("plain words\n"),
                                              language: nil, matches: [], currentMatch: nil))

        #expect(pane.textView.string == "plain words\n")
        #expect(pane.colour(of: "plain") == NSColor.labelColor)
    }

    // The gutter has to be wide enough for the biggest number it will draw, or the numbers
    // on the longest files run under the code.
    @Test func theGutterGrowsWithTheLineCount() {
        let narrow = gutter(Pane("a\n")).thickness
        let wide = gutter(Pane(String(repeating: "a\n", count: 5000))).thickness

        #expect(wide > narrow)
    }

    // Only the viewport is coloured, so a long file must not be read end to end just to
    // show its first screen.
    @Test func aLongFileOnlyColoursWhatIsOnScreen() {
        let pane = Pane(String(repeating: "let a = 1\n", count: 20_000))
        let lastLine = pane.storage.length - 10

        #expect(pane.colour(of: "let") == CodeStyle.keyword)
        #expect(pane.storage.attribute(.foregroundColor, at: lastLine,
                                       effectiveRange: nil) as? NSColor != CodeStyle.keyword)
    }
    // MARK: - The gutter

    private func gutter(_ pane: Pane) -> LineNumberGutter {
        pane.view.gutter
    }

    @Test func everyLineOnScreenIsNumberedOnce() {
        let pane = Pane("one\ntwo\nthree")

        #expect(gutter(pane).visibleLabels().map(\.number) == [1, 2, 3])
    }

    // A file ending in a newline leaves a last line with nothing on it. The text view puts
    // a caret there, so the gutter has to name it.
    @Test func theEmptyLineAfterATrailingNewlineIsNumbered() {
        let pane = Pane("one\ntwo\n")

        #expect(gutter(pane).visibleLabels().map(\.number) == [1, 2, 3])
    }

    // The gutter and the text are separate views that scroll together, so a number has to
    // land on the row it belongs to rather than at the top of the pane.
    @Test func theGutterFollowsTheTextWhenScrolled() {
        let pane = Pane(String(repeating: "let a = 1\n", count: 400))
        pane.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 743))
        pane.scrollView.reflectScrolledClipView(pane.scrollView.contentView)

        let labels = gutter(pane).visibleLabels()
        let first = try! #require(labels.first)

        // The first number showing is the first line actually in the viewport ...
        let textView = pane.textView
        let layoutManager = textView.layoutManager!
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect,
                                              in: textView.textContainer!)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        #expect(first.number == LineIndex(textView.string as NSString).line(at: characters.location) + 1)

        // ... drawn where that line itself sits, once the two views' coordinates are lined
        // up. A gutter that ignored the scroll would put it back at the top of the pane.
        var effective = NSRange()
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location,
                                                      effectiveRange: &effective)
        let textY = gutter(pane).convert(
            NSPoint(x: 0, y: fragment.minY + textView.textContainerInset.height),
            from: textView).y
        #expect(abs(first.y - textY) < 0.5)
        #expect(labels.map(\.number) == Array(first.number...(first.number + labels.count - 1)))
    }

    @Test func horizontalScrollingKeepsTheDocumentVisible() async throws {
        let longLine = String(repeating: "abcdefghij", count: 200)
        let pane = Pane("one\ntwo\n\(longLine)\nthree\n")
        let before = gutter(pane).visibleLabels().map(\.number)

        pane.scrollView.contentView.scroll(to: NSPoint(x: 700, y: 0))
        pane.scrollView.reflectScrolledClipView(pane.scrollView.contentView)
        await Task.yield()

        #expect(before == [1, 2, 3, 4, 5])
        #expect(pane.scrollView.contentView.bounds.minX == 700)
        #expect(pane.scrollView.horizontalScrollElasticity == .none)
        #expect(gutter(pane).visibleLabels().map(\.number) == before)

        let visible = pane.view.bounds
        let image = try #require(pane.view.bitmapImageRepForCachingDisplay(in: visible))
        pane.view.cacheDisplay(in: visible, to: image)
        let scale = CGFloat(image.pixelsWide) / visible.width
        let gutterEdge = Int(ceil(gutter(pane).thickness * scale)) + 1
        let bottomOfTextArea = max(0, image.pixelsHigh - Int(30 * scale))
        let hasTextPixel = (0..<bottomOfTextArea).contains { y in
            (gutterEdge..<image.pixelsWide).contains { x in
                guard let colour = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    return false
                }
                return colour.alphaComponent > 0.5
                    && colour.redComponent < 0.5
                    && colour.greenComponent < 0.5
                    && colour.blueComponent < 0.5
            }
        }
        #expect(hasTextPixel)
    }

}
