import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The header fits itself to what the rail asks for, so the rail has to give the same
// answer every time it is asked. A bar that measured its own words on screen answered
// narrow until it had been drawn once and wider afterwards, and a header handed the
// narrow answer laid out a row that did not fit, took the wide one, laid out a row that
// did, and went round again for as long as the window was being resized.
@MainActor
struct HeaderTabBarRoomTests {
    private var tabs: [HeaderTab] {
        [("Chat", "bubble.left.and.bubble.right"), ("Design", "paintbrush.pointed"),
         ("Troubleshoot", "stethoscope"), ("Project Changes", "plusminus"),
         ("Explorer", "folder")].map { label, icon in
            HeaderTab(label: label, icon: icon, selected: label == "Chat", activate: {})
        }
    }

    @Test func theBarAsksForOneWidthBeforeAndAfterItIsDrawn() {
        for holdsOpenRoom in [true, false] {
            let bar = NSHostingView(rootView:
                HeaderTabBar(tabs: tabs, holdsOpenRoom: holdsOpenRoom))
            let asked = bar.fittingSize.width
            #expect(asked > 0)

            draw(bar)
            #expect(bar.fittingSize.width == asked)
        }
    }

    // The room a bar holds is the room its labels need, so a bar that has been opened is
    // never wider than the space the closed one stood in.
    @Test func theRoomHeldIsTheRoomTheOpenLabelsNeed() {
        let opened = tabs.map {
            HeaderTab(label: $0.label, icon: $0.icon, selected: true, activate: {})
        }
        let held = NSHostingView(rootView: HeaderTabBar(tabs: tabs))
        let open = NSHostingView(rootView: HeaderTabBar(tabs: opened))
        draw(held)
        draw(open)
        #expect(held.fittingSize.width == open.fittingSize.width)
    }

    private func draw(_ view: NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 60)
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            view.layoutSubtreeIfNeeded()
        }
    }
}
