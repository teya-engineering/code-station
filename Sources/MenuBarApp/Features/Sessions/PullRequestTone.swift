import AppKit
import SwiftUI

// How a pull request's state is drawn, in GitHub's colours, wherever it shows: the rail
// and the word on the session chip, the mark and the badge in its card. The two read from
// here, so a state can never be one colour on the chip and another in the card. One not
// read from GitHub yet is Linked, outlined and grey, until it is.
struct PullRequestTone: Hashable {
    let readiness: PullRequestStatus.Readiness?

    init(_ status: PullRequestStatus?) {
        readiness = status?.readiness
    }

    var word: String { readiness?.label ?? "Linked" }

    // How much the pull request needs the person, most first. The chip names the one
    // that needs them most.
    var urgency: Int {
        switch readiness {
        case .changesRequested?: 0
        case .inReview?: 1
        case .approved?: 2
        case .draft?: 3
        case .merged?: 4
        case .closed?: 5
        case nil: 6
        }
    }

    var rail: Color {
        switch readiness {
        case .draft?: Theme.dotOff
        case .inReview?: Theme.attention
        case .approved?: Theme.dotOn
        case .changesRequested?, .closed?: Theme.deletion
        case .merged?: Theme.merged
        case nil: Color(nsColor: .tertiaryLabelColor)
        }
    }

    // Not read yet, so the rail is an outline, the way a session's waiting rail is.
    var railLook: StateRail.Look { readiness == nil ? .outlined : .filled }

    // The words and the card's mark.
    var ink: Color {
        switch readiness {
        case .draft?, nil: Theme.secondaryText
        case .inReview?: Theme.attentionText
        case .approved?: Theme.dotOnText
        case .changesRequested?, .closed?: Theme.deletionText
        case .merged?: Theme.mergedText
        }
    }

    // The badge behind the word in the card.
    var wash: Color {
        switch readiness {
        case .draft?, nil: Theme.field
        case .inReview?: Self.reviewWash
        case .approved?: Self.approvedWash
        case .changesRequested?: Self.changesWash
        case .merged?: Self.mergedWash
        case .closed?: Self.closedWash
        }
    }

    // Merged and closed have marks of their own, so the state is never told by colour
    // alone.
    var symbol: PullRequestMark.Symbol {
        switch readiness {
        case .draft?: .draft
        case .merged?: .merge
        case .closed?: .closed
        case .inReview?, .approved?, .changesRequested?, nil: .pull
        }
    }

    // Paper takes less of the green than charcoal does, or the green words on it fall
    // under 4.5:1. Closed is a shade quieter than changes requested, since it needs
    // nothing more.
    private static let approvedWash = Theme.wash(NSColor(Theme.dotOn), light: 0.08, dark: 0.26)
    private static let reviewWash = Theme.wash(NSColor(Theme.attention), light: 0.16, dark: 0.16)
    private static let changesWash = Theme.wash(Theme.deletionNSColor, light: 0.11, dark: 0.15)
    private static let mergedWash = Theme.wash(Theme.mergedNSColor, light: 0.12, dark: 0.17)
    private static let closedWash = Theme.wash(Theme.deletionNSColor, light: 0.08, dark: 0.10)
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
        // A new state swaps the whole mark at once rather than bending one path into
        // the other.
        ZStack {
            ZStack {
                PullRequestStrokes(symbol: symbol)
                    .stroke(style: StrokeStyle(lineWidth: max(1, size * 0.1), lineCap: .round, lineJoin: .round))
                if symbol == .draft {
                    PullRequestDraftDots()
                }
            }
            .id(symbol)
            .transition(.opacity)
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
