import SwiftUI

// The pieces the Settings sheet is built from, where the app-wide defaults live. A
// session's own overrides are picked on its composer bar instead; its Usage pane still
// borrows ChoiceBlock for the heading.

// A titled group of settings. The rule lets the small label hold a full-width section
// without adding another large heading to an already dense pane.
struct ChoiceBlock<Content: View>: View {
    let title: String
    let note: String?
    let badge: String?
    @ViewBuilder let content: Content

    init(_ title: String, note: String? = nil, badge: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.badge = badge
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.mono(9, .semibold))
                    .kerning(1.1)
                    .foregroundStyle(.secondary)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9.5, weight: .semibold))
                        .kerning(0.6)
                        .foregroundStyle(Theme.secret)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.secret.opacity(0.12)))
                }
                Rectangle()
                    .fill(Theme.settingsHairline)
                    .frame(height: 1)
            }
            if let note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -2)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// A settings group owns one card. Rows inside it use SettingsRowDivider instead of
// drawing separate rounded rectangles, so the group reads as one decision area.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.settingsBorder))
    }
}

struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.settingsHairline)
            .frame(height: 1)
            .padding(.horizontal, 14)
    }
}

// A row that turns one thing on or off. The copy claims the whole width the card gives
// it, so the switch sits at the trailing edge whether the sentence under the title wraps
// or not, and switches line up down a card however long the copy runs.
struct SettingsToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .toggleStyle(.appSwitch)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// One choice out of a list, with the sentence that says what picking it does. The whole
// row is the target: a radio button on its own is a small thing to hit.
struct OptionRow: View {
    let title: String
    let detail: String?
    let selected: Bool
    var warning = false
    let choose: () -> Void

    private var selectionColour: Color { warning ? Theme.deletion : Theme.accent }

    private var selectedBackground: Color {
        warning ? Theme.deletion.opacity(0.07) : Theme.field
    }

    @State private var hovering = false

    private var background: Color {
        if selected { return selectedBackground }
        return hovering ? Theme.field.opacity(0.5) : .clear
    }

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                // The mark is drawn rather than swapped between two symbols, so choosing
                // an option swells its dot instead of cutting one glyph for another.
                ZStack {
                    Circle()
                        .stroke(selected ? selectionColour : Color.secondary, lineWidth: 1.4)
                        .frame(width: 12.5, height: 12.5)
                    Circle()
                        .fill(selectionColour)
                        .frame(width: 6.5, height: 6.5)
                        .scaleEffect(selected ? 1 : 0.1)
                        .opacity(selected ? 1 : 0)
                }
                .frame(width: 15, height: 15)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .medium))
                        if warning {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .foregroundStyle(warning ? Theme.deletion : Color.primary)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(Motion.control, value: selected)
        .motion(Motion.hover, value: hovering)
    }
}

// A scale reads better as one strip than as a column of radio buttons, since the order is
// half of what it says.
struct ChoicePill: View {
    let title: String
    let selected: Bool
    var enabled = true
    // A choice that carries a consequence leads with a dot in the colour of that
    // consequence, so the warning is on the option itself rather than only in the
    // notice a click away.
    var dot: Color? = nil
    let choose: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 7) {
                if let dot {
                    // The accent fill swallows an amber dot, so a picked pill carries the
                    // brand mark instead and the warning stays visible on it.
                    Circle()
                        .fill(selected ? Theme.brand : dot)
                        .frame(width: 6, height: 6)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    // A squeezed pill must never fold its title onto two lines.
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(selected ? Color.white : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .surface(fill, cornerRadius: 8, border: selected ? .clear : Theme.border)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .motion(Motion.control, value: selected)
        .motion(Motion.hover, value: hovering)
    }

    private var fill: Color {
        if selected { return Theme.accentFill }
        return hovering && enabled ? Theme.field : Theme.card
    }
}
