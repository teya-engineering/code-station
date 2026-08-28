import SwiftUI

// The prompt box under a transcript: what has been dropped or pasted onto it, the field
// itself, and the button that sends, queues or stops. The Chat and Design panes both
// draw it, and differ only in the words in the field, what sits at its end, and what
// they put on the rows above it.
//
// The half-written prompt is the runner's, not this view's: switching sessions builds
// the pane again from nothing, and anything held here would go with it.
struct Composer<Above: View, Accessory: View>: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let sessionID: UUID
    // Whether the session can run at all: its folder is there and its CLI is installed.
    let blocked: Bool
    @Binding var isFocused: Bool
    let placeholder: String
    // The side margin, which the narrow Design pane keeps smaller.
    var inset: CGFloat = 20
    let onOversizedPaste: (String) -> Void
    var onRecallUp: (() -> Bool)? = nil
    @ViewBuilder let above: Above
    @ViewBuilder let accessory: Accessory

    @State private var dropTargeted = false

    private var attachments: [Attachment] { runner.draft(sessionID).attachments }

    private var draft: Binding<String> {
        Binding(get: { runner.draft(sessionID).text },
                set: { text in runner.editDraft(sessionID) { $0.text = text } })
    }

    var body: some View {
        let state = runner.state(sessionID)
        let busy = state.isBusy
        let canSend = !blocked && !runner.draft(sessionID).isEmpty

        VStack(alignment: .leading, spacing: 8) {
            above
            attachmentStrip

            HStack(alignment: .bottom, spacing: 10) {
                // Typing during a turn is allowed: what is written goes to the back of the
                // queue instead of waiting for the agent to be free. A turn parked on a
                // background task is the one case where it does not queue at all - the
                // pipe is open, so it goes straight to the agent.
                ComposerField(text: draft,
                              isFocused: $isFocused,
                              placeholder: placeholder,
                              isEnabled: !blocked,
                              onSubmit: send,
                              onOversizedPaste: onOversizedPaste,
                              onRecallUp: onRecallUp) {
                    accessory
                }

                if canSend {
                    Button(action: send) {
                        Image(systemName: busy ? "arrow.up.to.line" : "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(busy ? Theme.accentFill : Color.black.opacity(0.88)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .appTooltip(busy ? "Queue this for when the turn ends"
                                     : "Send (shift-return for a new line)")
                    .transition(.fadeIn)
                }

                if state == .stopping {
                    Image(systemName: "hourglass")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.field))
                        .appTooltip("Stopping this turn")
                } else if busy {
                    Button { runner.stop(sessionID) } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Theme.deletion))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .appTooltip("Stop this turn (esc)")
                } else if !canSend {
                    // The button keeps its place so the field does not change width as
                    // soon as there is something to send.
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.black.opacity(0.22)))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: canSend)
        }
        .padding(.horizontal, inset)
        .padding(.vertical, 14)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Theme.accent, lineWidth: dropTargeted ? 2 : 0)
            .padding(6))
        .pasteAttachments(enabled: isFocused && !blocked) { attach($0) }
        .dropDestination(for: URL.self) { urls, _ in
            guard !blocked else { return false }
            attach(Attachments.fromDrop(urls))
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    // What is waiting to go out with the next prompt. Long file names are common, so the
    // strip scrolls rather than squeezing the chips.
    @ViewBuilder private var attachmentStrip: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(attachments) { attachment in
                        AttachmentChip(url: attachment.url) {
                            runner.editDraft(sessionID) { $0.attachments.removeAll { $0.id == attachment.id } }
                        }
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func attach(_ found: [Attachment]) {
        runner.attach(found, to: sessionID)
        isFocused = true
    }

    private func send() {
        let draft = runner.draft(sessionID)
        guard !draft.isEmpty else { return }
        runner.send(draft.text.trimmed,
                    attachments: draft.attachments,
                    customInstructions: draft.customInstructions,
                    sessionID: sessionID,
                    store: store)
        runner.clearDraft(sessionID)
    }
}

extension SessionRunner {
    // Files joining the unsent prompt. The same file twice in one prompt says nothing
    // new, so one already waiting is skipped.
    func attach(_ found: [Attachment], to sessionID: UUID) {
        editDraft(sessionID) { draft in
            for item in found where !draft.attachments.contains(where: { $0.url == item.url }) {
                draft.attachments.append(item)
            }
        }
    }
}
