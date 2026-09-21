import AppKit
import SwiftUI

// The glyph a saved command can carry, so a row of chips can be read at a glance rather
// than only by name. A shortcut with no icon is the normal case, and nothing is drawn
// for it: an icon earns its place only when the reader chose one.
struct ShortcutIcon: Identifiable, Sendable {
    let symbol: String
    // What the glyph is meant to say, for the hint and for a reader who cannot see it.
    let label: String

    var id: String { symbol }

    // The glyphs on offer, in the order a command is usually thought about: make it,
    // check it, read it, ship it, then the housekeeping around all of that. It is a
    // chosen set rather than every symbol the system has, because a picker of thousands
    // is a search problem and naming a command is not.
    static let catalogue: [ShortcutIcon] = [
        ShortcutIcon(symbol: "hammer", label: "Build"),
        ShortcutIcon(symbol: "play", label: "Run"),
        ShortcutIcon(symbol: "bolt", label: "Fast"),
        ShortcutIcon(symbol: "wrench.and.screwdriver", label: "Tools"),
        ShortcutIcon(symbol: "gearshape", label: "Settings"),
        ShortcutIcon(symbol: "terminal", label: "Terminal"),

        ShortcutIcon(symbol: "checkmark.seal", label: "Tests"),
        ShortcutIcon(symbol: "checklist", label: "Checks"),
        ShortcutIcon(symbol: "ladybug", label: "Debug"),
        ShortcutIcon(symbol: "magnifyingglass", label: "Search"),
        ShortcutIcon(symbol: "eye", label: "Watch"),
        ShortcutIcon(symbol: "waveform.path.ecg", label: "Health"),

        ShortcutIcon(symbol: "chevron.left.forwardslash.chevron.right", label: "Code"),
        ShortcutIcon(symbol: "curlybraces", label: "Format"),
        ShortcutIcon(symbol: "doc.text", label: "Document"),
        ShortcutIcon(symbol: "book", label: "Docs"),
        ShortcutIcon(symbol: "paintbrush", label: "Lint"),
        ShortcutIcon(symbol: "wand.and.stars", label: "Generate"),

        ShortcutIcon(symbol: "shippingbox", label: "Package"),
        ShortcutIcon(symbol: "arrow.up.circle", label: "Deploy"),
        ShortcutIcon(symbol: "cloud", label: "Cloud"),
        ShortcutIcon(symbol: "server.rack", label: "Server"),
        ShortcutIcon(symbol: "globe", label: "Web"),
        ShortcutIcon(symbol: "network", label: "Network"),

        ShortcutIcon(symbol: "arrow.triangle.branch", label: "Branch"),
        ShortcutIcon(symbol: "arrow.triangle.pull", label: "Merge"),
        ShortcutIcon(symbol: "arrow.down.circle", label: "Fetch"),
        ShortcutIcon(symbol: "externaldrive", label: "Disk"),
        ShortcutIcon(symbol: "cylinder.split.1x2", label: "Database"),
        ShortcutIcon(symbol: "chart.bar", label: "Report"),

        ShortcutIcon(symbol: "arrow.clockwise", label: "Restart"),
        ShortcutIcon(symbol: "trash", label: "Clean"),
        ShortcutIcon(symbol: "sparkles", label: "Tidy"),
        ShortcutIcon(symbol: "flame", label: "Hot"),
        ShortcutIcon(symbol: "lock", label: "Secrets"),
        ShortcutIcon(symbol: "star", label: "Favourite")
    ]

    // A name that came from a saved file or a site configuration rather than from the
    // picker. A symbol this build does not have would draw as an empty gap, so anything
    // the system cannot render is treated as no icon at all.
    static func resolve(_ symbol: String?) -> String? {
        guard let symbol = symbol?.trimmed, !symbol.isEmpty,
              NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil else {
            return nil
        }
        return symbol
    }
}

// The grid of glyphs in the shortcut editor, with the first tile standing for no icon so
// that clearing one is a click in the same place as choosing one.
struct ShortcutIconPicker: View {
    @Binding var symbol: String?

    // Adaptive rather than a fixed count, because the same grid is shown in the shortcut
    // sheet and in the narrower site configuration form.
    private static let columns = [GridItem(.adaptive(minimum: 30), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: 6) {
            IconTile(symbol: nil, label: "No icon", selected: symbol == nil) { symbol = nil }
            ForEach(ShortcutIcon.catalogue) { icon in
                IconTile(symbol: icon.symbol, label: icon.label,
                         selected: symbol == icon.symbol) { symbol = icon.symbol }
            }
        }
        .padding(8)
        .cardSurface(cornerRadius: 9)
    }
}

// One glyph to pick. Hovering lifts it and puts the accent glow under it, the same way a
// shortcut chip answers the pointer, so the two places a glyph is seen behave alike.
private struct IconTile: View {
    // The tile that clears the icon has no symbol of its own, and is drawn with the sign
    // for nothing rather than left blank.
    let symbol: String?
    let label: String
    let selected: Bool
    let choose: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            Image(systemName: symbol ?? "slash.circle")
                .font(.system(size: 12.5))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .surface(background, cornerRadius: 7, border: border)
                .shadow(color: Theme.accent.opacity(hovering ? 0.35 : 0),
                        radius: hovering ? 5 : 0)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .hoverLift(hovering, amount: Motion.smallLift)
        .onHover { hovering = $0 }
        .appTooltip(label)
        .accessibilityLabel(label)
    }

    private var foreground: Color {
        if selected { return .white }
        return hovering ? Theme.accent : .secondary
    }

    private var background: Color {
        if selected { return Theme.accentFill }
        return hovering ? Theme.accent.opacity(0.1) : Theme.field
    }

    private var border: Color {
        if selected { return .clear }
        return hovering ? Theme.accent.opacity(0.75) : Theme.border
    }
}
