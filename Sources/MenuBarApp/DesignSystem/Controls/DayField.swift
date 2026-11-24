import SwiftUI

// A count of days typed or stepped, held to a range. Old session cleanup, the new
// workspace sheet and Stats all ask in days, so they share one field.
struct DayField: View {
    @Binding var days: Int
    var range = OldSessions.dayRange
    var accessibilityLabel = "Old session age in days"
    var validatesEntry = false
    var onValidityChange: (Bool) -> Void = { _ in }

    @State private var draft: String?
    @FocusState private var focused: Bool

    static func validDays(_ text: String, in range: ClosedRange<Int>) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text), range.contains(value) else { return nil }
        return value
    }

    private var invalid: Bool {
        validatesEntry && draft.map { Self.validDays($0, in: range) == nil } == true
    }

    private var correction: String {
        "Use \(range.lowerBound) to \(range.upperBound) whole days."
    }

    private func commit() {
        guard let draft, let value = Self.validDays(draft, in: range) else { return }
        days = value
        self.draft = nil
    }

    @ViewBuilder private var entry: some View {
        if validatesEntry {
            TextField("Days", text: Binding(get: { draft ?? String(days) }, set: { draft = $0 }))
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, active in if !active { commit() } }
                .onKeyPress(.escape) {
                    draft = nil
                    focused = false
                    return .handled
                }
                .onChange(of: days) { _, _ in draft = nil }
                .accessibilityHint(invalid ? correction : "Enter a whole number from \(range.lowerBound) to \(range.upperBound).")
        } else {
            TextField("Days", value: value, format: .number)
        }
    }

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
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                entry
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
                    DayStepButton(icon: "chevron.up", label: "\(accessibilityLabel): one more day",
                                  enabled: days < range.upperBound) {
                        draft = nil
                        days = resolved(days + 1)
                    }
                    DayStepButton(icon: "chevron.down", label: "\(accessibilityLabel): one less day",
                                  enabled: days > range.lowerBound) {
                        draft = nil
                        days = resolved(days - 1)
                    }
                }
            }
            .padding(.leading, Space.md)
            .padding(.trailing, Space.xs)
            .frame(height: ControlHeight.lg)
            .fieldSurface(cornerRadius: Radius.card)
            .overlay {
                if invalid {
                    RoundedRectangle(cornerRadius: Radius.card).stroke(Theme.deletion)
                } else {
                    FocusRingStroke(focused: focused, cornerRadius: Radius.card)
                }
            }
            if invalid {
                Text(correction)
                    .font(Typography.micro)
                    .foregroundStyle(Theme.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .motion(Motion.control, value: invalid)
        .onChange(of: invalid) { _, invalid in
            onValidityChange(!invalid)
            if invalid { AccessibilityNotification.Announcement("\(accessibilityLabel). \(correction)").post() }
        }
    }
}

private struct DayStepButton: View {
    let icon: String
    let label: String
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var clicks = 0
    @FocusState private var focused: Bool

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
        .focused($focused)
        .overlay { FocusRingStroke(focused: focused, cornerRadius: Radius.tag) }
    }
}
