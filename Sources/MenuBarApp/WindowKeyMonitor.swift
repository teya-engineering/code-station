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

    private let modifier: NSEvent.ModifierFlags
    private let key: String
    private var token: Any?
    private var handle: (() -> Bool)?

    init(_ modifier: NSEvent.ModifierFlags, _ key: String) {
        self.modifier = modifier
        self.key = key
    }

    // The handler returns true when it acted on the stroke, which swallows it. Returning
    // false leaves the stroke for whatever would otherwise have had it.
    func start(_ handle: @escaping () -> Bool) {
        // Kept on the monitor rather than captured by the handler: the view is a value
        // that is made again on every redraw, and the handler is registered once.
        self.handle = handle
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [modifier, key] event in
            // Nothing about the event itself is carried across: it stays here, and only
            // the answer to "was this ours" goes to the main actor.
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifier,
                  event.charactersIgnoringModifiers?.lowercased() == key
            else { return event }
            return MainActor.assumeIsolated { self.take() } ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
        handle = nil
    }

    private func take() -> Bool {
        guard let handle, let window = anchor?.window else { return false }
        return Self.routes(to: window, frontmost: Self.frontmostWindow) ? handle() : false
    }

    // Every control of this kind has a monitor of its own and they all see the key press,
    // so only the one in front acts on it: one left focused behind a sheet must not answer
    // for the sheet's own. A shell is typed into directly, so a stroke landing there is
    // its own and never a shortcut.
    static func routes(to window: NSWindow, frontmost: NSWindow?) -> Bool {
        window === frontmost && !(window.firstResponder is TerminalSurface)
    }

    // Which of a sheet and the window it hangs off counts as key is not worth relying on,
    // so the chain is followed to whichever sheet ended up on top.
    private static var frontmostWindow: NSWindow? {
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
