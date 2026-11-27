import Foundation
import SwiftUI

// A readable account of where a conversation stands. Claude Code can create one with its
// own recap command. Other agents produce the same shape from a focused prompt.
struct SessionRecap: Codable, Equatable, Sendable {
    enum Source: String, Codable, Equatable, Sendable {
        case claudeCode
        case prompt
    }

    let text: String
    let generatedAt: Date
    let source: Source

    static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let words = text.replacingOccurrences(of: "\u{2014}", with: "-")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = words.trimmingCharacters(in: CharacterSet(charactersIn: "#*>- "))
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 600 ? String(trimmed.prefix(600)) + "…" : trimmed
    }

    // Claude Code returns these messages when its local recap command cannot be used.
    // They are control results rather than recaps, so the ordinary prompt should take over.
    static func nativeText(from text: String?) -> String? {
        guard let cleaned = cleaned(text) else { return nil }
        let lower = cleaned.lowercased()
        let failures = [
            "couldn't generate a recap",
            "could not generate a recap",
            "failed to generate",
            "nothing to recap",
            "recap cancelled",
            "unknown command",
            "unknown skill",
            "unknown slash command",
            "not available",
            "not supported",
            "disabled",
        ]
        guard !failures.contains(where: lower.contains),
              cleaned.split(whereSeparator: \.isWhitespace).count <= 80 else { return nil }
        return cleaned
    }
}

// Where the recap card on the rail stands, with the rules that move it in one place.
struct RecapCard: Equatable {
    enum Shown: Equatable {
        case closed
        case open
        // Open with a recap nobody asked for, until the card is in place. It appears
        // where it hangs without moving, since nobody clicked anything for it.
        case arrivingUnasked
    }

    private(set) var shown = Shown.closed
    // Only ever set while the card is open: closing it is reading it.
    private(set) var needsAttention = false
    // Whether the person asked for the recap that is on its way.
    var requested = false

    var isOpen: Bool { shown != .closed }

    // A recap the person asked for lifts into place, and so does one that refreshes a
    // card already open.
    var arrivalLifts: Bool { requested || isOpen }

    // A session opened with a recap shows it, unread.
    mutating func appeared(with recap: SessionRecap?) {
        if recap == nil {
            shown = .closed
        } else if shown == .closed {
            shown = .open
        }
        needsAttention = recap != nil
    }

    mutating func recapChanged(old: SessionRecap?, new: SessionRecap?, finished: Bool) {
        guard old != new else { return }
        guard new != nil else {
            shown = .closed
            needsAttention = false
            return
        }
        if shown == .closed { shown = requested ? .open : .arrivingUnasked }
        requested = false
        needsAttention = finished
    }

    // Once it is in place, closing it fades out like any other.
    mutating func landed() {
        if shown == .arrivingUnasked { shown = .open }
    }

    mutating func toggle() {
        needsAttention = false
        shown = isOpen ? .closed : .open
    }

    mutating func close() {
        needsAttention = false
        shown = .closed
    }
}

// The trigger on the header rail. The card it opens is hung off the rail itself rather
// than off this button, so catching up never moves the transcript away from where it was
// and the card still lands under the rail when the button folds into the overflow.
struct SessionRecapControl: View {
    let recap: SessionRecap?
    let regenerating: Bool
    let canRegenerate: Bool
    let isOpen: Bool
    let needsAttention: Bool
    let toggle: () -> Void

    private var isGeneratingInitialRecap: Bool { regenerating && recap == nil }

    var body: some View {
        // Nothing to open until the first one lands, so the button says it is working
        // rather than offering a card that is not there yet.
        HeaderRailButton(
            icon: isGeneratingInitialRecap ? "hourglass" : "lightbulb",
            state: isGeneratingInitialRecap ? .working : (isOpen ? .open : .rest),
            badge: needsAttention,
            label: tooltip,
            openFill: Theme.brand,
            tool: .recap,
            action: isGeneratingInitialRecap ? nil : toggle)
            // An existing recap can still be closed while its replacement is running.
            .disabled(recap == nil && !regenerating && !canRegenerate)
            .accessibilityValue(accessibilityValue)
    }

    private var tooltip: String {
        if recap == nil {
            return regenerating ? "Generating a session recap" : "Summarise this conversation"
        }
        return isOpen ? "Close session recap" : "Open session recap"
    }

    private var accessibilityValue: String {
        if regenerating { return isOpen ? "Expanded, updating" : "Updating" }
        guard recap != nil else { return "No recap generated" }
        return isOpen ? "Expanded" : "Collapsed"
    }
}

// A recap is short enough to show whole. Keeping its plain-text shape preserves the
// generator contract while the title and actions make the card quick to scan.
struct SessionRecapView: View {
    let recap: SessionRecap
    let regenerating: Bool
    let regenerate: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.md) {
                // The recap shortcut's bulb and colour, so the card reads as the one that
                // shortcut opened.
                Image(systemName: "lightbulb")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RailTool.recap.mark)
                    .frame(width: 28, height: 28)
                    .surface(RailTool.recap.tint.wash, cornerRadius: Radius.control,
                             border: RailTool.recap.tint.edge)

                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("SESSION RECAP")
                        .font(Typography.caps)
                        .kerning(1)
                        .foregroundStyle(Theme.attentionText)
                    if regenerating {
                        Text("Updating recap")
                            .font(Font.mono(Typography.Size.micro))
                            .foregroundStyle(.tertiary)
                            .accessibilityAddTraits(.updatesFrequently)
                    } else {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(generatedLabel(at: context.date))
                                .font(Font.mono(Typography.Size.micro))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer(minLength: 12)

                GlyphButton(icon: regenerating ? "hourglass" : "arrow.clockwise",
                            side: ControlHeight.md, action: regenerate)
                    .disabled(regenerating)
                    .appTooltip("Generate a fresh recap")
                    .accessibilityLabel(regenerating
                        ? "Generating a fresh recap"
                        : "Generate a fresh recap")

                GlyphButton(icon: "xmark", side: ControlHeight.md, action: close)
                    .appTooltip("Close recap")
                    .accessibilityLabel("Close recap")
            }

            Text(recap.text)
                .font(Typography.body)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.lg)
        .frame(width: 430, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.floating).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.floating)
            .stroke(Theme.attention.opacity(0.38)))
        .elevation(.floating)
    }

    private func generatedLabel(at now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(recap.generatedAt))
        if seconds < 60 { return "Generated just now" }
        if seconds < 3_600 { return "Generated \(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "Generated \(Int(seconds / 3_600)) hr ago" }
        return "Generated \(recap.generatedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}
