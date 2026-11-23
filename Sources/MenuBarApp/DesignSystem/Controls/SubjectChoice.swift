import SwiftUI

struct SubjectChoice: View {
    let title: String
    let detail: String
    let icon: String
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Image(systemName: icon).font(Typography.title)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(Typography.caption)
                        .contentTransition(.symbolEffect(.replace))
                }
                .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
                Text(title).font(Typography.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, minHeight: ReviewMetrics.subjectHeight, alignment: .topLeading)
            .surface(selected ? Theme.accent.opacity(0.08) : Theme.card, cornerRadius: Radius.control,
                     border: selected ? Theme.accent.opacity(0.5) : Theme.border)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .overlay { FocusRingStroke(focused: focused) }
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.control, value: selected)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
