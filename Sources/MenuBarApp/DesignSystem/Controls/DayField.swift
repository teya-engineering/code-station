import SwiftUI

// A count of days typed or stepped, held to a range. Old session cleanup, the new
// workspace sheet and Stats all ask in days, so they share one field.
struct DayField: View {
    @Binding var days: Int
    var range = OldSessions.dayRange
    var accessibilityLabel = "Old session age in days"

    private func resolved(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private var value: Binding<Int> {
        Binding(
            get: { days },
            set: { days = resolved($0) }
        )
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            TextField("Days", value: value, format: .number)
                .textFieldStyle(.plain)
                .font(Typography.body.weight(.semibold))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 36)
                .accessibilityLabel(accessibilityLabel)
            Text(days == 1 ? "day" : "days")
                .font(Typography.body.weight(.medium))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                DayStepButton(icon: "chevron.up", label: "One more day",
                              enabled: days < range.upperBound) {
                    days = resolved(days + 1)
                }
                DayStepButton(icon: "chevron.down", label: "One less day",
                              enabled: days > range.lowerBound) {
                    days = resolved(days - 1)
                }
            }
        }
        .padding(.leading, Space.md)
        .padding(.trailing, Space.xs)
        .frame(height: ControlHeight.lg)
        .fieldSurface(cornerRadius: Radius.card)
    }
}

private struct DayStepButton: View {
    let icon: String
    let label: String
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var clicks = 0

    var body: some View {
        Button {
            clicks += 1
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering && enabled ? Theme.accent : .secondary)
                .actOut(icon, trigger: clicks)
                .frame(width: 20, height: 13)
                .background(hovering && enabled ? Theme.accent.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.tag))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onPointerHover { hovering = $0 }
        .hoverLift(hovering, amount: Motion.smallLift)
        .motion(Motion.hover, value: hovering)
        .motion(Motion.control, value: enabled)
        .accessibilityLabel(label)
    }
}
