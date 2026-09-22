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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ConfigStore()
    private let processes = ProcessManager()
    private let claude = ClaudeCodeManager()
    private let codex = CodexCodeManager()
    private let copilot = CopilotCodeManager()
    private let projects = ProjectStore()
    private lazy var runner = SessionRunner(configs: store)
    private lazy var mobileAccess = MobileAccessController(store: projects, runner: runner,
                                                           gitStats: gitStats)
    private let workingTrees = WorkingTreeWatch()
    // Named after the store's own transcript folder, so a second copy of the app reads
    // the conversations it actually owns.
    private lazy var sessionTimes = SessionTimeWatch(transcripts: projects.transcriptsURL)
    private let orphanedWorktrees = OrphanedWorktreeMonitor()
    private let gitStats = GitStatsCache()
    private let terminals = TerminalStore()
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
        SessionLog.startMemoryMonitoring()
        closeShellsLeftBehind()
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
        showManager()
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
    private func closeShellsLeftBehind() {
        Task.detached(priority: .utility) {
            let closed = await ShellRegistry.shared.reapOrphans()
            if !closed.isEmpty {
                SessionLog.note("closed \(counted(closed.count, "shell")) left behind by an earlier run")
            }
            let stopped = await ShellRegistry.tasks.reapOrphans()
            guard !stopped.isEmpty else { return }
            SessionLog.note("stopped \(counted(stopped.count, "command")) left behind by an earlier run")
        }
    }

    // The window is the app, so closing it quits rather than leaving a process with no
    // way back into it except the Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // Reopening only happens when the app is already running, which now means the window
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
                    .environment(workingTrees)
                    .environment(sessionTimes)
                    .environment(orphanedWorktrees)
                    .environment(gitStats)
                    .environment(terminals)
                    .environment(loginItem)
                    .environment(appSettings)
                    .environment(mobileAccess)
                    .environment(docker)
                    .environment(dispatch)
                    .environment(dispatchRunner)
                    .environment(dispatchAuth)
                    .environment(shortcuts)
                    .environment(appUpdates))
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
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        processes.stopAll()
        shortcuts.stopAll()
        runner.stopAll()
        terminals.stopEverything()
        mobileAccess.stop()
        projects.save()
        dispatch.save()
        dispatchAuth.save()
        store.flushPendingSave()
    }
}
