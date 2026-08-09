import Foundation
import Testing
@testable import MenuBarApp

// The log only earns its keep if it is on disk by the time someone goes looking, so what
// is pinned here is that a note actually lands in the file the Settings sheet reveals.
struct SessionLogTests {

    @Test func writesWhatItIsToldToTheFileSettingsReveals() throws {
        let marker = "test marker \(UUID().uuidString)"
        let session = UUID()

        SessionLog.note(marker, session: session)
        SessionLog.flush()

        let contents = try String(contentsOf: SessionLog.file, encoding: .utf8)
        let entry = try #require(contents.components(separatedBy: "\n").last { $0.contains(marker) })
        // The session's own id is what tells two live turns apart in one file.
        #expect(entry.contains(String(session.uuidString.prefix(8))))
    }

    // A tool result can be a whole file, and one of those per call would bury everything
    // else in the log within a turn or two.
    @Test func cutsALineDownToSomethingReadable() throws {
        let marker = "long \(UUID().uuidString)"
        SessionLog.note(marker + String(repeating: "x", count: 50_000))
        SessionLog.flush()

        let contents = try String(contentsOf: SessionLog.file, encoding: .utf8)
        let entry = try #require(contents.components(separatedBy: "\n").last { $0.contains(marker) })
        #expect(entry.count < 2_200)
        #expect(entry.hasSuffix("…"))
    }

    @Test func streamSummariesDoNotContainPayloads() {
        let secret = "token-\(UUID().uuidString)"

        #expect(StreamEvent.text(secret).logSummary == "text bytes=\(secret.utf8.count)")
        #expect(StreamEvent.toolResult(id: "tool-1", output: secret, isError: false)
            .logSummary == "tool result id=tool-1 bytes=\(secret.utf8.count) error=false")
        #expect(!StreamEvent.text(secret).logSummary.contains(secret))
    }
}
