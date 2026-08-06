import SwiftUI

// Central palette and small style helpers so the whole UI reads as one system.
enum Theme {
    static let background = Color(red: 0.965, green: 0.961, blue: 0.945)
    static let sidebar = Color(red: 0.949, green: 0.945, blue: 0.929)
    static let card = Color.white
    static let field = Color(red: 0.972, green: 0.969, blue: 0.957)

    static let accent = Color(red: 0.20, green: 0.34, blue: 0.24)
    static let dotOn = Color(red: 0.42, green: 0.60, blue: 0.43)
    static let dotOff = Color(red: 0.66, green: 0.66, blue: 0.63)
    static let secret = Color(red: 0.72, green: 0.52, blue: 0.20)
    // Something has stopped and is waiting to be looked at, as opposed to the green of
    // something running on its own.
    static let attention = Color(red: 0.82, green: 0.58, blue: 0.16)

    // Diff colours, shared by the changes screen, the chat's edit cards, and the
    // +N / -N counters everywhere.
    static let addition = Color(red: 0.24, green: 0.47, blue: 0.29)
    static let deletion = Color(red: 0.75, green: 0.28, blue: 0.24)

    static let border = Color.black.opacity(0.08)
    static let hairline = Color.black.opacity(0.06)

    // The band across the top of a pane or sheet. Every one of them is exactly this tall.
    // Grown from padding instead, each band ends up the height of whatever text it happens
    // to hold, and the rules closing two bands that sit side by side land a few points
    // apart.
    static let headerHeight: CGFloat = 72

    // A band that sits under one of those rather than at the top of a pane. It is shorter
    // so the two read as a heading and its sub-heading instead of two headings.
    static let subHeaderHeight: CGFloat = 48

    // Tints for the sidebar's project monograms. Picked from the name so a project
    // keeps the same colour between launches, which is what makes the tile readable
    // as an identity rather than decoration. They walk the whole colour wheel rather
    // than staying near the rest of the palette, because two projects sitting next to
    // each other have to be told apart at a glance.
    private static let monograms = [
        Color(red: 0.24, green: 0.47, blue: 0.31),
        Color(red: 0.13, green: 0.48, blue: 0.48),
        Color(red: 0.20, green: 0.44, blue: 0.66),
        Color(red: 0.34, green: 0.33, blue: 0.66),
        Color(red: 0.52, green: 0.31, blue: 0.62),
        Color(red: 0.74, green: 0.30, blue: 0.50),
        Color(red: 0.74, green: 0.28, blue: 0.30),
        Color(red: 0.78, green: 0.42, blue: 0.16),
        Color(red: 0.72, green: 0.54, blue: 0.10),
        Color(red: 0.45, green: 0.50, blue: 0.18)
    ]

    // Swift's own hashValue is salted per process, so the name is hashed here instead to
    // keep the choice stable. Summing the scalars would be stable too, but it lands names
    // built from the same letters on the same tint, which is most of a project list.
    static func monogram(for name: String) -> Color {
        var hash: UInt32 = 2166136261
        for scalar in name.unicodeScalars {
            hash = (hash ^ (scalar.value &* 2654435761)) &* 16777619
        }
        return monograms[Int(hash % UInt32(monograms.count))]
    }

    // Drawn by AppKit around the focused terminal, so it is an NSColor rather than a
    // SwiftUI one.
    static let focusRing = NSColor(red: 0.20, green: 0.34, blue: 0.24, alpha: 0.22)
}

extension View {
    // Lays a header out as a band of the shared height and draws the rule that closes it.
    // The rule belongs to the band rather than sitting next to it, so a header cannot be
    // given one twice or left without one.
    func headerBand(_ background: Color = Theme.card,
                    height: CGFloat = Theme.headerHeight) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(background)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
            }
    }
}

extension Font {
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// A small rounded chip used for command parts and badges.
struct Chip: View {
    let text: String
    var mono = true
    var body: some View {
        Text(text)
            .font(mono ? .mono(13) : .system(size: 13))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
    }
}

// Section label like COMMAND / ENVIRONMENT VARIABLES. The dot marks where a section
// starts, which is the only thing separating one from the next in a plain scroll.
struct SectionLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            SectionDot(size: 5)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
        }
    }
}

struct SectionDot: View {
    var size: CGFloat = 5
    var body: some View {
        Circle()
            .fill(Theme.dotOn)
            .frame(width: size, height: size)
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
