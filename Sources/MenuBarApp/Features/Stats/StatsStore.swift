import Foundation
import Observation

// Holds what Stats knows and is the only thing that writes it down. Nothing here runs,
// reads a transcript or writes a file until the person turns stats on, and turning them
// off deletes the file rather than leaving it to sit on disk.
//
// Each session is read once and read again only when something new has happened in it,
// the same way Home's day ribbon reads them, and the readings are kept in the file so
// opening the sheet does not mean reading every transcript from the top.
@MainActor
@Observable
final class StatsStore {
    typealias LoadedReader = @MainActor (UUID) -> [ChatMessage]?

    // What the file holds. Only times, counts, tool names and the session's own name.
    struct Archive: Codable, Equatable, Sendable {
        struct Cached: Codable, Equatable, Sendable {
            var mark: SessionSummary
            var digest: StatsDigest
        }

        var enabledAt: Date?
        var events: [StatsEvent] = []
        // Sessions that were removed while the person asked to keep their stats.
        var kept: [StatsDigest] = []
        var cache: [UUID: Cached] = [:]
    }

    private(set) var archive = Archive()
    private(set) var loadError: String?
    // How far the first read of a long history has got, for the line that says so.
    private(set) var pending = 0
    private(set) var total = 0
    // Moves on whenever a reading lands, so the sheet knows to work its numbers out again.
    private(set) var revision = 0

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let transcripts: URL
    @ObservationIgnored private let loaded: LoadedReader
    @ObservationIgnored private var scanning: Set<UUID> = []
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var landed = 0
    private static let revisionStep = 25
    @ObservationIgnored private lazy var saver = DebouncedSaver(delay: .seconds(1)) { [weak self] in
        self?.save()
    }

    // Read on each use rather than copied in, so the switch in the sheet takes effect at
    // once everywhere that records.
    @ObservationIgnored var isEnabled: () -> Bool = { false }
    @ObservationIgnored var keepsRemoved: () -> Bool = { false }

    init(fileURL: URL = AppPaths.supportFile("stats.json"),
         transcripts: URL,
         loaded: @escaping LoadedReader = { _ in nil }) {
        self.fileURL = fileURL
        self.transcripts = transcripts
        self.loaded = loaded
    }

    // A kept session that is somehow back in the app is counted once, from the app.
    var digests: [StatsDigest] {
        let live = archive.cache
        return live.values.map(\.digest) + archive.kept.filter { live[$0.id] == nil }
    }
    var keptCount: Int { archive.kept.count }
    var isReading: Bool { pending > 0 }

    // MARK: - Turning on and off

    func turnOn(at date: Date = Date()) {
        loadIfNeeded()
        if archive.enabledAt == nil { archive.enabledAt = date }
        saver.schedule()
    }

    // Everything Stats wrote goes with it. The sessions themselves are not touched.
    func erase() {
        saver.cancel()
        archive = Archive()
        scanning = []
        pending = 0
        total = 0
        revision += 1
        do {
            try PersistentFile.removeIfPresent(fileURL)
            loadError = nil
        } catch {
            loadError = PersistentFile.saveMessage(for: fileURL, error: error)
        }
    }

    // Drops the stats of sessions that are already gone, for when the person stops
    // wanting them kept.
    func forgetKept() {
        let ids = Set(archive.kept.map(\.id))
        archive.kept = []
        archive.events.removeAll { ids.contains($0.sessionID) }
        revision += 1
        saver.schedule()
    }

    // MARK: - Reading the sessions

    func refresh(_ store: ProjectStore) {
        guard isEnabled() else { return }
        loadIfNeeded()
        let sessions = store.sessions
        let live = Set(sessions.map(\.id))
        let before = archive.cache.count
        archive.cache = archive.cache.filter { live.contains($0.key) }
        var changed = archive.cache.count != before

        var due: [(header: StatsDigest.Header, mark: SessionSummary, path: String)] = []
        for session in sessions {
            let header = Self.header(of: session, store: store)
            if var cached = archive.cache[session.id], cached.mark == session.summary {
                // A rename or a new pull request changes the header but not what the
                // turns say, so it is put right without reading the transcript again.
                if cached.digest.header != header {
                    cached.digest.header = header
                    archive.cache[session.id] = cached
                    changed = true
                }
                continue
            }
            guard scanning.insert(session.id).inserted else { continue }
            due.append((header, session.summary, store.workingDirectory(for: session) ?? ""))
        }
        if changed {
            revision += 1
            saver.schedule()
        }
        guard !due.isEmpty else { return }
        pending += due.count
        total = max(total, pending)

        Task {
            for item in due {
                let digest: StatsDigest
                if let messages = loaded(item.header.id) {
                    let turns = StatsTurn.of(messages)
                    digest = await Self.measure(item.header, turns: turns, path: item.path)
                } else {
                    digest = await Self.measure(item.header, url: transcript(for: item.header.id),
                                                path: item.path)
                }
                scanning.remove(item.header.id)
                pending = max(0, pending - 1)
                if pending == 0 { total = 0 }
                // Turned off while the read was under way: what it found is not wanted.
                guard isEnabled() else { continue }
                archive.cache[item.header.id] = Archive.Cached(mark: item.mark, digest: digest)
                // A first read of a long history lands hundreds of sessions in a row, and
                // the numbers are worked out again on each revision, so they move on in
                // steps rather than once per session.
                landed += 1
                if pending == 0 || landed.isMultiple(of: Self.revisionStep) { revision += 1 }
                saver.schedule()
            }
        }
    }

