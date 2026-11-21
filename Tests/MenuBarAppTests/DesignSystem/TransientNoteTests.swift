import Testing
@testable import MenuBarApp

// A note stays up for its time and then goes. A second note starts the time again, so
// the first one's timer must not take the second one down.
@MainActor
struct TransientNoteTests {
    @Test func aSecondNoteOutlivesTheFirstOnesTimer() async throws {
        let note = TransientNote(duration: .seconds(1))

        note.show("First", icon: "folder")
        #expect(note.text == "First")
        #expect(note.icon == "folder")

        try await Task.sleep(for: .seconds(0.6))
        note.show("Second", icon: "checkmark")

        // The first note's second is over, the second note's is not.
        try await Task.sleep(for: .seconds(0.6))
        #expect(note.text == "Second")
        #expect(note.icon == "checkmark")

        try await Task.sleep(for: .seconds(0.9))
        #expect(note.text == nil)
    }
}
