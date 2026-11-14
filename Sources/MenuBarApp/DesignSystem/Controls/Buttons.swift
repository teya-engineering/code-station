import AppKit
import SwiftUI

// MARK: - Buttons

// The shapes a button takes. Which one a button wears says how much of the screen it
// owns, so the shape is chosen here rather than restated wherever a button is drawn.
enum ButtonTone {
    // The one action a card or a screen is really offering.
    case dark
    // The same weight, in the app's green, for starting work.
    case green
    // The same weight in the read-only blue, for asking something that changes nothing.
    case plan
    // The same weight in the deletion red, for the action a section exists to warn about.
    // It wears the same colour as the destructive button in a dialog, so the click that
    // opens the dialog and the click that confirms it read as the same action.
    case danger
    // The deletion red as an outline, for a deletion offered beside a quieter way out
    // because the app would do it anyway.
    case dangerOutlined
    // The amber the app uses for things that want a look, for an action that puts a
    // drifted setting right.
    case attention
    // The quieter amber used by an unread item whose action is to reveal it rather than
    // resolve it. Once read, it can return to the ordinary outlined treatment.
    case attentionOutlined
    // Beside a primary one, or on its own where the action is a choice rather than the
    // point of the row.
    case outlined
    // A control that has to stay quieter than the row it sits in.
    case sunken
}

struct ActionButton: View {
    let title: String
    var tone: ButtonTone = .dark
    var height: CGFloat = ControlHeight.lg
    var size: CGFloat = Typography.Size.detail
    var icon: String? = nil
    var trailingIcon: String? = nil
    // The key that does the same thing, drawn as a cap on the button that names it. Only
    // worth carrying where the key is the faster answer and the button is how it is learnt.
    var shortcut: String? = nil
    var disclosure = false
    var fills = false
    var keyboardShortcut: KeyboardShortcut? = nil
    // Left out when the button opens a menu: `appMenu` brings a button of its own, and
    // one nested inside another swallows the click before the menu ever sees it.
    var action: (() -> Void)? = nil

    // Set by `.disabled(...)` on the button, so a caller has nothing to dim by hand.
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { shape }
                    .buttonStyle(.plain)
                    .keyboardShortcut(keyboardShortcut)
            } else {
                shape
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
    }

    private var lit: Bool { hovering && isEnabled }

    private var shape: some View {
        HStack(spacing: Space.sm) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: size - 1, weight: .semibold))
            }
            Text(title)
                .font(.system(size: size, weight: .semibold))
                .lineLimit(1)
                .contentTransition(.interpolate)
                // A button's label is the button: it holds its width and lets whatever
                // shares the row give way, rather than truncating its own words.
                .fixedSize()
            if let trailingIcon {
                Image(systemName: trailingIcon)
                    .font(.system(size: size - 1, weight: .semibold))
            }
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: size - 1.5, weight: .semibold))
                    .fixedSize()
                    .padding(.horizontal, Space.xs)
                    .padding(.vertical, 1.5)
                    .overlay(RoundedRectangle(cornerRadius: Radius.tag).stroke(label.opacity(0.32)))
                    .opacity(0.75)
            }
            if disclosure {
                MenuChevron(size: size - 4, tint: label)
                    .opacity(0.65)
            }
        }
        .foregroundStyle(label)
        .padding(.horizontal, height * 0.4)
        .frame(height: height)
        .frame(maxWidth: fills ? .infinity : nil)
        .surface(fill, cornerRadius: height * 0.25, border: stroke)
        .contentShape(RoundedRectangle(cornerRadius: height * 0.25))
    }

    private var label: Color {
        switch tone {
        case .dark, .green, .danger, .attention: Theme.onFill
        // The card colour keeps the words clear on the blue in both appearances, since the
        // blue itself lightens in dark mode.
        case .plan: Theme.card
        case .attentionOutlined: Theme.attentionText
        case .dangerOutlined: Theme.deletion
        case .outlined, .sunken: Color.primary
        }
    }

    private var fill: Color {
        switch tone {
        case .dark: Color.black.opacity(lit ? 0.82 : 0.9)
        case .green: lit ? Theme.accentFill.opacity(0.86) : Theme.accentFill
        case .plan: lit ? Theme.plan.opacity(0.86) : Theme.plan
        case .danger: lit ? Theme.deletion.opacity(0.86) : Theme.deletion
        case .attention: lit ? Theme.secret.opacity(0.86) : Theme.secret
        case .attentionOutlined:
            lit ? Theme.attention.opacity(0.14) : Theme.attention.opacity(0.08)
        case .dangerOutlined: lit ? Theme.deletion.opacity(0.08) : .clear
        case .outlined: lit ? Theme.field : .clear
        case .sunken: lit ? Theme.border : Theme.field
        }
    }

    private var stroke: Color {
        switch tone {
        case .dark, .green, .plan, .danger, .attention: .clear
        case .attentionOutlined: Theme.attention.opacity(0.38)
        case .dangerOutlined: Theme.deletion.opacity(0.45)
        case .outlined, .sunken: Theme.border
        }
    }
}

