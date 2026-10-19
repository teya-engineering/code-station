import Foundation

public struct SessionTitleRequest: Equatable, Sendable {
    public let sessionID: UUID
    let originalTitle: String
    let revision: UUID?

    public init(_ session: ChatSession) {
        sessionID = session.id
        originalTitle = session.title
        revision = session.titleRevision
    }
}

public enum SessionTitle {
    public static let prompt = """
    Do not use tools or change files. Summarise the main goal of this conversation as a short session title in one sentence, using at most 8 words and 60 characters. Use simple language and sentence case. Do not answer the task or mention that you are generating a title. Use no markdown, quotes, prefixes, or em dashes. Return only the title.
    """

    public static func cleaned(_ text: String?) -> String? {
        guard var title = text?.trimmed, !title.isEmpty else { return nil }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "#*`\"“”"))
            .trimmed
        if title.lowercased().hasPrefix("title:") {
            title = String(title.dropFirst("title:".count)).trimmed
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "*`\"“”"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "\u{2014}", with: "-")
        guard !title.isEmpty, title.count <= 60, title.split(separator: " ").count <= 8 else {
            return nil
        }
        return title
    }
}
