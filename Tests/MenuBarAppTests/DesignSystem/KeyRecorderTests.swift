import AppKit
import Testing
@testable import MenuBarApp

// While a cap listens, every press in its window is its own: the keys being recorded must
// not also run what they are bound to, or close the sheet the cap sits in.
@MainActor
struct KeyRecorderTests {
    private final class Heard {
        var keys: [KeyCombo] = []
        var cleared = 0
        var cancelled = 0
    }

    private func mount() -> (NSWindow, KeyRecorderListener, Heard) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 10, y: 10, width: 60, height: 24))
        window.contentView?.addSubview(anchor)
        let listener = KeyRecorderListener()
        listener.anchor = anchor
        let heard = Heard()
        listener.start(onKeys: { heard.keys.append($0) },
                       onClear: { heard.cleared += 1 },
                       onCancel: { heard.cancelled += 1 })
        return (window, listener, heard)
    }

    private func press(_ characters: String, _ flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0,
                       in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: keyCode))
    }

    private func click(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                        eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func pressesAreOfferedAndNeverReachTheWindow() throws {
        let (window, listener, heard) = mount()
        defer { listener.stop(); window.close() }

        NSApp.sendEvent(try press("p", [.command, .option], keyCode: 35, in: window))
        NSApp.sendEvent(try press("\u{1b}", keyCode: 53, in: window))
        NSApp.sendEvent(try press("\u{7f}", keyCode: 51, in: window))

        #expect(heard.keys == [KeyCombo("p", [.command, .option])])
        #expect(heard.cancelled == 1)
        #expect(heard.cleared == 1)
    }

    @Test func aPressInAnotherWindowIsLeftAlone() throws {
        let (window, listener, heard) = mount()
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { listener.stop(); window.close(); other.close() }

        NSApp.sendEvent(try press("p", .command, keyCode: 35, in: other))

        #expect(heard.keys.isEmpty)
    }

    // The cap's own click is left to the cap, which toggles itself off.
    @Test func aClickAwayStopsListeningButAClickOnTheCapDoesNot() throws {
        let (window, listener, heard) = mount()
        defer { listener.stop(); window.close() }

        NSApp.sendEvent(try click(at: NSPoint(x: 20, y: 20), in: window))
        #expect(heard.cancelled == 0)

        NSApp.sendEvent(try click(at: NSPoint(x: 150, y: 100), in: window))
        #expect(heard.cancelled == 1)
    }

    @Test func stoppingHearsNothingMore() throws {
        let (window, listener, heard) = mount()
        defer { window.close() }
        listener.stop()

        NSApp.sendEvent(try press("p", .command, keyCode: 35, in: window))

        #expect(heard.keys.isEmpty)
    }
}
