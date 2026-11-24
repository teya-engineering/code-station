import SwiftUI

// What draws while the agent is still writing the block out, so the space it will take
// is held rather than the reply jumping when it lands.
struct TraceArrivingCard: View {
    var body: some View {
        Breathing(period: 1.8) { skeleton }
            .surface(Theme.card, cornerRadius: Radius.floating)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Trace arriving")
            .accessibilityValue("The agent is writing out the trace")
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            line(width: 0.46, height: 13)
            line(width: 0.22, height: 9)
            VStack(alignment: .leading, spacing: Space.md) {
                ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, bar in
                    GeometryReader { proxy in
                        HStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: Radius.tag)
                                .fill(Theme.field)
                                .frame(width: proxy.size.width * 0.3 * bar.label, height: 9)
                            Spacer(minLength: 0)
                        }
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: Radius.tag)
                                .fill(Theme.field)
                                .frame(width: max(proxy.size.width * 0.6 * bar.width, 4), height: 9)
                                .offset(x: proxy.size.width * (0.38 + 0.6 * bar.offset))
                        }
                    }
                    .frame(height: 9)
                }
            }
            .padding(.top, Space.md)
            Text("The agent is writing out the trace. It draws once the block is complete.")
                .scaledText(Typography.Size.detail)
                .foregroundStyle(.secondary)
                .padding(.top, Space.xs)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let bars: [(label: CGFloat, offset: CGFloat, width: CGFloat)] = [
        (1, 0, 1), (0.8, 0.03, 0.08), (0.66, 0.05, 0.04), (0.66, 0.33, 0.03),
        (0.8, 0.68, 0.04), (0.6, 0.96, 0.01),
    ]

    private func line(width: CGFloat, height: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: Radius.tag)
                .fill(Theme.field)
                .frame(width: proxy.size.width * width, height: height)
        }
        .frame(height: height)
    }
}

// A trace block that could not be read. What can be made out of it is named, so asking
// for it again asks for the right trace.
struct TraceUnreadableCard: View {
    @Environment(\.askAgent) private var askAgent
    @State private var asked = false

    let traceID: String?
    let server: String?

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.warningText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("This trace could not be drawn")
                    .scaledText(Typography.Size.body, .semibold)
                Text(detail)
                    .scaledText(Typography.Size.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let askAgent {
                    Group {
                        if asked {
                            ActionButton(title: "Asked the agent", tone: .outlined, height: ControlHeight.md,
                                         size: Typography.Size.detail, icon: "checkmark")
                                .disabled(true)
                        } else {
                            ActionButton(title: "Ask the agent to fetch it again", tone: .dark,
                                         height: ControlHeight.md, size: Typography.Size.detail, icon: "arrow.clockwise") {
                                askAgent(TraceFollowUp.drawAgain(traceID, server: server))
                                asked = true
                            }
                        }
                    }
                    .padding(.top, Space.xs)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.card, cornerRadius: Radius.floating)
    }

    private var detail: String {
        var text = "The block the agent wrote could not be read, so there is nothing reliable to show."
        if let traceID {
            let short = traceID.count > 12 ? "\(traceID.prefix(8))…\(traceID.suffix(4))" : traceID
            text += " Trace \(short)" + (server.map { " from \($0)" } ?? "") + "."
        }
        return text
    }
}
