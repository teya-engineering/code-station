import AppKit
import SwiftUI
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

// The GUI as a station host: while it holds the station it serves the same socket the
// daemon does, from the engine its windows use, and records it in the lock, so a terminal
// started beside it attaches instead of being refused.
@MainActor
struct GUIStationHostTests {

    // A terminal started while the GUI holds the station finds the GUI's socket in the
    // lock and attaches without starting a host of its own. What it does shows in the
    // GUI's store at once, and what the GUI does reaches its live list.
    @Test func aTerminalAttachesWhileTheGUIHoldsTheStation() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.waitsForRelease, host: RecordingHost())
        defer { fixture.tearDown() }
        fixture.store.renameSession(fixture.session.id, to: "From the GUI")
        let lockFile = fixture.scratch.path("station.lock")
        let lock = try #require(StationLock.claim(.gui, at: lockFile).lock)
        defer { lock.release() }
        let gui = GUIStationHost(store: fixture.store, runner: fixture.runner, refreshInterval: .milliseconds(50))
        try gui.serve(at: StationSocketPath.beside(lockFile), advertisingIn: lock)
        defer { gui.stop() }

        let terminal = try await StationDiscovery.attach(lockFile: lockFile, startHost: {
            Issue.record("The terminal started a host although the GUI holds the station.")
        })
        defer { terminal.close() }
        let titles = TitleLog()
        let reader = Task { @MainActor in
            for await directory in terminal.directoryUpdates() {
                titles.seen = directory.projects.flatMap(\.sessions).map(\.title)
            }
        }
        defer { reader.cancel() }
        #expect(await waitUntil { titles.seen == ["From the GUI"] })

        // The terminal's prompt runs in the GUI's runner.
        try await terminal.sendPrompt(fixture.session.id.uuidString, prompt: "hello")
        #expect(await waitUntil { fixture.runner.isBusy(fixture.session.id, store: fixture.store) })
        // A session the GUI starts shows in the terminal's live list.
        let project = try #require(fixture.store.projects.first)
        let added = try fixture.store.insertSession(in: project.id).get()
        fixture.store.renameSession(added.id, to: "Also from the GUI")
        #expect(await waitUntil { titles.seen.contains("Also from the GUI") }, "\(titles.seen)")

        try Data().write(to: fixture.scratch.path("release"))
    }

    // Stopping lets the terminals go and clears the endpoint, while the GUI keeps the
    // station.
    @Test func stoppingClearsTheEndpointAndKeepsTheStation() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let lockFile = fixture.scratch.path("station.lock")
        let lock = try #require(StationLock.claim(.gui, at: lockFile).lock)
        defer { lock.release() }
        let gui = GUIStationHost(store: fixture.store, runner: fixture.runner)
        let endpoint = try gui.serve(at: StationSocketPath.beside(lockFile), advertisingIn: lock)
        #expect(StationLock.holder(at: lockFile)?.endpoint == endpoint)

        gui.stop()

        #expect(StationLock.holder(at: lockFile)?.kind == .gui)
        #expect(StationLock.holder(at: lockFile)?.endpoint == nil)
        #expect(!FileManager.default.fileExists(atPath: endpoint))
    }

    // The GUI has a screen of its own: a turn that ends in the session it has selected,
    // while it is the active app, is read, though no terminal shows it.
    @Test func aTurnEndingInTheGUIsSelectionIsRead() async throws {
        let recorder = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}'
        """, host: recorder)
        defer { fixture.tearDown() }
        fixture.store.selectSession(fixture.session.id)
        let gui = GUIStationHost(store: fixture.store, runner: fixture.runner)
        let terminal: any StationInterface = gui.station.connect()

        try await terminal.sendPrompt(fixture.session.id.uuidString, prompt: "hello")

        #expect(await waitUntil { recorder.endings.count == 1 })
        #expect(try await terminal.listDirectory().projects.first?.sessions.first?.state == "IDLE")
    }

    // Quitting with nobody attached and nothing running quits as before: there is nobody
    // to hand the station to.
    @Test func quittingWithNothingAttachedOrBusyNeedsNoSuccessor() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let scratch = fixture.scratch.path("station.sock").path
        let gui = GUIStationHost(store: fixture.store, runner: fixture.runner)
        try gui.serve(at: scratch, advertisingIn: nil)
        defer { gui.stop() }

        #expect(!gui.needsSuccessor)
    }

    // Quitting the GUI with a terminal attached hands the station to a daemon: the GUI
    // stops starting turns, lets go once none runs and quits as before, and the daemon it
    // starts claims the station. The terminal ends up on the daemon and keeps working.
    @Test func quittingWithATerminalAttachedKeepsTheTerminalWorking() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let id = fixture.session.id
        let lockFile = fixture.scratch.path("station.lock")
        let lock = try #require(StationLock.claim(.gui, at: lockFile).lock)
        let gui = GUIStationHost(store: fixture.store, runner: fixture.runner, refreshInterval: .milliseconds(50))
        try gui.serve(at: StationSocketPath.beside(lockFile), advertisingIn: lock)
        let terminal = try await StationDiscovery.attach(lockFile: lockFile, startHost: {
            Issue.record("The terminal started a host although the GUI holds the station.")
        })
        defer { terminal.close() }
        let titles = TitleLog()
        let reader = Task { @MainActor in
            for await directory in terminal.directoryUpdates() {
                titles.seen = directory.projects.flatMap(\.sessions).map(\.title)
            }
        }
        defer { reader.cancel() }
        #expect(await waitUntil { !titles.seen.isEmpty && gui.server.clientCount == 1 })
        #expect(gui.needsSuccessor)

        // The app's quit: hand over, then everything it does on quit, then the daemon.
        var stopped = 0
        var released = false
        let handover = gui.handOverForQuit(onStarted: { stopped += 1 }, letGo: { released = true })
        #expect(handover.successor == StationLock.Kind.daemon.title)
        try await handover.run()
        #expect(await waitUntil { released })
        #expect(stopped == 1)
        fixture.store.renameSession(id, to: "Renamed as the GUI quits")
        gui.stop()
        gui.station.shutdown()
        lock.release()
        let daemonLock = try #require(await StationLock.claimOnceReleased(.daemon, at: lockFile).lock)
        let daemon = try StationDaemon(station: StationCommands.start(host: RecordingHost(),
                                                                      storeURL: fixture.scratch.path("projects.json")),
                                       lock: daemonLock, socketPath: StationSocketPath.beside(lockFile),
                                       onExit: {})
        defer { daemon.shutdown() }

        #expect(await waitUntil { titles.seen == ["Renamed as the GUI quits"] }, "\(titles.seen)")
        #expect(await waitUntil { daemon.server.clientCount == 1 })
        #expect(try await terminal.listDirectory().projects.first?.sessions.first?.id == id.uuidString)
    }

    // Closing the main window quits the app (ticket 28). With a turn running and a
    // terminal attached, AppKit is told "later" and waits in a loop of its own. While it
    // waits, the window comes back with the running-turns Dialog, a terminal starting up
    // still gets its handshake and hears where the station is going, and stopping the turn
    // hands the station over. The terminals end up on the daemon.
    @Test func closingTheWindowWithATurnRunningAsksAndStoppingHandsOver() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.waitsForRelease, host: RecordingHost())
        defer { fixture.tearDown() }
        let id = fixture.session.id
        fixture.store.renameSession(id, to: "Fix login")
        let lockFile = fixture.scratch.path("station.lock")
        let lock = try #require(StationLock.claim(.gui, at: lockFile).lock)
        let gui = GUIStationHost(store: fixture.store, runner: fixture.runner, refreshInterval: .milliseconds(50))
        try gui.serve(at: StationSocketPath.beside(lockFile), advertisingIn: lock)
        let terminal = try await StationDiscovery.attach(lockFile: lockFile, startHost: {
            Issue.record("The terminal started a host although the GUI holds the station.")
        })
        defer { terminal.close() }
        try await terminal.sendPrompt(id.uuidString, prompt: "hello")
        #expect(await waitUntil { fixture.runner.isBusy(id, store: fixture.store) })
        let app = QuittingApp()
        app.window.close()

        let quit = app.closeToQuit(gui)

        // The window comes back to ask.
        #expect(await waitUntil { app.dialogs.current?.title == "A turn is still running" })
        #expect(app.window.isVisible)
        #expect(app.dialogs.current?.actions.map(\.label) == ["Wait for it", "Stop it"])
        // A terminal starting now is answered, and told the station is moving.
        let late = try await StationDiscovery.attach(lockFile: lockFile, startHost: {
            Issue.record("A terminal started a host while the GUI was handing over.")
        })
        defer { late.close() }
        await #expect(throws: StationRefusal.self) {
            try await late.sendPrompt(id.uuidString, prompt: "one more")
        }

        try app.dialogs.run(#require(app.dialogs.current?.actions.last))

        #expect(await waitUntil { quit.answer != nil })
        #expect(quit.answer == true)
        #expect(quit.answeredWhileWaiting, "The quit's own loop never saw the handover through.")
        #expect(app.dialogs.current == nil)
        #expect(!fixture.runner.isBusy(id, store: fixture.store))
        let daemon = try await Self.daemonTakesOver(from: gui, lock: lock, lockFile: lockFile, fixture: fixture)
        defer { daemon.shutdown() }
        #expect(await waitUntil { daemon.server.clientCount == 2 })
        #expect(try await terminal.listDirectory().projects.first?.sessions.first?.title == "Fix login")
    }

    // Choosing to wait leaves the Dialog up with only the way to stop, and the station is
    // handed over once the turn ends on its own.
    @Test func closingTheWindowWithATurnRunningAndWaitingHandsOverOnceItEnds() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.waitsForRelease, host: RecordingHost())
        defer { fixture.tearDown() }
        let id = fixture.session.id
        let lockFile = fixture.scratch.path("station.lock")
        let lock = try #require(StationLock.claim(.gui, at: lockFile).lock)
        let gui = GUIStationHost(store: fixture.store, runner: fixture.runner, refreshInterval: .milliseconds(50))
        try gui.serve(at: StationSocketPath.beside(lockFile), advertisingIn: lock)
        let terminal = try await StationDiscovery.attach(lockFile: lockFile, startHost: {
            Issue.record("The terminal started a host although the GUI holds the station.")
        })
        defer { terminal.close() }
        try await terminal.sendPrompt(id.uuidString, prompt: "hello")
        #expect(await waitUntil { fixture.runner.isBusy(id, store: fixture.store) })
        let app = QuittingApp()
        app.window.close()

        let quit = app.closeToQuit(gui)
        #expect(await waitUntil { app.dialogs.current?.title == "A turn is still running" })
        try app.dialogs.run(#require(app.dialogs.current?.actions.first))

        #expect(await waitUntil { app.dialogs.current?.title == "Waiting for a turn to end" })
        #expect(app.dialogs.current?.actions.map(\.label) == ["Stop it"])
        #expect(quit.answer == nil)
        try Data().write(to: fixture.scratch.path("release"))

        #expect(await waitUntil { quit.answer != nil })
        #expect(quit.answer == true)
        #expect(quit.answeredWhileWaiting, "The quit's own loop never saw the handover through.")
        #expect(fixture.store.transcript(of: id).contains { $0.role == .assistant && $0.text == "Done" })
        let daemon = try await Self.daemonTakesOver(from: gui, lock: lock, lockFile: lockFile, fixture: fixture)
        defer { daemon.shutdown() }
        #expect(await waitUntil { daemon.server.clientCount == 1 })
    }

    // What the app does once the handover let go: everything it does on quit, then the
    // daemon it starts claims the station.
    private static func daemonTakesOver(from gui: GUIStationHost, lock: StationLock, lockFile: URL,
                                        fixture: RunnerHarness) async throws -> StationDaemon {
        gui.stop()
        gui.station.shutdown()
        lock.release()
        let daemonLock = try #require(await StationLock.claimOnceReleased(.daemon, at: lockFile).lock)
        return try StationDaemon(station: StationCommands.start(host: RecordingHost(),
                                                                storeURL: fixture.scratch.path("projects.json")),
                                 lock: daemonLock, socketPath: StationSocketPath.beside(lockFile),
                                 onExit: {})
    }

    private static let waitsForRelease = """
    IFS= read -r input
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
    wait_for "$folder/release"
    printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}'
    """
}

@MainActor
private final class TitleLog {
    var seen: [String] = []
}

// The parts of the app a quit by closing the window goes through: the main window with
// the handover's prompts in it, closed by the person, and AppKit's "later", which waits
// for the answer in a run loop of its own, in the modal panel mode.
@MainActor
private final class QuittingApp {
    let slot = StationHandoverSlot()
    let dialogs = DialogPresenter()
    let window: NSWindow

    init() {
        let content = Theme.background
            .overlay { DialogHost() }
            .background { StationHandoverPrompts() }
            .environment(slot)
            .environment(dialogs)
        window = testWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.orderFront(nil)
    }

    // Quits the way the window's close does: asks for the quit, which starts the handover
    // and then waits in AppKit's loop until it is answered.
    func closeToQuit(_ gui: GUIStationHost) -> QuitOutcome {
        let outcome = QuitOutcome()
        let window = self.window
        AppQuit.request { [slot] in
            gui.quitHandingOver(in: slot, message: "", shortWait: .milliseconds(300),
                                onStarted: {}, bringBackWindow: { window.orderFront(nil) },
                                quit: { outcome.answer = $0 })
            let deadline = Date().addingTimeInterval(20)
            while outcome.answer == nil, Date() < deadline {
                _ = RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05))
            }
            outcome.answeredWhileWaiting = outcome.answer != nil
        }
        return outcome
    }
}

@MainActor
private final class QuitOutcome {
    var answer: Bool?
    var answeredWhileWaiting = false
}
