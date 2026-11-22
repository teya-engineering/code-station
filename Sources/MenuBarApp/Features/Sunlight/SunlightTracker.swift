import AppKit
import Observation

// Follows the sun through the day for the Sunlight theme. It reads the sun once a minute
// and again whenever the clock could have jumped: the machine waking, the time zone
// changing, or the clock being set. Only the thing that draws the warmth should observe
// it, so a tick never lays the window out.
@MainActor
@Observable
final class SunlightTracker {
    private(set) var reading: SunReading
    private(set) var place: Coordinates

    // Replaced by a probe to scrub through a day; the app itself reads the real clock.
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(place: Coordinates? = nil, now: @escaping () -> Date = Date.init) {
        let place = place ?? ZoneLocation.bestGuess()
        self.place = place
        self.now = now
        reading = Sunlight.reading(at: now(), from: place)
    }

    deinit {
        timer?.cancel()
    }

    // The zone may have changed while the tracker was stopped, with nobody listening, so
    // the place is looked up again on every start.
    func start() {
        guard timer == nil else { return }
        relocate()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 60, repeating: .seconds(60), leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.resume()
        self.timer = timer

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.relocate() }
            })
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
    }

    // Reads the sun again from the same place.
    func refresh() {
        let next = Sunlight.reading(at: now(), from: place)
        if next != reading { reading = next }
    }

    // The zone may have changed with the clock, so the place is looked up again first.
    // Foundation keeps the zone it read last until it is told to drop it.
    func relocate() {
        NSTimeZone.resetSystemTimeZone()
        place = ZoneLocation.bestGuess()
        refresh()
    }
}
