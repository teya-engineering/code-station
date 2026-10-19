import Foundation
import Testing
@testable import CodeStationCore

// A half-written prompt is work the user cannot get back if it is dropped, and the detail
// pane is thrown away and rebuilt on every session switch. These pin the drafts to the
// runner, which outlives that, and keep each session's words its own.
@MainActor
struct SessionDraftTests {
    private let testPreferences = TestPreferences()

    @Test func keepsWhatWasTypedForEachSessionSeparately() {
        let runner = SessionRunner(preferences: testPreferences.store)
        let first = UUID()
        let second = UUID()

        runner.composer.editDraft(first) { $0.text = "rename the button" }
        runner.composer.editDraft(second) { $0.text = "add a test" }

        #expect(runner.composer.draft(first).text == "rename the button")
        #expect(runner.composer.draft(second).text == "add a test")
    }

    @Test func unknownSessionStartsEmpty() {
        let runner = SessionRunner(preferences: testPreferences.store)
        #expect(runner.composer.draft(UUID()).isEmpty)
    }

    @Test func keepsAttachmentsAlongsideTheText() throws {
        let runner = SessionRunner(preferences: testPreferences.store)
        let sessionID = UUID()
        let file = Attachment(url: URL(fileURLWithPath: "/tmp/shot.png"))

        runner.composer.editDraft(sessionID) {
            $0.text = "look at this"
            $0.attachments = [file]
        }

        #expect(runner.composer.draft(sessionID).attachments == [file])
    }

    // Whitespace alone is nothing to come back to, so it should not count as a draft.
    @Test func blankTextIsNotADraft() {
        let runner = SessionRunner(preferences: testPreferences.store)
        let sessionID = UUID()

        runner.composer.editDraft(sessionID) { $0.text = "   \n " }

        #expect(runner.composer.draft(sessionID).isEmpty)
    }

    @Test func clearingLeavesNothingBehind() {
        let runner = SessionRunner(preferences: testPreferences.store)
        let sessionID = UUID()

        runner.composer.editDraft(sessionID) { $0.text = "ship it" }
        runner.composer.clearDraft(sessionID)

        #expect(runner.composer.draft(sessionID).isEmpty)
    }
}
