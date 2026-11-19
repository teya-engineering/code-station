import SwiftUI

// Settings → Appearance → Timestamps: how a transcript writes the time of each entry, and
// which entries carry one.
struct TimestampSettingsRow: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(alignment: .center, spacing: Space.xxl) {
                SettingsView.settingCopy(
                    title: "Timestamps",
                    detail: "When each message and step happened. Hover one for the full date.")
                    .frame(width: 160, alignment: .leading)

                Spacer(minLength: 0)

                HStack(spacing: Space.xs) {
                    ForEach(TimestampFormat.allCases) { format in
                        ChoicePill(title: format.label,
                                   selected: settings.timestampFormat == format) {
                            settings.timestampFormat = format
                        }
                        .accessibilityLabel("Timestamps: \(format.label)")
                        .accessibilityValue(settings.timestampFormat == format
                                            ? "Selected" : "Not selected")
                    }
                }
            }

            HStack(alignment: .center, spacing: Space.xxl) {
                timestampPreview
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: Space.xs) {
                    ForEach(TimestampScope.allCases) { scope in
                        ChoicePill(title: scope.label,
                                   selected: settings.timestampScope == scope,
                                   enabled: settings.timestampFormat != .off) {
                            settings.timestampScope = scope
                        }
                        .accessibilityLabel("Show timestamps on: \(scope.label)")
                        .accessibilityValue(settings.timestampScope == scope
                                            ? "Selected" : "Not selected")
                    }
                }
            }
        }
        .padding(Space.lg)
    }

    // What a stamp would read for something sent right now, so a choice is seen before a
    // session is opened.
    @ViewBuilder private var timestampPreview: some View {
        let stamps = settings.transcriptTimestamps
        let now = Date()
        Group {
            if let label = stamps.label(for: now) {
                Text("Reads \(Text(label).fontWeight(.semibold).foregroundStyle(.primary)), and \(Text(stamps.tooltip(for: now)).fontWeight(.semibold).foregroundStyle(.primary)) on hover.")
            } else {
                Text("Transcripts show no times.")
            }
        }
        .font(Typography.detail)
        .foregroundStyle(.secondary)
        .contentTransition(.numericText())
        .motion(Motion.control, value: stamps)
        .fixedSize(horizontal: false, vertical: true)
    }
}
