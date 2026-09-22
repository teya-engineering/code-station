import Foundation

// How much of each session's time landed where, so Home can say where the day went
// without opening every conversation. A transcript is a file of its own and a long one
// costs real time to read, so a session is scanned once and scanned again only when
// something new has happened in it.
//
// A conversation already in memory is read from there instead. It is the same
// conversation the file holds, and it is the open and running ones that are held, which
// are exactly the ones whose file would otherwise be read from the top every time a call
// lands. Nothing here observes those messages, so a reply still streaming does not drag
// Home into a redraw on every token: they are sampled only when a scan is due anyway.
@MainActor
@Observable
final class SessionTimeWatch {
    typealias Reader = @Sendable (URL) -> [TurnTimes]
    // The conversation as it already stands in memory, or nil when it is not held there.
    typealias LoadedReader = @MainActor (UUID) -> [ChatMessage]?

    // One session to scan, and what it stood at when the scan was asked for. Neither the
    // message list nor the last activity moves while a turn runs, but the last call and
    // the change counts do, which is what keeps a running session's band growing rather
    // than frozen at the moment the turn started.
    struct Request: Equatable {
        let id: UUID
        let mark: SessionSummary
        let isRunning: Bool
        // Where the session works. A change measured off the working tree names its
        // files by their path inside the repository, and only the project path lines
        // that up with the file the call itself named.
        let projectPath: String
    }

    private struct Reading {
        let mark: SessionSummary
        let isRunning: Bool
        let spans: [TimeSpan]
        let changes: [DatedChange]
    }

    // What one pass over a transcript came back with.
    private struct Scan: Sendable {
        var spans: [TimeSpan] = []
        var changes: [DatedChange] = []
    }

    private var readings: [UUID: Reading] = [:]
    @ObservationIgnored private var scanning: Set<UUID> = []
    @ObservationIgnored private let transcripts: URL
    @ObservationIgnored private let read: Reader
    @ObservationIgnored private let loaded: LoadedReader

    // Without a store to ask, nothing counts as held and every session is read off disk,
    // which is the reading the file was always going to give.
    init(transcripts: URL,
         loaded: @escaping LoadedReader = { _ in nil },
         read: @escaping Reader = SessionTimeWatch.readTranscript) {
        self.transcripts = transcripts
        self.loaded = loaded
        self.read = read
    }

    func spans(for sessionID: UUID) -> [TimeSpan] { readings[sessionID]?.spans ?? [] }

    func changes(for sessionID: UUID) -> [DatedChange] { readings[sessionID]?.changes ?? [] }

    // Whether this session has been looked at yet, which is what tells a day with
    // nothing in it apart from a scan that has not landed.
    func hasScanned(_ sessionID: UUID) -> Bool { readings[sessionID] != nil }

    func refresh(_ requests: some Collection<Request>) {
        let pending = requests.filter { request in
            guard readings[request.id]?.mark != request.mark
                    || readings[request.id]?.isRunning != request.isRunning else { return false }
            return scanning.insert(request.id).inserted
        }
        guard !pending.isEmpty else { return }

        Task {
            for request in pending {
                let scan: Scan
                if let messages = loaded(request.id) {
                    scan = await measure(messages, projectPath: request.projectPath)
                } else {
                    scan = await measure(transcript(for: request.id),
                                         projectPath: request.projectPath)
                }
                scanning.remove(request.id)
                // Stamped with what was asked about rather than with what stands now, so
                // a turn that landed mid-scan is picked up by the next pass.
                readings[request.id] = Reading(mark: request.mark,
                                               isRunning: request.isRunning,
                                               spans: scan.spans,
                                               changes: scan.changes)
            }
        }
    }

    // The turns are read and measured in the same detached pass. Sizing a patch is real
    // work, and doing it back on the main actor would stall whatever Home is drawing.
    private func measure(_ url: URL, projectPath: String) async -> Scan {
        let read = read
        return await Task.detached(priority: .utility) {
            Self.measure(read(url), projectPath: projectPath)
        }.value
    }

    private func measure(_ messages: [ChatMessage], projectPath: String) async -> Scan {
        await Task.detached(priority: .utility) {
            Self.measure(SessionTime.turns(of: messages), projectPath: projectPath)
        }.value
    }

    private nonisolated static func measure(_ turns: [TurnTimes],
                                            projectPath: String) -> Scan {
        Scan(spans: SessionTime.spans(of: turns),
             changes: SessionTime.changes(of: turns, projectPath: projectPath))
    }

    private func transcript(for sessionID: UUID) -> URL {
        transcripts.appendingPathComponent("\(sessionID.uuidString).json")
    }

    // A transcript that is missing or cannot be read is a session with no time to show,
    // which is what a session that never started looks like anyway.
    nonisolated static func readTranscript(at url: URL) -> [TurnTimes] {
        ((try? PersistentFile.loadJSON([TurnTimes].self, from: url)) ?? nil) ?? []
    }
}
