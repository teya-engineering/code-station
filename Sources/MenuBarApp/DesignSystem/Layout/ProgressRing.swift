import SwiftUI

// How far through a short list the person is, as a small ring beside a count such as
// "3 of 7 viewed". The arc draws round with `Motion.draw` as the share moves. The words
// beside it carry the count, so the ring is left out of the accessibility tree.
struct ProgressRing: View {
    let fraction: Double
    var size: CGFloat = 14
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle().stroke(Theme.border, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
        .motion(Motion.draw, value: fraction)
        .accessibilityHidden(true)
    }
}
