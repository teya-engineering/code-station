import SwiftUI

// A range names its endpoints without inventing a commit count.
struct ComparisonRange: View {
    let base: String
    let includesCommits: Bool
    var snapshot = false
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Label(snapshot ? "Since the last review" : includesCommits ? "Branch changes" : "Working changes",
                  systemImage: snapshot ? "clock" : "arrow.triangle.branch")
                .font(Typography.caption).foregroundStyle(.secondary)
            GeometryReader { geometry in
                let width = geometry.size.width
                let middle = width * 0.65
                let y = geometry.size.height / 2
                Path { path in
                    path.move(to: CGPoint(x: Space.xs, y: y))
                    path.addLine(to: CGPoint(x: width - Space.xs, y: y))
                }
                .stroke(Theme.border, lineWidth: Space.xxs)
                Path { path in
                    path.move(to: CGPoint(x: Space.xs, y: y))
                    path.addLine(to: CGPoint(x: width - Space.xs, y: y))
                }
                .trim(from: 0, to: drawn || reduceMotion ? 1 : 0)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: Space.xxs, lineCap: .round))
                ForEach(includesCommits && !snapshot ? [Space.xs, middle, width - Space.xs]
                        : [Space.xs, width - Space.xs], id: \.self) { x in
                    Circle().fill(Theme.card)
                        .overlay(Circle().stroke(Theme.accent, lineWidth: Space.xxs))
                        .frame(width: Space.md, height: Space.md)
                        .position(x: x, y: y)
                }
            }
            .frame(height: ReviewMetrics.rangeHeight)
            HStack(alignment: .top, spacing: Space.sm) {
                Text(base).lineLimit(2)
                Spacer(minLength: 0)
                if includesCommits && !snapshot { Text("HEAD") }
                Text("Working tree")
            }
            .font(Typography.data).foregroundStyle(.secondary)
        }
        .padding(Space.card)
        .cardSurface()
        .onAppear { drawn = true }
        .motion(Motion.draw, value: drawn)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(base) to working tree. " + (snapshot ? "Edits since the review snapshot."
            : includesCommits ? "Committed and uncommitted changes." : "Uncommitted changes only."))
    }
}
