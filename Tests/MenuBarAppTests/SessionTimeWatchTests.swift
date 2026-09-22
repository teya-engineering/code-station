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
    private func settled(_ reads: Counter, at expected: Int) async {
        for _ in 0..<400 where reads.count < expected {
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
                                               isRunning: false)

        watch.refresh([request])
        await settled(reads, at: 1)
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
                             isRunning: true)])
        await settled(reads, at: 1)
        watch.refresh([.init(id: id, mark: mark("Bash · swift test", at: stamp),
                             isRunning: true)])
        await settled(reads, at: 2)

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

        watch.refresh([.init(id: id, mark: summary, isRunning: true)])
        await settled(reads, at: 1)
        watch.refresh([.init(id: id, mark: summary, isRunning: false)])
        await settled(reads, at: 2)

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
