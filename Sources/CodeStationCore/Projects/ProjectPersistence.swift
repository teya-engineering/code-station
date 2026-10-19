import Foundation

public struct ProjectPersistence: Sendable {
    let storeURL: URL
    let files: PersistentFileClient
    // A removal must run after every queued write, including writes from another store
    // that has opened the same index.
    private static let queue = DispatchQueue(label: "com.teya.code-station.project-store-writes")

    public struct Index: Codable, Sendable {
        var projects: [Project]
        var sessions: [ChatSession]
        // Optional so an index written before workspaces existed still decodes.
        var workspaces: [ProjectWorkspace]?
        // Written by an earlier version, which kept what was open in this file. It is a
        // preference now, so these are only read, to carry that choice over once.
        var selectedSessionID: UUID?
        var selectedProjectID: UUID?
    }

    public struct PendingTranscript: Sendable {
        let sessionID: UUID
        let revision: Int
        let messages: [ChatMessage]
        let projectPath: String
        let url: URL
    }

    public struct PendingIndex: Sendable {
        let revision: Int
        let value: Index
    }

    public struct WriteCompletion: Sendable {
        public struct Summary: Sendable {
            let revision: Int
            let value: SessionSummary
        }

        let generation: Int
        var transcriptSuccesses: [UUID: Int] = [:]
        var summaries: [UUID: Summary] = [:]
        var transcriptFailures: [String] = []
        var indexRevision: Int?
        var indexSucceeded = false
        var indexFailure: String?
        var blockedFailures: [String] = []

        var failures: [String] {
            blockedFailures + transcriptFailures + [indexFailure].compactMap { $0 }
        }
    }

    public struct Batch: Sendable {
        let generation: Int
        let transcripts: [PendingTranscript]
        let index: PendingIndex?
        let blockedFailures: [String]
    }

    func writeAndWait(_ batch: Batch) -> WriteCompletion {
        Self.queue.sync { writeContents(batch) }
    }

    func write(_ batch: Batch, completion: @escaping @Sendable (WriteCompletion) -> Void) {
        Self.queue.async { completion(writeContents(batch)) }
    }

    private func writeContents(_ batch: Batch) -> WriteCompletion {
        var completion = WriteCompletion(generation: batch.generation,
                                         blockedFailures: batch.blockedFailures)
        // Only this app reads the transcripts back, so they skip the pretty
        // formatting; the index stays readable for a human poking at it.
        let transcriptEncoder = JSONEncoder()
        transcriptEncoder.outputFormatting = .withoutEscapingSlashes
        transcriptEncoder.dateEncodingStrategy = .iso8601
        for transcript in batch.transcripts {
            let summary = SessionSummary.of(transcript.messages,
                                            projectPath: transcript.projectPath)
            do {
                let data = try transcriptEncoder.encode(transcript.messages)
                try files.write(data, transcript.url)
                completion.transcriptSuccesses[transcript.sessionID] = transcript.revision
                completion.summaries[transcript.sessionID] = WriteCompletion.Summary(
                    revision: transcript.revision, value: summary)
            } catch {
                completion.transcriptFailures.append(
                    PersistentFile.saveMessage(for: transcript.url, error: error))
            }
        }
        guard let pendingIndex = batch.index else { return completion }
        completion.indexRevision = pendingIndex.revision
        guard completion.transcriptFailures.isEmpty else {
            completion.indexFailure = "The project index was not saved because a transcript could not be saved."
            return completion
        }
        do {
            var value = pendingIndex.value
            for (sessionID, summary) in completion.summaries {
                guard let i = value.sessions.firstIndex(where: { $0.id == sessionID }) else {
                    continue
                }
                value.sessions[i].summary = summary.value
            }
            let data = try PersistentFile.makeEncoder().encode(value)
            try files.write(data, storeURL)
            completion.indexSucceeded = true
        } catch {
            completion.indexFailure = PersistentFile.saveMessage(for: storeURL, error: error)
        }
        return completion
    }

    func readTranscript(at url: URL) async -> TranscriptRead {
        await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume(returning: readTranscriptContents(at: url)) }
        }
    }

    func importTranscript(_ transcript: PendingTranscript) async -> Result<SessionSummary, PersistenceFailure> {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                let result = writeContents(Batch(generation: 0, transcripts: [transcript],
                                                 index: nil, blockedFailures: []))
                if let summary = result.summaries[transcript.sessionID]?.value {
                    continuation.resume(returning: .success(summary))
                } else {
                    continuation.resume(returning: .failure(PersistenceFailure(
                        message: result.failures.joined(separator: "\n"))))
                }
            }
        }
    }

    func conversationIDs(at url: URL) async -> Set<String>? {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                let read = readTranscriptContents(at: url)
                guard read.error == nil else { continuation.resume(returning: nil); return }
                let ids = read.messages.compactMap(\.checkpoint).flatMap { checkpoint in
                    [(AgentKind.claudeCode, checkpoint.claudeSessionID), (.codex, checkpoint.codexSessionID), (.copilot, checkpoint.copilotSessionID)]
                        .compactMap { agent, id in id.map { ImportedSessionOrigin.key(agent: agent, sessionID: $0) } }
                }
                continuation.resume(returning: Set(ids))
            }
        }
    }

    func readTranscriptAndWait(at url: URL) -> TranscriptRead {
        Self.queue.sync { readTranscriptContents(at: url) }
    }

    func removeTranscript(at url: URL) -> Result<Void, PersistenceFailure> {
        Self.queue.sync {
            do {
                try files.removeIfPresent(url)
                return .success(())
            } catch {
                return .failure(PersistenceFailure(
                    message: "The transcript at \(url.path) could not be deleted: \(error.localizedDescription)"))
            }
        }
    }

    func removeTranscriptInBackground(at url: URL) async -> Result<Void, PersistenceFailure> {
        await Task.detached { removeTranscript(at: url) }.value
    }

    func writeRemovalJournal(_ data: Data, to url: URL) throws {
        try Self.queue.sync { try files.write(data, url) }
    }

    public struct TranscriptRead: Sendable {
        var messages: [ChatMessage] = []
        var error: String?
    }

    private func readTranscriptContents(at url: URL) -> TranscriptRead {
        do {
            guard let data = try files.readIfPresent(url) else { return TranscriptRead() }
            let messages = try PersistentFile.makeDecoder().decode([ChatMessage].self, from: data)
            return TranscriptRead(messages: messages)
        } catch let error as DecodingError {
            return TranscriptRead(error: PersistentFile.decodeMessage(for: url, error: error))
        } catch {
            return TranscriptRead(error: PersistentFile.loadMessage(for: url, error: error))
        }
    }
}
