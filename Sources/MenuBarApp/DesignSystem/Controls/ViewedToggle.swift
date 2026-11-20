import SwiftUI

// A tick on a changed file saying it has been read, the way GitHub's Viewed box works.
// It is an outlined pill with the checkbox inside, so it reads as the file's own state
// and not as the commit checkbox on the file's row. A file changed since it was ticked
// wears an amber edge until it is read again.
struct ViewedToggle: View {
    let isOn: Bool
    var edited = false
    // `ControlHeight.md` in a pane's header, `.sm` in a card's own header.
    var height: CGFloat = ControlHeight.md
    let toggle: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var lit: Bool { hovering && isEnabled }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Space.sm) {
                CheckboxMark(isOn: isOn)
                Text("Viewed")
                    .font(.system(size: height < ControlHeight.md ? Typography.Size.caption : Typography.Size.detail,
                                  weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(isOn ? Theme.accent : lit ? Color.primary : Color.secondary)
            .padding(.leading, (height - 16) / 2)
            .padding(.trailing, height * 0.4)
            .frame(height: height)
            .surface(fill, cornerRadius: height * 0.25, border: stroke)
            .contentShape(RoundedRectangle(cornerRadius: height * 0.25))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.control, value: isOn)
        .motion(Motion.control, value: edited)
        .motion(Motion.hover, value: lit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Viewed")
        .accessibilityAddTraits(isOn ? [.isToggle, .isSelected] : [.isToggle])
    }

    private var fill: Color {
        if isOn { return Theme.accent.opacity(lit ? 0.14 : 0.10) }
        return lit ? Theme.field : .clear
    }

    private var stroke: Color {
        if isOn { return Theme.accent.opacity(0.32) }
        return edited ? Theme.attention.opacity(0.45) : Theme.border
    }
}
