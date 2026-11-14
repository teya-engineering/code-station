import SwiftUI

// The row for a project in the Workspace navigator. It is the one place a screen names
// the project it is showing and the one control that picks it, so Changes and Explorer
// both draw this row and picking a project looks and works the same on either screen.
//
// The trailing slot carries what the screen itself has to say about the project: how
// many files changed, or how many items are in it. The keyboard cursor is a ring round
// the whole row, and it is up to the screen to show it only while the keyboard drives.
struct WorkspaceProjectRow: View {
    let name: String
    var detail: String?
    let selected: Bool
    let showsCursor: Bool
    let hasChildren: Bool
    let collapsed: Bool
    let toggle: () -> Void
    let select: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            if hasChildren {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(Font.system(size: Typography.Size.micro))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .frame(width: 20, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .motion(Motion.control, value: collapsed)
                .accessibilityLabel("\(collapsed ? "Expand" : "Collapse") \(name)")
                .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            } else {
                Color.clear.frame(width: 20, height: 30).accessibilityHidden(true)
            }
            Button(action: select) {
                HStack(spacing: Space.sm) {
                    ProjectDot(tint: Theme.projectTint(for: name), size: 8)
                    Text(name).font(Typography.label).lineLimit(1)
                    Spacer(minLength: 0)
                    if let detail {
                        Text(detail)
                            .font(Font.system(size: Typography.Size.micro))
                            .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                            .fixedSize()
                    }
                }
                .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                .padding(.vertical, Space.md).padding(.trailing, Space.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .appTooltip(name)
        }
        .background(selected ? Theme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3).padding(.vertical, Space.md)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control).stroke(showsCursor ? Theme.accent : .clear, lineWidth: 2)
        }
        .hoverFill(cornerRadius: Radius.control)
        .motion(Motion.control, value: selected)
    }
}
