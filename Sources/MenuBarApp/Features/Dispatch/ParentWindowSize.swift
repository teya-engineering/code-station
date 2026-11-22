import AppKit
import SwiftUI

// Reports the size of the window a sheet hangs off, and keeps reporting it as that
// window is resized, so the sheet can grow with it.
struct ParentWindowSize: NSViewRepresentable {
    @Binding var size: CGSize?

    func makeNSView(context: Context) -> NSView {
        let view = WatchingView()
        view.onChange = { size = $0 }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class WatchingView: NSView {
        var onChange: ((CGSize) -> Void)?
        private var observer: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // A sheet leaves its window before it goes away, which is where the observer is let go.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil else { return }
            // The view joins the sheet's window before AppKit hangs that window off its parent.
            DispatchQueue.main.async { [weak self] in self?.watchParent() }
        }

        private func watchParent() {
            guard observer == nil, let parent = window?.sheetParent else { return }
            onChange?(parent.contentLayoutRect.size)
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: parent, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?(parent.contentLayoutRect.size) }
            }
        }
    }
}
