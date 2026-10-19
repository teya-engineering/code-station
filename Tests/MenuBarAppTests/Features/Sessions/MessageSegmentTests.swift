import Testing
@testable import CodeStationCore
@testable import MenuBarApp

struct MessageSegmentTests {
    @Test func stripsQuoteMarkersFromAFenceInsideAQuote() {
        let text = "> looks off\n>\n> ```suggestion\n>     let value = 1\n> ```\n\nAfter"
        let segments = MessageSegment.split(text)

        #expect(segments.map(\.text) == ["> looks off", "    let value = 1", "After"])
        #expect(segments[1].language == "suggestion")
        #expect(!segments[1].isDeletion)
    }

    @Test func keepsAnEmptySuggestionAsADeletion() {
        let segments = MessageSegment.split("> unused now\n>\n> ```suggestion\n>\n> ```\n> ps: more")

        #expect(segments.map(\.text) == ["> unused now", "", "> ps: more"])
        #expect(segments[1].isDeletion)
    }

    @Test func waitsForTheClosingFenceBeforeCallingASuggestionADeletion() {
        let segments = MessageSegment.split("Before\n```suggestion\n")

        #expect(segments.map(\.text) == ["Before"])
    }

    @Test func dropsOtherEmptyBlocks() {
        #expect(MessageSegment.split("Before\n```swift\n```\nAfter").map(\.text) == ["Before", "After"])
    }

    @Test func stripsNestedQuoteMarkers() {
        let segments = MessageSegment.split("> > ```\n> > code\n> > ```")

        #expect(segments.map(\.text) == ["code"])
    }

    @Test func leavesAFenceOutsideAQuoteAlone() {
        let segments = MessageSegment.split("> quoted\n\n```\n> not a quote\n```")

        #expect(segments.map(\.text) == ["> quoted", "> not a quote"])
    }

    // A reply asked for "all of that in one block to copy" wraps fenced code in a longer
    // fence. The inner fences are part of what gets copied, not the end of the block.
    @Test func keepsShorterFencesInsideALongerOne() {
        let text = "Here it is.\n\n````markdown\n# Title\n\n```swift\nlet a = 1\n```\n\nMore\n````\n\nAfter"
        let segments = MessageSegment.split(text)

        #expect(segments.map(\.text) == ["Here it is.", "# Title\n\n```swift\nlet a = 1\n```\n\nMore", "After"])
        #expect(segments.map(\.isCode) == [false, true, false])
        #expect(segments[1].language == "markdown")
        #expect(!segments[1].isOpen)
    }

    @Test func closesOnlyOnTheSameCharacterAtLeastAsLong() {
        let segments = MessageSegment.split("~~~~\n~~~\n```\n~~~~~\nAfter")

        #expect(segments.map(\.text) == ["~~~\n```", "After"])
        #expect(segments.map(\.isCode) == [true, false])
    }

    @Test func aFenceWithTextAfterItDoesNotClose() {
        let segments = MessageSegment.split("```\n``` not yet\n```")

        #expect(segments.map(\.text) == ["``` not yet"])
    }

    @Test func keepsAnOuterBlockOpenWhileItStreams() {
        let segments = MessageSegment.split("````markdown\n```swift\nlet a = 1\n```\n")

        #expect(segments.map(\.text) == ["```swift\nlet a = 1\n```"])
        #expect(segments[0].isOpen)
    }

    @Test func leavesBackticksInsideALineAsProse() {
        let text = "Run ```make``` first\n```make``` again"

        #expect(MessageSegment.split(text) == [MessageSegment(id: 0, text: text, isCode: false)])
    }

    @Test func takesTheFirstWordOfTheInfoAsTheLanguage() {
        let segments = MessageSegment.split("```swift title=\"a.swift\"\nlet a = 1\n```")

        #expect(segments.map(\.text) == ["let a = 1"])
        #expect(segments[0].language == "swift")
    }

    // A segment's id must not change as more of a streaming reply arrives after it.
    @Test func keepsIdsStableAsAReplyGrows() {
        let early = MessageSegment.split("Intro\n```\ncode\n")
        let later = MessageSegment.split("Intro\n```\ncode\n```\nOutro")

        #expect(early.map(\.id) == Array(later.map(\.id).prefix(2)))
    }
}
