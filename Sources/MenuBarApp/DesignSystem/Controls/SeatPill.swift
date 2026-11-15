import SwiftUI

// A compact reviewer menu, or a full-width field whose words can wrap.
struct SeatPill<Content: View>: View {
    var form = false
    @ViewBuilder let content: Content

    @State private var hovering = false
    @Environment(\.menuIsOpen) private var open

    var body: some View {
        HStack(spacing: Space.xs) {
            content
                .fixedSize(horizontal: false, vertical: form)
            if form { Spacer(minLength: 0) }
            MenuChevron(size: Space.md)
        }
        .font(Typography.label)
        .lineLimit(form ? nil : 1)
        .padding(.horizontal, Space.md)
        .padding(.vertical, form ? Space.xs : 0)
        .frame(minWidth: form ? 0 : nil, maxWidth: form ? .infinity : nil, minHeight: ControlHeight.sm)
        .background(Capsule().fill(hovering || open ? Theme.border : Theme.field))
        .contentShape(Capsule())
        .fixedSize(horizontal: !form, vertical: true)
        .hoverLift(hovering)
        .motion(Motion.hover, value: hovering || open)
        .onPointerHover { hovering = $0 }
    }
}