// The smallest way to offer an action: accent-coloured words, no shape at all. Used for
// the one link a section header or a footer strip carries.
struct InlineLink: View {
    let title: String
    var size: CGFloat = Typography.Size.detail
    var tint: Color = Theme.accent
    var icon: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                if let icon { Image(systemName: icon).font(.system(size: size - 1.5)) }
                Text(title).font(.system(size: size, weight: .semibold))
            }
            .foregroundStyle(tint)
            .opacity(hovering ? 0.75 : 1)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
    }
}

// A square button holding one glyph: the overflow menu at the end of a row, a close, a
// settings cog. Destructive actions live behind the overflow rather than in the row, so
// this is the only icon-only button the layouts use.
struct GlyphButton: View {
    let icon: String
    var side: CGFloat = ControlHeight.md
    // A toggle that is on wears the accent fill, the way a pressed tool does.
    var active = false
    var tint: Color? = nil
    var action: (() -> Void)? = nil

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var actOuts = 0

    var body: some View {
        Group {
            if let action {
                Button {
                    actOuts += 1
                    action()
                } label: { shape }
                    .buttonStyle(.plain)
            } else {
                shape
            }
        }
        .hoverLift(hovering, amount: Motion.smallLift)
        .onPointerHover { hovering = $0 }
    }

    private var shape: some View {
        Image(systemName: icon)
            .font(.system(size: side * 0.42, weight: .semibold))
            // A glyph that changes meaning, such as a star filling in, turns into the
            // new one rather than being swapped.
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .actOut(icon, trigger: actOuts)
            .foregroundStyle(active ? Color.white : tint ?? Color.secondary)
            .frame(width: side, height: side)
            .surface(fill, cornerRadius: side * 0.27, border: active ? .clear : Theme.border)
            .contentShape(RoundedRectangle(cornerRadius: side * 0.27))
    }

    private var fill: Color {
        let lit = hovering && isEnabled
        if active { return lit ? Theme.accentFill.opacity(0.86) : Theme.accentFill }
        return lit ? Theme.field : .clear
    }
}

// The dropdown: a pill showing the value in force, with the choices opening under it as
// the app's own menu. It takes the width its caption or row gives it, and the menu takes
// the same width by default so it reads as the pill unfolding.
struct OptionMenu: View {
    var caption: String? = nil
    let value: String
    var matchWidth = true
    let entries: () -> [MenuEntry]

    init(caption: String? = nil, value: String, matchWidth: Bool = true,
         entries: @escaping () -> [MenuEntry]) {
        self.caption = caption
        self.value = value
        self.matchWidth = matchWidth
        self.entries = entries
    }

    // The one-of-a-set form: each option says whether it is the one in force.
    init(caption: String? = nil, value: String,
         options: [(label: String, checked: Bool, choose: () -> Void)]) {
        self.init(caption: caption, value: value) {
            options.map { option in
                .item(option.label, checked: option.checked, action: option.choose)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let caption {
                SectionLabel(caption, style: .field)
            }
            OptionMenuPill(value: value)
                .appMenu(matchWidth: matchWidth, entries)
        }
    }
}

// The pill itself, kept apart from the control around it so it can read whether its own
// menu is open: that state is set on the label by the menu button, which is a layer
// below where OptionMenu's body is built.
private struct OptionMenuPill: View {
    let value: String

    @Environment(\.menuIsOpen) private var open
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.md) {
            Text(value)
                .font(Typography.detail.weight(.medium))
            Spacer()
            MenuChevron()
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .surface(open || hovering ? Theme.field : Theme.card, cornerRadius: Radius.card,
                 border: open ? Theme.accent.opacity(0.5) : Theme.border)
        .contentShape(Rectangle())
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .motion(Motion.reveal, value: open)
    }
}

// Accent or red words with a glyph in front, for a small inline action such as the
// delete link in an editor heading. The glyph plays its part once when clicked.
struct GlyphLink: View {
    let icon: String
    let title: String
    let tint: Color
    let action: () -> Void

    @State private var hovering = false
    @State private var actOuts = 0

    var body: some View {
        Button {
            actOuts += 1
            action()
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: icon)
                    .font(Typography.caption.weight(.semibold))
                    .actOut(icon, trigger: actOuts)
                Text(title).font(Typography.body.weight(.semibold))
            }
            .foregroundStyle(tint)
            .opacity(hovering ? 0.75 : 1)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
    }
}

// The button that makes a new item in a list-and-editor sheet. Outlined and full width
// at the foot of the list, where the new item appears, or filled on an empty pane.
struct NewItemButton: View {
    let title: String
    var filled = false
    let action: () -> Void

    @State private var hovering = false
    @State private var actOuts = 0

    var body: some View {
        Button {
            actOuts += 1
            action()
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "plus")
                    .font(Typography.label)
                    .actOut("plus", trigger: actOuts)
                Text(title).font(Typography.body.weight(.semibold))
            }
            .foregroundStyle(filled ? Color.white : Color.primary)
            .padding(.horizontal, Space.lg)
            .frame(maxWidth: filled ? nil : .infinity)
            .frame(height: ControlHeight.lg)
            .surface(fill, cornerRadius: Radius.control, border: filled ? .clear : Theme.border)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
    }

    private var fill: Color {
        if filled { return hovering ? Theme.accentFill.opacity(0.86) : Theme.accentFill }
        return hovering ? Theme.field : Theme.card
    }
}
