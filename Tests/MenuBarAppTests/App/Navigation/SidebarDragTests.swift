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
}
