import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The loops that run while something works are played by Core Animation: the ring round
// the stop button, the Run button's spinner and sweep, the usage shimmer, the side copy's
// ring, the reviewers' nod and the context fuse's sparks. These hold that each one loops
// only while it should move, so Reduce Motion really holds them still, and that each one
// reads the shared media clock.
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

    @Test func theUsageShimmerFollowsTheWidth() throws {
        let shimmer = ShimmerView(frame: .zero)
        shimmer.layoutLayers()
        #expect(shimmer.loops.isEmpty)

        shimmer.setFrameSize(NSSize(width: 100, height: 5))
        #expect(shimmer.loops == ["sweep"])
        let sweep = try #require(shimmer.layer?.sublayers?.first?.animation(forKey: "sweep")
            as? CABasicAnimation)
        #expect(sweep.toValue as? CGFloat == 150)
    }

    // The ring's dashes travel two whole patterns a period, so the loop has no seam.
    @Test func theSideCopyRingMarchesWholePatterns() throws {
        let ring = MarchingRingView(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        ring.restartLoops()
        #expect(ring.loops == ["march"])
        let march = try #require(ring.layer?.sublayers?.first?.animation(forKey: "march")
            as? CABasicAnimation)
        #expect(march.toValue as? CGFloat == -9)
    }

    @Test func aNodLoopsOnlyWhenItHasSomewhereToGo() {
        let still = NoddingCopyView(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        still.show(AnyView(Color.red), look: .init(depth: 0))
        #expect(still.loops.isEmpty)

        let nodding = NoddingCopyView(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        nodding.show(AnyView(Color.red), look: .init(depth: 2))
        #expect(nodding.loops == ["nod"])
    }

    // A row of nods reads the same media clock, so a delay of half a period puts a tile
    // half a beat behind its neighbour wherever the two are drawn.
    @Test func aDelayedNodRunsBehindOnTheSameClock() throws {
        let first = NoddingCopyView(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        let second = NoddingCopyView(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        first.show(AnyView(Color.red), look: .init(period: 1.6, delay: 0, depth: 2))
        second.show(AnyView(Color.red), look: .init(period: 1.6, delay: 0.8, depth: 2))
        let lead = try #require(first.subviews.first?.layer?.animation(forKey: "nod"))
        let lag = try #require(second.subviews.first?.layer?.animation(forKey: "nod"))
        let gap = (lead.timeOffset - lag.timeOffset + 1.6).truncatingRemainder(dividingBy: 1.6)
        #expect(abs(gap - 0.8) < 0.05)
    }

    // Every spark gets its own life once the hairline has a width, and starts from the
    // fuse's tip at the bottom edge.
    @Test func theFuseThrowsEverySparkFromItsTip() throws {
        let embers = FuseEmbersView(frame: .zero)
        embers.update(look: .init(progressWidth: 90, heat: 0.5, young: .black, old: .black))
        #expect(embers.loops.isEmpty)

        embers.setFrameSize(NSSize(width: 100, height: 10))
        #expect(embers.loops.count == FuseEmber.all.count)
        let spark = try #require(embers.layer?.sublayers?.first?.animation(forKey: "life")
            as? CAAnimationGroup)
        let flight = try #require(spark.animations?.first as? CAKeyframeAnimation)
        #expect((flight.values?.first as? NSValue)?.pointValue == CGPoint(x: 90, y: 9))
        #expect(spark.timeOffset >= 0 && spark.timeOffset < spark.duration)
    }

    @Test func aHotterFuseThrowsItsSparksFaster() {
        let ember = FuseEmber.all[0]
        #expect(ember.rate(heat: 1) > ember.rate(heat: 0))
        #expect(FuseEmber.heat(at: ContextHairline.fuseThreshold) == 0)
        #expect(FuseEmber.heat(at: 1) == 1)
        for time in stride(from: 0.0, through: 10, by: 0.37) {
            let life = ember.life(at: time, heat: 0.5)
            #expect(life >= 0 && life < 1)
        }
    }

    // A window that has never been shown is not visible, so its loops hold still.
    @Test func loopsHoldStillInAHiddenWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let wires = FlowingWiresView(dash: FlowingWiresView.wireDash,
                                     period: FlowingWiresView.wirePeriod)
        #expect(!wires.isPaused)

        window.contentView?.addSubview(wires)
        #expect(wires.isPaused)

        wires.removeFromSuperview()
    }
}
