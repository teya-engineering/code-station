import Foundation
import Testing
@testable import MenuBarApp

// A half-written prompt is work the user cannot get back if it is dropped, and the detail
// pane is thrown away and rebuilt on every session switch. These pin the drafts to the
// runner, which outlives that, and keep each session's words its own.
@MainActor
struct SessionDraftTests {

    @Test func keepsWhatWasTypedForEachSessionSeparately() {
        let runner = SessionRunner()
        let first = UUID()
        let second = UUID()

        runner.editDraft(first) { $0.text = "rename the button" }
        runner.editDraft(second) { $0.text = "add a test" }

        #expect(runner.draft(first).text == "rename the button")
        #expect(runner.draft(second).text == "add a test")
    }

    @Test func unknownSessionStartsEmpty() {
        let runner = SessionRunner()
        #expect(runner.draft(UUID()).isEmpty)
    }

    @Test func keepsAttachmentsAlongsideTheText() throws {
        let runner = SessionRunner()
        let sessionID = UUID()
        let file = Attachment(url: URL(fileURLWithPath: "/tmp/shot.png"))

        runner.editDraft(sessionID) {
            $0.text = "look at this"
            $0.attachments = [file]
        }

        #expect(runner.draft(sessionID).attachments == [file])
    }

    // Whitespace alone is nothing to come back to, so it should not count as a draft.
    @Test func blankTextIsNotADraft() {
        let runner = SessionRunner()
        let sessionID = UUID()

        runner.editDraft(sessionID) { $0.text = "   \n " }

        #expect(runner.draft(sessionID).isEmpty)
    }

    @Test func clearingLeavesNothingBehind() {
        let runner = SessionRunner()
        let sessionID = UUID()

        runner.editDraft(sessionID) { $0.text = "ship it" }
        runner.clearDraft(sessionID)

        #expect(runner.draft(sessionID).isEmpty)
    }
}
