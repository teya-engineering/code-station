import Foundation
import Testing
@testable import MenuBarApp

struct ExplorerSplitTests {
    @Test func draggingWidensAndNarrowsTheTree() {
        #expect(ExplorerSplitLayout.treeWidth(460, availableWidth: 1_000) == 460)
        #expect(ExplorerSplitLayout.treeWidth(260, availableWidth: 1_000) == 260)
    }

    @Test func draggingPastEitherEdgeKeepsBothPanesUsable() {
        #expect(ExplorerSplitLayout.treeWidth(-100, availableWidth: 1_000) == 220)
        #expect(ExplorerSplitLayout.treeWidth(1_500, availableWidth: 1_000) == 679)
    }

    @Test func narrowingTheWindowConstrainsTheTreeWithoutLosingItsPreferredWidth() {
        let preferredWidth: CGFloat = 500
        #expect(ExplorerSplitLayout.treeWidth(preferredWidth, availableWidth: 1_000) == 500)
        #expect(ExplorerSplitLayout.treeWidth(preferredWidth, availableWidth: 641) == 320)
        #expect(ExplorerSplitLayout.treeWidth(preferredWidth, availableWidth: 1_000) == 500)
    }

    @Test func veryNarrowLayoutsKeepBothPanesInsideTheAvailableSpace() {
        #expect(ExplorerSplitLayout.treeWidth(300, availableWidth: 400) == 199.5)
        #expect(ExplorerSplitLayout.treeWidth(300, availableWidth: 1) == 0)
        #expect(ExplorerSplitLayout.treeWidth(300, availableWidth: 0) == 0)
    }
}
