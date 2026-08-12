import Testing
@testable import MenuBarApp

struct ActivitySpineTests {

    @Test func staysOpenWhileTheTurnIsWorkingThroughIt() {
        #expect(ActivitySpine.rowsAreVisible(isFoldable: true,
                                             userChoice: nil,
                                             isLive: true,
                                             hasExpandedRows: false))
    }

    @Test func foldsOnceTheTurnHasEnded() {
        #expect(!ActivitySpine.rowsAreVisible(isFoldable: true,
                                              userChoice: nil,
                                              isLive: false,
                                              hasExpandedRows: false))
    }

    @Test func staysOpenWhileTheReaderHasARowExpanded() {
        #expect(ActivitySpine.rowsAreVisible(isFoldable: true,
                                             userChoice: nil,
                                             isLive: false,
                                             hasExpandedRows: true))
    }

    @Test func keepsAReadersChoiceAfterTheTurnEnds() {
        #expect(ActivitySpine.rowsAreVisible(isFoldable: true,
                                             userChoice: true,
                                             isLive: false,
                                             hasExpandedRows: false))
    }
}
