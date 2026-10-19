import AppKit
import CodeStationCore
import Foundation
import SwiftUI

// The three answers a person has to a suggestion, named so that a key and a button can
// ask for the same one. The composer only offers them while a suggestion is on screen,
// so with nothing to answer each key keeps the meaning it has everywhere else.
enum SuggestionKey {
    case edit
    case send
    case cancel
}

// The prediction sits above the composer rather than inside it: the field still holds
// whatever was half-written, and the suggestion is an offer with three named answers
// rather than one unlabelled click.
struct PromptSuggestionStrip: View {
    let suggestion: String
    // With something already typed there is nothing to send. The suggestion can only join
    // the end of the draft, so the pill that would have started a turn is replaced rather
    // than left where a stray click sends over words that are not finished.
    let hasDraft: Bool
    let edit: () -> Void
    let send: () -> Void
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private let pillHeight: CGFloat = 26

    var body: some View {
        HStack(spacing: 8) {
            // The widest target does the safest thing, so a mis-click reaches the composer
            // rather than starting a turn. Everything left of the pills is one target,
            // label and gap included, since a reader aiming at the row means the offer.
            Button(action: edit) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("SUGGESTED")
                            .font(.system(size: 11, weight: .semibold))
                            .kerning(1.2)
                    }
                    .foregroundStyle(Theme.accent)

                    Text(suggestion)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)
                }
                // A minimum matching the pills beside it, so the target covers the row
                // without the card growing to whatever height the composer offers.
                .frame(maxWidth: .infinity, minHeight: pillHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverFill(cornerRadius: 8)
            .appTooltip("Put this in the composer to change before sending")
            .accessibilityHidden(true)

            ActionButton(title: "Edit", tone: .outlined, height: pillHeight, size: 11.5,
                         shortcut: "⇥", action: edit)
                .appTooltip("Put this in the composer to change before sending")
                .accessibilityLabel("Edit the suggested prompt: \(suggestion)")

            if hasDraft {
                ActionButton(title: "Append", tone: .outlined, height: pillHeight, size: 11.5,
                             action: edit)
                    .appTooltip("Add this to the end of what you have typed")
                    .accessibilityLabel("Append the suggested prompt to the draft: \(suggestion)")
            } else {
                ActionButton(title: "Send", tone: .green, height: pillHeight, size: 11.5,
                             shortcut: "⌘⏎", action: send)
                    .appTooltip("Send this as the next turn")
                    .accessibilityLabel("Send the suggested prompt: \(suggestion)")
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverLift(amount: Motion.smallLift)
            .appTooltip("Cancel this suggestion")
            .accessibilityLabel("Cancel the suggested prompt")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A card rather than a field, so the row reads as an offer sitting on the pane
        // instead of as a second place to type.
        .surface(Theme.card, cornerRadius: 9, border: Theme.border)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 5)
        .onAppear {
            announce()
            guard !reduceMotion else {
                shown = true
                return
            }
            withAnimation(.easeOut(duration: 0.18)) { shown = true }
        }
    }

    // Read out once as the row arrives. Saying it again on every hover would make an
    // offer noisier than the turn it is offering.
    private func announce() {
        guard let window = NSApp?.keyWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: "Suggested next prompt: \(suggestion)",
                                        .priority: NSAccessibilityPriorityLevel.low.rawValue])
    }
}
