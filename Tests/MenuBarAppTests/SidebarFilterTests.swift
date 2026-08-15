import Foundation
import Testing
@testable import MenuBarApp

@Suite("Sidebar filter")
struct SidebarFilterTests {
    private func session(_ title: String, troubleshooting: Bool = false) -> ChatSession {
        var session = ChatSession(projectID: UUID())
        session.title = title
        session.isTroubleshooting = troubleshooting
        return session
    }

    @Test func anEmptyFilterMatchesEverything() {
        let filter = SidebarFilter("   ")

        #expect(!filter.isActive)
        #expect(filter.matches(name: "teya"))
        #expect(filter.matches(session("hello")))
    }

    @Test func matchesPartOfANameWhateverTheCase() {
        let filter = SidebarFilter("  ORDER ")

        #expect(filter.matches(name: "orders-service"))
        #expect(!filter.matches(name: "teya"))
    }

    @Test func aWorkspaceAlsoMatchesTheProjectsInsideIt() {
        let filter = SidebarFilter("orders")

        #expect(filter.matches(name: "release train",
                               orAnyOf: ["teya", "orders-service"]))
        #expect(!filter.matches(name: "release train", orAnyOf: ["teya"]))
    }

    @Test func matchesASessionTitle() {
        let filter = SidebarFilter("hello")

        #expect(filter.matches(session("hello world")))
        #expect(!filter.matches(session("goodbye")))
    }

    @Test func findsTroubleshootSessionsByTheirLabel() {
        #expect(SidebarFilter("troubleshoot").matches(session("hello", troubleshooting: true)))
        #expect(SidebarFilter("TROUBLE").matches(session("hello", troubleshooting: true)))
        #expect(SidebarFilter("trou").matches(session("hello", troubleshooting: true)))
    }

    @Test func theTroubleshootLabelBelongsOnlyToTroubleshootSessions() {
        #expect(!SidebarFilter("troubleshoot").matches(session("hello")))
    }
}
