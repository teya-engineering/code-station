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
}
