import AppKit
import Testing
@testable import MenuBarApp

// Stands in for whatever view the shell is typed into. The rule only cares that the
// first responder says it is one.
private final class ShellStandIn: NSView, TerminalKeyboardResponder {
    override var acceptsFirstResponder: Bool { true }
}

// A local monitor sees every key press in the app, so several controls listening for the
// same chord all wake on one stroke. This is the rule that decides which of them acts:
// ⌘V over a composer that is not in front must not attach to it, and ^C must reach the
// run the reader is watching rather than one behind it.
@MainActor
struct WindowKeyMonitorTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func onlyTheWindowInFrontActsOnTheStroke() {
        let front = window()
        defer { front.close() }
        let behind = window()
        defer { behind.close() }

        #expect(WindowKeyMonitor.routes(to: front, frontmost: front))
        #expect(!WindowKeyMonitor.routes(to: behind, frontmost: front))
    }

    // A composer left focused behind a sheet must not answer for the sheet's own chord.
    @Test func aWindowBehindASheetStandsDown() {
        let sheet = window()
        defer { sheet.close() }
        let owner = window()
        defer { owner.close() }

        #expect(!WindowKeyMonitor.routes(to: owner, frontmost: sheet))
        #expect(WindowKeyMonitor.routes(to: sheet, frontmost: sheet))
    }

    // A shell is typed into directly: ^C there belongs to whatever it is running, and a
    // paste there is the shell's, not the composer's. Being in front is not enough.
    @Test func aShellHoldingTheKeyboardKeepsTheStroke() {
        let host = window()
        defer { host.close() }
        // The app's real terminal view, so this also checks that it says it is a shell.
        let shell = TerminalSurface(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        host.contentView?.addSubview(shell)
        host.makeFirstResponder(shell)

        #expect(host.firstResponder === shell)
        #expect(!WindowKeyMonitor.routes(to: host, frontmost: host))
    }

    // The same window routes again once the shell gives the keyboard back, so a reader who
    // clicks out of the drawer gets the composer's shortcuts returned to them.
    @Test func theWindowRoutesAgainOnceTheShellLetsGo() {
        let host = window()
        defer { host.close() }
        let shell = ShellStandIn(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        host.contentView?.addSubview(shell)
        host.contentView?.addSubview(field)

        host.makeFirstResponder(shell)
        #expect(!WindowKeyMonitor.routes(to: host, frontmost: host))

        host.makeFirstResponder(field)
        #expect(WindowKeyMonitor.routes(to: host, frontmost: host))
    }

    // Nothing in front at all - the app is not the active one - is not a reason to act.
    @Test func nothingInFrontMeansNobodyActs() {
        let host = window()
        defer { host.close() }

        #expect(!WindowKeyMonitor.routes(to: host, frontmost: nil))
    }
}
