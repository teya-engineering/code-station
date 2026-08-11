import Testing
@testable import MenuBarApp

struct ActivitySpineTests {

    @Test func staysOpenWhileACallIsStillRunning() {
        #expect(ActivitySpine.rowsAreVisible(isFoldable: true,
                                             userChoice: nil,
                                             hasRunningCalls: true,
                                             hasExpandedRows: false))
    }

    @Test func foldsOnceEveryCallHasReportedIn() {
        #expect(!ActivitySpine.rowsAreVisible(isFoldable: true,
                                              userChoice: nil,
                                              hasRunningCalls: false,
                                              hasExpandedRows: false))
    }

    @Test func staysOpenWhileTheReaderHasARowExpanded() {
        #expect(ActivitySpine.rowsAreVisible(isFoldable: true,
                                             userChoice: nil,
                                             hasRunningCalls: false,
                                             hasExpandedRows: true))
    }

    @Test func keepsAReadersChoiceAfterTheCallsFinish() {
        #expect(ActivitySpine.rowsAreVisible(isFoldable: true,
                                             userChoice: true,
                                             hasRunningCalls: false,
                                             hasExpandedRows: false))
    }
}
