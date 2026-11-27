import SwiftUI

// Where the agent, model or effort changed between turns. A model or effort change is a
// quiet pill; an agent switch is a seam across the transcript in both agents' colours,
// with what the new agent runs on, what it was handed, and the way back.
struct SettingsMarkerView: View {
    let marker: SettingsMarker
    let date: Date

    var body: some View {
        switch marker.kind {
        case .model, .effort:
            ChangePill(marker: marker, date: date)
        case .agent:
            AgentSeam(marker: marker, date: date)
        }
    }
}

private struct ChangePill: View {
    let marker: SettingsMarker
    let date: Date

    var body: some View {
        HStack(spacing: Space.sm) {
            ReviewAvatar(agent: marker.agent, size: Space.xl)
            Text(marker.kind == .model ? "Model changed to " : "Effort changed to ")
                .foregroundStyle(.secondary)
                + Text(marker.value).foregroundStyle(.primary)
            TimeStamp(date: date)
        }
        .font(Typography.caption)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs)
        .background(Theme.field, in: Capsule())
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct AgentSeam: View {
    let marker: SettingsMarker
    let date: Date

    @State private var showsNote = false
    @Environment(\.switchAgentBack) private var switchBack
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var from: AgentKind { marker.from ?? marker.agent }

    var body: some View {
        VStack(spacing: Space.sm) {
            HStack(spacing: Space.md) {
                seamLine(from: from.tint.opacity(0), to: from.tint)
                HStack(spacing: -Space.sm) {
                    ReviewAvatar(agent: from, size: ControlHeight.xs, muted: true)
                    ReviewAvatar(agent: marker.agent, size: ControlHeight.xs)
                }
                Text("Switched to \(marker.agent.title)")
                    .font(Typography.label)
                TimeStamp(date: date)
                seamLine(from: marker.agent.tint, to: marker.agent.tint.opacity(0))
            }
            HStack(spacing: Space.sm) {
                if let settings = marker.settings {
                    Text(settings)
                        .font(Typography.data)
                        .foregroundStyle(.secondary)
                }
                if marker.note != nil || marker.handoff == .transcript {
                    Text("·").foregroundStyle(.tertiary)
                    InlineLink(title: showsNote ? "Hide the note" : "Show the note",
                               size: Typography.Size.caption) {
                        withAnimation(reduceMotion ? nil : showsNote ? Motion.leave : Motion.reveal) {
                            showsNote.toggle()
                        }
                    }
                    .accessibilityValue(showsNote ? "Expanded" : "Collapsed")
                }
                if let switchBack {
                    Text("·").foregroundStyle(.tertiary)
                    InlineLink(title: "Go back to \(from.title)", size: Typography.Size.caption) {
                        switchBack.action(from)
                    }
                    .disabled(!switchBack.available)
                    .appTooltip(switchBack.available
                                ? "Review a switch back to \(from.title). It resumes its own conversation."
                                : "You can switch when this turn ends.")
                }
            }
            .font(Typography.caption)
            if showsNote {
                noteBody
                    .transition(.fold)
            }
        }
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Switched from \(from.title) to \(marker.agent.title)")
    }

    private func seamLine(from start: Color, to end: Color) -> some View {
        LinearGradient(colors: [start, end], startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private var noteBody: some View {
        let text = marker.note ?? "The whole transcript was sent to \(marker.agent.title) as plain text."
        return SelectableText(plain: text, size: Typography.Size.detail, design: .monospaced,
                              secondary: true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.card)
            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: Radius.card))
    }
}
