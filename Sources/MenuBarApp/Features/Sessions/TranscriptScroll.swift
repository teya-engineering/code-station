import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Long conversations stay fully available to the runner and persistence layer, but the
// view only builds a bounded tail. Earlier pages are added on demand without changing
// the transcript format or making old sessions migrate their data.
struct TranscriptWindow: Equatable {
    // What a session opens with. Every row is built eagerly, so this is what opening one
    // costs, and it is kept small because it is paid before anything is on screen.
    let openingPage: Int
    // What each request for earlier messages adds. Every loaded message stays built and
    // laid out, and scrolling costs the whole loaded window rather than the part on
    // screen, so a page is kept small enough that reading back stays smooth.
    let step: Int
    private(set) var visibleCount: Int

    init(openingPage: Int = 20, step: Int = 25) {
        self.openingPage = max(1, openingPage)
        self.step = max(1, step)
        visibleCount = self.openingPage
    }

    func hiddenCount(totalCount: Int) -> Int {
        max(0, totalCount - visibleCount)
    }

    func visibleMessages(in messages: [ChatMessage]) -> ArraySlice<ChatMessage> {
        messages.suffix(visibleCount)
    }

    mutating func loadEarlier(totalCount: Int) {
        guard hiddenCount(totalCount: totalCount) > 0 else { return }
        visibleCount = min(totalCount, visibleCount + step)
    }

    mutating func reveal(_ messageID: UUID, in messages: [ChatMessage]) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        visibleCount = max(visibleCount, messages.count - index)
    }

    mutating func reset() {
        visibleCount = openingPage
    }
}

struct LoadEarlierMessages: View {
    let hiddenCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                Image(systemName: "arrow.up")
                Text("Load earlier messages")
                Text("\(hiddenCount) hidden")
                    .foregroundStyle(.secondary)
            }
            .font(Typography.label)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, Space.lg)
            .frame(height: ControlHeight.lg)
            .cardSurface(cornerRadius: Radius.control)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .hoverLift()
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Load earlier messages, \(hiddenCount) hidden")
    }
}

// Content growth and a person scrolling up both move the transcript's bottom marker.
// Only a person's scroll may decide whether the transcript follows the conversation,
// so streaming can keep its place without taking the scroll position back from someone
// reading an earlier line.
struct TranscriptScrollObserver: NSViewRepresentable {
    let pinnedToBottom: Bool
    let onPositionChange: (Bool) -> Void

    func makeNSView(context: Context) -> TranscriptScrollObserverView {
        let view = TranscriptScrollObserverView()
        view.pinnedToBottom = pinnedToBottom
        view.onPositionChange = onPositionChange
        return view
    }

    func updateNSView(_ view: TranscriptScrollObserverView, context: Context) {
        view.pinnedToBottom = pinnedToBottom
        view.onPositionChange = onPositionChange
        view.observeEnclosingScrollView()
    }

    static func dismantleNSView(_ view: TranscriptScrollObserverView, coordinator: ()) {
        view.stopObserving()
    }
}

