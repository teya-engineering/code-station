import SwiftUI
import AppKit

// The app is started as an AppKit one rather than through SwiftUI's App protocol. Every
// window it shows is an AppKit window it builds itself, so the only thing a SwiftUI scene
// would have brought is the main menu, and an empty scene kept around for that can end up
// on screen as a window with nothing in it.
@main
enum MenuBarApp {
    // NSApplication holds its delegate weakly, so ownership has to live somewhere else.
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        // Before the delegate, whose stores read their files as they are made.
        AppBackup.applyPending()
        let app = NSApplication.shared
        let appDelegate = AppDelegate()
        delegate = appDelegate
        app.delegate = appDelegate
        app.run()
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
        let runner = SessionRunner(configs: store)
        // Agents usually commit at the end of a turn, so the sidebar reads the session's
        // folders again then instead of waiting for the file system to report it.
        runner.onTurnEnded = { [projects, workingTrees] sessionID in
            guard let session = projects.session(sessionID) else { return }
            workingTrees.noteChanged(projects.workingDirectories(for: session))
        }
        let afterTurn = runner.onTurnEnded
        runner.onTurnEnded = { [pullRequestReviews] sessionID in
            afterTurn(sessionID)
            pullRequestReviews.turnEnded(sessionID)
        }
        return runner
    }()
    private lazy var scheduledTasks = ScheduledTaskService(
        store: projects, runner: runner, agentAvatarName: { [appSettings] in appSettings.defaultAgentAvatarName })
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
    private let pullRequestReviews = PullRequestReviewStore()
    private let gitStats = GitStatsCache()
    private let terminals = TerminalStore()
    private let explorerMemory = ExplorerMemory()
    private let loginItem = LoginItem()
    // Reached from the main menu as well as the window, so the text size items can
    // change the same setting the Settings sheet shows.
    let appSettings = AppSettings()
    private lazy var sunlight = SunlightController(settings: appSettings)
    private let docker = DockerService()
    private let dispatch = DispatchStore()
    private let dispatchRunner = DispatchRunner()
    private let dispatchAuth = DispatchAuthStore()
    private let shortcuts = ShortcutStore()
    private let appUpdates = AppUpdateChecker()
    private let accountUsage = AccountUsageMonitor()
    private let quitGuard = QuitGuard()
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
        widenOpenFileLimit()
        // A turn that was mid-flight when the app died leaves no other trace, so the log
        // needs somewhere to show that the run it belonged to ended here.
        SessionLog.note("app launched")
        SessionLog.startMemoryMonitoring()
        RunRegistry.shared.record(RunRegistry.launchCoalition())
        clearUpAfterEarlierRuns()
        // A deleted project or session leaves no way back to its terminals, so they are
        // closed with it rather than kept alive by a store nothing can reach. Its open
        // shortcut output goes for the same reason.
        projects.onRemoved = { [weak self] owner in
            self?.terminals.discard(TerminalScope(owner))
            if let scope = ShortcutScope(owner) { self?.shortcuts.discard(scope) }
        }
        Attachments.pruneOldPastes()
        AppNotifier.shared.activate()
        AppNotifier.shared.openSession = { [weak self] sessionID in
            self?.projects.selectSession(sessionID)
            self?.showManager()
        }
        AppNotifier.shared.isMuted = { [weak self] sessionID in
            self?.projects.isSnoozed(sessionID) ?? false
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [quitGuard] _ in
            MainActor.assumeIsolated { quitGuard.allow() }
        }
        showManager()
        scheduledTasks.start()
        sunlight.start()
    }

    // macOS starts the app with room for 2560 open files. Watching a tree for changes
    // holds its folder and every folder above it open, nine or so per tree, so a sidebar
    // full of worktrees uses most of that room on its own. Past the limit no pipe to git
    // or to an agent can be opened. The hard limit has no ceiling, so the soft one is
    // widened to what the kernel allows a single process.
    private func widenOpenFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        var perProcess: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let allowed = sysctlbyname("kern.maxfilesperproc", &perProcess, &size, nil, 0) == 0
            ? rlim_t(perProcess) : rlim_t(OPEN_MAX)
        let widened = min(limit.rlim_max, max(allowed, rlim_t(OPEN_MAX)))
        guard widened > limit.rlim_cur else { return }
        limit.rlim_cur = widened
        if setrlimit(RLIMIT_NOFILE, &limit) != 0 {
            limit.rlim_cur = min(limit.rlim_max, rlim_t(OPEN_MAX))
            setrlimit(RLIMIT_NOFILE, &limit)
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

    // A terminal outlives the app that opened it. A run ending anywhere other than
    // applicationWillTerminate - a crash, a force quit, a debug build killed from a
    // terminal - therefore strands every shell it had open, and nothing else will ever
    // close them. This launch is the first moment anything can. It waits on shells that
    // are slow to hang up, so it stays off the main actor.
    //
    // The same goes for anything else such a run started, like a daemon a command sent
    // off on its own. The shells and commands go first, since those have notes of their
    // own and are closed the way they expect.
    private func clearUpAfterEarlierRuns() {
        Task.detached(priority: .utility) {
            let closed = await ShellRegistry.shared.reapOrphans()
            if !closed.isEmpty {
                SessionLog.note("closed \(counted(closed.count, "shell")) left behind by an earlier run")
            }
            let stopped = await ShellRegistry.tasks.reapOrphans()
            if !stopped.isEmpty {
                SessionLog.note("stopped \(counted(stopped.count, "command")) left behind by an earlier run")
            }
            let ended = RunRegistry.shared.reapEarlierRuns()
            guard ended > 0 else { return }
            SessionLog.note("stopped \(counted(ended, "process", plural: "processes")) left behind by an earlier run")
        }
    }

    // The window is the app, so closing it quits rather than leaving a process with no
    // way back into it except the Dock. Waiting for the last window to close is not
    // enough: a detached Design window, minimised or on another Space, would keep the
    // app running unseen, so the main window decides on its own.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window, quitGuard.shouldAsk(running: runningSessions) else { return true }
        quitGuard.ask()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The update's own restart prompt has already said which sessions it stops.
        guard !appUpdates.isRelaunching, quitGuard.shouldAsk(running: runningSessions) else { return .terminateNow }
        showManager()
        quitGuard.ask()
        return .terminateCancel
    }

    private var runningSessions: Int {
        projects.sessions.count { $0.designSourceSessionID == nil && runner.isBusy($0.id, store: projects) }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        // Quitting from inside the close would tear the window down while AppKit is
        // still closing it, so it waits for the close to finish.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    // Reopening only happens when the app is already running, which means the window
    // was hidden rather than closed, but the Dock icon still has to bring it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showManager()
        return true
    }

    func showManager() {
        if window == nil {
            let hosting = NSHostingController(rootView: WindowMinimum(width: 960, height: 640) {
                RootView()
                    .environment(store)
                    .environment(processes)
                    .environment(claude)
                    .environment(codex)
                    .environment(copilot)
                    .environment(projects)
                    .environment(runner)
                    .environment(scheduledTasks)
                    .environment(dictation)
                    .environment(workingTrees)
                    .environment(sessionTimes)
                    .environment(orphanedWorktrees)
                    .environment(pullRequestReviews)
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
                    .environment(accountUsage)
                    .environment(quitGuard)
            })
            // The window owns its size instead of shrinking to the view's ideal size. The
            // minimum comes from the view, because the hosting controller resets the
            // window's own contentMinSize to zero.
            hosting.sizingOptions = [.minSize]
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
            win.delegate = self
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Taken first: stopping a process can orphan its children, and an orphan no
        // longer shows up as something the app started.
        let leftovers = QuitSweep.snapshot()
        scheduledTasks.stop()
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
    }
}
