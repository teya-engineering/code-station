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
            icon: isGeneratingInitialRecap ? "hourglass" : "doc.text",
            active: isOpen,
            tint: isGeneratingInitialRecap ? Theme.accent : nil,
            badge: needsAttention,
            label: tooltip,
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.attentionText)
                    .frame(width: 28, height: 28)
                    .surface(Theme.attention.opacity(0.08), cornerRadius: 8,
                             border: Theme.attention.opacity(0.38))

                VStack(alignment: .leading, spacing: 2) {
                    Text("SESSION RECAP")
                        .font(.mono(10, .semibold))
                        .kerning(1)
                        .foregroundStyle(Theme.attentionText)
                    if regenerating {
                        Text("Updating recap")
                            .font(.mono(9.5))
                            .foregroundStyle(.tertiary)
                            .accessibilityAddTraits(.updatesFrequently)
                    } else {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(generatedLabel(at: context.date))
                                .font(.mono(9.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer(minLength: 12)

                GlyphButton(icon: regenerating ? "hourglass" : "arrow.clockwise",
                            side: 28, action: regenerate)
                    .disabled(regenerating)
                    .appTooltip("Generate a fresh recap")
                    .accessibilityLabel(regenerating
                        ? "Generating a fresh recap"
                        : "Generate a fresh recap")

                GlyphButton(icon: "xmark", side: 28, action: close)
                    .appTooltip("Close recap")
                    .accessibilityLabel("Close recap")
            }

            Text(recap.text)
                .font(.system(size: 13.5))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(width: 430, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke(Theme.attention.opacity(0.38)))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
    }

    private func generatedLabel(at now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(recap.generatedAt))
        if seconds < 60 { return "Generated just now" }
        if seconds < 3_600 { return "Generated \(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "Generated \(Int(seconds / 3_600)) hr ago" }
        return "Generated \(recap.generatedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}
