import AppKit
import SwiftUI
import CodeStationCore

// MARK: - Header rail

// The header's actions sit in one rail at the trailing end of the band: the panel dock,
// then the session's actions, with one of these between the two.
struct HeaderRailDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 1, height: 18)
    }
}

// What a rail button is saying about itself. A state is a tinted glyph on a seat of the
// same colour, so it carries as a shape as well as a hue: at 13pt the accent and the
// resting grey are close enough in value that colour alone is easy to miss, and unreadable
// for anyone who cannot separate the two.
enum HeaderRailState {
    // Nothing is happening behind the button, so it does not ask for the eye.
    case rest
    // A panel this button opened is on screen right now.
    case open
    // Something outside the app is attached, which is why it is not the colour of `open`.
    case live
    // A job this button started is running. It passes, so it takes the colour on its own
    // rather than a seat that would come and go under the glyph.
    case working

    var tint: Color {
        switch self {
        case .rest: Color.secondary
        case .open, .working: Theme.accent
        case .live: Theme.addition
        }
    }

    // The fill the button already draws on hover, in the state's own colour.
    var seat: Color? {
        switch self {
        case .rest, .working: nil
        case .open: Theme.accent.opacity(0.12)
        case .live: Theme.addition.opacity(0.14)
        }
    }
}

// An icon-only button on that rail. It stands the same height as a tab so the whole rail
// reads as one row, and it always carries a word: with no label beside the glyph, the
// tooltip is the only thing that says what the button opens. Left without an action it
// draws as a label, for the overflow that hangs a menu under itself.
struct HeaderRailButton: View {
    let icon: String
    var state: HeaderRailState = .rest
    // Says there is something new behind the button, which a glyph on its own cannot.
    var badge = false
    let label: String
    // The saved text behind a button whose name is not the whole story - a prompt, where
    // what is about to be sent matters more than what it was called.
    var hint: String? = nil
    // The colour the glyph fills with while its panel is open, for a glyph whose filled
    // form says something of its own: a lit bulb for a recap that is out.
    var openFill: Color? = nil
    var action: (() -> Void)? = nil

    @State private var hovering = false
    @State private var actOuts = 0

    var body: some View {
        Group {
            if let action {
                Button {
                    // The glyph plays its part on the way in, not on the way out.
                    if state != .open { actOuts += 1 }
                    action()
                } label: { shape }
                    .buttonStyle(.plain)
            } else {
                shape
            }
        }
        .hoverLift(hovering, amount: Motion.smallLift)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .motion(Motion.hover, value: state)
        .appTooltip(delay: .zero) { Tooltip(title: label, subtitle: hint) }
        .accessibilityLabel(label)
    }

    private var shape: some View {
        ZStack {
            if state == .open, let openFill {
                Image(systemName: "\(icon).fill")
                    .foregroundStyle(openFill)
                    .transition(.opacity)
            }
            Image(systemName: icon)
                .foregroundStyle(state.tint)
        }
        .font(.system(size: 13, weight: .semibold))
        .actOut(icon, trigger: actOuts)
        .frame(width: 30, height: 34)
        .background {
            // The seat stands in for the hover fill rather than sitting under it, so a
            // button already saying something does not change colour when pointed at.
            if let seat = state.seat {
                RoundedRectangle(cornerRadius: 8).fill(seat)
            } else if hovering {
                RoundedRectangle(cornerRadius: 8).fill(Theme.field)
            }
        }
        .overlay(alignment: .topTrailing) {
            if badge {
                Circle()
                    .fill(Theme.attention)
                    .frame(width: 5, height: 5)
                    .offset(x: -3, y: 5)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

// The track the panel toggles share. One sunken strip makes them read as a set of
// switches for what sits beside the chat, apart from the actions on the session itself.
struct HeaderRailDock<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(2)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 11).fill(Theme.sunken))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.hairline))
    }
}

// A panel toggle in the dock. An open panel says so three ways: the seat rises to a card,
// the panel's word appears beside the glyph, and a short accent tick sits under it like the
// ink under a tab. Shape and word carry it for anyone who cannot tell the colours apart.
struct HeaderDockSeat: View {
    // A second half that opens a menu of other ways to reach the same panel.
    struct Options {
        let label: String
        let entries: () -> [MenuEntry]
    }

    let icon: String
    let word: String
    let isOpen: Bool
    // A number that says how much is behind the panel before it is opened.
    var count: Int? = nil
    // The word is the first thing to go when the window narrows. The raised seat and the
    // tick still say the panel is open.
    var showsWord = true
    var keys: [String] = []
    var detail: String? = nil
    var options: Options? = nil
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    @State private var caretHovering = false
    @State private var actOuts = 0
    @FocusState private var focused: Bool

    private static let height: CGFloat = 30
    private static let radius: CGFloat = 9