@MainActor
final class TranscriptScrollObserverView: NSView {
    var pinnedToBottom = true
    var onPositionChange: ((Bool) -> Void)?
    private weak var observedScrollView: NSScrollView?
    private var wheelMonitor: Any?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeEnclosingScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeEnclosingScrollView()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func observeEnclosingScrollView() {
        guard observedScrollView !== enclosingScrollView else { return }
        stopObserving()
        guard let enclosingScrollView else { return }
        observedScrollView = enclosingScrollView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didLiveScroll),
            name: NSScrollView.didLiveScrollNotification,
            object: enclosingScrollView)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didLiveScroll),
            name: NSScrollView.didEndLiveScrollNotification,
            object: enclosingScrollView)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportDidResize),
            name: NSView.frameDidChangeNotification,
            object: enclosingScrollView.contentView)
        // AppKit only sends live-scroll notifications for a trackpad gesture or a dragged
        // scroller. A mouse wheel sends none, so without this a transcript read that way
        // would stay pinned and be thrown back to its end whenever a row changes height.
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated { self?.wheelDidScroll(event) }
            return event
        }
    }

    private func wheelDidScroll(_ event: NSEvent) {
        guard let scrollView = observedScrollView, event.window === scrollView.window,
              scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil))
        else { return }
        // The monitor runs before the scroll view moves, so the position is read after.
        DispatchQueue.main.async { [weak self] in self?.readPosition() }
    }

    func stopObserving() {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
        guard let observedScrollView else { return }
        NotificationCenter.default.removeObserver(
            self, name: NSScrollView.didLiveScrollNotification, object: observedScrollView)
        NotificationCenter.default.removeObserver(
            self, name: NSScrollView.didEndLiveScrollNotification, object: observedScrollView)
        NotificationCenter.default.removeObserver(
            self, name: NSView.frameDidChangeNotification, object: observedScrollView.contentView)
        self.observedScrollView = nil
    }

    // When the pane gets shorter, say as the find bar opens above it, AppKit keeps the
    // top of the view where it was, so the end of the conversation drops out of sight.
    // SwiftUI only hears of the new height after that frame is drawn, so a pinned
    // transcript is put back at its end here, before anything is drawn.
    @objc private func viewportDidResize() {
        guard pinnedToBottom, let scrollView = observedScrollView,
              let documentView = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let document = clip.documentRect
        let visible = clip.bounds
        let y = documentView.isFlipped
            ? max(document.minY, document.maxY - visible.height)
            : document.minY
        guard abs(visible.minY - y) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: visible.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    @objc private func didLiveScroll() { readPosition() }

    func readPosition() {
        guard let scrollView = observedScrollView,
              let documentView = scrollView.documentView else { return }
        let visible = scrollView.documentVisibleRect
        let document = scrollView.contentView.documentRect
        guard document.height > visible.height + 1 else {
            onPositionChange?(true)
            return
        }
        let distance = documentView.isFlipped
            ? document.maxY - visible.maxY
            : visible.minY - document.minY
        // A small gap at the end should not stop following the conversation.
        onPositionChange?(distance <= 24)
    }
}

// A place in the transcript that can be scrolled to by name. SwiftUI's scroll proxy will
// not move a bottom-anchored transcript to a row drawn outside a lazy stack, so the
// transcript's own scroll view is moved to this marker instead.
struct TranscriptScrollTarget: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> TranscriptScrollTargetView {
        let view = TranscriptScrollTargetView()
        view.targetID = id
        return view
    }

    func updateNSView(_ view: TranscriptScrollTargetView, context: Context) {
        view.targetID = id
    }
}

@MainActor
final class TranscriptScrollTargetView: NSView {
    private static var targets: [String: WeakTarget] = [:]

    private struct WeakTarget {
        weak var view: TranscriptScrollTargetView?
    }

    var targetID = "" {
        didSet { register() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        register()
    }

    private func register() {
        Self.targets = Self.targets.filter { $0.value.view != nil }
        guard window != nil, !targetID.isEmpty else { return }
        Self.targets[targetID] = WeakTarget(view: self)
    }

    // Puts the top of the target at the top of the transcript. False when no target of
    // that name is on screen, so the caller can fall back to the scroll proxy.
    @discardableResult
    static func reveal(_ id: String) -> Bool {
        guard let view = targets[id]?.view, view.window != nil else { return false }
        // A code block sits in a scroller of its own, so it is the outermost one that moves.
        var outermost: NSScrollView?
        var ancestor: NSView? = view
        while let current = ancestor {
            if let scrollView = current as? NSScrollView { outermost = scrollView }
            ancestor = current.superview
        }
        guard let scrollView = outermost, let document = scrollView.documentView else { return false }
        let frame = view.convert(view.bounds, to: document)
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin.y = document.isFlipped ? frame.minY : frame.maxY - bounds.height
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
        return true
    }
}
