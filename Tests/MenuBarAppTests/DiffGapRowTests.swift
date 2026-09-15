import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The grey row between two parts of a diff is a control: it says how many unchanged
// lines it stands for, and each of its arrows opens one end of them.
@MainActor
struct DiffGapRowTests {

    private func gap(_ id: Int, _ count: Int?) -> DiffGap {
        DiffGap(revision: .workingTree, path: "app.txt", id: id, start: 1, count: count)
    }

    private var lines: [DiffLine] {
        [DiffLine(id: 0, kind: .gap, text: "", gap: gap(0, 146)),
         DiffLine(id: 1, kind: .hunk, text: "@@ -147,6 +147,7 @@"),
         DiffLine(id: 2, kind: .context, text: " line 147"),
         DiffLine(id: 3, kind: .addition, text: "+line 148 changed"),
         DiffLine(id: 4, kind: .gap, text: "", gap: gap(1, 12))]
    }

    @Test func aLongGapOffersBothEndsAndAShortOneOpensWhole() {
        let text = DiffText.attributed(lines).string
        #expect(text.contains("↑ 146 lines ↓"))
        #expect(text.contains("12 lines"))
        // Nothing to steer when one press opens the lot.
        #expect(!text.contains("↑ 12 lines"))
        // The hunk header is a divider again rather than a control.
        #expect(text.contains("@@ -147,6 +147,7 @@\n"))
        #expect(actions(DiffText.attributed(lines)).map(\.direction) == [.up, .all, .down, .all])
    }

    @Test func aGapWithNoEndInSightOffersTheRestOfTheFile() {
        let row = [DiffLine(id: 0, kind: .gap, text: "", gap: gap(0, nil))]
        let text = DiffText.attributed(row)
        #expect(text.string.contains("↓ the rest of the file"))
        #expect(actions(text).map(\.direction) == [.down, .all])
    }

    @Test func eachControlOpensItsOwnEndOfTheGap() throws {
        let text = DiffText.attributed(lines)
        let pane = try Pane(text)
        defer { pane.close() }

        for control in actions(text).prefix(3) {
            pane.textView.mouseDown(with: pane.press(on: control.range))
        }
        #expect(pane.opened.map(\.direction) == [.up, .all, .down])
        #expect(pane.opened.allSatisfy { $0.key == gap(0, 146).key })
    }

    @Test func theBandBesideTheControlsNamesTheRowAndOpensNothing() throws {
        let text = DiffText.attributed(lines)
        let pane = try Pane(text)
        defer { pane.close() }

        let control = try #require(actions(text).first)
        #expect(pane.hit(on: control.range)?.direction == .up)
        // Still the same row, so the band lights up, but there is nothing to open out
        // there past the end of the controls.
        let beside = try #require(pane.hit(on: control.range, offset: 160))
        #expect(beside.direction == nil)
        #expect(beside.key == gap(0, 146).key)
    }

    @Test func aPointOffAGapRowIsNotOnAnything() throws {
        let text = DiffText.attributed(lines)
        let pane = try Pane(text)
        defer { pane.close() }

        // The row below the first gap is the hunk header, which stands for nothing.
        let header = (text.string as NSString).range(of: "@@ -147,6 +147,7 @@")
        #expect(pane.hit(on: header) == nil)
    }

    private func actions(_ text: NSAttributedString)
    -> [(range: NSRange, direction: DiffExpandDirection)] {
        var found: [(NSRange, DiffExpandDirection)] = []
        text.enumerateAttribute(.diffGapAction, in: NSRange(location: 0, length: text.length)) {
            value, range, _ in
            if let raw = value as? String, let direction = DiffExpandDirection(rawValue: raw) {
                found.append((range, direction))
            }
        }
        return found.map { (range: $0.0, direction: $0.1) }
    }
}

// A diff pane on screen, so a press can be aimed at a point of a row and land the way a
// real one would.
@MainActor
private final class Pane {
    let textView: NSTextView
    private let window: NSWindow
    private let layoutManager: NSLayoutManager
    private let container: NSTextContainer

    init(_ text: NSAttributedString) throws {
        let recorded = Recorder()
        let host = NSHostingView(rootView: DiffTextView(text: text) { key, direction in
            recorded.opened.append((key, direction))
        })
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 500, height: 200)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()

        textView = try #require(Pane.textView(in: host))
        layoutManager = try #require(textView.layoutManager)
        container = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        self.recorded = recorded
    }

    private let recorded: Recorder

    var opened: [(key: String, direction: DiffExpandDirection)] { recorded.opened }

    // Presses land in the middle of a run, or past its end when an offset is given,
    // which is band and nothing else.
    func press(on range: NSRange, offset: CGFloat = 0) -> NSEvent {
        let point = textView.convert(CGPoint(x: aim(range, offset).x + textView.textContainerOrigin.x,
                                             y: aim(range, offset).y + textView.textContainerOrigin.y),
                                     to: nil)
        return NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1)!
    }

    // What the same point answers without a press. A press on a row that opens nothing
    // carries on into the text view's own tracking, which a made up event cannot finish.
    func hit(on range: NSRange, offset: CGFloat = 0) -> DiffGapHit? {
        DiffGapHit.at(aim(range, offset), layoutManager: layoutManager,
                      container: container, storage: textView.textStorage!)
    }

    private func aim(_ range: NSRange, _ offset: CGFloat) -> CGPoint {
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let frame = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        return CGPoint(x: offset == 0 ? frame.midX : frame.maxX + offset, y: frame.midY)
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    private final class Recorder {
        var opened: [(key: String, direction: DiffExpandDirection)] = []
    }

    private static func textView(in view: NSView) -> NSTextView? {
        if let found = view as? NSTextView { return found }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
}
