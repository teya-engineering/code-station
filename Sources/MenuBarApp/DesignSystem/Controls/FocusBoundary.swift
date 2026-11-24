import AppKit
import SwiftUI

extension View {
    func focusBoundary(active: Bool = true) -> some View {
        background(FocusBoundary(active: active))
    }
}

// Floating surfaces share the window's key loop. Keep Tab inside their bounds while
// allowing a menu or child dialog to take focus, then return to the opening control.
struct FocusBoundary: NSViewRepresentable {
    let active: Bool

    func makeNSView(context: Context) -> BoundaryView { BoundaryView() }
    func updateNSView(_ view: BoundaryView, context: Context) { view.active = active }
    static func dismantleNSView(_ view: BoundaryView, coordinator: ()) { view.stop() }

    final class BoundaryView: NSView {
        var active = true
        private var monitor: Any?
        private weak var previous: NSResponder?
        private weak var owner: NSWindow?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, monitor == nil else { return }
            owner = window
            let editor = window.firstResponder as? NSTextView
            previous = editor?.isFieldEditor == true ? editor?.delegate as? NSResponder : window.firstResponder
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, self.active, event.keyCode == 48,
                          event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                          let window = self.window, event.window === window,
                          WindowKeyMonitor.frontmostWindow === window else { return false }
                    return self.move(backward: event.modifierFlags.contains(.shift))
                }
                return handled ? nil : event
            }
        }

        private func contains(_ view: NSView) -> Bool {
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
            let area = convert(bounds, to: nil)
            let rect = view.convert(view.bounds, to: nil)
            if area.contains(rect) { return true }
            var ancestor = view.enclosingScrollView
            while let scroll = ancestor {
                if area.contains(scroll.convert(scroll.bounds, to: nil)) { return true }
                ancestor = scroll.superview?.enclosingScrollView
            }
            return false
        }

        func move(backward: Bool) -> Bool {
            guard let window else { return false }
            let editor = window.firstResponder as? NSTextView
            let control = editor?.isFieldEditor == true ? editor?.delegate as? NSView : window.firstResponder as? NSView
            guard let first = control ?? window.contentView else { return false }
            var seen = Set<ObjectIdentifier>()
            var next: NSView? = first
            while let view = next, seen.insert(ObjectIdentifier(view)).inserted {
                next = backward ? view.previousValidKeyView : view.nextValidKeyView
                if let candidate = next, contains(candidate), window.makeFirstResponder(candidate) {
                    candidate.scrollToVisible(candidate.bounds)
                    return true
                }
            }
            return true
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let previous, let owner,
               owner.firstResponder == nil || (owner.firstResponder as? NSView).map(contains) == true {
                owner.makeFirstResponder(previous)
            }
        }
    }
}
