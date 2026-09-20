import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The running dot breathes off the clock rather than off a repeating animation. An
// animation that never finishes is the animation in force for everything inside it, so a
// dot whose row moves rocks between its old place and its new one instead of landing.
// These hold what that has to keep true: the shape of the swing, where it rests, and the
// dot staying the size of the dot however wide the halo behind it grows.
@MainActor
struct BreathingTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func theSwingStartsInAndEndsWhereItBegan() {
        let period = Breath.period
        #expect(Breath.phase(at: Self.start).isApproximately(0))
        #expect(Breath.phase(at: Self.start.addingTimeInterval(period / 2))
            .isApproximately(1))
        #expect(Breath.phase(at: Self.start.addingTimeInterval(period)).isApproximately(0))
    }

    @Test func theSwingStaysBetweenItsEnds() {
        let steps = 200
        for step in 0...steps {
            let date = Self.start
                .addingTimeInterval(Breath.period * 3 * Double(step) / Double(steps))
            let phase = Breath.phase(at: date)
            #expect(phase >= 0 && phase <= 1, "phase left its range at step \(step)")
        }
    }

    // Halfway out and halfway back are the same width, or the dot would look like it was
    // drifting one way rather than breathing.
    @Test func theSwingIsSymmetric() {
        let quarter = Breath.phase(at: Self.start.addingTimeInterval(Breath.period / 4))
        let threeQuarters = Breath.phase(
            at: Self.start.addingTimeInterval(Breath.period * 3 / 4))
        #expect(quarter.isApproximately(threeQuarters))
    }

    // Resting is the state Reduce Motion and a session with nothing to do both land in,
    // and it has to be the full-strength drawing rather than some point mid-swing.
    @Test func restingHandsBackTheStartOfTheSwing() throws {
        let renderer = ImageRenderer(content: Breathing(active: false) { phase in
            Color.green.opacity(1 - phase).frame(width: 4, height: 4)
        })
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "the resting content did not render")
        let bitmap = try #require(NSBitmapImageRep(cgImage: image)
            .converting(to: .sRGB, renderingIntent: .default))
        let pixel = try #require(bitmap.colorAt(x: 2, y: 2))
        let strength = Double(pixel.alphaComponent)
        #expect(strength.isApproximately(1),
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

private extension Double {
    func isApproximately(_ other: Double) -> Bool { abs(self - other) < 0.000_1 }
}
