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

    @Test func newSessionsDoNotReplaceVisibleSessions() {
        var visibility = SidebarSessionVisibility()

        visibility.preserveVisibleSessions(added: 1, previousTotal: 12, in: projectID)
        #expect(visibility.visibleCount(for: projectID, total: 13) == 5)

        visibility.preserveVisibleSessions(added: 2, previousTotal: 13, in: projectID)
        #expect(visibility.visibleCount(for: projectID, total: 15) == 7)
    }

    @Test func additionsBelowTheLimitDoNotAccumulateUnusedCapacity() {
        var visibility = SidebarSessionVisibility()

        visibility.preserveVisibleSessions(added: 1, previousTotal: 1, in: projectID)
        visibility.preserveVisibleSessions(added: 1, previousTotal: 2, in: projectID)

        #expect(visibility.visibleCount(for: projectID, total: 12) == 4)
    }

    @Test func showingAllIncludesLaterSessions() {
        var visibility = SidebarSessionVisibility()
        visibility.showAll(projectID)

        #expect(visibility.visibleCount(for: projectID, total: 12) == 12)

        visibility.preserveVisibleSessions(added: 1, previousTotal: 12, in: projectID)
        #expect(visibility.visibleCount(for: projectID, total: 13) == 13)
    }

    @Test func resetReturnsToTheInitialLimit() {
        var visibility = SidebarSessionVisibility()
        visibility.preserveVisibleSessions(added: 3, previousTotal: 12, in: projectID)
        visibility.reset(projectID)

        #expect(visibility.visibleCount(for: projectID, total: 15) == 4)
    }
}
