import SwiftUI

struct SettingsNavigationItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    let seat: Namespace.ID
    let action: () -> Void

    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .frame(width: 20)
                Text(title)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                Spacer(minLength: 0)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)
                    .scaleEffect(selected ? 1 : 0.1)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, Space.md)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Radius.card)
                        .fill(Theme.card)
                        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(Theme.border))
                        .matchedGeometryEffect(id: "pane", in: seat)
                } else if hovering {
                    RoundedRectangle(cornerRadius: Radius.card).fill(Theme.card.opacity(0.5))
                }
            }
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: Radius.card)
                        .stroke(Theme.accent, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

struct SettingsSearchResultItem: View {
    let result: SettingsSearchResult
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                Image(systemName: result.tab.symbol)
                    .font(Typography.caption.weight(.medium))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title)
                        .font(Typography.label)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    Text(result.tab.title)
                        .font(Font.system(size: Typography.Size.micro))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.md)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .surface(selected ? Theme.card : .clear, cornerRadius: Radius.card,
                     border: selected ? Theme.border : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.card)
    }
}

// Each colour is shown as a small bubble wearing it, so the choice is judged by the thing
// it changes. The arrow keys step through the colours like a radio group.
struct MessageColourPicker: View {
    let selection: MessageColour
    let projectTints: [Theme.ProjectTint]
    let choose: (MessageColour) -> Void

    @FocusState private var focused: MessageColour?

    var body: some View {
        HStack(spacing: Space.md) {
            ForEach(MessageColour.allCases) { colour in
                choice(colour)
            }
        }
        .onMoveCommand { direction in
            let step = switch direction {
            case .left, .up: -1
            case .right, .down: 1
            @unknown default: 0
            }
            let all = MessageColour.allCases
            guard step != 0, let index = all.firstIndex(of: focused ?? selection) else { return }
            let next = all[(index + step + all.count) % all.count]
            choose(next)
            focused = next
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your message colour")
    }

    private func choice(_ colour: MessageColour) -> some View {
        let selected = selection == colour
        let isFocused = focused == colour
        return Button { choose(colour) } label: {
            VStack(spacing: Space.sm) {
                MessageColourMiniBubble(colour: colour, projectTints: projectTints)
                Text(colour.label)
                    .font(Typography.label)
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, Space.xs)
            .padding(.top, Space.md)
            .padding(.bottom, Space.sm)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(selected ? Theme.sunken : .clear))
            .overlay(RoundedRectangle(cornerRadius: Radius.card)
                .strokeBorder(Theme.accent, lineWidth: isFocused ? 2 : 1.5)
                .opacity(selected || isFocused ? 1 : 0))
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
        .hoverLift()
        .focused($focused, equals: colour)
        .accessibilityLabel("\(colour.label) message colour")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

private struct MessageColourMiniBubble: View {
    let colour: MessageColour
    let projectTints: [Theme.ProjectTint]

    private let shape = UnevenRoundedRectangle(topLeadingRadius: Radius.control, bottomLeadingRadius: Radius.control,
                                               bottomTrailingRadius: Radius.tag, topTrailingRadius: Radius.control)

    var body: some View {
        let style = colour.style(projectTint: projectTints.first)
        style.fill
            .overlay(alignment: .trailing) { edge }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Capsule().frame(width: 30, height: 3)
                    Capsule().frame(width: 20, height: 3)
                }
                .foregroundStyle(Color.primary.opacity(0.16))
                .padding(.leading, Space.md)
                .padding(.top, Space.md)
                .environment(\.colorScheme, style.inverts ? inverted : scheme)
            }
            .frame(width: 52, height: 26)
            .clipShape(shape)
            .overlay(shape.stroke(style.ring))
            .accessibilityHidden(true)
    }

    @Environment(\.colorScheme) private var scheme
    private var inverted: ColorScheme { scheme == .dark ? .light : .dark }

    // Project icon has no one colour, so its bar is split between the colours the
    // sample projects would get.
    @ViewBuilder private var edge: some View {
        if colour == .projectIcon {
            VStack(spacing: 0) {
                ForEach(Array(projectTints.enumerated()), id: \.offset) { _, tint in
                    UserMessageStyle.tinted(tint.colour).edge
                }
            }
            .frame(width: 3.5)
        }
    }
}

struct SettingsThemeChoice: View {
    let appearance: Appearance
    let selected: Bool
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                SettingsThemePreview(appearance: appearance)
                    .frame(height: 44)
                    .accessibilityHidden(true)

                HStack(spacing: Space.sm) {
                    Text(appearance.label)
                        .font(Typography.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .opacity(selected ? 1 : 0)
                }
                .padding(.horizontal, Space.md)
                .frame(height: 26)
                .background(Theme.field)
            }
            .frame(maxWidth: .infinity)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card)
                .stroke(focused || selected ? Theme.accent : Theme.border,
                        lineWidth: focused ? 2 : selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift()
        .focused($focused)
        .accessibilityLabel("\(appearance.label) theme")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

private struct SettingsThemePreview: View {
    let appearance: Appearance

    var body: some View {
        switch appearance {
        case .system:
            HStack(spacing: 0) {
                preview(dark: false)
                preview(dark: true)
            }
        case .light:
            preview(dark: false)
        case .dark:
            preview(dark: true)
        }
    }

    private func preview(dark: Bool) -> some View {
        ZStack {
            Color(nsColor: dark ? Theme.canvasDarkNSColor : Theme.canvasLightNSColor)

            HStack(spacing: Space.xs) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(dark
                          ? Color(red: 0.18, green: 0.18, blue: 0.16)
                          : Color(red: 0.91, green: 0.90, blue: 0.85))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: Space.xs) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(dark ? Color.white.opacity(0.15) : Color.black.opacity(0.12))
                        .frame(maxWidth: .infinity, minHeight: 7)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(dark
                              ? Color(red: 0.58, green: 0.76, blue: 0.60).opacity(0.55)
                              : Theme.accentFill.opacity(0.32))
                        .frame(maxWidth: .infinity, minHeight: 7)
                }
            }
            .padding(Space.sm)
            .surface(Color(nsColor: dark ? Theme.cardDarkNSColor : Theme.cardLightNSColor),
                     cornerRadius: Radius.inset,
                     border: dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
            .padding(Space.sm)
        }
    }
}
