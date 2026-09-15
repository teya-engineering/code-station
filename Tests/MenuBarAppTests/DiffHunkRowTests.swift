import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The grey header row between two parts of a diff is a control: it says how many
// unchanged lines it stands for, and pressing anywhere along the band opens them.
@MainActor
struct DiffHunkRowTests {

    private func hidden(_ count: Int) -> DiffHunk {
        DiffHunk(revision: .workingTree, path: "app.txt", hiddenStart: 1, hidden: count)
    }

    private var lines: [DiffLine] {
        [DiffLine(id: 0, kind: .hunk, text: "@@ -34,6 +37,7 @@", hunk: hidden(36)),
         DiffLine(id: 1, kind: .context, text: " line 37"),
         DiffLine(id: 2, kind: .addition, text: "+line 38 changed"),
         DiffLine(id: 3, kind: .hunk, text: "@@ -50,3 +52,3 @@", hunk: hidden(0))]
    }

    @Test func onlyAHeaderHidingSomethingSaysSoAndAnswersAPress() throws {
        let text = DiffText.attributed(lines)
        #expect(text.string.contains("@@ -34,6 +37,7 @@   ↑ 36 lines"))
        // The second header stands for nothing, so it stays a plain divider.
        #expect(text.string.hasSuffix("@@ -50,3 +52,3 @@"))

        let marked = keyed(text)
        #expect(marked.count == 1)
        #expect(marked.first?.value == hidden(36).key)
        let row = try #require(marked.first)
        #expect((text.string as NSString).substring(with: row.range).hasPrefix("@@ -34,6 +37,7 @@"))
    }

    @Test func pressingTheBandBesideTheTextOpensTheRow() throws {
        var opened: [String] = []
        let text = DiffText.attributed(lines)
        let host = NSHostingView(rootView: DiffTextView(text: text) { opened.append($0) })
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 500, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()

        let textView = try #require(textView(in: host))
        let layoutManager = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: container)

        // Well past the end of the header's own text: the whole band is the control,
        // not the characters on it.
        textView.mouseDown(with: press(on: keyed(text)[0].range, in: textView, window: window,
                                       layoutManager: layoutManager, container: container))
        #expect(opened == [hidden(36).key])
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let found = view as? NSTextView { return found }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    private func keyed(_ text: NSAttributedString) -> [(range: NSRange, value: String)] {
        var found: [(NSRange, String)] = []
        text.enumerateAttribute(.diffHunk, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let key = value as? String { found.append((range, key)) }
        }
        return found.map { (range: $0.0, value: $0.1) }
    }

    // A click to the right of a row's text, which is band and nothing else.
    private func press(on range: NSRange, in textView: NSTextView, window: NSWindow,
                       layoutManager: NSLayoutManager, container: NSTextContainer) -> NSEvent {
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let frame = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let point = textView.convert(
            CGPoint(x: frame.maxX + 120 + textView.textContainerOrigin.x,
                    y: frame.midY + textView.textContainerOrigin.y), to: nil)
        return NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1)!
    }
}
