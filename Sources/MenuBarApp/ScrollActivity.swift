import AppKit
import SwiftUI

// Whether a list is moving under the pointer right now.
//
// A scroll drags rows past a pointer that has not moved, and AppKit reports every one of
// them as a hover. A row that answers each one lights up, swaps its count for its buttons
// and lays itself out again, so a single flick relayouts the whole way down the list.
// Rows hand their hover here instead, and it is held until the list comes to rest, which
// is the moment the pointer is really over a row rather than the row passing under it.
@MainActor
final class ScrollActivity {
    static let shared = ScrollActivity()

    // Long enough to bridge the gap between two flicks of a wheel, short enough that the
    // row the list stops under answers as soon as it has stopped.
    private static let rest = Duration.milliseconds(140)

    private var isScrolling = false
    private var waiting: [() -> Void] = []
    private var settle: Task<Void, Never>?
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.began() }
            return event
        }
    }

    // Runs the work now if nothing is scrolling, and otherwise once the scroll ends. Two
    // answers from the same row arrive in the order they happened, so the last one wins
    // and the row ends up in the state the pointer left it in.
    func whenRested(_ work: @escaping () -> Void) {
        guard isScrolling else {
            work()
            return
        }
        waiting.append(work)
    }

    private func began() {
        isScrolling = true
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: Self.rest)
            guard !Task.isCancelled else { return }
            self?.rested()
        }
    }

    private func rested() {
        isScrolling = false
        let held = waiting
        waiting = []
        for work in held { work() }
    }
}

extension View {
    // Hover that a scroll cannot cause: it answers the pointer arriving on its own, and
    // whatever a scroll had to say waits until the scroll is over.
    func onPointerHover(_ handler: @escaping (Bool) -> Void) -> some View {
        onHover { inside in
            ScrollActivity.shared.whenRested { handler(inside) }
        }
    }
}
