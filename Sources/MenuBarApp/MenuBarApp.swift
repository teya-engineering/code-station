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
            }
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
    private let projects = ProjectStore()
    private let runner = SessionRunner()
    private let terminals = TerminalStore()
    private let dialogs = DialogPresenter()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        showManager()
    }

    // Closing the window leaves the app running in the Dock, so clicking the Dock icon
    // has to be able to bring it back. Without this there is no way back in.
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
                    .environment(projects)
                    .environment(runner)
                    .environment(terminals)
                    .environment(dialogs))
            // Let the window own its size instead of shrinking to the view's ideal size.
            hosting.sizingOptions = []
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            win.contentViewController = hosting
            win.setContentSize(NSSize(width: 1180, height: 820))
            win.title = "Claude Conductor"
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.backgroundColor = .white
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
        runner.stopAll()
        terminals.stopEverything()
        projects.save()
    }
}
