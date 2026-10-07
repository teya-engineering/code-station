import Testing
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
}
