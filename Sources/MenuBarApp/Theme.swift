import SwiftUI

// Central palette and small style helpers so the whole UI reads as one system.
enum Theme {
    // Text falls through to SwiftUI's adaptive colours, so a surface that stays light in
    // dark mode leaves white text on a white card. Values are Lemonade's neutral tokens.
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func adaptiveNSColor(light: NSColor,
                                dark: NSColor) -> NSColor {
        NSColor(name: nil) { isDark($0) ? dark : light }
    }

    static func adaptive(light: NSColor,
                         dark: NSColor) -> Color {
        Color(nsColor: adaptiveNSColor(light: light, dark: dark))
    }

    // The canvas a pane sits on. The sidebar is a shade under it and a card a shade over
    // it, so the three surfaces separate without a single line between them.
    static let backgroundNSColor = adaptiveNSColor(
        light: NSColor(srgbRed: 0.961, green: 0.953, blue: 0.929, alpha: 1),
        dark: NSColor(srgbRed: 0.082, green: 0.082, blue: 0.075, alpha: 1))
    static let background = Color(nsColor: backgroundNSColor)
    static let sidebar = adaptive(
        light: NSColor(srgbRed: 0.937, green: 0.929, blue: 0.898, alpha: 1),
        dark: NSColor(srgbRed: 0.067, green: 0.067, blue: 0.062, alpha: 1))
    static let card = adaptive(
        light: NSColor(srgbRed: 1, green: 0.992, blue: 0.965, alpha: 1),
        dark: NSColor(srgbRed: 0.125, green: 0.122, blue: 0.114, alpha: 1))
    static let field = adaptive(
        light: NSColor(srgbRed: 0.102, green: 0.102, blue: 0.082, alpha: 0.05),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05))
    // The quieter fill under a row inside a card, where `field` would read as a control.
    static let sunken = adaptive(
        light: NSColor(srgbRed: 0.102, green: 0.102, blue: 0.082, alpha: 0.035),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.035))

    // Filled controls stay deep enough for white labels. The adaptive accent is used on
    // surfaces, where the same deep green would not have enough contrast in dark mode.
    static let accentFill = Color(red: 0.184, green: 0.290, blue: 0.200)
    static let accent = adaptive(
        light: NSColor(srgbRed: 0.184, green: 0.290, blue: 0.200, alpha: 1),
        dark: NSColor(srgbRed: 0.58, green: 0.76, blue: 0.60, alpha: 1))
    static let dotOn = Color(red: 0.243, green: 0.478, blue: 0.275)
    static let dotOff = Color(red: 0.66, green: 0.66, blue: 0.63)
    static let secret = Color(red: 0.72, green: 0.52, blue: 0.20)
    // Something has stopped and is waiting to be looked at, as opposed to the green of
    // something running on its own.
    static let attention = Color(red: 0.788, green: 0.545, blue: 0.118)
    // The same amber read as words rather than as a light, which has to carry on a
    // pale card.
    static let attentionText = adaptive(
        light: NSColor(srgbRed: 0.541, green: 0.365, blue: 0.063, alpha: 1),
        dark: NSColor(srgbRed: 0.90, green: 0.72, blue: 0.36, alpha: 1))

    // The mark on anything the app itself owns: the brand tile, and Home wherever it
    // needs a colour of its own.
    static let brand = Color(red: 0.867, green: 0.878, blue: 0.282)

    // The one tinted block in a transcript. It is the brand yellow taken most of the way
    // to a leaf green, so a person's turn is picked out of the page without the agent's
    // answers having to be tinted in reply.
    static let userMessage = adaptive(
        light: NSColor(srgbRed: 0.902, green: 0.914, blue: 0.784, alpha: 1),
        dark: NSColor(srgbRed: 0.180, green: 0.196, blue: 0.129, alpha: 1))
    static let userMessageRing = Color(red: 0.471, green: 0.502, blue: 0.196).opacity(0.3)

    // Diff colours, shared by the changes screen, the chat's edit cards, and the
    // +N / -N counters everywhere.
    static let addition = adaptive(
        light: NSColor(srgbRed: 0.184, green: 0.420, blue: 0.227, alpha: 1),
        dark: NSColor(srgbRed: 0.612, green: 0.769, blue: 0.416, alpha: 1))
    static let deletion = adaptive(
        light: NSColor(srgbRed: 0.639, green: 0.239, blue: 0.188, alpha: 1),
        dark: NSColor(srgbRed: 0.851, green: 0.388, blue: 0.357, alpha: 1))

    static let border = adaptive(
        light: NSColor(srgbRed: 0.46, green: 0.42, blue: 0.34, alpha: 0.1),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.1))
    static let hairline = adaptive(
        light: NSColor(srgbRed: 0.46, green: 0.42, blue: 0.34, alpha: 0.06),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06))

    // The band across the top of a pane or sheet. Every one of them is exactly this tall.
    // Grown from padding instead, each band ends up the height of whatever text it happens
    // to hold, and the rules closing two bands that sit side by side land a few points
    // apart.
    static let headerHeight: CGFloat = 60

    // A band that sits under one of those rather than at the top of a pane. It is shorter
    // so the two read as a heading and its sub-heading instead of two headings.
    static let subHeaderHeight: CGFloat = 48

    // The line of state under a header: a shade off both the card above it and the canvas
    // below, so it reads as a footnote to the heading rather than a band of its own.
    static let statusBand = adaptive(
        light: NSColor(srgbRed: 0.945, green: 0.937, blue: 0.910, alpha: 1),
        dark: NSColor(srgbRed: 0.102, green: 0.102, blue: 0.094, alpha: 1))
    static let statusBandHeight: CGFloat = 30

    // A project's colour, used everywhere the project appears: its sidebar tile, the rail
    // under its expanded sessions, and the square dot beside its name on every other
    // screen. The tile is the colour at a low alpha behind the darker ink, which is what
    // keeps a full column of them legible.
    struct ProjectTint {
        let colour: Color
        let ink: Color

        var fill: Color { colour.opacity(0.15) }
        var ring: Color { colour.opacity(0.3) }
    }

    private static func tint(_ colour: (Double, Double, Double),
                             _ ink: (Double, Double, Double)) -> ProjectTint {
        // The ink is picked to carry on a pale tile, so in dark mode the tile is dark and
        // the glyph has to come back up to the colour itself.
        ProjectTint(colour: Color(red: colour.0, green: colour.1, blue: colour.2),
                    ink: adaptive(light: NSColor(srgbRed: ink.0, green: ink.1, blue: ink.2, alpha: 1),
                                  dark: NSColor(srgbRed: colour.0, green: colour.1, blue: colour.2,
                                                alpha: 1)))
    }

    // Picked from the name so a project keeps the same colour between launches, which is
    // what makes the tile readable as an identity rather than decoration. They walk the
    // whole colour wheel rather than staying near the rest of the palette, because two
    // projects sitting next to each other have to be told apart at a glance.
    private static let projectTints = [
        tint((0.357, 0.608, 0.847), (0.184, 0.376, 0.588)),
        tint((0.247, 0.647, 0.647), (0.118, 0.431, 0.431)),
        tint((0.643, 0.482, 0.753), (0.420, 0.267, 0.533)),
        tint((0.851, 0.451, 0.612), (0.639, 0.239, 0.420)),
        tint((0.863, 0.545, 0.278), (0.620, 0.353, 0.118)),
        tint((0.576, 0.635, 0.286), (0.373, 0.420, 0.133))
    ]

    // A workspace is not one repository, so it sits outside the project wheel on the
    // olive the rest of the app uses for a group.
    static let workspaceTint = tint((0.494, 0.541, 0.243), (0.353, 0.392, 0.145))

    // Swift's own hashValue is salted per process, so the name is hashed here instead to
    // keep the choice stable. Summing the scalars would be stable too, but it lands names
    // built from the same letters on the same tint, which is most of a project list.
    static func projectTint(for name: String) -> ProjectTint {
        var hash: UInt32 = 2166136261
        for scalar in name.unicodeScalars {
            hash = (hash ^ (scalar.value &* 2654435761)) &* 16777619
        }
        return projectTints[Int(hash % UInt32(projectTints.count))]
    }

    static func monogram(for name: String) -> Color { projectTint(for: name).ink }

    // Drawn by AppKit around the focused terminal, so it is an NSColor rather than a
    // SwiftUI one.
    static let focusRing = adaptiveNSColor(
        light: NSColor(srgbRed: 0.20, green: 0.34, blue: 0.24, alpha: 0.22),
        dark: NSColor(srgbRed: 0.58, green: 0.76, blue: 0.60, alpha: 0.32))
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
    // The wordmark's own face, so the name next to the mark stays the same shape on any
    // machine. Weight is a point on the axis, not a Font.Weight, because the file is a
    // single variable font.
    static func logo(_ size: CGFloat, weight: Double = 600) -> Font {
        guard SoraFont.isRegistered,
              let font = NSFont(descriptor: SoraFont.descriptor(weight: weight), size: size)
        else { return .system(size: size, weight: .semibold) }
        return Font(font)
    }
}

// Sora ships with the app instead of coming from the system, so Core Text has to be told
// about the file before anything can ask for the family by name.
private enum SoraFont {
    // The name the file itself carries. Its named weights are separate faces that the
    // variation axis picks between, so they are not asked for by name.
    private static let family = "Sora-Regular"
    private static let weightAxis = 0x77676874  // 'wght'

    static let isRegistered: Bool = {
        guard let url = Bundle.module.url(forResource: "Sora-Variable", withExtension: "ttf")
        else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func descriptor(weight: Double) -> NSFontDescriptor {
        NSFontDescriptor(fontAttributes: [
            .name: family,
            NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String): [weightAxis: weight]
        ])
    }
}

// What a pane says when it has nothing to show: no changes, no file picked, a folder that
// is not there any more. Centred in whatever room it is given.
struct PaneMessage: View {
    let icon: String
    let title: String
    var detail: String
    var mono = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.serif(17, .semibold))
            if !detail.isEmpty {
                Text(detail)
                    .font(mono ? .mono(11) : .system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
