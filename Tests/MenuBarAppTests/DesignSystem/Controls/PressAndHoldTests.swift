import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct PressAndHoldTests {
    @Test func aStationaryPressFiresOnce() async throws {
        let harness = HoldHarness()
        defer { harness.close() }

        try harness.send(.leftMouseDown)
        #expect(await waitUntil(timeout: .seconds(2)) { harness.holds == 1 })
        await harness.waitPastHold()
        #expect(harness.holds == 1)
        try harness.send(.leftMouseUp)
    }

    @Test func aReleaseThatBypassesTheEventMonitorCancelsTheHold() async throws {
        let harness = HoldHarness()
        defer { harness.close() }

        try harness.send(.leftMouseDown)
        harness.mouse.state.isLeftButtonDown = false
        await harness.waitPastHold()

        #expect(harness.holds == 0)
    }

    @Test func aDragThatBypassesTheEventMonitorCancelsTheHold() async throws {
        let harness = HoldHarness()
        defer { harness.close() }

        try harness.send(.leftMouseDown)
        harness.mouse.state.location.x += PressAndHold.slop + 10
        await harness.waitPastHold()

        #expect(harness.holds == 0)
    }

    @Test func returningAfterADragDoesNotRestoreTheHold() async throws {
        let harness = HoldHarness()
        defer { harness.close() }

        try harness.send(.leftMouseDown)
        try harness.send(.leftMouseDragged, at: NSPoint(x: 130, y: 40))
        try harness.send(.leftMouseDragged)
        await harness.waitPastHold()
        #expect(harness.holds == 0)
        try harness.send(.leftMouseUp)

        try harness.send(.leftMouseDown)
        #expect(await waitUntil(timeout: .seconds(2)) { harness.holds == 1 })
        try harness.send(.leftMouseUp)
    }

    @Test func releasingBeforeTheThresholdCancelsTheHold() async throws {
        let harness = HoldHarness()
        defer { harness.close() }

        try harness.send(.leftMouseDown)
        try harness.send(.leftMouseUp)
        await harness.waitPastHold()

        #expect(harness.holds == 0)
    }

    @Test func removingTheViewCancelsTheHold() async throws {
        let harness = HoldHarness()
        defer { harness.close() }

        try harness.send(.leftMouseDown)
        harness.window.contentView = nil
        await harness.waitPastHold()

        #expect(harness.holds == 0)
    }
}

@MainActor
private final class HoldHarness {
    let mouse = TestMouse()
    let window: NSWindow
    var holds = 0

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView:
            Rectangle().fill(Theme.card)
                .onPressAndHold { [weak self] in self?.holds += 1 }
                .environment(\.pressAndHoldMouseInput, mouse.input))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(NSSize(width: 200, height: 80))
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 80)
        window.center()
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func send(_ type: NSEvent.EventType, at point: NSPoint = NSPoint(x: 100, y: 40)) throws {
        try mouse.send(type, at: point, in: window)
    }

    func waitPastHold() async {
        try? await Task.sleep(for: .seconds(PressAndHold.duration + 0.2))
    }

    func close() {
        window.close()
        window.contentView = nil
    }
}
