import AppKit
import SwiftUI

struct SessionFactsLayout: Equatable {
    var width: CGFloat = 430
    var height: CGFloat = 560

    init() {}

    init(anchor: CGRect, bounds: CGSize) {
        width = min(430, max(0, min(anchor.maxX, bounds.width) - 8))
        height = max(0, bounds.height - anchor.maxY - 15)
    }
}

private struct SessionFactsFocusKey: FocusedValueKey {
    typealias Value = UUID
}

extension FocusedValues {
    var sessionFactsPreview: UUID? {
        get { self[SessionFactsFocusKey.self] }
        set { self[SessionFactsFocusKey.self] = newValue }
    }
}

// Observe outside clicks without swallowing the action they were meant for.
struct SessionFactsBoundary: NSViewRepresentable {
    let cardAnchor: FrameAnchor
    let isOpen: Bool
    let dismiss: () -> Void
    let resized: (SessionFactsLayout) -> Void

    func makeNSView(context: Context) -> BoundaryView { BoundaryView() }

    func updateNSView(_ view: BoundaryView, context: Context) {
        view.cardAnchor = cardAnchor
        view.isOpen = isOpen
        view.dismiss = dismiss
        view.resized = resized
        view.measure()
    }

    static func dismantleNSView(_ view: BoundaryView, coordinator: ()) { view.stop() }

    final class BoundaryView: NSView {
        var cardAnchor: FrameAnchor?
        var isOpen = false
        var dismiss: (() -> Void)?
        var resized: ((SessionFactsLayout) -> Void)?
        private var clickMonitor: Any?
        private var resizeObserver: NSObjectProtocol?
        private var lastLayout: SessionFactsLayout?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak self] event in
                MainActor.assumeIsolated { self?.mouseDownOutside(event) }
                return event
            }
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.measure() }
                }
            measure()
        }

        func mouseDownOutside(_ event: NSEvent) {
            guard isOpen, event.window === window else { return }
            let point = event.locationInWindow
            let onChip = bounds.contains(convert(point, from: nil))
            let onCard = cardAnchor?.view.map {
                $0.bounds.contains($0.convert(point, from: nil))
            } ?? false
            if !onChip && !onCard { dismiss?() }
        }

        override func layout() {
            super.layout()
            measure()
        }

        func measure() {
            guard let content = window?.contentView else { return }
            let frame = FrameAnchor.fromTop(convert(bounds, to: content), in: content)
            let layout = SessionFactsLayout(anchor: frame, bounds: content.bounds.size)
            guard layout != lastLayout else { return }
            lastLayout = layout
            DispatchQueue.main.async { [weak self] in self?.resized?(layout) }
        }

        func stop() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            clickMonitor = nil
            resizeObserver = nil
        }
    }
}