    var body: some View {
        HStack(spacing: 0) {
            Button {
                // The glyph plays its part on the way in, not on the way out.
                if !isOpen { actOuts += 1 }
                action()
            } label: { face }
                .buttonStyle(.plain)
                .focused($focused)
                .appTooltip(delay: .zero) { tooltip }
                .accessibilityLabel(word)
                .accessibilityValue(isOpen ? "open" : "closed")
                .accessibilityAddTraits(isOpen ? [.isSelected] : [])
            if let options {
                caret(options)
            }
        }
        .frame(height: Self.height)
        .background { seat }
        .overlay(alignment: .bottom) {
            if isOpen {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accent.opacity(0.9))
                    .frame(width: 14, height: 2)
                    .offset(y: 4)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: Self.radius + 2)
                    .strokeBorder(Theme.accent.opacity(0.3), lineWidth: 2)
                    .padding(-2)
                    .allowsHitTesting(false)
            }
        }
        .opacity(isEnabled ? 1 : 0.38)
        .onHover { hovering = $0 && isEnabled }
        .motion(Motion.hover, value: hovering)
        .motion(Motion.hover, value: caretHovering)
        .motion(HeaderMotion.slide, value: isOpen)
        .motion(HeaderMotion.slide, value: showsWord)
    }

    private var tint: Color {
        if isOpen { return Theme.accent }
        return hovering ? .primary : .secondary
    }

    private var face: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .actOut(icon, trigger: actOuts)
            if isOpen && showsWord {
                Text(word)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
            if let count {
                Text("\(count)")
                    .font(.mono(10.5, .semibold))
                    .foregroundStyle(isOpen ? Theme.accent.opacity(0.75) : Color(nsColor: .tertiaryLabelColor))
                    .padding(.leading, -2)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(minWidth: 30, minHeight: Self.height)
        .contentShape(Rectangle())
    }

    private var seat: some View {
        RoundedRectangle(cornerRadius: Self.radius)
            .fill(isOpen ? Theme.card : (hovering ? Theme.field : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Self.radius)
                .strokeBorder(isOpen ? Theme.border : Color.clear, lineWidth: 0.5))
            .shadow(color: .black.opacity(isOpen ? 0.08 : 0), radius: 1, y: 1)
    }

    private func caret(_ options: Options) -> some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(caretHovering ? Color.primary : Color(nsColor: .tertiaryLabelColor))
            .frame(width: 18, height: Self.height)
            .background(UnevenRoundedRectangle(bottomTrailingRadius: Self.radius,
                                               topTrailingRadius: Self.radius)
                .fill(caretHovering ? Theme.field : Color.clear))
            .contentShape(Rectangle())
            .padding(.leading, -4)
            .onHover { caretHovering = $0 && isEnabled }
            .appMenu(options.entries)
            .appTooltip(options.label)
            .accessibilityElement()
            .accessibilityLabel(options.label)
            .accessibilityAddTraits(.isButton)
    }

    private var tooltip: Tooltip {
        Tooltip(title: isOpen ? "Close \(word.lowercased())" : word,
                subtitle: detail, keys: keys)
    }
}

// A worded action with a choice behind it: the main half does the last thing picked, and
// the chevron offers the others. A card-and-border pill, so it reads as a secondary button
// rather than as one of the panel switches beside it.
struct HeaderSplitButton: View {
    let image: NSImage
    let word: String
    // At a medium width only the app's icon is left, which still says where it opens.
    var showsWord = true
    let menuLabel: String
    let tooltip: () -> Tooltip
    let action: () -> Void
    var refresh: (() async -> Void)? = nil
    let entries: () -> [MenuEntry]

    @State private var hovering = false
    @State private var mainHovering = false
    @State private var moreHovering = false

    private static let height: CGFloat = 30
    private static let radius: CGFloat = 9

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                    if showsWord {
                        Text(word)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, showsWord ? 9 : 7)
                .frame(height: Self.height)
                .background(UnevenRoundedRectangle(topLeadingRadius: Self.radius,
                                                   bottomLeadingRadius: Self.radius)
                    .fill(mainHovering ? Theme.field : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { mainHovering = $0 }
            .appTooltip(delay: .zero, tooltip)
            .accessibilityLabel(word)

            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1, height: Self.height)

            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(moreHovering ? Color.primary : Color(nsColor: .tertiaryLabelColor))
                .frame(width: 24, height: Self.height)
                .background(UnevenRoundedRectangle(bottomTrailingRadius: Self.radius,
                                                   topTrailingRadius: Self.radius)
                    .fill(moreHovering ? Theme.field : Color.clear))
                .contentShape(Rectangle())
                .onHover { moreHovering = $0 }
                .appMenu(refreshOnOpen: refresh, entries)
                .appTooltip(menuLabel)
                .accessibilityElement()
                .accessibilityLabel(menuLabel)
                .accessibilityAddTraits(.isButton)
        }
        .background(RoundedRectangle(cornerRadius: Self.radius).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Self.radius)
            .strokeBorder(hovering ? Theme.accent.opacity(0.22) : Theme.border))
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .motion(Motion.hover, value: mainHovering)
        .motion(Motion.hover, value: moreHovering)
        .motion(HeaderMotion.slide, value: showsWord)
    }
}
