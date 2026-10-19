import AppKit
import SwiftUI
import CodeStationCore

// What a second copy of the app runs instead of the app when another front end already
// owns the station's files. None of the stores are built, so nothing is read or written;
// the only thing on screen is a dialog naming the owner, and closing it quits.
@MainActor
final class StationLockRefusal: NSObject, NSApplicationDelegate {
    private let holder: StationLock.Holder?
    private var window: NSWindow?

    init(holder: StationLock.Holder?) {
        self.holder = holder
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Preferences.appearance().apply()

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.backgroundColor = Theme.backgroundNSColor
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: StationLockRefusalView(dialog: dialog))
        win.center()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private var dialog: Dialog {
        let owner = holder?.name ?? "another copy of Code Station"
        let quit = { NSApp.terminate(nil) }
        var dialog = Dialog(
            title: "Code Station is already running",
            message: "Its files are in use by \(owner). Quit that one first, then open Code Station again.",
            actions: [Dialog.Action(label: "Quit", kind: .primary, handler: quit)],
            onCancel: quit)
        dialog.width = 380
        return dialog
    }
}

private struct StationLockRefusalView: View {
    let dialog: Dialog
    @State private var presenter = DialogPresenter()

    var body: some View {
        Theme.background
            .ignoresSafeArea()
            .overlay { DialogHost() }
            .environment(presenter)
            .onAppear { presenter.show(dialog) }
    }
}
