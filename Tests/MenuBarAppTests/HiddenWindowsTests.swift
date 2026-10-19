import AppKit
import Testing
@testable import CodeStationCore

// The suite builds real windows and orders them on screen. None of them may show over
// the user's work or take their clicks, whether a test built it or the code under test
// opened it.
@MainActor
struct HiddenWindowsTests {
    @Test func aTestWindowIsOnScreenButInvisibleAtItsOwnFrame() {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        let window = testWindow(contentRect: frame, styleMask: [.borderless],
                                backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        window.makeKeyAndOrderFront(nil)

        #expect(window.isVisible)
        #expect(window.alphaValue == 0)
        #expect(window.ignoresMouseEvents)
        #expect(window.frame.size == frame.size)
        #expect(!NSApp.isActive)
    }

    @Test func aWindowTheAppOpensItselfIsHiddenToo() {
        HiddenWindows.install()
        let orders: [(NSWindow) -> Void] = [
            { $0.orderFront(nil) },
            { $0.makeKeyAndOrderFront(nil) },
            { $0.orderFrontRegardless() },
            { $0.setIsVisible(true) },
        ]
        for order in orders {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                                  styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            order(window)

            #expect(window.isVisible)
            #expect(window.alphaValue == 0)
            #expect(window.ignoresMouseEvents)
            window.close()
        }
    }
}
