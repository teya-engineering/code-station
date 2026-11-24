import SwiftUI

// A pull request's light: the size of a session's own light, filled in the state's colour,
// or an empty ring while the state is not known yet.
struct PullRequestLight: View {
    let colour: Color
    var isRing = false

    static let size: CGFloat = 7

    var body: some View {
        ZStack {
            if isRing {
                Circle().strokeBorder(colour, lineWidth: 1)
            } else {
                Circle().fill(colour)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }
}

// GitHub's pull request marks, drawn on a sixteen point grid: two commits joined on the
// left and the branch on the right, which the state changes. Open carries the arrow back
// to the base, a draft trails off in dots, merged curves into the line, and closed is
// crossed out.
struct PullRequestMark: View {
    enum Symbol: Hashable { case pull, draft, merge, closed }

    let symbol: Symbol
    let size: CGFloat

    var body: some View {
        ZStack {
            PullRequestStrokes(symbol: symbol)
                .stroke(style: StrokeStyle(lineWidth: max(1, size * 0.1), lineCap: .round, lineJoin: .round))
            if symbol == .draft {
                PullRequestDraftDots()
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PullRequestStrokes: Shape {
    let symbol: PullRequestMark.Symbol

    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 16
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        func ring(_ x: CGFloat, _ y: CGFloat, into path: inout Path) {
            path.addEllipse(in: CGRect(x: rect.minX + (x - 1.7) * scale, y: rect.minY + (y - 1.7) * scale,
                                       width: 3.4 * scale, height: 3.4 * scale))
        }

        var path = Path()
        ring(4, 3.6, into: &path)
        ring(4, 12.4, into: &path)
        path.move(to: at(4, 5.3))
        path.addLine(to: at(4, 10.7))
        switch symbol {
        case .pull:
            ring(12, 12.4, into: &path)
            path.move(to: at(12, 10.7))
            path.addLine(to: at(12, 6.6))
            path.addArc(tangent1End: at(12, 4.6), tangent2End: at(10, 4.6), radius: 2 * scale)
            path.addLine(to: at(7.4, 4.6))
            path.move(to: at(8.9, 3.1))
            path.addLine(to: at(7.4, 4.6))
            path.addLine(to: at(8.9, 6.1))
        case .draft:
            ring(12, 12.4, into: &path)
        case .merge:
            ring(12, 9.2, into: &path)
            path.move(to: at(4, 5.3))
            path.addCurve(to: at(10.3, 9.2), control1: at(4, 7.9), control2: at(6.2, 9.2))
        case .closed:
            ring(12, 12.4, into: &path)
            path.move(to: at(12, 10.7))
            path.addLine(to: at(12, 8.2))
            path.move(to: at(10.4, 2.6))
            path.addLine(to: at(13.6, 5.8))
            path.move(to: at(13.6, 2.6))
            path.addLine(to: at(10.4, 5.8))
        }
        return path
    }
}

// The two dots a draft's branch trails off in, filled rather than stroked.
private struct PullRequestDraftDots: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 16
        var path = Path()
        for y in [4.6, 8.1] as [CGFloat] {
            path.addEllipse(in: CGRect(x: rect.minX + (12 - 0.85) * scale, y: rect.minY + (y - 0.85) * scale,
                                       width: 1.7 * scale, height: 1.7 * scale))
        }
        return path
    }
}
