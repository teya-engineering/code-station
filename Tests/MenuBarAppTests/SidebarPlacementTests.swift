import Foundation
import Testing
@testable import MenuBarApp

// A drag in the "Last used" rail is saved as a date, so each drop has to produce a date
// that sorts the row exactly where it was let go, and later work has to win over it.
struct SidebarPlacementTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func hoursAgo(_ hours: Double) -> Date {
        now.addingTimeInterval(-hours * 3_600)
    }

    private func session(in project: Project, hoursAgo hours: Double) -> ChatSession {
        var session = ChatSession(projectID: project.id)
        session.createdAt = hoursAgo(hours)
        return session
    }

    private func rows(_ dates: [Date?], pinned: Set<Int> = []) -> [SidebarPlacement.Row] {
        dates.enumerated().map { index, date in
            SidebarPlacement.Row(id: UUID(), isPinned: pinned.contains(index), date: date)
        }
    }

    @Test func droppingBetweenTwoRowsLandsBetweenTheirDates() throws {
        let list = rows([hoursAgo(1), hoursAgo(2), hoursAgo(3), hoursAgo(4)])

        // Drag the last row up onto the bottom half of the first.
        let date = try #require(SidebarPlacement.date(moving: list[3].id, beside: list[0].id,
                                                      after: true, in: list, now: now))

        #expect(date < hoursAgo(1))
        #expect(date > hoursAgo(2))
    }

    @Test func droppingAboveTheTopRowGoesNewerThanIt() throws {
        let list = rows([hoursAgo(1), hoursAgo(2)])

        let date = try #require(SidebarPlacement.date(moving: list[1].id, beside: list[0].id,
                                                      after: false, in: list, now: now))

        #expect(date > hoursAgo(1))
    }

    @Test func droppingBelowTheLastRowGoesOlderThanIt() throws {
        let list = rows([hoursAgo(1), hoursAgo(2), hoursAgo(3)])

        let date = try #require(SidebarPlacement.date(moving: list[0].id, beside: list[2].id,
                                                      after: true, in: list, now: now))

        #expect(date < hoursAgo(3))
    }

    // The moved row is not its own neighbour: dropping the second row just under the
    // third means it lands between the third and the fourth.
    @Test func movingDownSkipsTheRowBeingMoved() throws {
        let list = rows([hoursAgo(1), hoursAgo(2), hoursAgo(3), hoursAgo(4)])

        let date = try #require(SidebarPlacement.date(moving: list[1].id, beside: list[2].id,
                                                      after: true, in: list, now: now))

        #expect(date < hoursAgo(3))
        #expect(date > hoursAgo(4))
    }

    // Pinned rows always sit on top, so a drop only counts the rows on the same side.
    @Test func anUnpinnedRowCannotBeDroppedAmongPinnedOnes() {
        let list = rows([hoursAgo(5), hoursAgo(1), hoursAgo(2)], pinned: [0])

        #expect(SidebarPlacement.date(moving: list[2].id, beside: list[0].id,
                                      after: true, in: list, now: now) == nil)
    }

    @Test func aDropAmongNeverUsedRowsIsIgnored() {
        let list = rows([hoursAgo(1), nil, nil])

        #expect(SidebarPlacement.date(moving: list[0].id, beside: list[2].id,
                                      after: true, in: list, now: now) == nil)
    }

    @Test func aNeverUsedRowDroppedJustUnderTheUsedOnesJoinsThem() throws {
        let list = rows([hoursAgo(1), hoursAgo(2), nil])

        let date = try #require(SidebarPlacement.date(moving: list[2].id, beside: list[1].id,
                                                      after: true, in: list, now: now))

        #expect(date < hoursAgo(2))
    }

    @Test func aProjectStaysWhereItWasDropped() throws {
        var first = Project(name: "first", path: "/1")
        let second = Project(name: "second", path: "/2")
        let third = Project(name: "third", path: "/3")
        let sessions = [session(in: first, hoursAgo: 1),
                        session(in: second, hoursAgo: 2),
                        session(in: third, hoursAgo: 3)]
        let items = [first, second, third].map(SidebarItem.project)
        let dates = ProjectSort.sortDates(of: items, sessions: sessions)
        let list = items.map { SidebarPlacement.Row(id: $0.id, isPinned: false, date: dates[$0.id]) }

        let date = try #require(SidebarPlacement.date(moving: first.id, beside: second.id,
                                                      after: true, in: list, now: now))
        first.sidebarPlacement = SidebarPlacement(date: date, placedAt: now)

        let sorted = ProjectSort.lastUsed.apply(
            to: [first, second, third].map(SidebarItem.project), sessions: sessions)
        #expect(sorted.map(\.name) == ["second", "first", "third"])
    }

    @Test func workAfterTheDropMovesTheRowAgain() {
        var dropped = Project(name: "dropped", path: "/d")
        let other = Project(name: "other", path: "/o")
        dropped.sidebarPlacement = SidebarPlacement(date: hoursAgo(10), placedAt: hoursAgo(1))
        var fresh = session(in: dropped, hoursAgo: 5)
        let otherSession = session(in: other, hoursAgo: 2)

        let before = ProjectSort.lastUsed.apply(
            to: [dropped, other].map(SidebarItem.project), sessions: [fresh, otherSession])
        #expect(before.map(\.name) == ["other", "dropped"])

        fresh.summary.lastMessageAt = now
        let after = ProjectSort.lastUsed.apply(
            to: [dropped, other].map(SidebarItem.project), sessions: [fresh, otherSession])
        #expect(after.map(\.name) == ["dropped", "other"])
    }

    @Test func aSessionKeepsItsPlaceButShowsItsRealActivity() {
        let project = Project(name: "project", path: "/p")
        var moved = session(in: project, hoursAgo: 1)
        let other = session(in: project, hoursAgo: 2)
        moved.sidebarPlacement = SidebarPlacement(date: hoursAgo(3), placedAt: now)

        let sorted = [moved, other].sorted(by: SessionSort.pinnedFirstByLastActivity)

        #expect(sorted.map(\.id) == [other.id, moved.id])
        #expect(moved.lastActivity == hoursAgo(1))
    }

    // Moving a session inside its project says nothing about the project.
    @Test func aSessionsPlaceDoesNotMoveItsProject() {
        let first = Project(name: "first", path: "/1")
        let second = Project(name: "second", path: "/2")
        var moved = session(in: second, hoursAgo: 2)
        moved.sidebarPlacement = SidebarPlacement(date: now, placedAt: now)

        let sorted = ProjectSort.lastUsed.apply(
            to: [second, first].map(SidebarItem.project),
            sessions: [session(in: first, hoursAgo: 1), moved])

        #expect(sorted.map(\.name) == ["first", "second"])
    }

    @Test func placementsSurviveSaving() throws {
        let placement = SidebarPlacement(date: hoursAgo(3), placedAt: now)
        var project = Project(name: "project", path: "/p")
        project.sidebarPlacement = placement
        var workspace = ProjectWorkspace(name: "workspace", projectIDs: [project.id],
                                         leadProjectID: project.id)
        workspace.sidebarPlacement = placement
        var session = ChatSession(projectID: project.id)
        session.sidebarPlacement = placement

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(Project.self, from: encoder.encode(project))
                    .sidebarPlacement == placement)
        #expect(try decoder.decode(ProjectWorkspace.self, from: encoder.encode(workspace))
                    .sidebarPlacement == placement)
        #expect(try decoder.decode(ChatSession.self, from: encoder.encode(session))
                    .sidebarPlacement == placement)
    }
}
