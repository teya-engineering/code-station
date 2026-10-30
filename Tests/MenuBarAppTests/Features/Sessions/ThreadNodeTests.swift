import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The dot keeps its own look while motion plays, so these check what it shows once a
// change has played out. A point just outside the resting dot is filled only while the
// dot is swollen, which is how a done or failed turn wears its mark.
@MainActor
struct ThreadNodeTests {
    @MainActor @Observable final class Phase {
        var value: ThreadPhase
        init(_ value: ThreadPhase) { self.value = value }
    }

    private struct Node: View {
        let phase: Phase

        var body: some View {
            ThreadNode(phase: phase.value, endedCleanly: true, colour: .purple,
                       restingFill: .purple.opacity(0.72))
                .frame(width: 40, height: 40)
                .background(Color.white)
                // Pinned so the result does not depend on the Reduce Motion setting of
                // the Mac running the tests.
                .environment(\._accessibilityReduceMotion, false)
        }
    }

    @Test func aFinishTheUserWatchedGoesBackToThePlainDot() async throws {
        let phase = Phase(.running)
        let (window, host) = mount(phase)
        defer { window.close() }
        try await settle(0.4)

        phase.value = .idle
        try await settle(0.8)
        #expect(isSwollen(host), "the watched finish still plays its close")

        try await settle(ThreadNode.settleDelay)
        #expect(!isSwollen(host))
    }

    @Test func anUnreadFinishKeepsItsTick() async throws {
        let phase = Phase(.running)
        let (window, host) = mount(phase)
        defer { window.close() }
        try await settle(0.4)

        phase.value = .finished
        try await settle(ThreadNode.settleDelay + 0.6)
        #expect(isSwollen(host))
    }

    private func mount(_ phase: Phase) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: Node(phase: phase))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        window.orderFront(nil)
        return (window, host)
    }

    // Waits by suspending rather than spinning the run loop, so the view's own tasks get
    // the main actor while the test waits.
    private func settle(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private func isSwollen(_ view: NSView) -> Bool {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = rep.pixelsWide / Int(view.bounds.width)
        guard let colour = rep.colorAt(x: 26 * scale, y: 20 * scale)?.usingColorSpace(.deviceRGB)
        else { return false }
        return colour.greenComponent < 0.8
    }
}
