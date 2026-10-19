import Foundation

// A readable account of where a conversation stands. Claude Code can create one with its
// own recap command. Other agents produce the same shape from a focused prompt.
public struct SessionRecap: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Equatable, Sendable {
        case claudeCode
        case prompt
    }

    public let text: String
    public let generatedAt: Date
    let source: Source

    public static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let words = text.replacingOccurrences(of: "\u{2014}", with: "-")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = words.trimmingCharacters(in: CharacterSet(charactersIn: "#*>- "))
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 600 ? String(trimmed.prefix(600)) + "…" : trimmed
    }

    // Claude Code returns these messages when its local recap command cannot be used.
    // They are control results rather than recaps, so the ordinary prompt should take over.
    public static func nativeText(from text: String?) -> String? {
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

    public init(text: String, generatedAt: Date, source: Source) {
        self.text = text
        self.generatedAt = generatedAt
        self.source = source
    }
}
