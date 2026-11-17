import AppKit
import Testing
@testable import MenuBarApp

// Sending an NSEvent through the app does not update the device state read by a hold.
@MainActor
final class TestMouse {
    var state = PressAndHold.MouseState(location: .zero, isLeftButtonDown: false)

    var input: PressAndHold.MouseInput { .init { [self] in state } }

    func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws {
        state.location = window.convertPoint(toScreen: point)
        if type == .leftMouseDown { state.isLeftButtonDown = true }
        if type == .leftMouseUp { state.isLeftButtonDown = false }
        NSApp.sendEvent(try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: state.isLeftButtonDown ? 1 : 0)))
    }
}
