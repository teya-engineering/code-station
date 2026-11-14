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
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                Text(title)
                    .font(Typography.caps)
                    .kerning(1.1)
                    .foregroundStyle(.secondary)
                if let badge {
                    Text(badge)
                        .font(Typography.micro)
                        .kerning(0.6)
                        .foregroundStyle(Theme.secret)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, Space.xxs)
                        .background(RoundedRectangle(cornerRadius: Radius.inset).fill(Theme.secret.opacity(0.12)))
                }
                Rectangle()
                    .fill(Theme.settingsHairline)
                    .frame(height: 1)
            }
            if let note {
                Text(note)
                    .font(Typography.detail)
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
        .background(RoundedRectangle(cornerRadius: Radius.floating).fill(Theme.card))
        .clipShape(RoundedRectangle(cornerRadius: Radius.floating))
        .overlay(RoundedRectangle(cornerRadius: Radius.floating).stroke(Theme.settingsBorder))
    }
}

struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.settingsHairline)
            .frame(height: 1)
            .padding(.horizontal, Space.lg)
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
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(title)
                        .font(Typography.body.weight(.semibold))
                    if let detail {
                        Text(detail)
                            .font(Typography.detail)
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
            HStack(spacing: Space.md) {
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
                    HStack(spacing: Space.sm) {
                        Text(title).font(Typography.body.weight(.medium))
                        if warning {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(Typography.micro)
                        }
                    }
                    .foregroundStyle(warning ? Theme.deletion : Color.primary)
                    if let detail {
                        Text(detail)
                            .font(Typography.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onPointerHover { hovering = $0 }
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
    // Pills sharing a track pass the track's namespace, and the picked one's fill then
    // slides across to the next pick instead of fading out of one pill and into another.
    var thumb: Namespace.ID? = nil
    // A line under the title, for a choice whose name alone does not say what it does.
    var detail: String? = nil
    // Takes an equal share of the track rather than hugging its title.
    var fills = false
    var icon: String? = nil
    // How many items the choice covers, such as the rows a filter would show.
    var count: Int? = nil
    let choose: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            label
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .hoverLift(hovering && enabled)
        .onPointerHover { hovering = $0 }
        .motion(Motion.control, value: selected)
        .motion(Motion.hover, value: hovering)
    }

    @ViewBuilder private var label: some View {
        if let thumb {
            content
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: Radius.control)
                            .fill(Theme.accentFill)
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                    } else if hovering && enabled {
                        RoundedRectangle(cornerRadius: Radius.control).fill(Theme.field)
                    }
                }
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.45)
        } else {
            content
                .surface(fill, cornerRadius: Radius.control, border: selected ? .clear : Theme.border)
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.45)
        }
    }

    private var content: some View {
        HStack(spacing: Space.sm) {
            if let dot {
                // The accent fill swallows an amber dot, so a picked pill carries the
                // brand mark instead and the warning stays visible on it.
                Circle()
                    .fill(selected ? Theme.brand : dot)
                    .frame(width: 6, height: 6)
            }
            if let detail {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Typography.body.weight(.semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(Typography.caption)
                        .lineLimit(1)
                        .opacity(0.8)
                }
                .foregroundStyle(selected ? Color.white : Color.primary)
            } else {
                if let icon {
                    Image(systemName: icon).font(Typography.label)
                }
                Text(title)
                    .font(Typography.label)
                    // A squeezed pill must never fold its title onto two lines.
                    .lineLimit(1)
                    .fixedSize()
                if let count {
                    Text("\(count)")
                        .font(Typography.detail.weight(.medium).monospacedDigit())
                        .opacity(0.7)
                        .fixedSize()
                        .contentTransition(.numericText())
                        .motion(Motion.pop, value: count)
                }
            }
        }
        .foregroundStyle(selected ? Color.white : Color.secondary)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, detail == nil ? 6 : 7)
        // A counted filter shares its track evenly, so its words sit in the middle.
        .frame(maxWidth: fills ? .infinity : nil, alignment: count == nil ? .leading : .center)
    }

    private var fill: Color {
        if selected { return Theme.accentFill }
        return hovering && enabled ? Theme.field : Theme.card
    }
}
