import AppKit
import SwiftUI
import CodeStationCore

// MARK: - Warnings

// A surface that carries a warning: a failed turn, a stalled agent, a configuration that
// could not be read. Drawn once here so every warning in the app reads as the same kind of
// interruption, and so the pair of adaptive colours WarningContrastTests measures is the
// pair everything actually uses.
private struct WarningCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.warningText)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warningBackground))
            .transition(.fadeIn)
    }
}

extension View {
    func warningCard() -> some View { modifier(WarningCard()) }
}

// The same warning as a band across the full width of a sheet or a pane, for a state
// that belongs to the whole screen rather than to one card on it. Whatever it offers,
// a retry or a reload, sits at its trailing end.
struct WarningStrip<Trailing: View>: View {
    let text: String
    var icon = "exclamationmark.triangle.fill"
    @ViewBuilder let trailing: Trailing

    init(_ text: String, icon: String = "exclamationmark.triangle.fill",
         @ViewBuilder trailing: () -> Trailing) {
        self.text = text
        self.icon = icon
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.warningText)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.warningBackground)
        .transition(.fadeIn)
    }
}

extension WarningStrip where Trailing == EmptyView {
    init(_ text: String, icon: String = "exclamationmark.triangle.fill") {
        self.init(text, icon: icon) { EmptyView() }
    }
}
