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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var measurement = OverlayMeasurement()

    private var size: CGSize { measurement.size }

    var body: some View {
        ZStack {
            if let presented = presenter.current {
                content(presented)
            }
        }
        .motion(presenter.current == nil ? Motion.leave : Motion.reveal,
                value: presenter.current == nil)
        // A card on its way out stays in the tree until it has shrunk away, and must not
        // take the click meant for the row it came from.
        .allowsHitTesting(presenter.current != nil)
    }

    private func content(_ presented: PresentedToolCall) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { presenter.dismiss() }

                // Picking another row swaps only what is inside: the old call goes at
                // once and the new one fades in, and an update from the agent to the
                // call already open does not move at all.
                ZStack {
                    ZStack {
                        card(presented, bounds: geometry.size)
                            .id(presented.call.id)
                            .transition(.asymmetric(insertion: AnyTransition.opacity.animation(Motion.reveal),
                                                    removal: .identity))
                    }
                    .measuredOverlay(generation: presenter.generation, into: $measurement)
                    .transition(.popover(reduceMotion: reduceMotion))
                }
                .offset(x: x(in: geometry.size), y: y(in: geometry.size))

                Button("") { presenter.dismiss() }
                    .buttonStyle(.plain)
                    .opacity(0)
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .ignoresSafeArea()
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
                    .padding(Space.lg)
            }
        }
        .frame(width: min(Self.width, max(0, bounds.width - Self.margin * 2)))
        .floatingCard(cornerRadius: Radius.floating)
    }

    private func header(_ call: WorkingSetToolCall) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: call.state.symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(call.state.colour)
                .frame(width: 20, height: 20)
                .background(Circle().fill(call.state.colour.opacity(0.12)))
                .accessibilityHidden(true)
            Text("TOOL CALL")
                .font(Typography.caps)
                .kerning(0.8)
                .foregroundStyle(.secondary)
            Text(call.state.label)
                .font(Font.mono(Typography.Size.micro))
                .foregroundStyle(call.state.colour)
            Spacer(minLength: 8)
            Button(action: { presenter.dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: Radius.inset).fill(Theme.field))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.inset))
            }
            .buttonStyle(.plain)
            .hoverLift(amount: Motion.smallLift)
            .appTooltip("Close tool call details")
            .accessibilityLabel("Close tool call details")
        }
        .padding(.horizontal, Space.lg)
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
