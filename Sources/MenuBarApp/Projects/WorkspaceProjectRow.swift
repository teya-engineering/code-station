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
        HStack(spacing: 6) {
            if hasChildren {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
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
                HStack(spacing: 7) {
                    ProjectDot(tint: Theme.projectTint(for: name), size: 8)
                    Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                            .fixedSize()
                    }
                }
                .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                .padding(.vertical, 10).padding(.trailing, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .appTooltip(name)
        }
        .background(selected ? Theme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3).padding(.vertical, 8)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7).stroke(showsCursor ? Theme.accent : .clear, lineWidth: 2)
        }
    }
}
