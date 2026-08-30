import SwiftUI

struct PresentedToolCall: Equatable {
    let call: WorkingSetToolCall
    let projectPath: String
}

@MainActor
@Observable
final class ToolCallDetailPresenter {
    private(set) var current: PresentedToolCall?
    private(set) var anchor = CGRect.zero
    private(set) var generation = 0

    func toggle(_ call: WorkingSetToolCall, projectPath: String, from anchor: CGRect) {
        if current?.call.id == call.id {
            dismiss()
            return
        }
        current = PresentedToolCall(call: call, projectPath: projectPath)
        self.anchor = anchor
        generation += 1
    }

    func refresh(_ call: WorkingSetToolCall, projectPath: String) {
        guard current?.call.id == call.id,
              current != PresentedToolCall(call: call, projectPath: projectPath) else { return }
        current = PresentedToolCall(call: call, projectPath: projectPath)
        generation += 1
    }

    func dismiss(callID: String? = nil) {
        guard callID == nil || current?.call.id == callID else { return }
        current = nil
    }
}

struct ToolCallDetailHost: View {
    @Environment(ToolCallDetailPresenter.self) private var presenter

    private static let width: CGFloat = 560
    private static let gap: CGFloat = 10
    private static let margin: CGFloat = 8

    @State private var measurement = OverlayMeasurement()

    private var size: CGSize { measurement.size }

    var body: some View {
        if let presented = presenter.current {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { presenter.dismiss() }

                    card(presented, bounds: geometry.size)
                        .id(presenter.generation)
                        .measuredOverlay(generation: presenter.generation,
                                         into: $measurement)
                        .offset(x: x(in: geometry.size), y: y(in: geometry.size))

                    Button("") { presenter.dismiss() }
                        .buttonStyle(.plain)
                        .opacity(0)
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
            .ignoresSafeArea()
        }
    }

    private func card(_ presented: PresentedToolCall, bounds: CGSize) -> some View {
        VStack(spacing: 0) {
            header(presented.call)
            Divider().overlay(Theme.hairline)
            MenuContentScrollView(maxHeight: max(0, bounds.height - 90)) {
                ToolCallExpandedDetail(
                    tool: presented.call.tool,
                    projectPath: presented.projectPath,
                    isRunning: presented.call.state == .running)
                    .padding(12)
            }
        }
        .frame(width: min(Self.width, max(0, bounds.width - Self.margin * 2)))
        .floatingCard(cornerRadius: 12)
    }

    private func header(_ call: WorkingSetToolCall) -> some View {
        HStack(spacing: 8) {
            Image(systemName: call.state.symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(call.state.colour)
                .frame(width: 20, height: 20)
                .background(Circle().fill(call.state.colour.opacity(0.12)))
                .accessibilityHidden(true)
            Text("TOOL CALL")
                .font(.mono(9, .semibold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
            Text(call.state.label)
                .font(.mono(9))
                .foregroundStyle(call.state.colour)
            Spacer(minLength: 8)
            Button(action: { presenter.dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .appTooltip("Close tool call details")
            .accessibilityLabel("Close tool call details")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private func x(in bounds: CGSize) -> CGFloat {
        let left = presenter.anchor.minX - Self.gap - size.width
        let right = presenter.anchor.maxX + Self.gap
        let proposed = left >= Self.margin ? left : right
        return max(Self.margin, min(proposed, bounds.width - size.width - Self.margin))
    }

    private func y(in bounds: CGSize) -> CGFloat {
        let centred = presenter.anchor.midY - size.height / 2
        return max(Self.margin, min(centred, bounds.height - size.height - Self.margin))
    }
}
