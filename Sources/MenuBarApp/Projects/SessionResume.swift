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

// A recap is already short, so it is shown whole instead of hiding its useful part behind
// an expansion control. The transcript remains the full record.
struct SessionRecapView: View {
    let recap: SessionRecap
    let regenerating: Bool
    let regenerate: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.attentionText)

                VStack(alignment: .leading, spacing: 2) {
                    Text("SESSION RECAP")
                        .font(.mono(10, .semibold))
                        .kerning(1)
                        .foregroundStyle(Theme.attentionText)
                    Text(recap.generatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.mono(9.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 12)

                GlyphButton(icon: regenerating ? "hourglass" : "arrow.clockwise",
                            side: 25, action: regenerate)
                    .disabled(regenerating)
                    .appTooltip("Generate a fresh recap")
                    .accessibilityLabel("Generate a fresh recap")

                GlyphButton(icon: "xmark", side: 25, action: dismiss)
                    .appTooltip("Dismiss recap")
                    .accessibilityLabel("Dismiss recap")
            }

            Text(recap.text)
                .font(.system(size: 13.5))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .surface(Theme.attention.opacity(0.08), cornerRadius: 11,
                 border: Theme.attention.opacity(0.38))
    }
}
