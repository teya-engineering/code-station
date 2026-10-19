import AppKit
import SwiftUI
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

// Breathing is played by Core Animation, read off the media clock. These hold what that
// has to keep true: loops of the same length move in step, resting is the full-strength
// drawing, and the dot stays the size of the dot however wide the halo behind it grows.
@MainActor
struct BreathingTests {
    @Test func loopsOfTheSameLengthMoveInStep() {
        let period = Breath.period
        let first = LayerLoop.repeating(CABasicAnimation(keyPath: "opacity"), period: period)
        let second = LayerLoop.repeating(CABasicAnimation(keyPath: "opacity"), period: period)
        #expect(first.timeOffset >= 0 && first.timeOffset < period)
        #expect(abs(second.timeOffset - first.timeOffset) < 0.05)
        #expect(first.repeatCount == .infinity)
        #expect(!first.isRemovedOnCompletion)
    }

    @Test func aBreathingCircleLoopsOnlyWhileItMoves() {
        let circle = BreathingCircleView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let moving = BreathingCircleView.Look(moving: true, scale: [0.45, 1], opacity: [0.5, 0])
        circle.update(colour: .black, look: moving)
        #expect(circle.loops == ["breath"])
        #expect(circle.restingOpacity == 0.5)

        circle.update(colour: .black, look: BreathingCircleView.Look(moving: false))
        #expect(circle.loops.isEmpty)
    }

    // The pill's rail flows on the same media clock as every other loop.
    @Test func theStateRailFlowsOnceItIsOnScreen() {
        let rail = FlowingRailView(frame: NSRect(x: 0, y: 0, width: 3, height: 22))
        rail.update(colour: .black)
        #expect(rail.loops.isEmpty)
        rail.restartLoops()
        #expect(rail.loops == ["flow"])
    }

    // Resting is the state Reduce Motion and a session with nothing to do both land in,
    // and it has to be the full-strength drawing rather than some point mid-swing.
    @Test func restingDrawsTheContentAtFullStrength() throws {
        let renderer = ImageRenderer(content: Breathing(active: false) {
            Color.green.frame(width: 4, height: 4)
        })
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "the resting content did not render")
        let bitmap = try #require(NSBitmapImageRep(cgImage: image)
            .converting(to: .sRGB, renderingIntent: .default))
        let pixel = try #require(bitmap.colorAt(x: 2, y: 2))
        let strength = Double(pixel.alphaComponent)
        #expect(abs(strength - 1) < 0.000_1,
                "a resting swing drew at \(strength) rather than full strength")
    }

    // The halo is more than twice the width of the dot. It sits in a background, which
    // takes no room, and nothing about it is allowed to reach the row it is drawn in.
    @Test func theHaloTakesNoRoom() throws {
        let size: CGFloat = 7
        let renderer = ImageRenderer(content: PulsingDot(size: size))
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "the dot did not render")
        #expect(image.width == Int(size), "the dot is \(image.width) wide, not \(size)")
        #expect(image.height == Int(size), "the dot is \(image.height) tall, not \(size)")
    }
}
