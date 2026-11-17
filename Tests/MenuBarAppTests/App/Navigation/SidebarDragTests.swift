import Foundation
import Testing
@testable import MenuBarApp

struct SidebarDragTests {

    private typealias Place = SidebarDropSlot.Place

    @Test func aRowThatReordersAndTakesInSplitsIntoEdgesAndMiddle() {
        #expect(Place.at(5, rowHeight: 40, reorders: true, takesIn: true) == .before)
        #expect(Place.at(20, rowHeight: 40, reorders: true, takesIn: true) == .into)
        #expect(Place.at(35, rowHeight: 40, reorders: true, takesIn: true) == .after)
    }

    @Test func aRowThatOnlyReordersSplitsInHalves() {
        #expect(Place.at(19, rowHeight: 40, reorders: true, takesIn: false) == .before)
        #expect(Place.at(21, rowHeight: 40, reorders: true, takesIn: false) == .after)
    }

    @Test func aRowThatOnlyTakesInTakesTheWholeRow() {
        #expect(Place.at(1, rowHeight: 40, reorders: false, takesIn: true) == .into)
        #expect(Place.at(39, rowHeight: 40, reorders: false, takesIn: true) == .into)
    }

    @Test func aRowThatDoesNeitherRefusesTheDrop() {
        #expect(Place.at(20, rowHeight: 40, reorders: false, takesIn: false) == nil)
    }

    // A project is never reordered beside a workspace, so a workspace takes it in with
    // the whole row rather than splitting into edges.
    @Test func aRowThatTakesInWithTheWholeRowNeverReorders() {
        #expect(Place.at(2, rowHeight: 40, reorders: true, takesIn: true, wholeRow: true) == .into)
        #expect(Place.at(38, rowHeight: 40, reorders: true, takesIn: true, wholeRow: true) == .into)
    }

    @Test func aWholeRowStillReordersWhatItCannotTakeIn() {
        #expect(Place.at(5, rowHeight: 40, reorders: true, takesIn: false, wholeRow: true) == .before)
    }

    // A workspace that already holds the project says so, wherever the pointer is.
    @Test func aRowThatAlreadyHoldsTheDraggedOneRefusesIt() {
        #expect(Place.at(2, rowHeight: 40, reorders: true, takesIn: false, wholeRow: true, holds: true) == .refused)
        #expect(Place.at(20, rowHeight: 40, reorders: false, takesIn: false, holds: true) == .refused)
    }
}
