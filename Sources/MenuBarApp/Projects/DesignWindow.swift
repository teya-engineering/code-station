import AppKit
import SwiftUI

// Sharing the pane's canvas keeps the detached window current as the agent edits it.
@MainActor
@Observable
final class DesignWindow {
    private(set) var isOpen = false

    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    // Set when the window is closing itself and has to leave full screen first, so the
    // green button can drop the window back to a normal size without closing it.
    @ObservationIgnored private var closingAfterFullScreen = false

    func show(title: String, content: some View) {
        if let window {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: content)
        // Let the window own its size instead of shrinking to the view's ideal size.
        hosting.sizingOptions = []
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.contentViewController = hosting
        win.setContentSize(NSSize(width: 1280, height: 860))
        win.title = title
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.backgroundColor = Theme.backgroundNSColor
        win.isReleasedWhenClosed = false
        win.contentMinSize = NSSize(width: 640, height: 420)
        win.collectionBehavior.insert(.fullScreenPrimary)
        win.center()
        window = win
        isOpen = true
        watch(win)
        win.makeKeyAndOrderFront(nil)
    }

    // Closing a window that is still in full screen leaves its empty space behind on the
    // desktop, so the window steps out of full screen first and closes once it is back.
    func close() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            closingAfterFullScreen = true
            window.toggleFullScreen(nil)
        } else {
            window.close()
        }
    }

    private func watch(_ window: NSWindow) {
        let centre = NotificationCenter.default
        observers = [
            centre.addObserver(forName: NSWindow.willCloseNotification,
                               object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.forget() }
            },
            centre.addObserver(forName: NSWindow.didExitFullScreenNotification,
                               object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.closingAfterFullScreen else { return }
                    self.closingAfterFullScreen = false
                    self.window?.close()
                }
            },
        ]
    }

    private func forget() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        closingAfterFullScreen = false
        window = nil
        isOpen = false
    }
}

struct DesignWindowView: View {
    let canvas: DesignCanvas
    let directory: URL
    let label: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DesignCanvasBar(canvas: canvas) {
                Image(systemName: "paintbrush.pointed.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(label.uppercased())
                    .font(.mono(10, .semibold))
                    .kerning(1)
                    .lineLimit(1)
                if canvas.revision != nil {
                    StatusDot()
                    Text(canvas.selectedScreen?.path ?? "index.html")
                        .font(.mono(10.5))
                        .foregroundStyle(.secondary)
                }
            } tools: {
                GlyphButton(icon: "xmark", side: 28,
                            tint: Theme.accent, action: onClose)
                    .appTooltip("Close design window")
            }

            if let revision = canvas.revision, let url = canvas.screenURL(in: directory) {
                DesignWebView(url: url,
                              readAccessURL: directory,
                              screen: canvas.selectedScreen,
                              revision: revision,
                              reloadGeneration: canvas.reloadGeneration,
                              selectionEnabled: false,
                              snapshotRequest: nil,
                              onSelection: { _ in },
                              onSnapshot: { _, _ in })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
            } else {
                PaneMessage(icon: "rectangle.on.rectangle.angled",
                            title: "Your design will appear here",
                            detail: "Describe the first direction in the Design conversation.")
                    .background(Theme.sunken)
            }
        }
        .background(Theme.background)
        .appOverlays()
    }
}
