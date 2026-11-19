import AppKit
import SwiftUI

// Catches one chord anywhere in a window, for a control that has no text field of its own
// to type it into. A local monitor sees every key press in the app, so each one is tied to
// a view and only acts while that view's window is the one in front.
@MainActor
final class WindowKeyMonitor {
    // Says which window the control is in. This is what tells one control's stroke from
    // another's when several are listening for the same chord.
    weak var anchor: NSView?

    // Can change while the monitor runs, when the person picks another key for it. Nil
    // leaves the monitor listening for nothing.
    var keys: KeyCombo?
    private var token: Any?
    private var handle: (() -> Bool)?

    init(_ keys: KeyCombo?) {
        self.keys = keys
    }

    init(_ modifier: NSEvent.ModifierFlags, _ key: String) {
        var modifiers: KeyCombo.Modifiers = []
        if modifier.contains(.control) { modifiers.insert(.control) }
        if modifier.contains(.option) { modifiers.insert(.option) }
        if modifier.contains(.shift) { modifiers.insert(.shift) }
        if modifier.contains(.command) { modifiers.insert(.command) }
        let name = switch key {
        case "\u{1b}": KeyCombo.escape
        case "\r": KeyCombo.returnKey
        default: key
        }
        self.keys = KeyCombo(name, modifiers)
    }

    // The handler returns true when it acted on the stroke, which swallows it. Returning
    // false leaves the stroke for whatever would otherwise have had it.
    func start(_ handle: @escaping () -> Bool) {
        // Kept on the monitor rather than captured by the handler: the view is a value
        // that is made again on every redraw, and the handler is registered once.
        self.handle = handle
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Read on the way in, so only the answer to "was this ours" crosses over.
            let pressed = KeyCombo(event: event)
            return MainActor.assumeIsolated { self.take(pressed) } ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
        handle = nil
    }

    private func take(_ pressed: KeyCombo?) -> Bool {
        guard let pressed, pressed == keys, let handle, let window = anchor?.window else { return false }
        return Self.routes(to: window, frontmost: Self.frontmostWindow) ? handle() : false
    }

    // Every control of this kind has a monitor of its own and they all see the key press,
    // so only the one in front acts on it: one left focused behind a sheet must not answer
    // for the sheet's own. A shell is typed into directly, so a stroke landing there is
    // its own and never a shortcut.
    static func routes(to window: NSWindow, frontmost: NSWindow?) -> Bool {
        window === frontmost && !(window.firstResponder is any TerminalKeyboardResponder)
    }

    // Which of a sheet and the window it hangs off counts as key is not worth relying on,
    // so the chain is followed to whichever sheet ended up on top.
    static var frontmostWindow: NSWindow? {
        var window = NSApp.keyWindow
        while let sheet = window?.attachedSheet { window = sheet }
        return window
    }
}

// Names the window its monitor is in. Only there for that, so it takes no clicks of its own.
struct WindowAnchor: NSViewRepresentable {
    let monitor: WindowKeyMonitor

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        monitor.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { monitor.anchor = view }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// Hears every key press in its window and lets a view decide which are its own, for a
// screen whose keys are single letters that only mean something while nothing is being
// typed. A press while a text field or a shell has the keyboard is always left alone.
@MainActor
final class WindowKeyHandler {
    weak var anchor: NSView?

    private let handlesTyping: Bool
    // Kept up to date by the anchor, so a handler registered once still answers to a key
    // the person changes later.
    var keyBindings = KeyBindings()

    init(handlesTyping: Bool = false) { self.handlesTyping = handlesTyping }

    // Whether the press is the key the person has for the command right now.
    func pressed(_ command: AppCommand, _ event: NSEvent) -> Bool {
        guard let keys = keyBindings.keys(for: command) else { return false }
        return keys.matches(event)
    }

    private var token: Any?
    private var handle: ((NSEvent) -> Bool)?

    func start(_ handle: @escaping (NSEvent) -> Bool) {
        self.handle = handle
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let event = event
            return MainActor.assumeIsolated { self.take(event) } ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
        handle = nil
    }

    private func take(_ event: NSEvent) -> Bool {
        guard let handle, let window = anchor?.window,
              WindowKeyMonitor.routes(to: window, frontmost: WindowKeyMonitor.frontmostWindow),
              event.window === window,
              handlesTyping || !Self.isTyping(window.firstResponder) else { return false }
        return handle(event)
    }

    static func isTyping(_ responder: NSResponder?) -> Bool {
        if let text = responder as? NSTextView { return text.isEditable }
        return responder is NSTextField
    }
}

struct WindowKeyAnchor: NSViewRepresentable {
    let handler: WindowKeyHandler

    @Environment(\.keyBindings) private var keyBindings

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        handler.anchor = view
        handler.keyBindings = keyBindings
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        handler.anchor = view
        handler.keyBindings = keyBindings
    }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
