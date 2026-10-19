import SwiftUI
import AppKit
import CodeStationCore

// The app is started as an AppKit one rather than through SwiftUI's App protocol. Every
// window it shows is an AppKit window it builds itself, so the only thing a SwiftUI scene
// would have brought is the main menu, and an empty scene kept around for that can end up
// on screen as a window with nothing in it.
@main
enum MenuBarApp {
    // NSApplication holds its delegate weakly, so ownership has to live somewhere else.
    @MainActor private static var delegate: NSApplicationDelegate?
    // Held for the life of the app and handed back on a normal quit. A crash leaves it to
    // the kernel, and the next launch reclaims what the dead process left behind.
    @MainActor static var stationLock: StationLock?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        // Claimed before AppDelegate is built: its stores open the station's files as
        // they are created, and a second copy must not get that far.
        switch StationLock.claim(.gui) {
        case .claimed(let lock):
            stationLock = lock
            let appDelegate = AppDelegate()
            delegate = appDelegate
            app.delegate = appDelegate
        case .refused(let holder?) where holder.kind == .daemon:
            // The background service hands the station over (ADR-0003); the app starts
            // once it has the station.
            let takeover = StationTakeoverLaunch(onClaimed: { lock in startClaimed(lock) })
            delegate = takeover
            app.delegate = takeover
        case .refused(let holder):
            let refusal = StationLockRefusal(holder: holder)
            delegate = refusal
            app.delegate = refusal
        }
        app.run()
    }

    // Starts the app proper once a handover gave it the station, after the app has
    // already finished launching under the takeover.
    @MainActor
    private static func startClaimed(_ lock: StationLock) {
        stationLock = lock
        let appDelegate = AppDelegate()
        delegate = appDelegate
        NSApp.delegate = appDelegate
        let launched = Notification(name: NSApplication.didFinishLaunchingNotification, object: NSApp)
        appDelegate.applicationWillFinishLaunching(launched)
        appDelegate.applicationDidFinishLaunching(launched)
    }
}

