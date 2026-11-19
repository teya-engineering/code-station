import Foundation
import Observation

// Holds what Stats knows and is the only thing that writes it down. Nothing here runs,
// reads a transcript or writes a file until the person turns stats on, and turning them
// off deletes the file rather than leaving it to sit on disk.
//
// Each session is read once and read again only when something new has happened in it,
// the same way Home's day ribbon reads them, and the readings are kept in the file so
// opening Home does not mean reading every transcript from the top.
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
        // Removed sessions whose stats are still inside the days the person chose.
        var kept: [StatsDigest] = []
        var cache: [UUID: Cached] = [:]
    }

    // What a session's turns are read from. Turning messages or a file into turns is real
    // work for a long session, so it happens away from the main actor.
    enum Source: Sendable {
        case messages([ChatMessage])
        case file(URL)
        case bytes(Data)

        nonisolated var turns: [StatsTurn] {
            switch self {
            case .messages(let messages):
                StatsTurn.of(messages)
            case .file(let url):
                StatsStore.readTurns(url)
            case .bytes(let data):
                (try? PersistentFile.makeDecoder().decode([StatsTurn].self, from: data)) ?? []
            }
        }
    }

    // Not observed: Home follows `revision` instead, so a first read that lands
    // hundreds of sessions does not draw it again for each one.
    @ObservationIgnored private(set) var archive = Archive()
    private(set) var keptCount = 0
    private(set) var loadError: String?
    // How far the first read of a long history has got, for the line that says so.
    private(set) var pending = 0
    private(set) var total = 0
    // Moves on whenever a reading lands, so Home knows to work its numbers out again.
    private(set) var revision = 0

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let transcripts: URL
    @ObservationIgnored private let loaded: LoadedReader
    @ObservationIgnored private var scanning: Set<UUID> = []
    // Sessions last read while a turn was running. Its calls keep landing without the
    // summary changing, so such a session is read again once the turn has stopped.
    @ObservationIgnored private var readWhileRunning: Set<UUID> = []
    // Moves on when Stats is turned off, so a read begun before then lands on nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var landed = 0
    private static let revisionStep = 25
    @ObservationIgnored private lazy var saver = DebouncedSaver(delay: .seconds(1)) { [weak self] in
        self?.save()
    }

    // Read on each use rather than copied in, so the switch in Settings takes effect at
    // once everywhere that records.
    @ObservationIgnored var isEnabled: () -> Bool = { false }
    @ObservationIgnored var keptDays: () -> Int = { 0 }
    @ObservationIgnored var isRunning: (UUID) -> Bool = { _ in false }

    nonisolated static let keptDayRange = 0...365
    nonisolated static let defaultKeptDays = 30

    nonisolated static func resolvedKeptDays(_ days: Int) -> Int {
        min(max(days, keptDayRange.lowerBound), keptDayRange.upperBound)
    }

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
    var isReading: Bool { pending > 0 }

    // MARK: - Turning on and off

    func turnOn(at date: Date = Date()) {
        loadIfNeeded()
        if archive.enabledAt == nil { archive.enabledAt = date }
        revision += 1
        saver.schedule()
    }

    // Reads the file without touching any session, so Settings can say what is kept.
    func load() {
        guard isEnabled() else { return }
        loadIfNeeded()
    }

    // Everything Stats wrote goes with it. The sessions themselves are not touched.
    func erase() {
        saver.cancel()
        archive = Archive()
        keptCount = 0
        scanning = []
        readWhileRunning = []
        generation += 1
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

    // Drops removed sessions whose last turn is older than the days the person chose,
    // with the waits recorded against them. Done when Stats is read rather than when the
    // setting moves, so stepping the days down past a value and back loses nothing.
    @discardableResult
    func pruneKept(now: Date = Date()) -> Bool {
        let days = keptDays()
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let gone = Set(archive.kept.filter { days == 0 || $0.lastActive < cutoff }.map(\.id))
        guard !gone.isEmpty else { return false }
        archive.kept.removeAll { gone.contains($0.id) }
        keptCount = archive.kept.count
        archive.events.removeAll { gone.contains($0.sessionID) }
        return true
    }

    // A file that could not be read or written is tried once more when the person asks:
    // the next save clears the message if it works, and a read that started over finds
    // every session again.
    func readAgain(_ store: ProjectStore) {
        loadError = nil
        refresh(store)
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
        if pruneKept() { changed = true }

        var due: [(header: StatsDigest.Header, mark: SessionSummary, running: Bool,
                   path: String)] = []
        for session in sessions {
            let header = Self.header(of: session, store: store)
            let running = isRunning(session.id)
            if var cached = archive.cache[session.id], cached.mark == session.summary,
               readWhileRunning.contains(session.id) == running {
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
            due.append((header, session.summary, running,
                        store.workingDirectory(for: session) ?? ""))
        }
        if changed {
            revision += 1
            saver.schedule()
        }
        guard !due.isEmpty else { return }
        pending += due.count
        total = max(total, pending)

        let started = generation
        Task {
            for item in due {
                let id = item.header.id
                let source = loaded(id).map(Source.messages) ?? .file(transcript(for: id))
                let digest = await Self.measure(item.header, source: source, path: item.path)
                guard generation == started else { return }
                pending = max(0, pending - 1)
                if pending == 0 { total = 0 }
                // The session was removed, or Stats turned off, while the read was under
                // way: what it found is not wanted.
                guard scanning.remove(id) != nil, isEnabled() else { continue }
                // Stamped with what was asked about rather than with what stands now, so
                // a turn that landed mid-read is picked up by the next pass.
                archive.cache[id] = Archive.Cached(mark: item.mark, digest: digest)
                if item.running {
                    readWhileRunning.insert(id)
                } else {
                    readWhileRunning.remove(id)
                }
                // A first read of a long history lands hundreds of sessions in a row, and
                // the numbers are worked out again on each revision, so they move on in
                // steps rather than once per session.
                landed += 1
                if pending == 0 || landed.isMultiple(of: Self.revisionStep) { revision += 1 }
                saver.schedule()
            }
        }
    }

    // Called once a session's removal is certain, while its transcript is still on disk.
    // Its stats stay only while the person keeps removed sessions for some days; otherwise
    // the waits recorded against it go too.
    func sessionLeaving(_ session: ChatSession, store: ProjectStore) {
        guard isEnabled() else { return }
        loadIfNeeded()
        let cached = archive.cache.removeValue(forKey: session.id)
        let isCurrent = cached?.mark == session.summary
            && !readWhileRunning.contains(session.id)
        scanning.remove(session.id)
        readWhileRunning.remove(session.id)
        defer {
            revision += 1
            saver.schedule()
        }
        guard keptDays() > 0 else {
            archive.events.removeAll { $0.sessionID == session.id }
            return
        }

        let header = Self.header(of: session, store: store)
        // What was read before stands in at once, so a quit before the new read lands
        // still keeps something.
        if var digest = cached?.digest {
            digest.header = header
            keep(digest)
        }
        guard !isCurrent else { return }

        // The transcript is deleted as soon as this returns, so its bytes are taken now
        // and turned into turns away from the main actor.
        let source = loaded(session.id).map(Source.messages)
            ?? .bytes(((try? PersistentFile.readIfPresent(transcript(for: session.id))) ?? nil) ?? Data())
        let path = store.workingDirectory(for: session) ?? ""
        let started = generation
        Task {
            let digest = await Self.measure(header, source: source, path: path)
            guard generation == started, isEnabled() else { return }
            if keptDays() > 0 {
                keep(digest)
            } else {
                archive.events.removeAll { $0.sessionID == header.id }
            }
            revision += 1
            saver.schedule()
        }
    }

    private func keep(_ digest: StatsDigest) {
        archive.kept.removeAll { $0.id == digest.id }
        archive.kept.append(digest)
        keptCount = archive.kept.count
        pruneKept()
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
        keptCount = archive.kept.count
        revision += 1
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
        let workspace = session.workspaceID.flatMap(store.owningWorkspace)
        let project = store.owningProject(session.projectID)
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
    private nonisolated static func measure(_ header: StatsDigest.Header, source: Source,
                                            path: String) async -> StatsDigest {
        await Task.detached(priority: .utility) {
            StatsDigestBuilder.digest(header, turns: source.turns, projectPath: path)
        }.value
    }
}
