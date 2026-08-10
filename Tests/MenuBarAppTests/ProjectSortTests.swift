import Foundation
import Testing
@testable import MenuBarApp

// Last-used order is read from the sessions, so an item with none of them and an item
// whose newest session is old have to land somewhere predictable.
struct ProjectSortTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(in project: Project, hoursAgo: Double) -> ChatSession {
        var session = ChatSession(projectID: project.id)
        session.createdAt = now.addingTimeInterval(-hoursAgo * 3_600)
        return session
    }

    private func session(in workspace: ProjectWorkspace, lead: Project,
                         hoursAgo: Double) -> ChatSession {
        var session = session(in: lead, hoursAgo: hoursAgo)
        session.workspaceID = workspace.id
        return session
    }

    @Test func ordersByNameIgnoringCase() {
        let projects = [Project(name: "zebra", path: "/z"),
                        Project(name: "Alpha", path: "/a"),
                        Project(name: "beta", path: "/b")]
        let sorted = ProjectSort.name.apply(to: projects.map(SidebarItem.project), sessions: [])
        #expect(sorted.map(\.name) == ["Alpha", "beta", "zebra"])
    }

    @Test func ordersByTheNewestSessionInEachProject() {
        let old = Project(name: "old", path: "/old")
        let recent = Project(name: "recent", path: "/recent")
        let sessions = [session(in: old, hoursAgo: 40),
                        session(in: recent, hoursAgo: 30),
                        session(in: old, hoursAgo: 2)]

        let sorted = ProjectSort.lastUsed.apply(
            to: [recent, old].map(SidebarItem.project), sessions: sessions)
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

        let sorted = ProjectSort.lastUsed.apply(
            to: [quiet, talking].map(SidebarItem.project),
            sessions: [going, session(in: quiet, hoursAgo: 5)])
        #expect(sorted.map(\.name) == ["talking", "quiet"])
    }

    @Test func projectsWithNoSessionsSitAtTheBottomInNameOrder() {
        let used = Project(name: "used", path: "/u")
        let empty = Project(name: "empty", path: "/e")
        let alsoEmpty = Project(name: "also", path: "/a")

        let sorted = ProjectSort.lastUsed.apply(
            to: [empty, alsoEmpty, used].map(SidebarItem.project),
            sessions: [session(in: used, hoursAgo: 500)])
        #expect(sorted.map(\.name) == ["used", "also", "empty"])
    }

    @Test func interleavesWorkspacesAndProjectsByLastUse() {
        let lead = Project(name: "workspace lead", path: "/lead")
        let recent = Project(name: "recent project", path: "/recent")
        let older = Project(name: "older project", path: "/older")
        let workspace = ProjectWorkspace(name: "Scorecards", projectIDs: [lead.id],
                                         leadProjectID: lead.id)
        let items: [SidebarItem] = [.workspace(workspace), .project(older), .project(recent)]
        let sessions = [session(in: workspace, lead: lead, hoursAgo: 2),
                        session(in: recent, hoursAgo: 1),
                        session(in: older, hoursAgo: 3)]

        let sorted = ProjectSort.lastUsed.apply(to: items, sessions: sessions)

        #expect(sorted.map(\.name) == ["recent project", "Scorecards", "older project"])
    }

    @Test func workspaceSessionsDoNotCountAsStandaloneProjectUse() {
        let lead = Project(name: "lead", path: "/lead")
        let standalone = Project(name: "standalone", path: "/standalone")
        let workspace = ProjectWorkspace(name: "workspace", projectIDs: [lead.id],
                                         leadProjectID: lead.id)
        let items: [SidebarItem] = [.project(lead), .project(standalone), .workspace(workspace)]
        let sessions = [session(in: workspace, lead: lead, hoursAgo: 1),
                        session(in: standalone, hoursAgo: 2)]

        let sorted = ProjectSort.lastUsed.apply(to: items, sessions: sessions)

        #expect(sorted.map(\.name) == ["workspace", "standalone", "lead"])
    }
}
