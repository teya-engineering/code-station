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

    static let border = Color.black.opacity(0.08)
    static let hairline = Color.black.opacity(0.06)
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

// Section label like COMMAND / ENVIRONMENT VARIABLES.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
    }
}
