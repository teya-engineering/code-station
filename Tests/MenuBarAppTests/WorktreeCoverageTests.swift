import Foundation
import Testing
@testable import MenuBarApp

// A session's WT chip answers one question: can it run beside the other sessions in
// its projects. That is only true when every checkout is a worktree, so the chip has
// to look past the lead project.
@MainActor
struct WorktreeCoverageTests {
    private let scratch: ScratchDirectory
    private let store: ProjectStore
    private let lead: Project
    private let attached: Project

    init() throws {
        (store, scratch) = TestStore.make()
        lead = try TestStore.project(in: store, named: "android")
        attached = try TestStore.project(in: store, named: "ios")
    }

    private func workspaceSession(lead leadWorktree: String?, attached attachedWorktree: String?)
        throws -> ChatSession {
        let workspace = try #require(store.addWorkspace(
            name: "App", projectIDs: [lead.id, attached.id], leadProjectID: lead.id))
        let projects = [
            SessionProject(projectID: lead.id, worktreePath: leadWorktree,
                           worktreeBranch: leadWorktree.map { _ in "lead" }),
            SessionProject(projectID: attached.id, worktreePath: attachedWorktree,
                           worktreeBranch: attachedWorktree.map { _ in "attached" }),
        ]
        return try #require(store.newSession(in: workspace.id, projects: projects,
                                             seed: .init(agent: .claudeCode)))
    }

    @Test func aFolderSessionIsNeitherIsolatedNorPartlyIsolated() {
        let session = store.newSession(in: lead.id)
        let coverage = store.worktreeCoverage(for: session)

        #expect(coverage == WorktreeCoverage(isolated: [], shared: [lead.name]))
        #expect(!coverage.isComplete)
        #expect(!coverage.isPartial)
    }

    @Test func aWorktreeSessionIsFullyIsolated() {
        let session = store.newSession(in: lead.id, worktreePath: "/tmp/wt-android",
                                       worktreeBranch: "code-station/one")
        let coverage = store.worktreeCoverage(for: session)

        #expect(coverage == WorktreeCoverage(isolated: [lead.name], shared: []))
        #expect(coverage.isComplete)
        #expect(!coverage.isPartial)
    }

    @Test func aWorkspaceSessionWithEveryProjectInAWorktreeIsFullyIsolated() throws {
        let session = try workspaceSession(lead: "/tmp/wt-android", attached: "/tmp/wt-ios")
        let coverage = store.worktreeCoverage(for: session)

        #expect(coverage.isolated == [lead.name, attached.name])
        #expect(coverage.shared.isEmpty)
        #expect(coverage.isComplete)
    }

    // The lead is in a worktree, so the old lead-only check would have called this
    // session isolated. Its attached project still shares the folder with everyone.
    @Test func aWorkspaceSessionWithOneProjectOnItsFolderIsOnlyPartlyIsolated() throws {
        let session = try workspaceSession(lead: "/tmp/wt-android", attached: nil)
        let coverage = store.worktreeCoverage(for: session)

        #expect(coverage == WorktreeCoverage(isolated: [lead.name], shared: [attached.name]))
        #expect(!coverage.isComplete)
        #expect(coverage.isPartial)
    }

    @Test func aWorkspaceSessionOnEveryProjectFolderIsNotIsolated() throws {
        let session = try workspaceSession(lead: nil, attached: nil)
        let coverage = store.worktreeCoverage(for: session)

        #expect(coverage.isolated.isEmpty)
        #expect(coverage.shared == [lead.name, attached.name])
        #expect(!coverage.isComplete)
        #expect(!coverage.isPartial)
    }
}

// Two sessions on the same folder cannot run together. The refusal names the folder,
// because a session that is partly in worktrees looks isolated and the person has to
// be told which half is not.
struct SharedFolderConflictTests {
    @MainActor @Test func theRefusalNamesTheSharedFolder() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        input=$(cat)
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"one"}'
        sleep 30
        """)
        defer { fixture.tearDown() }
        let project = try #require(fixture.store.projects.first)
        let second = try fixture.store.insertSession(in: project.id,
                                                     seed: .init(agent: .claudeCode)).get()

        fixture.runner.send("hold the folder", sessionID: fixture.session.id,
                            store: fixture.store)
        #expect(await waitUntil { fixture.runner.state(fixture.session.id).isBusy })
        fixture.runner.send("also run", sessionID: second.id, store: fixture.store)

        guard case .failed(let message) = fixture.runner.state(second.id) else {
            Issue.record("expected the second session to be refused")
            return
        }
        // The first prompt renames the session, so the title is read back at the end.
        let holder = try #require(fixture.store.session(fixture.session.id))
        #expect(message.contains("\"\(holder.title)\" is already running in \(project.path.abbreviatedPath)."))
    }
}
