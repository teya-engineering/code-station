import SwiftUI

// When a transcript entry happened, as a quiet caption at the end of its row. The row
// shows the time in the format picked in Settings → Appearance; hovering it gives the
// whole moment, day and second. Draws nothing when stamps are off or the entry has no
// time, so a call site can place it unconditionally.
struct TimeStamp: View {
    let date: Date?
    // A step's stamp, which the "Messages only" choice hides.
    var step = false

    @Environment(\.transcriptTimestamps) private var stamps

    var body: some View {
        if let date, let label = stamps.label(for: date, step: step) {
            let full = stamps.tooltip(for: date)
            Text(label)
                .scaledMono(Typography.Size.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
                .appTooltip(full)
                .accessibilityLabel("At \(full)")
                .transition(.fold)
        }
    }
}
