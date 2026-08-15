import SwiftUI
import AppKit

@main
struct MenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The window itself is owned by AppDelegate, so this scene renders nothing. It earns
    // its place by giving the app the standard macOS main menu, which is what supplies
    // Cmd+C/V/A in the composer and diff views. Settings is dropped from that menu
    // because there is nothing to configure.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) { }
                textSize
            }
    }

    // Text size is in the View menu because that is where Cmd+ and Cmd- live in every
    // other Mac app. The menu is also the only place these keys can be found: bound to a
    // hidden button in the window the way the app's other shortcuts are, nothing on
    // screen would ever say they exist, and this is the one setting whose whole point is
    // helping someone who is struggling to read.
    private var textSize: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { step { $0.bigger } }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Text") { step { $0.smaller } }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { step { _ in .standard } }
                .keyboardShortcut("0", modifiers: .command)
        }
    }

    private func step(_ next: (TextSize) -> TextSize) {
        let settings = appDelegate.appSettings
        settings.textSize = next(settings.textSize)
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
    private let projects = ProjectStore()
    private lazy var runner = SessionRunner(configs: store)
    private lazy var mobileAccess = MobileAccessController(store: projects, runner: runner)
    private let workingTrees = WorkingTreeWatch()
    private let gitStats = GitStatsCache()
    private let terminals = TerminalStore()
    private let loginItem = LoginItem()
    // Reached from the main menu as well as the window, so the text size commands can
    // change the same setting the Settings sheet shows.
    let appSettings = AppSettings()
    private let docker = DockerService()
    private let dispatch = DispatchStore()
    private let dispatchRunner = DispatchRunner()
    private let dispatchAuth = DispatchAuthStore()
    private let shortcuts = ShortcutStore()
    private var window: NSWindow?

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
        Attachments.pruneOldPastes()
        AppNotifier.shared.activate()
        AppNotifier.shared.openSession = { [weak self] sessionID in
            self?.projects.selectSession(sessionID)
            self?.showManager()
        }
        showManager()
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
                    .environment(projects)
                    .environment(runner)
                    .environment(workingTrees)
                    .environment(gitStats)
                    .environment(terminals)
                    .environment(loginItem)
                    .environment(appSettings)
                    .environment(mobileAccess)
                    .environment(docker)
                    .environment(dispatch)
                    .environment(dispatchRunner)
                    .environment(dispatchAuth)
                    .environment(shortcuts))
            // Let the window own its size instead of shrinking to the view's ideal size.
            hosting.sizingOptions = []
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            win.contentViewController = hosting
            win.setContentSize(NSSize(width: 1180, height: 820))
            win.title = "Teya Conductor"
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
