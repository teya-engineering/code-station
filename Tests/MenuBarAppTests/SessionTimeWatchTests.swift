import Foundation
import Testing
@testable import MenuBarApp

// The cache behind the time breakdown: a conversation is read off disk once, and read
// again only when something new has happened in it.
@MainActor
struct SessionTimeWatchTests {
    private let scratch = ScratchDirectory()

    private func mark(_ tool: String, at date: Date) -> SessionSummary {
        SessionSummary(lastMessageAt: date, lastTool: tool)
    }

    // The scan runs off the main actor, so a test has to let it land before it counts.
    // Waiting on the read alone is not enough: the reading is filed once the read comes
    // back, and until it is the session still counts as being scanned, which makes the
    // next request a repeat of one already in flight rather than a fresh one.
    private func settled(_ reads: Counter, at expected: Int,
                         on watch: SessionTimeWatch, session: UUID) async {
        for _ in 0..<400 where reads.count < expected || !watch.hasScanned(session) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // The scan decodes the very file the app writes, so the two shapes have to agree.
    // Nothing else notices if they drift: the band just quietly empties.
    @Test func readsTheTranscriptTheAppWrote() throws {
        let start = Date(timeIntervalSince1970: 1_758_502_800)
        var reply = ChatMessage(role: .assistant)
        reply.date = start
        reply.tools = [ToolUse(id: "1", name: "Bash", input: "{}", result: "ok",
                               startedAt: start.addingTimeInterval(60),
                               finishedAt: start.addingTimeInterval(600))]
        let messages = [ChatMessage(role: .user, text: "go", date: start), reply]

        let url = scratch.path("\(UUID().uuidString).json")
        try PersistentFile.write(PersistentFile.makeEncoder().encode(messages), to: url)

        let spans = SessionTime.spans(of: SessionTimeWatch.readTranscript(at: url))

        #expect(spans.count == 1)
        #expect(spans.first?.seconds == 600)
    }

    // The two readings have to agree, or a session would be measured one way while it is
    // open and another way once it has been put down.
    @Test func aHeldConversationReadsTheSameAsTheStoredOne() throws {
        let start = Date(timeIntervalSince1970: 1_758_502_800)
        var reply = ChatMessage(role: .assistant)
        reply.date = start
        reply.tools = [
            ToolUse(id: "1", name: "Edit",
                    input: #"{"file_path":"/repo/a.swift","old_string":"one","new_string":"one\ntwo"}"#,
                    result: "ok",
                    startedAt: start.addingTimeInterval(60),
                    finishedAt: start.addingTimeInterval(120)),
            ToolUse(id: "2", name: "Bash", input: "{}", result: "ok",
                    written: WrittenChange(files: 1, added: 4, removed: 2),
                    startedAt: start.addingTimeInterval(200),
                    finishedAt: start.addingTimeInterval(600))
        ]
        let messages = [ChatMessage(role: .user, text: "go", date: start), reply]

        let url = scratch.path("\(UUID().uuidString).json")
        try PersistentFile.write(PersistentFile.makeEncoder().encode(messages), to: url)

        let stored = SessionTimeWatch.readTranscript(at: url)
        let held = SessionTime.turns(of: messages)

        #expect(SessionTime.spans(of: held) == SessionTime.spans(of: stored))
        #expect(SessionTime.changes(of: held, projectPath: "/repo")
                    == SessionTime.changes(of: stored, projectPath: "/repo"))
        #expect(SessionTime.changes(of: held, projectPath: "/repo").count == 2)
    }

    // A conversation already in memory is the same one the file holds, so the file is
    // left alone. The held ones are the open and running sessions, whose files are the
    // ones a re-read would cost the most.
    @Test func readsAHeldConversationWithoutOpeningItsFile() async {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_758_502_800)
        var reply = ChatMessage(role: .assistant)
        reply.date = start
        reply.tools = [ToolUse(id: "1", name: "Bash", input: "{}", result: "ok",
                               startedAt: start.addingTimeInterval(60),
                               finishedAt: start.addingTimeInterval(600))]
        let held = [reply]
        let reads = Counter()
        let watch = SessionTimeWatch(transcripts: scratch.url,
                                     loaded: { _ in held },
                                     read: { _ in
                                         reads.bump()
                                         return []
                                     })

        watch.refresh([.init(id: id, mark: mark("Bash", at: start), isRunning: false,
                             projectPath: "/repo")])
        await settled(reads, at: 0, on: watch, session: id)

        #expect(reads.count == 0)
        #expect(watch.spans(for: id).first?.seconds == 600)
    }

    @Test func missingTranscriptIsASessionWithNoTimeToShow() {
        #expect(SessionTimeWatch.readTranscript(at: scratch.path("absent.json")).isEmpty)
    }

    @Test func readsASessionOnceWhileNothingMoves() async {
        let id = UUID()
        let reads = Counter()
        let watch = SessionTimeWatch(transcripts: scratch.url) { _ in
            reads.bump()
            return []
        }
        let request = SessionTimeWatch.Request(id: id, mark: mark("Bash", at: .now),
                                               isRunning: false, projectPath: "/repo")

        watch.refresh([request])
        await settled(reads, at: 1, on: watch, session: id)
        watch.refresh([request])
        watch.refresh([request])
        try? await Task.sleep(for: .milliseconds(30))

        #expect(reads.count == 1)
    }

    // Neither the message list nor the last activity moves while a turn runs, so without
    // the last call in the key a running session's band would freeze where it started.
    @Test func readsAgainWhenTheLastCallMoves() async {
        let id = UUID()
        let stamp = Date(timeIntervalSince1970: 1_758_502_800)
        let reads = Counter()
        let watch = SessionTimeWatch(transcripts: scratch.url) { _ in
            reads.bump()
            return []
        }

        watch.refresh([.init(id: id, mark: mark("Bash · swift build", at: stamp),
                             isRunning: true, projectPath: "/repo")])
        await settled(reads, at: 1, on: watch, session: id)
        watch.refresh([.init(id: id, mark: mark("Bash · swift test", at: stamp),
                             isRunning: true, projectPath: "/repo")])
        await settled(reads, at: 2, on: watch, session: id)

        #expect(reads.count == 2)
    }

    // A turn ending changes nothing else about a session that only wrote text.
    @Test func readsAgainWhenATurnEnds() async {
        let id = UUID()
        let summary = mark("Bash", at: Date(timeIntervalSince1970: 1_758_502_800))
        let reads = Counter()
        let watch = SessionTimeWatch(transcripts: scratch.url) { _ in
            reads.bump()
            return []
        }

        watch.refresh([.init(id: id, mark: summary, isRunning: true, projectPath: "/repo")])
        await settled(reads, at: 1, on: watch, session: id)
        watch.refresh([.init(id: id, mark: summary, isRunning: false, projectPath: "/repo")])
        await settled(reads, at: 2, on: watch, session: id)

        #expect(reads.count == 2)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
