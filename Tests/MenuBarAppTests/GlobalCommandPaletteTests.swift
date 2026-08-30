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
            destination: .session(UUID()),
            category: .sessions,
            group: .recent,
            title: "Fix command palette",
            subtitle: "Code Station · Waiting for review",
            keywords: "sidebar navigation",
            priority: 2)
        let other = item(.project(UUID()), category: .projects, group: .projects,
                         title: "Command tools", priority: 3)

        let results = GlobalCommandSearch.results(
            in: [other, match], query: "command station navigation", category: .all)

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

    @Test func resultWindowLoadsBoundedPages() {
        var window = GlobalCommandResultWindow(openingPage: 3, step: 2)
        let results = Array(0..<8)

        #expect(Array(window.visibleResults(in: results)) == [0, 1, 2])
        #expect(window.hasMore(totalCount: results.count))

        window.loadMore(totalCount: results.count)
        #expect(Array(window.visibleResults(in: results)) == [0, 1, 2, 3, 4])

        window.loadMore(totalCount: results.count)
        window.loadMore(totalCount: results.count)
        #expect(Array(window.visibleResults(in: results)) == results)
        #expect(!window.hasMore(totalCount: results.count))
    }

    @Test func resultWindowResetsToItsOpeningPage() {
        var window = GlobalCommandResultWindow(openingPage: 2, step: 3)
        let results = Array(0..<6)

        window.loadMore(totalCount: results.count)
        window.reset()

        #expect(Array(window.visibleResults(in: results)) == [0, 1])
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
