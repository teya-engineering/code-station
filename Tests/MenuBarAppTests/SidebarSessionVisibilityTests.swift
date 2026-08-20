import Foundation
import Testing
@testable import MenuBarApp

@Suite("Sidebar session visibility")
struct SidebarSessionVisibilityTests {
    private struct Session: Identifiable {
        let id: UUID
    }

    private let projectID = UUID()

    private func sessions(_ count: Int) -> [Session] {
        (0..<count).map { _ in Session(id: UUID()) }
    }

    @Test func initiallyUsesTheDefaultLimit() {
        let visibility = SidebarSessionVisibility()
        let all = sessions(12)

        #expect(visibility.visible(all, in: projectID).map(\.id) == all.prefix(4).map(\.id))
    }

    @Test func usesTheConfiguredLimit() {
        let visibility = SidebarSessionVisibility()
        let all = sessions(12)

        #expect(visibility.visible(all, in: projectID, limit: 7).map(\.id)
                == all.prefix(7).map(\.id))
    }

    @Test func clampsTheConfiguredLimitToTheSupportedRange() {
        let visibility = SidebarSessionVisibility()

        #expect(visibility.visible(sessions(12), in: projectID, limit: 1).count == 2)
        #expect(visibility.visible(sessions(12), in: projectID, limit: 11).count == 10)
    }

    @Test func staysCappedWhenSessionsAreAdded() {
        let visibility = SidebarSessionVisibility()

        #expect(visibility.visible(sessions(4), in: projectID).count == 4)
        #expect(visibility.visible(sessions(5), in: projectID).count == 4)
    }

    @Test func showsFewerWhenThereAreFewerThanTheDefaultLimit() {
        let visibility = SidebarSessionVisibility()

        #expect(visibility.visible(sessions(2), in: projectID).count == 2)
    }

    @Test func showingAllIncludesEverySession() {
        var visibility = SidebarSessionVisibility()
        visibility.showAll(projectID)

        #expect(visibility.visible(sessions(12), in: projectID).count == 12)
        #expect(visibility.visible(sessions(13), in: projectID).count == 13)
    }

    @Test func pinningKeepsTheCapAndAddsTheOpenedSession() {
        var visibility = SidebarSessionVisibility()
        let all = sessions(12)
        visibility.pin(all[8].id, in: projectID)

        let visible = visibility.visible(all, in: projectID)

        #expect(visible.map(\.id) == all.prefix(4).map(\.id) + [all[8].id])
    }

    @Test func pinningASessionAlreadyShownAddsNothing() {
        var visibility = SidebarSessionVisibility()
        let all = sessions(12)
        visibility.pin(all[1].id, in: projectID)

        #expect(visibility.visible(all, in: projectID).map(\.id) == all.prefix(4).map(\.id))
    }

    @Test func pinningOnlyAffectsItsOwnContainer() {
        var visibility = SidebarSessionVisibility()
        let all = sessions(12)
        visibility.pin(all[8].id, in: UUID())

        #expect(visibility.visible(all, in: projectID).count == 4)
    }

    @Test func resetReturnsToTheDefaultLimit() {
        var visibility = SidebarSessionVisibility()
        let all = sessions(15)
        visibility.showAll(projectID)
        visibility.pin(all[9].id, in: projectID)
        visibility.reset(projectID)

        #expect(visibility.visible(all, in: projectID).count == 4)
    }
}
