import SwiftUI

// The strip a find lives in, shared by every pane that can search what it shows, so
// finding in a file and finding in a conversation look and behave the same.
struct FindBar: View {
    let placeholder: String
    @Binding var query: String
    let summary: String
    let hasMatches: Bool
    var focused: FocusState<Bool>.Binding
    let move: (Int) -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused(focused)
                    .onSubmit { move(1) }
                    .onExitCommand(perform: close)
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 90, idealWidth: 260, maxWidth: 260)
            .frame(height: 28)
            .fieldSurface(cornerRadius: 7)

            Text(summary)
                .font(.mono(10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 55, idealWidth: 82, alignment: .trailing)

            button("chevron.up", help: "Previous match", disabled: !hasMatches) { move(-1) }
            button("chevron.down", help: "Next match", disabled: !hasMatches) { move(1) }
            button("xmark", help: "Close find", action: close)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .onAppear { focused.request() }
    }

    private func button(_ systemName: String, help: String, disabled: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.accent.opacity(disabled ? 0.3 : 1))
                .frame(width: 26, height: 26)
                .fieldSurface(cornerRadius: 7)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .hoverLift(amount: Motion.smallLift)
        .disabled(disabled)
        .appTooltip(help)
        .accessibilityLabel(help)
    }
}

enum FindSummary {
    static func text(query: String, matchCount: Int, hasMore: Bool, selection: Int) -> String {
        guard !query.isEmpty else { return "" }
        guard matchCount > 0 else { return "No matches" }
        return "\(selection + 1) of \(matchCount)\(hasMore ? "+" : "")"
    }
}

extension FocusState<Bool>.Binding {
    // SwiftUI can go on believing a field is focused after the caret has left it, and
    // then setting the flag to true again changes nothing. Clearing it first and setting
    // it on the next pass makes every request a real change.
    @MainActor func request() {
        wrappedValue = false
        DispatchQueue.main.async { wrappedValue = true }
    }
}
