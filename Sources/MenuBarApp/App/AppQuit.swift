import AppKit
import CodeStationCore

// The app asking AppKit to quit on its own, rather than from the Quit menu item: the main
// window was closed, or an update is ready to take.
@MainActor
enum AppQuit {
    // Asks for the quit once whatever is running now has finished, such as the window's
    // close. `quit` stands in for `NSApp.terminate` in tests.
    //
    // It goes through the run loop, not the main queue. A quit that hands the station over
    // answers AppKit "later", and AppKit then waits in a run loop of its own inside
    // `terminate`. Started from a main-queue block, that loop could never run the main
    // queue again: the handover, the window coming back with its Dialog and every
    // terminal's handshake all wait on it, so the app would sit there with nothing on
    // screen (ticket 28).
    static func request(_ quit: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        RunLoop.main.perform { MainActor.assumeIsolated { quit() } }
    }
}

extension GUIStationHost {
    // Quits handing the station to a daemon (ADR-0003), once AppKit was told "later". The
    // handover goes in `slot`, where the main window's `StationHandoverPrompts` asks
    // about turns still running. Whenever it asks, `bringBackWindow` runs, so a window
    // closed to quit comes back with the question. `quit` runs once: with true when the
    // station was let go for a daemon to claim, false when the handover failed and the
    // app quits as it always has.
    func quitHandingOver(in slot: StationHandoverSlot, message: String,
                         shortWait: Duration = .seconds(3),
                         onStarted: @escaping @MainActor () -> Void,
                         bringBackWindow: @escaping @MainActor () -> Void,
                         quit: @escaping @MainActor (_ handedOver: Bool) -> Void) {
        let once = QuitAnswer(quit)
        let running = handOverForQuit(shortWait: shortWait, onStarted: onStarted,
                                      letGo: { once.answer(true) })
        slot.message = message
        slot.current = running
        Task { @MainActor in
            do {
                try await running.run()
            } catch {
                SessionLog.note("could not hand the station over: \(error)")
                once.answer(false)
            }
        }
        Self.bringBack(bringBackWindow, whenever: running)
    }

    // Watches the handover's phase rather than polling it, so the window is back the moment
    // the Dialog is, and each time the handover asks again (a turn started while stopping).
    private static func bringBack(_ bringBackWindow: @escaping @MainActor () -> Void,
                                  whenever handover: StationHandover) {
        if handover.isAsking { bringBackWindow() }
        guard handover.phase != .released else { return }
        withObservationTracking {
            _ = handover.phase
        } onChange: {
            // Told before the change lands, so it is read once it has.
            Task { @MainActor in bringBack(bringBackWindow, whenever: handover) }
        }
    }
}

@MainActor
private final class QuitAnswer {
    private var quit: (@MainActor (Bool) -> Void)?

    init(_ quit: @escaping @MainActor (Bool) -> Void) {
        self.quit = quit
    }

    func answer(_ handedOver: Bool) {
        let quit = self.quit
        self.quit = nil
        quit?(handedOver)
    }
}
