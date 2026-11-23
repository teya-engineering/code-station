import AppKit
import SwiftUI

// MARK: - Motion

// The pace everything interactive moves at. A switch, a pill, a menu and a pane all move
// on one of these curves, so the window reads as a single surface reacting rather
// than a set of parts each keeping its own time.
enum Motion {
    static let hoverDuration: TimeInterval = 0.12
    static let revealDuration: TimeInterval = 0.18
    static let controlDuration: TimeInterval = 0.26
    static let popDuration: TimeInterval = 0.3
    static let leaveDuration: TimeInterval = 0.12
    static let popDamping = 0.66

    // A colour settling under the pointer: over almost before it is noticed.
    static let hover = Animation.easeOut(duration: hoverDuration)
    // A control taking a new state. The spring overshoots by a hair, which is what makes
    // a switch feel thrown rather than redrawn.
    static let control = Animation.spring(response: controlDuration, dampingFraction: 0.78)
    // Something arriving or leaving: a menu unfolding, a pane swapped for another.
    static let reveal = Animation.easeOut(duration: revealDuration)
    // A dialog's card rising into place. A touch softer than a control, so a large
    // surface settles rather than snaps.
    static let arrive = Animation.spring(response: 0.3, dampingFraction: 0.85)
    // A small mark landing, such as the badge on a dialog row. It bounces more than a
    // control, since on something this small a firmer spring reads as no motion at all.
    static let pop = Animation.spring(response: popDuration, dampingFraction: popDamping)
    // A line drawing itself: quick out of the gate, then a long gentle finish.
    static let draw = drawAnimation(duration: 0.28)
    // Anything put away. Leaving is always quicker than arriving, so closing never
    // feels like waiting.
    static let leave = Animation.easeIn(duration: leaveDuration)

    // Something carried across the window to where it lands. It moves across on an
    // ease-out and down on an ease-in, and the two together bend its path into a curve.
    // Going home is quicker, since that is a thing being put away.
    static let flightDuration: TimeInterval = 0.36
    static let flightHomeDuration: TimeInterval = 0.24
    static func flightAcross(_ duration: TimeInterval = flightDuration) -> Animation {
        .easeOut(duration: duration)
    }
    static func flightDown(_ duration: TimeInterval = flightDuration) -> Animation {
        .easeIn(duration: duration)
    }
    // A ring spreading out from a mark that has just landed and fading as it goes. It
    // starts on the curve a line draws on, held long enough to be seen spreading.
    static let ringDuration: TimeInterval = 0.52
    static let ringGap: TimeInterval = 0.09
    static let ring = drawAnimation(duration: ringDuration)
    // A wash fading off words that have just been put into a field. It runs on the curve
    // a line draws on, held long enough for the eye to find where the words went.
    static let washDuration: TimeInterval = 0.7

    // The step between rows that arrive together, such as a folder's files, so they
    // read as a list unfolding rather than a block appearing.
    static let stagger: TimeInterval = 0.02

    static let wordmarkPeriod: TimeInterval = 12

    // The curve a line draws on. Kept in one place so the SwiftUI marks and the ones
    // Core Animation plays in AppKit views move the same way.
    private static let drawPoints: (Double, Double, Double, Double) = (0.2, 0.7, 0.1, 1)

    private static func drawAnimation(duration: TimeInterval) -> Animation {
        .timingCurve(drawPoints.0, drawPoints.1, drawPoints.2, drawPoints.3, duration: duration)
    }

    static var drawCurve: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(drawPoints.0), Float(drawPoints.1),
                              Float(drawPoints.2), Float(drawPoints.3))
    }

    // How far a control swells under the pointer. Kept this small on purpose: at this
    // size the lift is felt as the control waking up, and much past it the window starts
    // to twitch as the mouse crosses a row of buttons.
    static let lift: CGFloat = 1.02
    // A small control needs a larger share to show the same movement. Two percent of a
    // sixteen point checkbox is a third of a point, which nobody sees.
    static let smallLift: CGFloat = 1.08
}

extension View {
    // Runs one of the shared curves when `value` changes, and stands still for anyone who
    // has asked the system for less motion.
    func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}
