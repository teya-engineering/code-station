import Foundation
import Testing
@testable import MenuBarApp

// How a reading's move is said: as words in the reading card, and only when it is big
// enough to round to a whole percent.
struct ChangeFigureTests {
    @Test func aRiseAndAFallAreSaidAsMoreAndLess() {
        #expect(ChangeFigure.words(0.18) == "18% more")
        #expect(ChangeFigure.words(-0.243) == "24% less")
    }

    @Test func aMoveThatRoundsToNothingIsLeftOut() {
        #expect(ChangeFigure.isWorthSaying(0.004) == false)
        #expect(ChangeFigure.isWorthSaying(-0.004) == false)
        #expect(ChangeFigure.isWorthSaying(0.005))
        #expect(ChangeFigure.isWorthSaying(nil) == false)
        #expect(ChangeFigure.isWorthSaying(.infinity) == false)
        #expect(ChangeFigure.isWorthSaying(.nan) == false)
    }

    @Test func greenMeansTheGoodWayForBothKindsOfReading() {
        #expect(ChangeFigure.tint(0.2, lowerIsBetter: false) == Theme.dotOnText)
        #expect(ChangeFigure.tint(-0.2, lowerIsBetter: false) == Theme.attentionText)
        #expect(ChangeFigure.tint(-0.2, lowerIsBetter: true) == Theme.dotOnText)
        #expect(ChangeFigure.tint(0.2, lowerIsBetter: true) == Theme.attentionText)
    }
}
