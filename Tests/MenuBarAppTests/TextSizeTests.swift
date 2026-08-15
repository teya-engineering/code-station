import Testing
@testable import MenuBarApp

// The reading size the transcript, tool output, diffs and the terminal are drawn at.
struct TextSizeTests {

    @Test func theStepsRunFromSmallestToLargest() {
        #expect(TextSize.allCases == [.small, .standard, .large, .larger])
        #expect(TextSize.small.scale < TextSize.standard.scale)
        #expect(TextSize.large.scale > TextSize.standard.scale)
        #expect(TextSize.larger.scale > TextSize.large.scale)
    }

    // The whole app draws at its written point sizes until someone asks for something
    // else, so the default has to leave every size exactly as it is.
    @Test func theDefaultChangesNothing() {
        #expect(TextSize.standard.scale == 1)
    }

    @Test func theKeysStepOneSizeAtATime() {
        #expect(TextSize.standard.bigger == .large)
        #expect(TextSize.large.bigger == .larger)
        #expect(TextSize.standard.smaller == .small)
        #expect(TextSize.large.smaller == .standard)
    }

    // Holding a step key down has to settle on the end of the scale. Wrapping would take
    // the largest size back round to the smallest, which is the opposite of what someone
    // leaning on Cmd+ is asking for.
    @Test func theStepsStopAtTheEndsRatherThanWrapping() {
        #expect(TextSize.larger.bigger == .larger)
        #expect(TextSize.small.smaller == .small)
    }
}
