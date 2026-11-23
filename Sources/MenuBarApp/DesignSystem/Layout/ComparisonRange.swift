import SwiftUI

// A range names its endpoints without inventing a commit count.
struct ComparisonRange: View {
    let base: String
    let includesCommits: Bool
    var snapshot = false
    // A slim strip for the head of a card that already says what the range is: the line
    // and its endpoints, with no card and no heading of its own.
    var compact = false
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsHead: Bool { includesCommits && !snapshot }

    var body: some View {
        Group {
            if compact {
                strip
            } else {
                VStack(alignment: .leading, spacing: Space.md) {
                    Label(snapshot ? "Since the last review" : includesCommits ? "Branch changes" : "Working changes",
                          systemImage: snapshot ? "clock" : "arrow.triangle.branch")
                        .font(Typography.caption).foregroundStyle(.secondary)
                    line.frame(height: ReviewMetrics.rangeHeight)
                    labels
                }
                .padding(Space.card)
                .cardSurface()
            }
        }
        .onAppear { drawn = true }
        .motion(Motion.draw, value: drawn)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(base) to working tree. " + (snapshot ? "Edits since the review snapshot."
            : includesCommits ? "Committed and uncommitted changes." : "Uncommitted changes only."))
    }

    private var strip: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            line.frame(height: Space.md + Space.xxs)
            labels
        }
        .frame(height: ReviewMetrics.rangeStripHeight, alignment: .top)
    }

    private var line: some View {
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
            ForEach(showsHead ? [Space.xs, middle, width - Space.xs] : [Space.xs, width - Space.xs], id: \.self) { x in
                Circle().fill(Theme.card)
                    .overlay(Circle().stroke(Theme.accent, lineWidth: Space.xxs))
                    .frame(width: Space.md, height: Space.md)
                    .position(x: x, y: y)
            }
        }
    }

    private var labels: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Text(base).lineLimit(compact ? 1 : 2).truncationMode(.middle)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
            if showsHead { Text("HEAD").transition(.opacity) }
            Text("Working tree")
        }
        .font(Typography.data).foregroundStyle(.secondary)
    }
}
