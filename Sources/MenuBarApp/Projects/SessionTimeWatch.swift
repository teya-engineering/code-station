import Foundation

// How much of each session's time landed where, so Home can say where the day went
// without opening every conversation. A transcript is a file of its own and a long one
// costs real time to read, so a session is scanned once and scanned again only when
// something new has happened in it.
//
// The scan reads the file rather than the copy in memory: a streaming reply is written
// out a second behind itself, and reaching for the messages instead would make Home
// redraw on every token of whatever session happens to be open.
@MainActor
@Observable
final class SessionTimeWatch {
    typealias Reader = @Sendable (URL) -> [TurnTimes]

    // One session to scan, and what it stood at when the scan was asked for. Neither the
    // message list nor the last activity moves while a turn runs, but the last call and
    // the change counts do, which is what keeps a running session's band growing rather
    // than frozen at the moment the turn started.
    struct Request: Equatable {
        let id: UUID
        let mark: SessionSummary
        let isRunning: Bool
    }

    private struct Reading {
        let mark: SessionSummary
        let isRunning: Bool
        let spans: [TimeSpan]
    }

    private var readings: [UUID: Reading] = [:]
    @ObservationIgnored private var scanning: Set<UUID> = []
    @ObservationIgnored private let transcripts: URL
    @ObservationIgnored private let read: Reader

    init(transcripts: URL, read: @escaping Reader = SessionTimeWatch.readTranscript) {
        self.transcripts = transcripts
        self.read = read
    }

    func spans(for sessionID: UUID) -> [TimeSpan] { readings[sessionID]?.spans ?? [] }

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
                let turns = await scan(transcript(for: request.id))
                scanning.remove(request.id)
                // Stamped with what was asked about rather than with what stands now, so
                // a turn that landed mid-scan is picked up by the next pass.
                readings[request.id] = Reading(mark: request.mark,
                                               isRunning: request.isRunning,
                                               spans: SessionTime.spans(of: turns))
            }
        }
    }

    private func scan(_ url: URL) async -> [TurnTimes] {
        let read = read
        return await Task.detached(priority: .utility) { read(url) }.value
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
