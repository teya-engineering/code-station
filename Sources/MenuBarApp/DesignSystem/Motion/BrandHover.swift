import AppKit

struct BrandHover {
    struct Input: Equatable {
        var hovered = false
        var reducedMotion = false
        var visible = true
    }

    enum Style { case rest, still, moving }

    private(set) var input = Input()
    private(set) var style = Style.rest

    mutating func update(_ next: Input) {
        let entered = next.hovered && !input.hovered
        let changedMotion = next.reducedMotion != input.reducedMotion
        input = next
        if !next.hovered || !next.visible {
            style = .rest
        } else if entered {
            style = next.reducedMotion ? .still : .moving
        } else if changedMotion {
            style = next.reducedMotion && style != .rest ? .still : .rest
        }
    }
}

// Both halves of the brand cancel on the same window events. Becoming visible or
// active again never replays a hover that happened before the interruption.
class BrandLayerView: LoopLayerView {
    private(set) var hover = BrandHover()

    func updateHover(_ input: BrandHover.Input) {
        var next = input
        next.visible = window?.isKeyWindow == true && window?.occlusionState.contains(.visible) == true
        applyHover(next)
    }

    private func applyHover(_ input: BrandHover.Input) {
        let previous = hover.style
        let interrupted = (hover.input.visible && !input.visible)
            || hover.input.reducedMotion != input.reducedMotion
        hover.update(input)
        if previous != hover.style || interrupted { hoverChanged(from: previous) }
    }

    func hoverChanged(from previous: BrandHover.Style) {}

    func stop() {
        var input = hover.input
        input.visible = false
        applyHover(input)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self)
        stop()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(availabilityChanged),
                                                   name: name, object: window)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationLeft),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        updateHover(hover.input)
    }

    @objc private func availabilityChanged() { updateHover(hover.input) }
    @objc private func applicationLeft() { stop() }
}
