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
                      changesHaveContent: Bool? = nil,
                      lineCounts: HeaderTabLineCounts? = nil) -> [HeaderTab] {
        [("Chat", "bubble.left.and.bubble.right"), ("Design", "paintbrush.pointed"),
         ("Troubleshoot", "stethoscope"), ("Changes", "plusminus"),
         ("Explorer", "folder")].map { label, icon in
            var tab = HeaderTab(label: label, icon: icon, selected: label == selected,
                                activate: {})
            if label == "Changes" {
                tab.hasContent = changesHaveContent ?? (lineCounts != nil ? true : nil)
                tab.lineCounts = lineCounts
            }
            return tab
        }
    }

    @Test func theDeckAsksForOneWidthBeforeAndAfterItIsDrawn() {
        for hasContent in [nil, false, true] {
            let deck = NSHostingView(rootView: HeaderTabDeck(
                tabs: tabs(selecting: "Chat", changesHaveContent: hasContent))
                .environment(TooltipPresenter()))
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

    @Test func contentAndSelectionKeepTheSameWidth() {
        let widths = [false, true].flatMap { hasContent in
            ["Chat", "Design"].map { selected in
                var destinations = tabs(selecting: selected, changesHaveContent: hasContent)
                destinations[1].hasContent = hasContent
                let deck = NSHostingView(rootView: HeaderTabDeck(tabs: destinations)
                    .environment(TooltipPresenter()))
                draw(deck)
                return deck.fittingSize.width
            }
        }
        #expect(widths.allSatisfy { $0 == widths.first })
    }

    // The chosen Changes tab widens to show its counts. The deck keeps that room at its
    // end while another tab is chosen, so the header beside it never has to fit itself
    // again, and the deck gives the same answer before and after it is drawn.
    @Test(arguments: [HeaderTabLineCounts(added: 412, removed: 271),
                      HeaderTabLineCounts(added: 18_349, removed: 0),
                      HeaderTabLineCounts(added: 3, removed: 183_499)])
    func lineCountsDoNotChangeTheDecksWidth(counts: HeaderTabLineCounts) {
        let widths = ["Chat", "Changes", "Explorer"].map { selected in
            let deck = NSHostingView(rootView: HeaderTabDeck(
                tabs: tabs(selecting: selected, lineCounts: counts))
                .environment(TooltipPresenter()))
            let asked = deck.fittingSize.width
            draw(deck)
            #expect(deck.fittingSize.width == asked)
            return asked
        }
        #expect(widths.allSatisfy { $0 == widths.first })

        let withoutCounts = NSHostingView(rootView: HeaderTabDeck(
            tabs: tabs(selecting: "Chat", changesHaveContent: true))
            .environment(TooltipPresenter()))
        #expect(widths[0] > withoutCounts.fittingSize.width)
    }

    @Test func lineCountsShortenFromTenThousand() {
        #expect(HeaderTabLineCounts.short(0) == "0")
        #expect(HeaderTabLineCounts.short(9_999) == "9999")
        #expect(HeaderTabLineCounts.short(10_000) == "10.0k")
        #expect(HeaderTabLineCounts.short(18_349) == "18.3k")
        #expect(HeaderTabLineCounts.short(99_960) == "99.9k")
        #expect(HeaderTabLineCounts.short(100_000) == "100k")
        #expect(HeaderTabLineCounts.short(183_499) == "183k")
    }

    private func draw(_ view: NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
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
        window.isReleasedWhenClosed = false
        defer { window.close() }
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
