import AppKit
import Observation

// Ties Sunlight together: while it is switched on, every window the app shows wears a
// SunlightFilter set to the colour the tracker reads from the sun, with the night colour
// the user chose at the warm end. Switching it off fades the windows back to neutral and
// lets the sheets go.
@MainActor
final class SunlightController {
    private let settings: AppSettings
    private let tracker: SunlightTracker
    private var filters: [Filter] = []
    private var observers: [NSObjectProtocol] = []

    private struct Filter {
        weak var window: NSWindow?
        let filter: SunlightFilter
    }

    init(settings: AppSettings, tracker: SunlightTracker = SunlightTracker()) {
        self.settings = settings
        self.tracker = tracker
    }

    func start() {
        guard observers.isEmpty else { return }
        // A sheet or a panel is a window of its own and arrives at any time, so each one
        // is dressed as it comes on screen. Not every window takes focus when it shows,
        // so a change in what is visible counts as well as a change of key window.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(duration: 0) }
            })
        }
        observeSettings()
        observeSun()
        apply(duration: 0)
    }

    // A switch or a slider is answered at a control's pace.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.sunlightEnabled
            _ = settings.sunlightMode
            _ = settings.sunlightNightKelvin
            _ = settings.sunlightPreviewing
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                apply(duration: Motion.controlDuration)
                observeSettings()
            }
        }
    }

    // A step the sun takes is a change nobody asked for, so it lands without motion. A
    // minute's step is far too small to see.
    private func observeSun() {
        withObservationTracking {
            _ = tracker.reading
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                apply(duration: 0)
                observeSun()
            }
        }
    }

    // The colour every window should wear right now. Held at the chosen colour when the
    // warmth is fixed, and while the slider is held, so the choice can be seen whatever
    // the hour.
    var tint: SunlightTint {
        guard settings.sunlightEnabled else { return .neutral }
        let night = settings.sunlightNightKelvin
        if settings.sunlightPreviewing || settings.sunlightMode == .fixed {
            return SunlightTint(kelvin: night)
        }
        return SunlightTint(kelvin: tracker.reading.kelvin(night: night))
    }

    private var followsSun: Bool {
        settings.sunlightEnabled && settings.sunlightMode == .followsSun
    }

    private func apply(duration: TimeInterval) {
        if followsSun { tracker.start() } else { tracker.stop() }
        let tint = self.tint
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
        filters.removeAll { $0.window == nil }
        if !tint.isNeutral {
            for window in NSApplication.shared.windows
            where Self.wearsSunlight(window) && !filters.contains(where: { $0.window === window }) {
                guard let filter = SunlightFilter(window: window) else { continue }
                filters.append(Filter(window: window, filter: filter))
            }
        }
        for entry in filters { entry.filter.set(tint, duration: duration) }
        // Once neutral, a sheet only costs a blend on every frame, so it goes once the
        // fade is over.
        if tint.isNeutral, !filters.isEmpty {
            let fading = filters
            filters = []
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                for entry in fading { entry.filter.remove() }
            }
        }
    }

    // Only the app's own windows and their sheets. A borderless window, such as the one
    // that takes pictures of a design, has no backdrop for the sheet to blend into, and
    // the file chooser belongs to the system.
    private static func wearsSunlight(_ window: NSWindow) -> Bool {
        guard window.isVisible, !(window is NSSavePanel) else { return false }
        return window.styleMask.contains(.titled) || window.sheetParent != nil
    }
}
