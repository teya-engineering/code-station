import Foundation
import Testing
@testable import MenuBarApp

@Suite("Global command search")
struct GlobalCommandPaletteTests {
    @Test func ranksAttentionBeforeRecentWorkAndNavigation() {
        let recent = item(.session(UUID()), category: .sessions, group: .recent,
                          title: "Recent session", priority: 2)
        let action = item(.settings, category: .actions, group: .actions,
                          title: "Open Settings", priority: 5)
        let attention = item(.session(UUID()), category: .sessions, group: .needsYou,
                             title: "Needs review", priority: 0)
        let project = item(.project(UUID()), category: .projects, group: .projects,
                           title: "Payments", priority: 3)

        let results = GlobalCommandSearch.results(
            in: [recent, action, attention, project], query: "", category: .all)

        #expect(results.map(\.title)
                == ["Needs review", "Recent session", "Payments", "Open Settings"])
    }

    @Test func everyQueryWordCanMatchAcrossTheRow() {
        let match = GlobalCommandItem(
            destination: .file(sessionID: UUID(), root: "/workspace", path: "Sources/SessionView.swift"),
            category: .files,
            group: .files,
            title: "SessionView.swift",
            subtitle: "Code Station · Sources/MenuBarApp/Projects",
            keywords: "modified working tree",
            priority: 4)
        let other = item(.project(UUID()), category: .projects, group: .projects,
                         title: "Session tools", priority: 3)

        let results = GlobalCommandSearch.results(
            in: [other, match], query: "session projects modified", category: .all)

        #expect(results.map(\.id) == [match.id])
    }

    @Test func categoryKeepsOnlyItsOwnResults() {
        let session = item(.session(UUID()), category: .sessions, group: .recent,
                           title: "Fix checkout", priority: 2)
        let project = item(.project(UUID()), category: .projects, group: .projects,
                           title: "Checkout", priority: 3)

        let results = GlobalCommandSearch.results(
            in: [project, session], query: "checkout", category: .projects)

        #expect(results.map(\.id) == [project.id])
    }

    @Test func anExactTitleWinsInsideTheSamePriority() {
        let containing = item(.project(UUID()), category: .projects, group: .projects,
                              title: "Payments API", priority: 3)
        let exact = item(.project(UUID()), category: .projects, group: .projects,
                         title: "Payments", priority: 3)

        let results = GlobalCommandSearch.results(
            in: [containing, exact], query: "payments", category: .all)

        #expect(results.map(\.id) == [exact.id, containing.id])
    }

    private func item(_ destination: GlobalCommandDestination,
                      category: GlobalCommandCategory,
                      group: GlobalCommandGroup,
                      title: String,
                      priority: Int) -> GlobalCommandItem {
        GlobalCommandItem(destination: destination,
                          category: category,
                          group: group,
                          title: title,
                          subtitle: "",
                          priority: priority)
    }
}
