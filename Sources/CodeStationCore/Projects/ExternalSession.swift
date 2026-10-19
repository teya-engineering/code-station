import Foundation

public struct ImportedSessionOrigin: Codable, Equatable, Sendable {
    public let sessionID: String
    public let agent: AgentKind
    public let configDirectory: String

    public static func key(agent: AgentKind, sessionID: String) -> String {
        "\(agent.rawValue):\(sessionID)"
    }
}

public struct ExternalSessionCandidate: Identifiable, Hashable, Sendable {
    public let sessionID: String
    public var agent: AgentKind = .claudeCode
    public let file: URL
    public let cwd: String
    public let title: String?
    public let firstPrompt: String?
    public let startedAt: Date?
    public let lastActivity: Date
    public let gitBranch: String?
    public let bytes: Int
    public var configDirectory: URL? = nil

    public var id: String { ImportedSessionOrigin.key(agent: agent, sessionID: sessionID) }

    public var origin: ImportedSessionOrigin {
        ImportedSessionOrigin(sessionID: sessionID, agent: agent,
                              configDirectory: (configDirectory ?? file.deletingLastPathComponent()
                                .deletingLastPathComponent().deletingLastPathComponent()).path)
    }

    public var displayTitle: String {
        if let title, !title.isBlank { return title }
        let words = (firstPrompt ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return "Untitled session" }
        return words.count > 48 ? String(words.prefix(48)) + "…" : words
    }
}

extension AgentKind {
    public var historyEnvironmentVariable: String {
        switch self {
        case .claudeCode: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        case .copilot: "COPILOT_HOME"
        }
    }
}
