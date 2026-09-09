import AppKit
import SwiftUI
import WebKit

struct DesignViewport: Equatable {
    private(set) var size = CGSize.zero
    private(set) var contentSize = CGSize.zero
    private(set) var scale: CGFloat = 1
    private(set) var origin = CGPoint.zero
    private(set) var isFitted = true

    var contentFrame: CGRect {
        CGRect(origin: origin, size: CGSize(width: contentSize.width * scale,
                                           height: contentSize.height * scale))
    }

    private var fitScale: CGFloat {
        guard size.width > 0, size.height > 0,
              contentSize.width > 0, contentSize.height > 0 else { return 1 }
        return min(1, size.width / contentSize.width, size.height / contentSize.height)
    }

    mutating func resize(to size: CGSize, contentSize: CGSize) {
        guard size != self.size || contentSize != self.contentSize else { return }
        let change = CGSize(width: (size.width - self.size.width) / 2,
                            height: (size.height - self.size.height) / 2)
        self.size = size
        self.contentSize = contentSize
        if isFitted {
            fit()
        } else {
            origin.x += change.width
            origin.y += change.height
            constrainOrigin()
        }
    }

    mutating func fit() {
        isFitted = true
        scale = fitScale
        origin = CGPoint(x: (size.width - contentSize.width * scale) / 2,
                         y: (size.height - contentSize.height * scale) / 2)
    }

    mutating func zoom(by factor: CGFloat, at point: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let next = min(4, max(min(0.1, fitScale), scale * factor))
        guard next != scale else { return }
        let ratio = next / scale
        origin = CGPoint(x: point.x - (point.x - origin.x) * ratio,
                         y: point.y - (point.y - origin.y) * ratio)
        scale = next
        isFitted = false
        constrainOrigin()
    }

    mutating func pan(by delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite,
              delta.width != 0 || delta.height != 0 else { return }
        origin.x += delta.width
        origin.y += delta.height
        isFitted = false
        constrainOrigin()
    }

    private mutating func constrainOrigin() {
        // Keep part of the artboard reachable even after a long drag.
        let visibleWidth = min(48, size.width, contentFrame.width)
        let visibleHeight = min(48, size.height, contentFrame.height)
        origin.x = min(size.width - visibleWidth,
                       max(visibleWidth - contentFrame.width, origin.x))
        origin.y = min(size.height - visibleHeight,
                       max(visibleHeight - contentFrame.height, origin.y))
    }
}

@MainActor
final class DesignCanvasViewport: NSView {
    let webView: WKWebView
    private(set) var viewport = DesignViewport()
    var onScale: ((CGFloat) -> Void)?
    private var screen: DesignScreen?
    private var overflowWidth: CGFloat?
    private var overflowHeight: CGFloat?
    private var eventMonitor: Any?
    private var dragPoint: CGPoint?

    override var isFlipped: Bool { true }

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        layer?.backgroundColor = NSColor(Theme.sunken).cgColor
        addSubview(webView)
    }

    required init?(coder: NSCoder) { nil }

    func configure(screen: DesignScreen?, reset: Bool) {
        overflowWidth = nil
        overflowHeight = nil
        self.screen = screen
        if reset { viewport.fit() }
        needsLayout = true
    }

    func measureContent(width: CGFloat, height: CGFloat) {
        // Only overflow is intrinsic. A responsive page's scroll size also includes
        // its current viewport, which must not turn into a fixed artboard size.
        var changed = false
        if (screen?.width ?? 0) <= 0, width.isFinite, width > viewport.contentSize.width + 2 {
            overflowWidth = width
            changed = true
        }
        if (screen?.height ?? 0) <= 0, height.isFinite, height > viewport.contentSize.height + 2 {
            overflowHeight = height
            changed = true
        }
        if changed { needsLayout = true }
    }

    override func layout() {
        super.layout()
        let width = screen?.width.flatMap { $0 > 0 ? CGFloat($0) : nil }
            ?? max(bounds.width, overflowWidth ?? 0)
        let height = screen?.height.flatMap { $0 > 0 ? CGFloat($0) : nil }
            ?? max(bounds.height, overflowHeight ?? 0)
        viewport.resize(to: bounds.size, contentSize: CGSize(width: width, height: height))
        applyViewport()
    }

    func fit() {
        viewport.fit()
        applyViewport()
    }

    func zoom(by factor: CGFloat, at point: CGPoint) {
        viewport.zoom(by: factor, at: point)
        applyViewport()
    }

    func pan(by delta: CGSize) {
        viewport.pan(by: delta)
        applyViewport()
    }

    private func applyViewport() {
        guard viewport.size.width > 0, viewport.size.height > 0 else { return }
        // Scale the view and its page together so CSS keeps the artboard's layout
        // width. Browser magnification alone cannot zoom out to fit a clipped page.
        if webView.pageZoom != viewport.scale { webView.pageZoom = viewport.scale }
        if webView.frame != viewport.contentFrame { webView.frame = viewport.contentFrame }
        onScale?(viewport.scale)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .magnify, .smartMagnify,
                       .otherMouseDown, .otherMouseDragged, .otherMouseUp]
        ) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return handled ? nil : event
        }
    }

    func stopMonitoring() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        dragPoint = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        let point = convert(event.locationInWindow, from: nil)
        let hit = window.contentView?.hitTest(event.locationInWindow)
        let inside = bounds.contains(point) && (hit === self || hit?.isDescendant(of: self) == true)
        guard inside || dragPoint != nil else { return event }

        switch event.type {
        case .scrollWheel:
            if event.hasPreciseScrollingDeltas {
                pan(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            } else {
                let direction: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
                zoom(by: exp(event.scrollingDeltaY * direction * 0.08), at: point)
            }
        case .magnify:
            zoom(by: 1 + event.magnification, at: point)
        case .smartMagnify:
            fit()
        case .otherMouseDown where event.buttonNumber == 2:
            dragPoint = point
            NSCursor.closedHand.set()
        case .otherMouseDragged where event.buttonNumber == 2:
            guard let previous = dragPoint else { return event }
            pan(by: CGSize(width: point.x - previous.x, height: point.y - previous.y))
            dragPoint = point
        case .otherMouseUp where event.buttonNumber == 2:
            dragPoint = nil
            NSCursor.arrow.set()
        default:
            return event
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            fit()
        } else {
            dragPoint = convert(event.locationInWindow, from: nil)
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previous = dragPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        pan(by: CGSize(width: point.x - previous.x, height: point.y - previous.y))
        dragPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        dragPoint = nil
        NSCursor.arrow.set()
    }
}
