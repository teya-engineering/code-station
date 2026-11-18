import AppKit
import Testing
@testable import MenuBarApp

@MainActor
struct CommandListMonitorTests {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    // A press near the top of the window must count as inside a list drawn near the top,
    // in both a flipped view, as SwiftUI hosts its content, and an unflipped one.
    @Test(arguments: [true, false])
    func aPressOnTheListCountsAsInside(flipped: Bool) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = flipped ? FlippedView() : NSView()
        window.contentView = content
        content.frame = CGRect(x: 0, y: 0, width: 400, height: 600)

        // The list, counted from the top: its top 100 points.
        let list = CGRect(x: 0, y: 0, width: 400, height: 100)
        let nearTop = CGPoint(x: 200, y: 550)
        let nearBottom = CGPoint(x: 200, y: 50)

        #expect(CommandListMonitor.lands(nearTop, in: content, on: [list]))
        #expect(!CommandListMonitor.lands(nearBottom, in: content, on: [list]))
    }

    // Option with an arrow sorts the highlighted shortcut; any other held key leaves the
    // press to the window.
    @Test func optionArrowsSortAndOtherModifiersPassThrough() {
        #expect(CommandListMonitor.key(for: 126, modifiers: []) == .up)
        #expect(CommandListMonitor.key(for: 125, modifiers: []) == .down)
        #expect(CommandListMonitor.key(for: 126, modifiers: .option) == .moveUp)
        #expect(CommandListMonitor.key(for: 125, modifiers: [.option, .shift]) == .moveDown)
        #expect(CommandListMonitor.key(for: 36, modifiers: .option) == nil)
        #expect(CommandListMonitor.key(for: 126, modifiers: .command) == nil)
        #expect(CommandListMonitor.key(for: 126, modifiers: [.command, .option]) == nil)
        #expect(CommandListMonitor.key(for: 53, modifiers: []) == .close)
    }
}
