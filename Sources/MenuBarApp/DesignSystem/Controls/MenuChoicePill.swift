import SwiftUI

// A ChoicePill whose choice carries a value of its own, such as the branch to compare
// with. The words pick the choice. The chevron opens the menu of values, and so do the
// words once the choice is picked, since picking it again would do nothing.
struct MenuChoicePill: View {
    let title: String
    let selected: Bool
    var enabled = true
    // For a value the machine made, such as a branch, which reads as data.
    var monospaced = false
    // What the chevron says to a screen reader, such as "Pick the branch to compare with".
    let menuLabel: String
    let choose: () -> Void
    let entries: () -> [MenuEntry]

    @State private var hovering = false

    private var ink: Color { selected ? Theme.onFill : Color.secondary }

    var body: some View {
        HStack(spacing: 0) {
            words
            Rectangle()
                .fill(selected ? Theme.onFill.opacity(0.22) : Theme.border)
                .frame(width: 1)
                .padding(.vertical, Space.sm)
            MenuChevron(tint: ink)
                .padding(.horizontal, Space.sm)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .appMenu(entries)
                .accessibilityLabel(menuLabel)
        }
        .frame(height: ControlHeight.md)
        .surface(fill, cornerRadius: Radius.control, border: selected ? .clear : Theme.border)
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .hoverLift(hovering && enabled)
        .onPointerHover { hovering = $0 }
        .motion(Motion.control, value: selected)
        .motion(Motion.hover, value: hovering)
    }

    @ViewBuilder private var words: some View {
        let label = Text(title)
            .font(monospaced ? Typography.data.weight(.semibold) : Typography.label)
            .foregroundStyle(ink)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.leading, Space.lg)
            .padding(.trailing, Space.sm)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        if selected {
            label
                .appMenu(entries)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isSelected)
                .accessibilityHint(menuLabel)
        } else {
            Button(action: choose) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
        }
    }

    private var fill: Color {
        if selected { return Theme.accentFill }
        return hovering && enabled ? Theme.field : Theme.card
    }
}
