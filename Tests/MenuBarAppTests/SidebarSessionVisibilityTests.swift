import Foundation
import Testing
@testable import MenuBarApp

@Suite("Sidebar session visibility")
struct SidebarSessionVisibilityTests {
    private let projectID = UUID()

    @Test func initiallyShowsFourSessions() {
        let visibility = SidebarSessionVisibility()

        #expect(visibility.visibleCount(for: projectID, total: 12) == 4)
    }

    @Test func staysCappedWhenSessionsAreAdded() {
        let visibility = SidebarSessionVisibility()

        #expect(visibility.visibleCount(for: projectID, total: 4) == 4)
        #expect(visibility.visibleCount(for: projectID, total: 5) == 4)
    }

    @Test func showsFewerWhenThereAreFewerThanFour() {
        let visibility = SidebarSessionVisibility()

        #expect(visibility.visibleCount(for: projectID, total: 2) == 2)
    }

    @Test func showingAllIncludesEverySession() {
        var visibility = SidebarSessionVisibility()
        visibility.showAll(projectID)

        #expect(visibility.visibleCount(for: projectID, total: 12) == 12)
        #expect(visibility.visibleCount(for: projectID, total: 13) == 13)
    }

    @Test func resetReturnsToTheInitialLimit() {
        var visibility = SidebarSessionVisibility()
        visibility.showAll(projectID)
        visibility.reset(projectID)

        #expect(visibility.visibleCount(for: projectID, total: 15) == 4)
    }
}
