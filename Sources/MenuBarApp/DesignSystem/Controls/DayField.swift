import SwiftUI

// A count of days typed or stepped, held to the range old session cleanup allows. Old
// session settings and the new workspace sheet both ask in days, so they share one field.
struct DayField: View {
    @Binding var days: Int
    var accessibilityLabel = "Old session age in days"

    private var value: Binding<Int> {
        Binding(
            get: { days },
            set: { days = OldSessions.resolvedDays($0) }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("Days", value: value, format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 36)
                .accessibilityLabel(accessibilityLabel)
            Text(days == 1 ? "day" : "days")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                DayStepButton(icon: "chevron.up", label: "One more day",
                              enabled: days < OldSessions.dayRange.upperBound) {
                    days = OldSessions.resolvedDays(days + 1)
                }
                DayStepButton(icon: "chevron.down", label: "One less day",
                              enabled: days > OldSessions.dayRange.lowerBound) {
                    days = OldSessions.resolvedDays(days - 1)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 34)
        .fieldSurface(cornerRadius: 9)
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
                            in: RoundedRectangle(cornerRadius: 4))
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
