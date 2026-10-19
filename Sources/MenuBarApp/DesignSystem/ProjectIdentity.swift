import AppKit
import SwiftUI
import CodeStationCore

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
            .background(alignment: .center) { if stacked { backTile } }
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

    // The tile underneath, shifted up and to the right. The part it would share with the
    // front tile is cut away: both fills are translucent, so left whole it would darken
    // the face instead of sitting behind it.
    private var backTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(tint.fill)
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(tint.ring))
                .offset(x: side * 0.15, y: -side * 0.15)
            RoundedRectangle(cornerRadius: radius)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: side, height: side)
    }
}