    // Called just before a session leaves the app for good. Its stats stay only if the
    // person asked for that; otherwise the waits recorded against it go too.
    func sessionLeaving(_ session: ChatSession, store: ProjectStore) {
        guard isEnabled() else { return }
        loadIfNeeded()
        let cached = archive.cache.removeValue(forKey: session.id)
        if keepsRemoved() {
            let header = Self.header(of: session, store: store)
            var digest = cached?.digest ?? StatsDigestBuilder.digest(
                header, turns: Self.readTurns(transcript(for: session.id)),
                projectPath: store.workingDirectory(for: session) ?? "")
            digest.header = header
            archive.kept.removeAll { $0.id == session.id }
            archive.kept.append(digest)
        } else {
            archive.events.removeAll { $0.sessionID == session.id }
        }
        revision += 1
        saver.schedule()
    }

    // MARK: - Recording

    func recordAnswer(to request: PermissionRequest, allowed: Bool, sessionID: UUID,
                      subjectID: UUID?, at date: Date = Date()) {
        record(StatsEvent(kind: .answered, sessionID: sessionID, subjectID: subjectID,
                          date: request.askedAt,
                          seconds: max(0, date.timeIntervalSince(request.askedAt)),
                          tool: request.isQuestion ? nil : request.toolName,
                          isQuestion: request.isQuestion,
                          allowed: request.isQuestion ? nil : allowed))
    }

    func recordTurn(_ ending: TurnEnding, sessionID: UUID, subjectID: UUID?) {
        let outcome: StatsEvent.Outcome = switch ending.outcome {
        case .finished: .finished
        case .stopped: .stopped
        case .failed: .failed
        }
        record(StatsEvent(kind: .turnEnded, sessionID: sessionID, subjectID: subjectID,
                          date: ending.started, seconds: ending.duration, outcome: outcome))
    }

    private func record(_ event: StatsEvent) {
        guard isEnabled() else { return }
        loadIfNeeded()
        archive.events.append(event)
        revision += 1
        saver.schedule()
    }

    func flush() { saver.flush() }

    // MARK: - The file

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            archive = try PersistentFile.loadJSON(Archive.self, from: fileURL) ?? Archive()
            loadError = nil
        } catch {
            // A file that cannot be read is started over rather than left to block
            // every later save; it only ever held what can be read again.
            loadError = PersistentFile.decodeMessage(for: fileURL, error: error)
            archive = Archive()
        }
    }

    private func save() {
        guard isEnabled() else { return }
        do {
            try PersistentFile.saveJSON(archive, to: fileURL, encoder: Self.encoder)
            loadError = nil
        } catch {
            loadError = PersistentFile.saveMessage(for: fileURL, error: error)
        }
    }

    // Compact rather than pretty: the file is for the app, and a long history is mostly
    // dates that indentation would double.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private func transcript(for sessionID: UUID) -> URL {
        transcripts.appendingPathComponent("\(sessionID.uuidString).json")
    }

    // MARK: - Reading one session

    static func header(of session: ChatSession, store: ProjectStore) -> StatsDigest.Header {
        let workspace = session.workspaceID.flatMap(store.workspace)
        let project = store.project(session.projectID)
        let subject = StatsSubject(id: workspace?.id ?? session.projectID,
                                   name: workspace?.name ?? project?.name ?? "Removed project",
                                   isWorkspace: workspace != nil)
        let worktree = session.worktreePath != nil
            || session.sessionProjects?.contains { $0.worktreePath != nil } == true
        return StatsDigest.Header(id: session.id, title: session.title, subject: subject,
                                  agent: session.agent, mode: session.mode,
                                  createdAt: session.createdAt, usage: session.usage,
                                  pullRequests: session.pullRequests.count,
                                  usesWorktree: worktree)
    }

    nonisolated static func readTurns(_ url: URL) -> [StatsTurn] {
        ((try? PersistentFile.loadJSON([StatsTurn].self, from: url)) ?? nil) ?? []
    }

    // Sizing a patch is real work, so it is done away from whatever is being drawn.
    private nonisolated static func measure(_ header: StatsDigest.Header, url: URL,
                                            path: String) async -> StatsDigest {
        await Task.detached(priority: .utility) {
            StatsDigestBuilder.digest(header, turns: readTurns(url), projectPath: path)
        }.value
    }

    private nonisolated static func measure(_ header: StatsDigest.Header, turns: [StatsTurn],
                                            path: String) async -> StatsDigest {
        await Task.detached(priority: .utility) {
            StatsDigestBuilder.digest(header, turns: turns, projectPath: path)
        }.value
    }
}
