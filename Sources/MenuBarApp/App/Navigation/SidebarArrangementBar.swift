import SwiftUI

struct SidebarArrangementBar: View {
    @Binding var sort: ProjectSort
    @Binding var grouping: ProjectGrouping

    var body: some View {
        HStack(spacing: Space.sm) {
            SidebarArrangementLabel(title: sort.label, icon: sort.icon)
                .appMenu(showsFocusRing: true) {
                    [ProjectSort.lastUsed, .name].map { option in
                        .item(option.label, icon: option.icon, checked: sort == option,
                              subtitle: option.hint) { sort = option }
                    } + [
                        .separator,
                        .item(MenuItem(label: "Pinned work always stays at the top."))
                    ]
                }
                .accessibilityLabel("Sort: \(sort.label)")
                .appTooltip("Sort your work")

            Spacer(minLength: 6)

            SidebarArrangementLabel(title: grouping.label, icon: grouping.icon)
                .appMenu(showsFocusRing: true) {
                    ProjectGrouping.allCases.map { option in
                        .item(option.label, icon: option.icon, checked: grouping == option,
                              subtitle: option.hint) { grouping = option }
                    }
                }
                .accessibilityLabel("Grouping: \(grouping.label)")
                .appTooltip("Group your work")
        }
        .frame(height: 43)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
        .padding(.horizontal, Space.lg)
    }
}

private struct SidebarArrangementLabel: View {
    let title: String
    let icon: String

    @Environment(\.menuIsOpen) private var isOpen
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: icon)
                .font(Typography.detail)
            Text(title)
                .font(Font.system(size: Typography.Size.micro, weight: .medium))
                .lineLimit(1)
            MenuChevron(size: 8)
        }
        .foregroundStyle(isOpen ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
        .padding(.horizontal, Space.xxs)
        .padding(.vertical, Space.sm)
        .background(RoundedRectangle(cornerRadius: Radius.inset)
            .fill(isOpen || hovering ? Theme.field : .clear))
        .contentShape(RoundedRectangle(cornerRadius: Radius.inset))
        .motion(Motion.hover, value: hovering)
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
    }
}
