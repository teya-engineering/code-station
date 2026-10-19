import AppKit
import SwiftUI
import CodeStationCore

// Whether the hand-drawn focus rings should show right now.
//
// With keyboard navigation turned on, a click leaves focus on the button it pressed, and
// SwiftUI cannot tell that apart from focus that arrived by Tab. A ring left behind by a
// click reads as a stray box, so the rings only show once the keyboard is moving focus
// around, and hide again as soon as the mouse takes over.
@MainActor
@Observable
final class KeyboardFocusVisibility {
    static let shared = KeyboardFocusVisibility()

    private static let tab: UInt16 = 48
    private static let arrows: ClosedRange<UInt16> = 123...126

    private(set) var isVisible = false
    @ObservationIgnored private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            let keyboard = event.type == .keyDown
            let moves = keyboard && (event.keyCode == Self.tab || Self.arrows.contains(event.keyCode))
            MainActor.assumeIsolated {
                guard let self else { return }
                if moves && !self.isVisible { self.isVisible = true }
                if !keyboard && self.isVisible { self.isVisible = false }
            }
            return event
        }
    }
}

struct FocusRingStroke: View {
    let focused: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(focused && KeyboardFocusVisibility.shared.isVisible ? Theme.accent : .clear,
                    lineWidth: 2)
            .padding(-2)
            .allowsHitTesting(false)
    }
}
