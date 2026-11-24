import Foundation

actor SessionHistoryCatalog {
    static let shared = SessionHistoryCatalog()

    struct Listing: Sendable {
        var candidates: [ExternalSessionCandidate] = []
        var failures: [String] = []
    }

    private struct Key: Hashable {
        let folder: String
        let root: URL
        let agent: AgentKind
    }

    private struct FileEntry {
        let size: Int
        let modified: Date?
        let candidate: ExternalSessionCandidate?
    }

    private var listings: [Key: (Date, Listing)] = [:]
    private var pending: [Key: Task<Listing, Never>] = [:]
    private var files: [URL: FileEntry] = [:]
    private(set) var fileReads = 0
    private let readAgentHistory: @Sendable (AgentKind, String, URL) async throws -> [ExternalSessionCandidate]

    init(readAgentHistory: @escaping @Sendable (AgentKind, String, URL) async throws -> [ExternalSessionCandidate] = {
        try await AgentHistoryReader.list(agent: $0, folder: $1, root: $2)
    }) {
        self.readAgentHistory = readAgentHistory
    }

    func sessions(in folder: String, roots: [AgentKind: URL], force: Bool = false) async -> Listing {
        var combined = Listing()
        let folder = ClaudeSessionCatalog.standardized(folder)
        await withTaskGroup(of: Listing.self) { group in
            for agent in AgentKind.allCases {
                guard let root = roots[agent], !Task.isCancelled else { continue }
                let key = Key(folder: folder, root: root, agent: agent)
                group.addTask { await self.listing(for: key, force: force) }
            }
            for await listing in group {
                combined.candidates += listing.candidates
                combined.failures += listing.failures
            }
        }
        combined.candidates.sort { $0.lastActivity > $1.lastActivity }
        return combined
    }

    private func listing(for key: Key, force: Bool) async -> Listing {
        if !force, let cached = listings[key], Date().timeIntervalSince(cached.0) < 30 { return cached.1 }
        if let task = pending[key] { return await task.value }
        let task = Task { await load(key) }
        pending[key] = task
        let listing = await task.value
        pending[key] = nil
        listings[key] = (Date(), listing)
        if listings.count > 64, let oldest = listings.min(by: { $0.value.0 < $1.value.0 })?.key {
            listings.removeValue(forKey: oldest)
        }
        return listing
    }

    private func load(_ key: Key) async -> Listing {
        if key.agent == .claudeCode {
            return Listing(candidates: ClaudeSessionCatalog.sessions(in: key.folder, root: key.root,
                                                                     read: claudeCandidate))
        }
        let history = key.root.appendingPathComponent(key.agent == .copilot ? "session-state" : "sessions")
        guard FileManager.default.fileExists(atPath: history.path) else { return Listing() }
        do {
            return Listing(candidates: try await readAgentHistory(key.agent, key.folder, key.root))
        } catch { return Listing(failures: ["\(key.agent.title): \(error.localizedDescription)"]) }
    }

    private func claudeCandidate(at file: URL) -> ExternalSessionCandidate? {
        guard let attributes = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = attributes.fileSize else { return nil }
        if let cached = files[file], cached.size == size, cached.modified == attributes.contentModificationDate {
            return cached.candidate
        }
        fileReads += 1
        let candidate = ClaudeSessionCatalog.candidate(at: file)
        // Opening more projects must not retain metadata for every history ever visited.
        if files.count >= 8_192, files[file] == nil { files.removeAll(keepingCapacity: true) }
        files[file] = FileEntry(size: size, modified: attributes.contentModificationDate, candidate: candidate)
        return candidate
    }

    nonisolated static func roots(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  defaults: UserDefaults = .standard) -> [AgentKind: URL] {
        var roots: [AgentKind: URL] = [.claudeCode: ClaudeSessionCatalog.defaultRoot(environment: environment,
                                                                                    defaults: defaults)]
        for agent in [AgentKind.codex, .copilot, .kiro] {
            // Kiro has no setting to move its history, so only its default folder counts.
            let path = agent == .kiro ? nil
                : defaults.string(forKey: chosenRootKey(agent)) ?? environment[agent.historyEnvironmentVariable]
            roots[agent] = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".\(agent.rawValue)")
        }
        return roots
    }

    nonisolated static func chosenRootKey(_ agent: AgentKind) -> String { "sessionHistoryFolder.\(agent.rawValue)" }
}
