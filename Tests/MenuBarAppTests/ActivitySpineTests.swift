import Testing
@testable import MenuBarApp

struct ActivitySpineTests {

    @Test func keepsCompletedCallsVisibleUntilTheTurnEnds() {
        #expect(ActivitySpine.rowsAreVisible(isFoldable: true,
                                             userChoice: nil,
                                             isTurnActive: true,
                                             hasExpandedRows: false))
    }

    @Test func foldsCallsWhenTheTurnEnds() {
        #expect(!ActivitySpine.rowsAreVisible(isFoldable: true,
                                              userChoice: nil,
                                              isTurnActive: false,
                                              hasExpandedRows: false))
    }

    @Test func keepsAReadersChoiceAcrossTheEndOfTheTurn() {
        #expect(ActivitySpine.rowsAreVisible(isFoldable: true,
                                             userChoice: true,
                                             isTurnActive: false,
                                             hasExpandedRows: false))
    }
}
