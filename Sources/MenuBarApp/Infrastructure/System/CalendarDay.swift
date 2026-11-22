import AppKit
import Observation

// The day it is now, for text that says "today" or "yesterday". A view that writes those
// words reads `today`, so it is drawn again when midnight passes instead of keeping a
// day that has gone. It changes once a day, so observing it costs nothing between days.
@MainActor
@Observable
final class CalendarDay {
    static let shared = CalendarDay()

    private(set) var today = Calendar.current.startOfDay(for: Date())

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        // The day can also turn while the Mac sleeps or when the clock or zone is changed,
        // and the day-changed notice is not promised for those.
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemClockDidChange,
                     .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    private func refresh() {
        let day = Calendar.current.startOfDay(for: Date())
        if day != today { today = day }
    }
}
