import SwiftUI

// A whole number typed or stepped, held to a range, with its unit beside it. Anything the
// person sets as a count, such as days or lines, uses this one field.
struct NumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    // The unit after the number, singular then plural.
    let unit: (one: String, many: String)
    // Wide enough for the longest number the range allows.
    var width: CGFloat = 36
    let accessibilityLabel: String
    var validatesEntry = false
    var onValidityChange: (Bool) -> Void = { _ in }

    @State private var draft: String?
    @FocusState private var focused: Bool

    static func validNumber(_ text: String, in range: ClosedRange<Int>) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text), range.contains(value) else { return nil }
        return value
    }

    private var invalid: Bool {
        validatesEntry && draft.map { Self.validNumber($0, in: range) == nil } == true
    }

    private var correction: String {
        "Use \(range.lowerBound.formatted()) to \(range.upperBound.formatted()) whole \(unit.many)."
    }

    private func stepLabel(_ direction: String) -> String {
        "\(accessibilityLabel): \(step == 1 ? "one" : step.formatted()) \(direction) \(step == 1 ? unit.one : unit.many)"
    }

    private func commit() {
        guard let draft, let typed = Self.validNumber(draft, in: range) else { return }
        value = typed
        self.draft = nil
    }

    @ViewBuilder private var entry: some View {
        if validatesEntry {
            TextField(unit.many.capitalized,
                      text: Binding(get: { draft ?? String(value) }, set: { draft = $0 }))
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, active in if !active { commit() } }
                .onKeyPress(.escape) {
                    draft = nil
                    focused = false
                    return .handled
                }
                .onChange(of: value) { _, _ in draft = nil }
                .accessibilityHint(invalid ? correction : "Enter a whole number from \(range.lowerBound) to \(range.upperBound).")
        } else {
            TextField(unit.many.capitalized, value: clamped, format: .number)
        }
    }

    private func resolved(_ candidate: Int) -> Int {
        min(max(candidate, range.lowerBound), range.upperBound)
    }

    private var clamped: Binding<Int> {
        Binding(
            get: { value },
            set: { value = resolved($0) }
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
                    .frame(width: width)
                    .accessibilityLabel(accessibilityLabel)
                Text(value == 1 ? unit.one : unit.many)
                    .font(Typography.body.weight(.medium))
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    NumberStepButton(icon: "chevron.up", label: stepLabel("more"),
                                     enabled: value < range.upperBound) {
                        draft = nil
                        value = resolved(value + step)
                    }
                    NumberStepButton(icon: "chevron.down", label: stepLabel(step == 1 ? "less" : "fewer"),
                                     enabled: value > range.lowerBound) {
                        draft = nil
                        value = resolved(value - step)
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

// A count of days, held to a range. Old session cleanup, the new workspace sheet and
// Stats all ask in days, so they share one field.
struct DayField: View {
    @Binding var days: Int
    var range = OldSessions.dayRange
    var accessibilityLabel = "Old session age in days"
    var validatesEntry = false
    var onValidityChange: (Bool) -> Void = { _ in }

    static func validDays(_ text: String, in range: ClosedRange<Int>) -> Int? {
        NumberField.validNumber(text, in: range)
    }

    var body: some View {
        NumberField(value: $days, range: range, unit: (one: "day", many: "days"),
                    accessibilityLabel: accessibilityLabel, validatesEntry: validatesEntry,
                    onValidityChange: onValidityChange)
    }
}

private struct NumberStepButton: View {
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
