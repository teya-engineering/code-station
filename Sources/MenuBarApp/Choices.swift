import SwiftUI

// The pieces the Settings sheet is built from, where the app-wide defaults live. A
// session's own overrides are picked on its composer bar instead; its Usage pane still
// borrows ChoiceBlock for the heading.

// A titled group of choices with a line underneath saying what the group means. The badge
// is what marks a group as overridden, so a session shows at a glance where it has stepped
// away from the app settings.
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
                SectionLabel(text: title)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9.5, weight: .semibold))
                        .kerning(0.6)
                        .foregroundStyle(Theme.secret)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.secret.opacity(0.12)))
                }
            }
            content
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? selectionColour : Color.secondary)
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
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? selectedBackground : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(selected ? selectionColour.opacity(0.35) : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// A scale reads better as one strip than as a column of radio buttons, since the order is
// half of what it says.
struct ChoicePill: View {
    let title: String
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                // A squeezed pill must never fold its title onto two lines.
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Theme.accentFill : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? .clear : Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
