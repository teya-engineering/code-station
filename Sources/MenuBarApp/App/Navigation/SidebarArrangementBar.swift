import SwiftUI
import CodeStationCore

struct SidebarArrangementBar: View {
    @Binding var sort: ProjectSort
    @Binding var grouping: ProjectGrouping

    var body: some View {
        HStack(spacing: 6) {
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
        .padding(.horizontal, 14)
    }
}

private struct SidebarArrangementLabel: View {
    let title: String
    let icon: String

    @Environment(\.menuIsOpen) private var isOpen
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(isOpen ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 3)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isOpen || hovering ? Theme.field : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }
}
