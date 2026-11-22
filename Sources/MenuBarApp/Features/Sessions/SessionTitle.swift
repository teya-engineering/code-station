import Foundation

struct SessionTitleRequest: Equatable, Sendable {
    let sessionID: UUID
    let originalTitle: String
    let revision: UUID?

    init(_ session: ChatSession) {
        sessionID = session.id
        originalTitle = session.title
        revision = session.titleRevision
    }
}

enum SessionTitle {
    static let prompt = """
    Do not use tools or change files. Summarise the main goal of this conversation as a short session title in one sentence, using at most 8 words and 60 characters. Use simple language and sentence case. Do not answer the task or mention that you are generating a title. Use no markdown, quotes, prefixes, or em dashes. Return only the title.
    """

    static let maximumLength = 60

    static func cleaned(_ text: String?) -> String? {
        guard var title = text?.trimmed, !title.isEmpty else { return nil }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "#*`\"“”"))
            .trimmed
        if title.lowercased().hasPrefix("title:") {
            title = String(title.dropFirst("title:".count)).trimmed
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "*`\"“”"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "\u{2014}", with: "-")
        // The prompt asks for 8 words, but models often go one over. Only the length is
        // enforced, since that is what the sidebar and header have room for.
        guard !title.isEmpty, title.count <= maximumLength else { return nil }
        return title
    }

    @MainActor
    static func menuEntry(for sessionID: UUID, runner: SessionRunner,
                          store: ProjectStore) -> MenuEntry {
        let generating = runner.isGeneratingTitle(sessionID)
        let canGenerate = runner.canRegenerateTitle(sessionID)
        return .item(MenuItem(
            label: generating ? "Generating session title…" : "Regenerate session title",
            icon: "sparkles",
            handler: canGenerate ? { _ = runner.regenerateTitle(sessionID) } : nil))
    }
}
