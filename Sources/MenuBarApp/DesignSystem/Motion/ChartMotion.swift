import SwiftUI

// How a bar chart over time answers a change.
//
// A zoom is a change of stretch. The time axis itself moves from the old stretch to the
// new one, so the old bars squeeze into the place their time takes on the new axis while
// they fade, and the new bars grow up into theirs. It shows where the new bars came from:
// a day zoomed out to a week lands on the right, where today sits.
//
// A re-stack is a change of what the bars measure, or of whose share they show. The bars
// keep their places and change height one after another, left to right, so the eye can
// follow the change across the chart.
enum ChartMotion {
    static let zoomDuration: TimeInterval = 0.64
    // Positions move on an ease in and out, so the axis sets off and lands gently.
    static let zoom = Animation.timingCurve(0.65, 0, 0.35, 1, duration: zoomDuration)
    // The old bars are gone before the move is, and the new ones arrive a beat behind it,
    // so the two sets are never both fully drawn.
    static let zoomLeave = Animation.easeOut(duration: zoomDuration * 0.6)
    static let zoomArrive = Animation.easeOut(duration: zoomDuration * 0.7).delay(zoomDuration * 0.2)
    // Where the new bars start growing from, as a share of their height. From zero they
    // would seem to appear late; from a quarter they read as the same bars getting taller.
    static let zoomGrowth: CGFloat = 0.25

    static let restackDuration: TimeInterval = 0.32
    // How long the last bar waits behind the first.
    static let restackSpread: TimeInterval = 0.14

    // One bar's part of a re-stack.
    static func restack(bar index: Int, of count: Int) -> Animation {
        let delay = restackSpread * Double(index) / Double(max(count - 1, 1))
        return Animation.timingCurve(0.25, 1, 0.5, 1, duration: restackDuration).delay(delay)
    }

    // Where a stretch of time sits along a chart drawn over `domain`, in points. Kept
    // apart from the views so a zoom can place the outgoing and incoming bars on one
    // shared axis.
    static func place(_ interval: DateInterval, in domain: DateInterval,
                      width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        guard domain.duration > 0 else { return (0, 0) }
        let scale = width / domain.duration
        return (interval.start.timeIntervalSince(domain.start) * scale, interval.duration * scale)
    }
}
