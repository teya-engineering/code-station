import SwiftUI

// Prompts typed ahead, above the composer where what happens next belongs. A queue that
// is not moving on its own - the last turn failed, or was stopped - gets a button,
// since nothing else would ever start it. Chat and Design draw the same strip, so the
// two screens cannot drift apart.
struct SessionQueueStrip: View {
    let sessionID: UUID
    let busy: Bool
    let blocked: Bool
    // A short panel caps the list and scrolls inside it, so the queue cannot push the
    // composer off the bottom.
    var maxListHeight: CGFloat?
    let onRecall: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownCount = 0
    // The row being steered, so it leaves the queue upwards rather than folding.
    @State private var steering: UUID?
    @State private var listHeight: CGFloat = 0

    var body: some View {
        let waiting = runner.queued(sessionID)
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                heading(count: waiting.count)
                if let maxListHeight {
                    ScrollView {
                        rows(waiting)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(listHeight, maxListHeight))
                } else {
                    rows(waiting)
                }
            }
            // Leaving is faster than arriving, so the curve follows which way the count went.
            .motion(waiting.count < shownCount ? Motion.leave : Motion.reveal,
                    value: waiting.map(\.id))
            .onChange(of: waiting.count, initial: true) { shownCount = $1 }
            .transition(.fold)
        }
    }

    private func heading(count: Int) -> some View {
        HStack(spacing: 6) {
            // The count sits in the heading because the list can be scrolled past or
            // capped, and how much is waiting is the part worth knowing.
            HStack(spacing: 0) {
                Text("QUEUED · ")
                Text("\(count)")
                    .contentTransition(.numericText(value: Double(count)))
                if busy {
                    Text(" · RUNS WHEN THIS TURN ENDS")
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .kerning(1.2)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if !busy && !blocked {
                InlineLink(title: "Send now", size: 12) {
                    runner.runQueue(sessionID, store: store)
                }
                .transition(.fadeIn)
            }
        }
        .foregroundStyle(Theme.accent)
        .motion(Motion.control, value: busy)
    }

    private func rows(_ waiting: [SessionRunner.QueuedPrompt]) -> some View {
        let canSteer = runner.canSteer(sessionID)
        // An agent that can never take a prompt mid-turn has no use for the button at all.
        let steerable = store.session(sessionID)?.agent.canSteer ?? false
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(waiting) { item in
                HStack(alignment: .center, spacing: 12) {
                    Text(item.text)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        // Only a running turn can be steered into. Once it ends the
                        // heading's Send now is the way to start the queue instead.
                        if busy && steerable {
                            QueueRowAction(title: "Steer now", icon: "arrow.up", tone: .steer,
                                           tooltip: canSteer ? "Send into the running turn - the agent reads it at its next step"
                                               : "This turn cannot take a prompt right now",
                                           value: item.text) {
                                steer(item.id)
                            }
                            .disabled(!canSteer)
                            .padding(.trailing, 4)
                            .transition(.fadeIn)
                        }
                        QueueRowAction(title: "Edit", icon: "pencil", tone: .plain,
                                       tooltip: "Take it back into the composer to rework",
                                       value: item.text) {
                            runner.recall(item.id, sessionID: sessionID)
                            onRecall()
                        }
                        QueueRowAction(title: "Remove", icon: "xmark", tone: .remove,
                                       tooltip: "Remove from the queue",
                                       value: item.text) {
                            runner.unqueue(item.id, sessionID: sessionID)
                        }
                    }
                    .fixedSize()
                    .motion(Motion.control, value: busy)
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .fieldSurface(cornerRadius: 8)
                .transition(.asymmetric(insertion: .fadeIn, removal: removal(for: item.id)))
            }
        }
    }

    // A steered prompt rises out of the queue towards the transcript it is going into.
    // Anything else just folds away.
    private func removal(for id: UUID) -> AnyTransition {
        guard id == steering, !reduceMotion else { return .fold }
        return .opacity.combined(with: .offset(y: -14))
    }

    // The row is marked first, so it already carries the rising transition by the time
    // it leaves. A turn that can no longer take the prompt leaves it where it was.
    private func steer(_ id: UUID) {
        steering = id
        Task { @MainActor in
            if !runner.steer(id, sessionID: sessionID, store: store) { steering = nil }
        }
    }
}

// A labelled action on a queued row: quiet until pointed at, then filled. Steer now is
// drawn as a card pill so the one that acts on the running turn stands out.
private struct QueueRowAction: View {
    enum Tone { case plain, steer, remove }

    let title: String
    let icon: String
    let tone: Tone
    let tooltip: String
    // The prompt the row holds, so a screen reader hears which one the button acts on.
    let value: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .buttonStyle(QueueRowActionStyle(tone: tone, hovering: hovering))
        .hoverLift(hovering, amount: Motion.smallLift)
        .onPointerHover { hovering = $0 }
        .appTooltip(tooltip)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

private struct QueueRowActionStyle: ButtonStyle {
    let tone: QueueRowAction.Tone
    let hovering: Bool

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let lit = hovering && isEnabled
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .foregroundStyle(foreground(lit: lit))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(fill(lit: lit, pressed: pressed)))
            .overlay {
                if tone == .steer {
                    Capsule().stroke(lit ? Theme.accent.opacity(0.35) : Theme.border)
                }
            }
            .contentShape(Capsule())
            .motion(Motion.hover, value: lit)
            .motion(Motion.hover, value: pressed)
    }

    private func foreground(lit: Bool) -> Color {
        guard isEnabled else { return Theme.secondaryText.opacity(0.55) }
        switch tone {
        case .steer: return Theme.accent
        case .remove: return lit ? Theme.deletion : Theme.secondaryText
        case .plain: return lit ? Color.primary : Theme.secondaryText
        }
    }

    private func fill(lit: Bool, pressed: Bool) -> Color {
        switch tone {
        case .steer:
            guard isEnabled else { return .clear }
            return pressed ? Theme.accent.opacity(0.12) : Theme.card
        case .remove:
            return pressed ? Theme.deletion.opacity(0.14) : lit ? Theme.deletion.opacity(0.08) : .clear
        case .plain:
            return pressed ? Color.primary.opacity(0.1) : lit ? Theme.field : .clear
        }
    }
}
