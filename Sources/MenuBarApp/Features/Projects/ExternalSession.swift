import Foundation

struct ImportedSessionOrigin: Codable, Equatable, Sendable {
    let sessionID: String
    let agent: AgentKind
    let configDirectory: String

    static func key(agent: AgentKind, sessionID: String) -> String {
        "\(agent.rawValue):\(sessionID)"
    }

    // The folder the agent must be pointed at to resume this session, or nil when it
    // already looks there. Claude Code ties its Keychain sign-in to CLAUDE_CONFIG_DIR
    // whenever the variable is set, even to the default folder, so setting it without
    // need signs the user out.
    func historyOverride(environment: [String: String] = ProcessInfo.processInfo.environment,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let inherited = agent.configDirectory(environment: environment, home: home).path
        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return resolved(inherited) == resolved(configDirectory) ? nil : configDirectory
    }
}

struct ExternalSessionCandidate: Identifiable, Hashable, Sendable {
    let sessionID: String
    var agent: AgentKind = .claudeCode
    let file: URL
    let cwd: String
    let title: String?
    let firstPrompt: String?
    let startedAt: Date?
    let lastActivity: Date
    let gitBranch: String?
    let bytes: Int
    var configDirectory: URL? = nil

    var id: String { ImportedSessionOrigin.key(agent: agent, sessionID: sessionID) }

    var origin: ImportedSessionOrigin {
        ImportedSessionOrigin(sessionID: sessionID, agent: agent,
                              configDirectory: (configDirectory ?? file.deletingLastPathComponent()
                                .deletingLastPathComponent().deletingLastPathComponent()).path)
    }

    var displayTitle: String {
        if let title, !title.isBlank { return title }
        let words = (firstPrompt ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return "Untitled session" }
        return words.count > 48 ? String(words.prefix(48)) + "…" : words
    }
}

extension AgentKind {
    var historyEnvironmentVariable: String {
        switch self {
        case .claudeCode: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        case .copilot: "COPILOT_HOME"
        case .kiro: "KIRO_HOME"
        }
    }

    // The folder the CLI keeps its settings and history in when it inherits the app's
    // environment. An empty variable counts as unset.
    func configDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let fallback = home.appendingPathComponent(".\(rawValue)")
        guard let path = environment[historyEnvironmentVariable], !path.isEmpty else { return fallback }
        guard self == .kiro else { return URL(fileURLWithPath: path) }
        // Kiro ignores a KIRO_HOME that is relative, the root, or holds the home folder.
        let resolvedHome = home.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().path
        guard path.hasPrefix("/"), resolved != "/", resolved != resolvedHome,
              !resolvedHome.hasPrefix(resolved + "/") else { return fallback }
        return candidate
    }
}
