import AppKit
import SwiftUI

// MARK: - Identity

// A project wherever it is not the subject of the screen: a small square of its colour
// ahead of its name. Square rather than round, so it never reads as a state light.
struct ProjectDot: View {
    let tint: Theme.ProjectTint
    var size: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4)
            .fill(tint.colour)
            .frame(width: size, height: size)
    }
}

// The initial on its tinted tile. Everything about it scales from the side, so the same
// tile serves the 26pt sidebar row and the 36pt workspace lead. Stacked draws a second
// tile peeking out behind, which is what a workspace is: a pile of projects.
struct ProjectTileView: View {
    let name: String
    let tint: Theme.ProjectTint
    var side: CGFloat = 26
    var dashed = false
    var stacked = false

    private var radius: CGFloat { side * 0.27 }

    var body: some View {
        face
            // The stack rides behind without taking room, so the front tile keeps the
            // place a plain project tile would have and a column of them stays aligned.
            .background(alignment: .center) { if stacked { ProjectTileBack(tint: tint, side: side) } }
    }

    private var face: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(tint.fill)
            .frame(width: side, height: side)
            .overlay {
                if dashed {
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(tint.colour.opacity(0.65),
                                style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                    Image(systemName: "bolt.fill")
                        .font(.system(size: side * 0.4, weight: .semibold))
                        .foregroundStyle(tint.ink)
                } else {
                    RoundedRectangle(cornerRadius: radius).stroke(tint.ring)
                    Text(String(name.prefix(1)).uppercased())
                        .font(.mono(side * 0.42, .semibold))
                        .foregroundStyle(tint.ink)
                }
            }
    }
}

// The tile underneath a stacked tile, shifted up and to the right. Put it behind any
// front tile of the same side to make a pile, such as a project tucked behind another
// before the two become a workspace. The part it would share with the front tile is cut
// away: both fills are translucent, so left whole it would darken the face instead of
// sitting behind it.
struct ProjectTileBack: View {
    let tint: Theme.ProjectTint
    var side: CGFloat = 26

    // How far the back tile peeks out, as a share of the side.
    static let shift: CGFloat = 0.15

    private var radius: CGFloat { side * 0.27 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(tint.fill)
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(tint.ring))
                .offset(x: side * Self.shift, y: -side * Self.shift)
            RoundedRectangle(cornerRadius: radius)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: side, height: side)
    }
}

// The projects of one session or workspace as a short row of tiles, each tucked under
// the one before, lead first. It says how many there are and whose they are in the room
// of two letters. A tile that joins lands with `Motion.pop`, and `landing` sends rings
// out from the newest one. Past `limit` the rest are left to the count beside it.
struct ProjectLineup: View {
    let names: [String]
    var side: CGFloat = 14
    // The surface the row sits on, drawn round each tile so the overlap reads as a gap.
    var surface: Color = Theme.card
    var limit = 4
    var landing: Int? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = Array(names.prefix(limit))
        HStack(spacing: -side * 0.3) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, name in
                let tint = Theme.projectTint(for: name)
                ProjectTileView(name: name, tint: tint, side: side)
                    .background(RoundedRectangle(cornerRadius: side * 0.27).fill(surface))
                    .padding(1)
                    .background(RoundedRectangle(cornerRadius: side * 0.27 + 1).fill(surface))
                    .landingRings(index == shown.count - 1 ? landing : nil, colour: tint.colour,
                                  cornerRadius: side * 0.27, reach: 2)
                    .zIndex(Double(index))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .motion(Motion.pop, value: shown)
        .fixedSize()
        .accessibilityHidden(true)
    }
}
