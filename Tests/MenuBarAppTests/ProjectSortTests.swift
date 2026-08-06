import Foundation
import Testing
@testable import MenuBarApp

// The order the sidebar puts its projects in. The last-used order is the one worth
// pinning down: it is read from the sessions, so a project with none of them and a
// project whose newest session is old have to land somewhere predictable.
struct ProjectSortTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(in project: Project, hoursAgo: Double) -> ChatSession {
        var session = ChatSession(projectID: project.id)
        session.createdAt = now.addingTimeInterval(-hoursAgo * 3_600)
        return session
    }

    @Test func ordersByNameIgnoringCase() {
        let projects = [Project(name: "zebra", path: "/z"),
                        Project(name: "Alpha", path: "/a"),
                        Project(name: "beta", path: "/b")]
        let sorted = ProjectSort.name.apply(to: projects, sessions: [])
        #expect(sorted.map(\.name) == ["Alpha", "beta", "zebra"])
    }

    @Test func ordersByTheNewestSessionInEachProject() {
        let old = Project(name: "old", path: "/old")
        let recent = Project(name: "recent", path: "/recent")
        let sessions = [session(in: old, hoursAgo: 40),
                        session(in: recent, hoursAgo: 30),
                        session(in: old, hoursAgo: 2)]

        let sorted = ProjectSort.lastUsed.apply(to: [recent, old], sessions: sessions)
        // "old" wins on its newest session, not on its oldest or on how many it has.
        #expect(sorted.map(\.name) == ["old", "recent"])
    }

    // The last turn is what counts as use, so a long conversation started days ago is
    // ahead of one opened this morning and left alone.
    @Test func countsTheLastTurnRatherThanWhenTheSessionStarted() {
        let talking = Project(name: "talking", path: "/t")
        let quiet = Project(name: "quiet", path: "/q")
        var going = session(in: talking, hoursAgo: 72)
        going.summary.lastMessageAt = now.addingTimeInterval(-60)

        let sorted = ProjectSort.lastUsed.apply(to: [quiet, talking],
                                                sessions: [going, session(in: quiet, hoursAgo: 5)])
        #expect(sorted.map(\.name) == ["talking", "quiet"])
    }

    @Test func projectsWithNoSessionsSitAtTheBottomInNameOrder() {
        let used = Project(name: "used", path: "/u")
        let empty = Project(name: "empty", path: "/e")
        let alsoEmpty = Project(name: "also", path: "/a")

        let sorted = ProjectSort.lastUsed.apply(to: [empty, alsoEmpty, used],
                                                sessions: [session(in: used, hoursAgo: 500)])
        #expect(sorted.map(\.name) == ["used", "also", "empty"])
    }
}
