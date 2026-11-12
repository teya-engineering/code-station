import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct EmptyWorkspaceSweepTests {
    private let testPreferences = TestPreferences()
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    init() {
        (store, scratch) = TestStore.make()
    }

    private func makeWorkspace(removeAfter days: Int?) throws
        -> (ProjectWorkspace, [Project]) {
        let first = try TestStore.project(in: store, named: "api")
        let second = try TestStore.project(in: store, named: "web")
        let workspace = try #require(store.addWorkspace(
            name: "Fix flaky tests", projectIDs: [first.id, second.id],
            leadProjectID: first.id, removeWhenEmptyAfterDays: days, now: start))
        return (workspace, [first, second])
    }

    private func startSession(in workspace: ProjectWorkspace) throws -> ChatSession {
        try #require(store.newSession(
            in: workspace.id,
            projects: workspace.projectIDs.map { SessionProject(projectID: $0) }))
    }

    // Runs the sweep at a moment, then once more an hour later, the way the loop would.
    private func sweepThroughTheWarningHour(at now: Date) -> [ProjectWorkspace] {
        var buffer = EmptyWorkspaceSweep.Buffer()
        EmptyWorkspaceSweep.run(store: store, buffer: &buffer, now: now)
        return EmptyWorkspaceSweep.run(store: store, buffer: &buffer,
                                       now: now.addingTimeInterval(OldSessionSweep.gracePeriod))
    }

    @Test func aWorkspaceMadeWithoutTheSwitchIsNeverRemoved() throws {
        let (workspace, _) = try makeWorkspace(removeAfter: nil)

        let removed = sweepThroughTheWarningHour(at: start.addingTimeInterval(365 * day))

        #expect(removed.isEmpty)
        #expect(store.workspace(workspace.id) != nil)
    }

    @Test func anEmptyWorkspaceGoesAfterItsDaysAndAWarningHourKeepingItsProjects() throws {
        let (workspace, projects) = try makeWorkspace(removeAfter: 3)
        let standalone = store.newSession(in: projects[0].id)
        var buffer = EmptyWorkspaceSweep.Buffer()

        #expect(EmptyWorkspaceSweep.run(store: store, buffer: &buffer,
                                        now: start.addingTimeInterval(2 * day)).isEmpty)
        #expect(buffer.removal == nil)

        let due = start.addingTimeInterval(3 * day)
        #expect(EmptyWorkspaceSweep.run(store: store, buffer: &buffer, now: due).isEmpty)
        let removal = try #require(buffer.removal)
        #expect(removal.workspaces == [workspace.id])
        #expect(removal.at == due.addingTimeInterval(OldSessionSweep.gracePeriod))

        let removed = EmptyWorkspaceSweep.run(store: store, buffer: &buffer, now: removal.at)

        #expect(removed.map(\.id) == [workspace.id])
        #expect(store.workspace(workspace.id) == nil)
        #expect(store.projects.map(\.id) == projects.map(\.id))
        #expect(store.session(standalone.id) != nil)
        #expect(buffer.removal == nil)
    }

    @Test func aWorkspaceWithASessionIsNeverRemovedHoweverOld() throws {
        let (workspace, _) = try makeWorkspace(removeAfter: 1)
        _ = try startSession(in: workspace)

        let removed = sweepThroughTheWarningHour(at: start.addingTimeInterval(60 * day))

        #expect(removed.isEmpty)
        #expect(store.workspace(workspace.id) != nil)
    }

    @Test func startingASessionDuringTheWarningHourKeepsTheWorkspace() throws {
        let (workspace, _) = try makeWorkspace(removeAfter: 1)
        var buffer = EmptyWorkspaceSweep.Buffer()
        let due = start.addingTimeInterval(day)
        EmptyWorkspaceSweep.run(store: store, buffer: &buffer, now: due)
        #expect(buffer.removal != nil)

        _ = try startSession(in: workspace)
        let removed = EmptyWorkspaceSweep.run(
            store: store, buffer: &buffer, now: due.addingTimeInterval(OldSessionSweep.gracePeriod))

        #expect(removed.isEmpty)
        #expect(buffer.removal == nil)
        #expect(store.workspace(workspace.id) != nil)
    }

    @Test func keepForGoodCancelsTheWarning() throws {
        let (workspace, _) = try makeWorkspace(removeAfter: 2)
        var buffer = EmptyWorkspaceSweep.Buffer()
        let due = start.addingTimeInterval(2 * day)
        EmptyWorkspaceSweep.run(store: store, buffer: &buffer, now: due)
        #expect(buffer.removal?.goes(workspace.id) == true)

        store.keepForGood(workspace: workspace.id)
        let removed = EmptyWorkspaceSweep.run(
            store: store, buffer: &buffer, now: due.addingTimeInterval(OldSessionSweep.gracePeriod))

        #expect(removed.isEmpty)
        #expect(buffer.removal == nil)
        #expect(store.workspace(workspace.id)?.removeWhenEmptyAfterDays == nil)
    }

    // The days count from the moment the last session went, not from when the workspace
    // was made, so a long-lived workspace is not removed the instant it empties.
    @Test func theClockRestartsWhenTheLastSessionGoes() throws {
        let (workspace, _) = try makeWorkspace(removeAfter: 3)
        let session = try startSession(in: workspace)
        #expect(store.save())

        let before = Date()
        #expect((try? store.removeSession(session.id).get()) != nil)

        let emptySince = try #require(store.workspace(workspace.id)?.emptySince)
        #expect(emptySince >= before)
        #expect(sweepThroughTheWarningHour(at: before.addingTimeInterval(2 * day)).isEmpty)
        #expect(store.workspace(workspace.id) != nil)
    }

    @Test func theRuleSurvivesAReload() throws {
        let (workspace, _) = try makeWorkspace(removeAfter: 5)
        #expect(store.save())

        let reopened = ProjectStore(preferences: testPreferences.store, storeURL: store.storeURL)

        let loaded = try #require(reopened.workspace(workspace.id))
        #expect(loaded.removeWhenEmptyAfterDays == 5)
        #expect(loaded.emptySince == start)
    }

    @Test func theDayCountIsHeldToTheOldSessionRange() throws {
        let (workspace, _) = try makeWorkspace(removeAfter: 90)

        #expect(workspace.removeWhenEmptyAfterDays == OldSessions.dayRange.upperBound)
    }

    @Test func theSidebarLineSaysWhenItGoes() {
        var workspace = ProjectWorkspace(name: "Fix", projectIDs: [], leadProjectID: UUID(),
                                         removeWhenEmptyAfterDays: 3, emptySince: start)

        #expect(EmptyWorkspaceSweep.lifeLine(for: workspace, holdsSessions: false,
                                             removalAt: nil, now: start)
            == .init(text: "Goes in 3 days if no session starts", isFinalHour: false))
        #expect(EmptyWorkspaceSweep.lifeLine(for: workspace, holdsSessions: false, removalAt: nil,
                                             now: start.addingTimeInterval(2 * day))
            == .init(text: "Goes in 1 day · no session for 2 days", isFinalHour: false))
        #expect(EmptyWorkspaceSweep.lifeLine(for: workspace, holdsSessions: false, removalAt: nil,
                                             now: start.addingTimeInterval(3 * day - 5 * 3_600))
            == .init(text: "Goes in 5 hours · no session for 2 days", isFinalHour: false))
        #expect(EmptyWorkspaceSweep.lifeLine(for: workspace, holdsSessions: true,
                                             removalAt: nil, now: start)
            == .init(text: "Kept while it has sessions", isFinalHour: false))
        let now = start.addingTimeInterval(3 * day)
        #expect(EmptyWorkspaceSweep.lifeLine(for: workspace, holdsSessions: false,
                                             removalAt: now.addingTimeInterval(52 * 60), now: now)
            == .init(text: "Goes in 52 min", isFinalHour: true))

        workspace.removeWhenEmptyAfterDays = nil
        #expect(EmptyWorkspaceSweep.lifeLine(for: workspace, holdsSessions: false,
                                             removalAt: nil, now: start) == nil)
    }

    @Test func theRemovalNoteSaysTheProjectsStay() {
        let workspace = ProjectWorkspace(name: "Fix", projectIDs: [UUID(), UUID(), UUID()],
                                         leadProjectID: UUID())

        #expect(EmptyWorkspaceSweep.removedNote([workspace]) == "Removed Fix. Its 3 projects stay.")
        #expect(EmptyWorkspacesStrip.title(count: 1) == "1 empty workspace will be removed")
    }
}