// The manager window is created and retained here rather than via a SwiftUI
// `Window` scene, because openWindow(id:) does not reliably re-show a singleton
// window once it has been closed. An AppKit window we own always comes back.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = ConfigStore()
    private let processes = ProcessManager()
    private let claude = ClaudeCodeManager()
    private let codex = CodexCodeManager()
    private let copilot = CopilotCodeManager()
    private let projects = ProjectStore()
    private lazy var runner: SessionRunner = {
        let runner = SessionRunner(
            mcpConfiguration: { [store] names in
                ConfigStore.mcpConfigurationData(from: store.servers, allowing: names,
                                                 taggingEnvironments: false)
            },
            host: AppHost(),
            defaultTroubleshootEnvironment: { TroubleshootEnvironment.first() })
        runner.designOpinions.captureScreens = { await DesignSecondOpinion.capture($0, in: $1, to: $2) }
        // Agents usually commit at the end of a turn, so the sidebar reads the session's
        // folders again then instead of waiting for the file system to report it.
        runner.onTurnEnded = { [projects, workingTrees] sessionID in
            guard let session = projects.session(sessionID) else { return }
            workingTrees.noteChanged(projects.workingDirectories(for: session))
        }
        return runner
    }()
    // The station served to terminals while this app holds it (ADR-0003). The app itself
    // keeps using the store and runner directly.
    private lazy var stationHost = GUIStationHost(store: projects, runner: runner, shortcuts: shortcuts)
    private let dictation = Dictation()
    private lazy var mobileAccess = MobileAccessController(store: projects, runner: runner,
                                                           gitStats: gitStats)
    private let workingTrees = WorkingTreeWatch()
    // Named after the store's own transcript folder, so a second copy of the app reads
    // the conversations it actually owns.
    private lazy var sessionTimes = SessionTimeWatch(
        transcripts: projects.transcriptsURL,
        loaded: { [projects] in projects.loadedTranscript(of: $0) })
    private let orphanedWorktrees = OrphanedWorktreeMonitor()
    // Schedules, sweeps and the rest of what the station does unasked, the same work the
    // daemon does when it is the host.
    private lazy var upkeep = StationUpkeep(store: projects, runner: runner,
                                            orphanedWorktrees: orphanedWorktrees)
    private let gitStats = GitStatsCache()
    private let terminals = TerminalStore()
    private let explorerMemory = ExplorerMemory()
    private let loginItem = LoginItem()
    // Reached from the main menu as well as the window, so the text size items can
    // change the same setting the Settings sheet shows.
    let appSettings = AppSettings()
    private let docker = DockerService()
    private let dispatch = DispatchStore()
    private let dispatchRunner = DispatchRunner()
    private let dispatchAuth = DispatchAuthStore()
    private let shortcuts = ShortcutStore()
    private let appUpdates = AppUpdateChecker()
    // The handover to a daemon as the app quits with terminals attached or sessions busy
    // (ADR-0003), and whether it went through, so the quit starts the daemon.
    private let handover = StationHandoverSlot()
    private var handsOverToDaemon = false
    private var answeredQuit = false
    private var window: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        appSettings.appearance.apply()
        // Sessions hold a pipe open to a CLI they do not control the lifetime of. Writing
        // to one that has just exited raises SIGPIPE, which would take the app down with
        // it; ignored, the write fails as an error the runner can report instead.
        signal(SIGPIPE, SIG_IGN)
        // A turn that was mid-flight when the app died leaves no other trace, so the log
        // needs somewhere to show that the run it belonged to ended here.
        SessionLog.note("app launched")
        StationUpkeep.launchHousekeeping()
        // A deleted project or session leaves no way back to its terminals, so they are
        // closed with it rather than kept alive by a store nothing can reach. Its open
        // shortcut output goes for the same reason.
        projects.onRemoved = { [weak self] owner in
            self?.terminals.discard(TerminalScope(owner))
            if let scope = ShortcutScope(owner) { self?.shortcuts.discard(scope) }
        }
        // The cleanup strips a terminal draws read the same upkeep.
        stationHost.station.upkeep = upkeep
        upkeep.start()
        AppNotifier.shared.activate()
        AppNotifier.shared.openSession = { [weak self] sessionID in
            self?.projects.selectSession(sessionID)
            self?.showManager()
        }
        serveTerminals()
        showManager()
    }

    // A terminal started while the app runs attaches to it instead of being refused: the
    // app serves the station's socket and records it in the lock it holds. Failing to
    // serve leaves the app as it was, with terminals refused.
    private func serveTerminals() {
        guard let lock = MenuBarApp.stationLock else { return }
        do {
            try stationHost.serve(at: StationSocketPath.beside(StationLock.defaultFile), advertisingIn: lock)
        } catch {
            SessionLog.note("could not serve the station to terminals: \(error)")
        }
    }

    @objc func biggerText(_ sender: Any?) {
        appSettings.textSize = appSettings.textSize.bigger
    }

    @objc func smallerText(_ sender: Any?) {
        appSettings.textSize = appSettings.textSize.smaller
    }

    @objc func actualSizeText(_ sender: Any?) {
        appSettings.textSize = .standard
    }

    // The window is the app, so closing it quits rather than leaving a process with no
    // way back into it except the Dock. Waiting for the last window to close is not
    // enough: a detached Design window, minimised or on another Space, would keep the
    // app running unseen, so the main window decides on its own.
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        // Quitting from inside the close would tear the window down while AppKit is
        // still closing it, so it waits for the close to finish. It must not wait on the
        // main queue: see `AppQuit`.
        AppQuit.request()
    }

    // Reopening only happens when the app is already running, which means the window
    // was hidden rather than closed, but the Dock icon still has to bring it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showManager()
        return true
    }

    func showManager() {
        if window == nil {
            let hosting = NSHostingController(rootView:
                RootView()
                    .environment(store)
                    .environment(processes)
                    .environment(claude)
                    .environment(codex)
                    .environment(copilot)
                    .environment(projects)
                    .environment(runner)
                    .environment(dictation)
                    .environment(workingTrees)
                    .environment(sessionTimes)
                    .environment(orphanedWorktrees)
                    .environment(upkeep)
                    .environment(gitStats)
                    .environment(terminals)
                    .environment(explorerMemory)
                    .environment(loginItem)
                    .environment(appSettings)
                    .environment(mobileAccess)
                    .environment(docker)
                    .environment(dispatch)
                    .environment(dispatchRunner)
                    .environment(dispatchAuth)
                    .environment(shortcuts)
                    .environment(appUpdates)
                    .environment(handover))
            // Let the window own its size instead of shrinking to the view's ideal size.
            hosting.sizingOptions = []
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            win.contentViewController = hosting
            win.setContentSize(NSSize(width: 1180, height: 820))
            win.title = "Teya Code Station"
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.backgroundColor = Theme.backgroundNSColor
            win.isReleasedWhenClosed = false
            win.contentMinSize = NSSize(width: 960, height: 640)
            win.delegate = self
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // Quitting with a terminal attached or a session busy hands the station to a daemon,
    // so the terminals keep working (ADR-0003). New turns stop, running ones are waited
    // for (or stopped, if the person says so), and the quit goes on once none is left.
    // With nobody attached and nothing busy, the app quits as it always has.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if handover.current != nil { return .terminateCancel }
        guard MenuBarApp.stationLock != nil, stationHost.needsSuccessor, Self.daemonExecutable != nil else {
            return .terminateNow
        }
        stationHost.quitHandingOver(
            in: handover,
            message: "Code Station hands the station to the background service once they end, "
                + "so your terminals keep working. Wait for them, or stop them and keep what they have done.",
            onStarted: { [weak self] in self?.upkeep.stop() },
            // A window closed to quit comes back to ask about turns still running.
            bringBackWindow: { [weak self] in self?.showManager() },
            quit: { [weak self] handedOver in
                self?.handsOverToDaemon = handedOver
                self?.answerQuit()
            })
        return .terminateLater
    }

    private func answerQuit() {
        guard !answeredQuit else { return }
        answeredQuit = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // `code-station` ships beside the app's own binary, in the bundle and in a build folder.
    private static var daemonExecutable: String? {
        guard let folder = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = folder.appendingPathComponent("code-station").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Taken first: stopping a process can orphan its children, and an orphan no
        // longer shows up as something the app started.
        let leftovers = QuitSweep.snapshot()
        // Terminals are let go first, so none starts anything while the app winds down,
        // and the upkeep next, so no schedule starts a run.
        stationHost.stop()
        upkeep.stop()
        processes.stopAll()
        shortcuts.stopAll()
        runner.stopAll()
        terminals.stopEverything()
        mobileAccess.stop()
        // Blocking here is deliberate. While the main thread waits, nothing can react to
        // a process ending by starting the next one, such as a queued prompt.
        let swept = leftovers.finish()
        if swept.killed > 0 {
            SessionLog.note("app quitting: killed \(counted(swept.killed, "process", plural: "processes")) "
                            + "that ignored the stop, \(swept.left) still running")
            SessionLog.flush()
        }
        projects.save()
        dispatch.save()
        dispatchAuth.save()
        store.flushPendingSave()
        runner.reviews.flush()
        // Last, once everything the app owns is on disk.
        MenuBarApp.stationLock?.release()
        MenuBarApp.stationLock = nil
        // The daemon claims the station now that it is free, and the terminals find it
        // there on their own.
        if handsOverToDaemon, let executable = Self.daemonExecutable {
            do {
                try StationDaemon.launch(executable: executable)
                SessionLog.note("app quitting: handed the station to the background service")
            } catch {
                SessionLog.note("app quitting: could not start the background service: \(error)")
            }
            SessionLog.flush()
        }
    }
}
