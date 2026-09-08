import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The destination deck fits itself to what the deck and the rail together ask for, so the
// deck has to give the same answer every time it is asked. A deck whose width moved -
// with the pointer, or with which tab is chosen - would take the rail beside it with it,
// and a header handed two answers lays out a row that fits, is handed the other, lays
// itself out again, and never comes to rest.
@MainActor
struct HeaderTabDeckRoomTests {
    private func tabs(selecting selected: String,
                      diffOnChanges: HeaderTab.Diff? = nil) -> [HeaderTab] {
        [("Chat", "bubble.left.and.bubble.right"), ("Design", "paintbrush.pointed"),
         ("Troubleshoot", "stethoscope"), ("Project Changes", "plusminus"),
         ("Explorer", "folder")].map { label, icon in
            HeaderTab(label: label, icon: icon, selected: label == selected,
                      diff: label == "Project Changes" ? diffOnChanges : nil,
                      activate: {})
        }
    }

    @Test func theDeckAsksForOneWidthBeforeAndAfterItIsDrawn() {
        for diff in [nil, HeaderTab.Diff(added: 412, removed: 86)] {
            let deck = NSHostingView(rootView: HeaderTabDeck(
                tabs: tabs(selecting: "Chat", diffOnChanges: diff)))
            let asked = deck.fittingSize.width
            #expect(asked > 0)

            draw(deck)
            #expect(deck.fittingSize.width == asked)
        }
    }

    // The chosen tab is marked by a line under it rather than by anything that takes room,
    // so choosing a destination moves the line and nothing else.
    @Test func choosingATabDoesNotMoveTheRailBesideIt() {
        let chat = NSHostingView(rootView: HeaderTabDeck(tabs: tabs(selecting: "Chat")))
        let explorer = NSHostingView(rootView: HeaderTabDeck(tabs: tabs(selecting: "Explorer")))
        draw(chat)
        draw(explorer)
        #expect(chat.fittingSize.width == explorer.fittingSize.width)
    }

    // Counts arriving on the Changes tab are the one thing that does widen the deck, and
    // they widen it once: the tab keeps its word either way.
    @Test func countsWidenOnlyTheTabTheyBelongTo() {
        let bare = NSHostingView(rootView: HeaderTabDeck(tabs: tabs(selecting: "Chat")))
        let counted = NSHostingView(rootView: HeaderTabDeck(
            tabs: tabs(selecting: "Chat", diffOnChanges: .init(added: 412, removed: 86))))
        draw(bare)
        draw(counted)
        #expect(counted.fittingSize.width > bare.fittingSize.width)
    }

    private func draw(_ view: NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 40)
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            view.layoutSubtreeIfNeeded()
        }
    }

    @Test func scrollingKeepsTheSelectedTabVisibleWhenResizedOrChanged() async throws {
        let hosting = NSHostingController(rootView: HeaderTabDeck(
            tabs: tabs(selecting: "Explorer"), scrollable: true))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = hosting

        for width: CGFloat in [400, 250, 450] {
            window.setContentSize(NSSize(width: width, height: 40))
            await settle(hosting.view)
            let scroll = try #require(scrollView(in: hosting.view))
            let document = try #require(scroll.documentView)
            #expect(abs(scroll.contentView.bounds.width - width) < 1)
            #expect(abs(scroll.documentVisibleRect.maxX - document.bounds.maxX) < 1)
        }

        hosting.rootView = HeaderTabDeck(tabs: tabs(selecting: "Chat"), scrollable: true)
        await settle(hosting.view)
        let scroll = try #require(scrollView(in: hosting.view))
        #expect(abs(scroll.documentVisibleRect.minX) < 1)
    }

    private func settle(_ view: NSView) async {
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(20))
            view.layoutSubtreeIfNeeded()
        }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
}
