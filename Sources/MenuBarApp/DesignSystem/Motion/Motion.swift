import AppKit
import SwiftUI
import CodeStationCore

// MARK: - Motion

// The pace everything interactive moves at. A switch, a pill, a menu and a pane all move
// on one of these three curves, so the window reads as a single surface reacting rather
// than a set of parts each keeping its own time.
enum Motion {
    static let hoverDuration: TimeInterval = 0.12
    static let revealDuration: TimeInterval = 0.18

    // A colour settling under the pointer: over almost before it is noticed.
    static let hover = Animation.easeOut(duration: hoverDuration)
    // A control taking a new state. The spring overshoots by a hair, which is what makes
    // a switch feel thrown rather than redrawn.
    static let control = Animation.spring(response: 0.26, dampingFraction: 0.78)
    // Something arriving or leaving: a menu unfolding, a pane swapped for another.
    static let reveal = Animation.easeOut(duration: revealDuration)
    // A dialog's card rising into place. A touch softer than a control, so a large
    // surface settles rather than snaps.
    static let arrive = Animation.spring(response: 0.3, dampingFraction: 0.85)
    // A small mark landing, such as the badge on a dialog row. It bounces more than a
    // control, since on something this small a firmer spring reads as no motion at all.
    static let pop = Animation.spring(response: 0.3, dampingFraction: 0.66)
    // A line drawing itself: quick out of the gate, then a long gentle finish.
    static let draw = Animation.timingCurve(0.2, 0.7, 0.1, 1, duration: 0.28)
    // Anything put away. Leaving is always quicker than arriving, so closing never
    // feels like waiting.
    static let leave = Animation.easeIn(duration: 0.12)

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
