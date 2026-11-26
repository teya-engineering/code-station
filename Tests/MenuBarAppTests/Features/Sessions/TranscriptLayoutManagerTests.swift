import AppKit
import Testing
@testable import MenuBarApp

// A transcript block paints its own selection, so AppKit's selection fill has to go
// while every background the text asks for stays.
@MainActor
struct TranscriptLayoutManagerTests {
    // The layout manager only holds its text view weakly, so the test keeps it alive.
    private let view = NSTextView(usingTextLayoutManager: false)
    private static let text = "one two three four five"
    private static let selected = NSRange(location: 4, length: 9)

    @Test func aBlockThatPaintsItsOwnSelectionDropsTheSystemFill() {
        let manager = makeManager(drops: true)

        #expect(!manager.draws(.unemphasizedSelectedTextBackgroundColor, over: Self.selected))
        #expect(!manager.draws(.selectedTextBackgroundColor, over: NSRange(location: 6, length: 3)))
    }

    @Test func textThatSelectsOnItsOwnKeepsTheSystemFill() {
        let manager = makeManager(drops: false)

        #expect(manager.draws(.unemphasizedSelectedTextBackgroundColor, over: Self.selected))
    }

    @Test func aBackgroundOutsideTheSelectionIsAlwaysDrawn() {
        let manager = makeManager(drops: true)

        #expect(manager.draws(.systemRed, over: NSRange(location: 14, length: 4)))
    }

    @Test func theTextsOwnBackgroundIsDrawnInsideTheSelection() {
        let manager = makeManager(drops: true)
        manager.textStorage?.addAttribute(.backgroundColor, value: Theme.accentNSColor,
                                          range: NSRange(location: 8, length: 5))

        #expect(manager.draws(Theme.accentNSColor, over: NSRange(location: 8, length: 5)))
        #expect(!manager.draws(.unemphasizedSelectedTextBackgroundColor, over: NSRange(location: 4, length: 4)))
    }

    @Test func aTemporaryBackgroundIsDrawnInsideTheSelection() {
        let manager = makeManager(drops: true)
        manager.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow,
                                      forCharacterRange: NSRange(location: 4, length: 3))

        #expect(manager.draws(.systemYellow, over: NSRange(location: 4, length: 3)))
    }

    private func makeManager(drops: Bool) -> TranscriptLayoutManager {
        let manager = TranscriptLayoutManager()
        view.textContainer?.replaceLayoutManager(manager)
        view.string = Self.text
        view.setSelectedRange(Self.selected)
        manager.dropsSelectionFill = drops
        return manager
    }
}
