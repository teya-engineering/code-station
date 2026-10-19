import AppKit
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

// The ring round the stop button and the Run button's spinner and sweep are played by
// Core Animation. These hold that each one loops only while it should move, so Reduce
// Motion really holds them still.
@MainActor
struct BusyLoopTests {
    @Test func theTurnRingLoopsOnlyWhileItMoves() {
        let ring = TurnRingView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        ring.update(colour: .black, moving: true)
        #expect(ring.loops == ["turn"])

        ring.update(colour: .black, moving: false)
        #expect(ring.loops.isEmpty)
    }

    @Test func theRunSpinnerLoopsOnlyWhileItMoves() {
        let spinner = RunSpinnerView(frame: NSRect(x: 0, y: 0, width: 11, height: 11))
        spinner.update(moving: true)
        #expect(spinner.loops == ["turn"])

        spinner.update(moving: false)
        #expect(spinner.loops.isEmpty)
    }

    // The sweep's travel is worked out from the width, so it waits for one and starts
    // again when the button changes size.
    @Test func theRunSweepFollowsTheWidth() throws {
        let sweep = RunSweepView(frame: .zero)
        sweep.layoutLayers()
        #expect(sweep.loops.isEmpty)

        sweep.setFrameSize(NSSize(width: 100, height: 2))
        #expect(sweep.loops == ["sweep"])
        let first = try #require(sweep.layer?.sublayers?.first?.animation(forKey: "sweep")
            as? CABasicAnimation)
        #expect(first.toValue as? CGFloat == 135)

        sweep.setFrameSize(NSSize(width: 200, height: 2))
        let second = try #require(sweep.layer?.sublayers?.first?.animation(forKey: "sweep")
            as? CABasicAnimation)
        #expect(second.toValue as? CGFloat == 270)
    }

    // A window that has never been shown is not visible, so its loops hold still.
    @Test func loopsHoldStillInAHiddenWindow() {
        let window = testWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                                styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let wires = FlowingWiresView(dash: FlowingWiresView.wireDash,
                                     period: FlowingWiresView.wirePeriod)
        #expect(!wires.isPaused)

        window.contentView?.addSubview(wires)
        #expect(wires.isPaused)

        wires.removeFromSuperview()
        window.close()
    }
}
