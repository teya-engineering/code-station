import SwiftUI

struct UpdateIndicator: View {
    var body: some View {
        Circle()
            .fill(Theme.deletion)
            .frame(width: 7, height: 7)
            .accessibilityLabel("Update available")
    }
}

// How full something is, from a rate limit window to a context window. It takes the width
// it is given, so the caller decides whether it is a full-width bar or a small inline one.
struct Meter: View {
    let fraction: Double
    let colour: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.field)
                Capsule().fill(colour)
                    .frame(width: max(2, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}
