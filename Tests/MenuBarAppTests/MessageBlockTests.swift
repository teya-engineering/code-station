import Foundation
import Testing
@testable import MenuBarApp

// A turn arrives as separate text and tool events and is stored as two flat lists, so
// the only thing that says what came first is the offset stamped on each call.
struct MessageBlockTests {

    private func tool(_ id: String, at offset: Int?) -> ToolUse {
        ToolUse(id: id, name: "Bash", input: "{}", result: "ok", textOffset: offset)
    }

    private func prose(_ block: MessageBlock) -> String? {
        guard case .prose(_, let text) = block else { return nil }
        return text
    }

    private func toolIDs(_ block: MessageBlock) -> [String]? {
        guard case .tools(_, let tools) = block else { return nil }
        return tools.map(\.id)
    }

    @Test func putsACallMadeAfterSpeakingBelowTheWords() {
        let message = ChatMessage(role: .assistant,
                                  text: "Looking now.\n\nFound it.",
                                  tools: [tool("a", at: 12)])
        let blocks = message.blocks

        #expect(blocks.count == 3)
        #expect(prose(blocks[0]) == "Looking now.")
        #expect(toolIDs(blocks[1]) == ["a"])
        #expect(prose(blocks[2]) == "\n\nFound it.")
    }

    @Test func keepsACallMadeBeforeAnythingWasSaidOnTop() {
        let message = ChatMessage(role: .assistant,
                                  text: "Done.",
                                  tools: [tool("a", at: 0)])
        let blocks = message.blocks

        #expect(toolIDs(blocks[0]) == ["a"])
        #expect(prose(blocks[1]) == "Done.")
    }

    // Calls the model made in one go share an offset, and reading them as one spine is
    // what tells a round of parallel work from a sequence of separate steps.
    @Test func groupsCallsMadeAtTheSamePointIntoOneRound() {
        let message = ChatMessage(role: .assistant,
                                  text: "Checking.\n\nAnd again.",
                                  tools: [tool("a", at: 9), tool("b", at: 9), tool("c", at: 21)])
        let blocks = message.blocks

        #expect(blocks.map(toolIDs) == [nil, ["a", "b"], nil, ["c"]])
        #expect(prose(blocks[0]) == "Checking.")
        #expect(prose(blocks[2]) == "\n\nAnd again.")
    }

    @Test func endsWithTheCallsWhenTheTurnSaidNothingAfterThem() {
        let message = ChatMessage(role: .assistant,
                                  text: "On it.",
                                  tools: [tool("a", at: 6)])
        let blocks = message.blocks

        #expect(blocks.count == 2)
        #expect(prose(blocks[0]) == "On it.")
        #expect(toolIDs(blocks[1]) == ["a"])
    }

    @Test func readsAConversationSavedWithoutOffsetsTheWayItAlwaysLooked() {
        let message = ChatMessage(role: .assistant,
                                  text: "All done.",
                                  tools: [tool("a", at: nil), tool("b", at: nil)])
        let blocks = message.blocks

        #expect(toolIDs(blocks[0]) == ["a", "b"])
        #expect(prose(blocks[1]) == "All done.")
    }

    // An offset is a count of characters, and text the app never rewrites can still be
    // shorter than a stale offset if a conversation was edited on disk.
    @Test func survivesAnOffsetPastTheEndOfTheText() {
        let message = ChatMessage(role: .assistant, text: "Hi", tools: [tool("a", at: 99)])
        let blocks = message.blocks

        #expect(prose(blocks[0]) == "Hi")
        #expect(toolIDs(blocks[1]) == ["a"])
    }

    // Offsets count characters, not bytes, so text the pointer has to step over must be
    // measured the same way it was stamped.
    @Test func countsCharactersRatherThanBytes() {
        let spoken = "🇵🇹 já"
        let message = ChatMessage(role: .assistant,
                                  text: spoken + "\n\nrest",
                                  tools: [tool("a", at: spoken.count)])

        #expect(prose(message.blocks[0]) == spoken)
        #expect(prose(message.blocks[2]) == "\n\nrest")
    }

    @Test func hasNothingToDrawForAnEmptyTurn() {
        #expect(ChatMessage(role: .assistant).blocks.isEmpty)
    }

    @Test func givesEveryBlockItsOwnIdentity() {
        let message = ChatMessage(role: .assistant,
                                  text: "one\n\ntwo",
                                  tools: [tool("a", at: 3), tool("b", at: 8)])
        let ids = message.blocks.map(\.id)

        #expect(Set(ids).count == ids.count)
    }
}
