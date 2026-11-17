import AppKit
import SwiftUI

extension View {
    // Calls `onHold` once the left button has been held still on this view for a moment.
    // The press still reaches the view underneath as an ordinary click when it is let go,
    // so a caller that acts on the hold has to ignore that click itself.
    func onPressAndHold(perform onHold: @escaping () -> Void) -> some View {
        overlay(PressAndHoldCatcher(onHold: onHold))
    }
}

enum PressAndHold {
    static let duration: TimeInterval = 0.45
    // A press that wanders further than this is a drag, not a hold.
    static let slop: CGFloat = 4

    struct MouseState {
        var location: NSPoint
        var isLeftButtonDown: Bool

        @MainActor static var current: MouseState {
            MouseState(location: NSEvent.mouseLocation,
                       isLeftButtonDown: NSEvent.pressedMouseButtons & 1 != 0)
        }
    }

    final class MouseInput: Sendable {
        static let live = MouseInput { .current }
        let read: @MainActor @Sendable () -> MouseState

        init(_ read: @escaping @MainActor @Sendable () -> MouseState) {
            self.read = read
        }
    }

    // Runs `action` once the press now under way has been let go and its click has been
    // delivered. A view watching for its own release can be rebuilt during the hold and
    // miss it, so this watches the whole app instead.
    static func afterRelease(_ action: @escaping @MainActor () -> Void) {
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            DispatchQueue.main.async { action() }
            return event
        }
    }
}

extension EnvironmentValues {
    @Entry var pressAndHoldMouseInput = PressAndHold.MouseInput.live
}

private struct PressAndHoldCatcher: NSViewRepresentable {
    let onHold: () -> Void

    @Environment(\.pressAndHoldMouseInput) private var mouseInput

    func makeNSView(context: Context) -> PressAndHoldView {
        let view = PressAndHoldView()
        view.onHold = onHold
        view.mouseInput = mouseInput
        return view
    }

    func updateNSView(_ view: PressAndHoldView, context: Context) {
        view.onHold = onHold
        view.mouseInput = mouseInput
    }
}

// Watches presses through a local monitor rather than taking them, so the button under it
// still gets its click, its hover and its drag.
private final class PressAndHoldView: NSView {
    var onHold: (() -> Void)?
    var mouseInput = PressAndHold.MouseInput.live

    private var monitor: Any?
    private var timer: Timer?
    private var pressedAt: NSPoint = .zero

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopWatching()
        } else if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                self?.handle(event)
                return event
            }
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.window === window else { return }
        switch event.type {
        case .leftMouseDown:
            cancel()
            // A control-click is a right-click, and a double click is its own gesture.
            guard event.clickCount == 1, !event.modifierFlags.contains(.control) else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return }
            pressedAt = event.locationInWindow
            let pressedOnScreen = mouseInput.read().location
            let timer = Timer(timeInterval: PressAndHold.duration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.timer = nil
                    // Once a drag session starts it takes the mouse events, so the monitor
                    // may never see the press wander or end. The pointer and button still tell.
                    let now = self.mouseInput.read()
                    guard now.isLeftButtonDown,
                          hypot(now.location.x - pressedOnScreen.x,
                                now.location.y - pressedOnScreen.y) <= PressAndHold.slop else { return }
                    self.onHold?()
                }
            }
            // Common modes, so the hold still fires while AppKit is tracking the press.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        case .leftMouseDragged:
            let moved = hypot(event.locationInWindow.x - pressedAt.x,
                              event.locationInWindow.y - pressedAt.y)
            if moved > PressAndHold.slop { cancel() }
        default:
            cancel()
        }
    }

    private func cancel() {
        timer?.invalidate()
        timer = nil
    }

    private func stopWatching() {
        cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
