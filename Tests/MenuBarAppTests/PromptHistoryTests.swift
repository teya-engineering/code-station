import Foundation
import Testing
@testable import MenuBarApp

// Walking back through the prompts a session has already sent, the way a shell recalls
// what was typed into it.
@MainActor
struct PromptHistoryTests {
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let runner: SessionRunner
    private let session: ChatSession

    init() throws {
        (store, scratch) = TestStore.make()
        runner = SessionRunner(paths: [:])
        let project = try TestStore.project(in: store)
        session = store.newSession(in: project.id)
    }

    private func sent(_ prompts: String...) {
        for prompt in prompts {
            store.append(ChatMessage(role: .user, text: prompt), to: session.id)
            store.append(ChatMessage(role: .assistant, text: "Done"), to: session.id)
        }
    }

    private var draft: String { runner.draft(session.id).text }

    private func pressUp() -> Bool { runner.recallEarlier(session.id, store: store) }
    private func pressDown() -> Bool { runner.recallLater(session.id, store: store) }

    // MARK: - Reading the transcript

    @Test func listsSentPromptsNewestFirst() {
        sent("First", "Second", "Third")
        let found = PromptHistory.entries(in: store.transcript(of: session.id))
        #expect(found == ["Third", "Second", "First"])
    }

    // Only the person's own prompts are somewhere to go back to. What the agent said, and
    // what the app noted on the person's behalf, were never typed into the composer.
    @Test func readsOnlyUserPrompts() {
        store.append(ChatMessage(role: .user, text: "Mine"), to: session.id)
        store.append(ChatMessage(role: .assistant, text: "The reply"), to: session.id)
        store.append(ChatMessage(role: .system, text: "A note"), to: session.id)
        store.append(ChatMessage(role: .instructions, text: "Some instructions"), to: session.id)
        let found = PromptHistory.entries(in: store.transcript(of: session.id))
        #expect(found == ["Mine"])
    }

    @Test func skipsBlanksAndRepeats() {
        sent("Run the tests", "Run the tests", "   ", "Ship it")
        let found = PromptHistory.entries(in: store.transcript(of: session.id))
        #expect(found == ["Ship it", "Run the tests"])
    }

    // A repeat only collapses against the prompt next to it: the same words asked for
    // again after something else is a different point in the conversation to go back to.
    @Test func keepsARepeatThatIsNotConsecutive() {
        sent("Run the tests", "Fix the failure", "Run the tests")
        let found = PromptHistory.entries(in: store.transcript(of: session.id))
        #expect(found == ["Run the tests", "Fix the failure", "Run the tests"])
    }

    // MARK: - Walking

    @Test func upTakesTheMostRecentPromptAndThenGoesFurtherBack() {
        sent("First", "Second", "Third")

        #expect(pressUp())
        #expect(draft == "Third")
        #expect(pressUp())
        #expect(draft == "Second")
        #expect(pressUp())
        #expect(draft == "First")
    }

    // The walk stops at the oldest prompt rather than wrapping round, so holding the key
    // down settles somewhere instead of cycling for ever.
    @Test func upStopsAtTheOldestPrompt() {
        sent("Only one")

        #expect(pressUp())
        #expect(draft == "Only one")
        #expect(!pressUp())
        #expect(draft == "Only one")
    }

    @Test func downComesBackTowardsThePresentAndEmptiesTheBox() {
        sent("First", "Second")

        #expect(pressUp())
        #expect(pressUp())
        #expect(draft == "First")
        #expect(pressDown())
        #expect(draft == "Second")
        #expect(pressDown())
        #expect(draft == "")
    }

    @Test func downDoesNothingWithoutAWalk() {
        sent("First")
        #expect(!pressDown())
        #expect(draft == "")
    }

    @Test func doesNothingWhenNothingHasBeenSent() {
        #expect(!pressUp())
        #expect(draft == "")
    }

    // MARK: - Leaving a prompt being written alone

    @Test func upIgnoresABoxWithSomethingInIt() {
        sent("First")
        runner.editDraft(session.id) { $0.text = "Half a thought" }

        #expect(!pressUp())
        #expect(draft == "Half a thought")
    }

    // Files dropped on the composer are the start of a prompt, so they hold the box the
    // same way written words do.
    @Test func upIgnoresABoxHoldingOnlyAttachments() {
        sent("First")
        runner.editDraft(session.id) {
            $0.attachments = [Attachment(url: URL(fileURLWithPath: "/tmp/notes.md"))]
        }

        #expect(!pressUp())
        #expect(draft == "")
    }

    // Editing a recalled prompt ends the walk: from then on the arrows belong to the text
    // being written, so a rewritten prompt is never pulled out from under the person.
    @Test func editingARecalledPromptEndsTheWalk() {
        sent("First", "Second")

        #expect(pressUp())
        #expect(draft == "Second")
        runner.editDraft(session.id) { $0.text = "Second, but better" }

        #expect(!pressUp())
        #expect(!pressDown())
        #expect(draft == "Second, but better")
    }

    // Sending starts again from the present, rather than from wherever the last walk had
    // reached.
    @Test func sendingEndsTheWalk() {
        sent("First", "Second")

        #expect(pressUp())
        #expect(pressUp())
        #expect(draft == "First")

        runner.clearDraft(session.id)
        sent("Third")

        #expect(pressUp())
        #expect(draft == "Third")
    }

    // A walk belongs to the session it started in, so moving to another one and back does
    // not carry a half-finished walk across.
    @Test func walksAreKeptPerSession() {
        sent("First", "Second")
        let other = store.newSession(in: session.projectID)
        store.append(ChatMessage(role: .user, text: "Elsewhere"), to: other.id)

        #expect(pressUp())
        #expect(draft == "Second")
        #expect(runner.recallEarlier(other.id, store: store))
        #expect(runner.draft(other.id).text == "Elsewhere")
        #expect(draft == "Second")
    }
}
