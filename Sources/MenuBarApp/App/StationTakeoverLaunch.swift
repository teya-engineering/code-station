import AppKit
import SwiftUI
import CodeStationCore

// What the app runs first when it opens while the background service holds the station
// (ADR-0003). It asks the service to hand the station over and claims it once the service
// has let go, then starts the app proper. None of the stores are built until then, so
// nothing is read while the service still owns the files. Turns still running on the
// service after a short wait are put to the person in a Dialog: wait for them, or stop
// them.
@MainActor
final class StationTakeoverLaunch: NSObject, NSApplicationDelegate {
    private let lockFile: URL
    private let patience: StationSocketClient.Patience
    private let onClaimed: @MainActor (StationLock) -> Void
    let slot = StationHandoverSlot()
    let dialogs = DialogPresenter()
    private var window: NSWindow?
    // The client of the service while the takeover talks to it.
    private var service: StationSocketClient?

    // `patience` is how long the service may stay silent before the person is told.
    init(lockFile: URL = StationLock.defaultFile, patience: StationSocketClient.Patience = .standard,
         onClaimed: @escaping @MainActor (StationLock) -> Void) {
        self.lockFile = lockFile
        self.patience = patience
        self.onClaimed = onClaimed
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Preferences.appearance().apply()

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.backgroundColor = Theme.backgroundNSColor
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: StationTakeoverView()
            .environment(slot)
            .environment(dialogs))
        win.center()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        begin()
    }

    // Starts taking the station over. The window shows what `slot` and `dialogs` say.
    func begin() {
        Task { await takeOver() }
    }

    // Closing the window before the app has started gives up and quits; the service
    // keeps the station if it has not let go yet.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func takeOver() async {
        let lockFile = self.lockFile
        let service = StationSocketClient(endpoint: { StationLock.holder(at: lockFile)?.endpoint },
                                          holder: { StationLock.holder(at: lockFile) }, patience: patience)
        self.service = service
        defer { service.close() }
        slot.message = "Code Station takes over from the background service once they end. "
            + "Wait for them, or stop them and keep what they have done."
        while true {
            let handover = StationHandover(station: service, successor: StationLock.Kind.gui.title)
            slot.current = handover
            do {
                try await handover.run()
            } catch {
                // A service from another build will not talk to this one, so it cannot be
                // asked to hand over: offer to stop it instead.
                if service.isRefused { return offerToStop(error.message) }
                // A service that takes the connection and does not answer may be busy, or
                // stuck. The client keeps trying, so the takeover waits for an answer and
                // asks again, offering meanwhile to stop it.
                if error == StationRefusal.notAnswering {
                    guard await waitForAnswer(from: service) else { return }
                    continue
                }
                // A service that has just gone (its idle exit) left the station free anyway.
                if error != StationRefusal.unreachable && error != StationRefusal.hostGone {
                    return fail(error.message)
                }
            }
            break
        }
        await claim(StationLock.claimOnceReleased(.gui, at: lockFile))
    }

    // Says the service is not answering, with the choice to stop it or quit, until it
    // answers. False when the person chose to stop it, which takes the station on its own.
    private func waitForAnswer(from service: StationSocketClient) async -> Bool {
        slot.current = nil
        let quit = { NSApp.terminate(nil) }
        var dialog = Dialog(
            title: "The background service isn't answering",
            message: "It may be busy handing over. Code Station keeps trying and takes over once it answers. "
                + "Stop it to take over now: any turns it is running stop, keeping what they have done.",
            actions: [
                Dialog.Action(label: "Stop it and take over", kind: .destructive) { [weak self] in
                    self?.stopOldService()
                },
                Dialog.Action(label: "Quit", kind: .cancel, handler: quit),
            ],
            onCancel: quit)
        dialog.width = 400
        SessionLog.note("the background service is not answering the takeover")
        dialogs.show(dialog)
        // Ends when the client is closed, which stopping the service does.
        for await link in service.linkUpdates() where link == .answering {
            dialogs.withdraw(dialog.id)
            return true
        }
        return false
    }

    // The service is from another version of Code Station, which cannot hand the station
    // over to this one. Stopping it is what quitting it would do: its turns stop, keeping
    // what they have done, it saves and lets go, and this app takes the station.
    private func offerToStop(_ reason: String) {
        slot.current = nil
        let quit = { NSApp.terminate(nil) }
        var dialog = Dialog(
            title: "The background service is from another version",
            message: "It cannot hand the station over to this Code Station. Stop it to take over: "
                + "any turns it is running stop, keeping what they have done.",
            actions: [
                Dialog.Action(label: "Stop it and take over", kind: .primary) { [weak self] in
                    self?.stopOldService()
                },
                Dialog.Action(label: "Quit", kind: .cancel, handler: quit),
            ],
            onCancel: quit)
        dialog.width = 400
        SessionLog.note("the background service refused the takeover: \(reason)")
        dialogs.show(dialog)
    }

    private func stopOldService() {
        let lockFile = self.lockFile
        service?.close()
        slot.waitingWithoutHandover = true
        Task {
            SessionLog.note("stopping a background service of another version")
            await claim(StationLock.stopHolder(at: lockFile, claiming: .gui))
        }
    }

    private func claim(_ outcome: StationLock.Outcome) {
        slot.waitingWithoutHandover = false
        guard let lock = outcome.lock else {
            let owner = StationLock.holder(at: lockFile)?.name ?? "the Code Station background service"
            return fail("Its files are still in use by \(owner). Quit it, then open Code Station again.")
        }
        SessionLog.note("took the station over from the background service")
        slot.current = nil
        let window = self.window
        self.window = nil
        onClaimed(lock)
        window?.orderOut(nil)
    }

    private func fail(_ message: String) {
        slot.current = nil
        let quit = { NSApp.terminate(nil) }
        var dialog = Dialog(title: "Code Station could not take over",
                            message: message,
                            actions: [Dialog.Action(label: "Quit", kind: .primary, handler: quit)],
                            onCancel: quit)
        dialog.width = 380
        dialogs.show(dialog)
    }
}

private struct StationTakeoverView: View {
    @Environment(StationHandoverSlot.self) private var slot

    var body: some View {
        Theme.background
            .ignoresSafeArea()
            .overlay {
                if slot.current != nil || slot.waitingWithoutHandover {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Taking over from the background service…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay { DialogHost() }
            .overlay { StationHandoverPrompts() }
    }
}
