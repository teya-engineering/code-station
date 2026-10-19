import Foundation
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

// What the app says before it deletes a workspace: its sessions and their worktrees go,
// and the projects it groups stay.
@MainActor
struct WorkspaceRemovalTests {
    private let store: ProjectStore
    private let scratch: ScratchDirectory

    init() {
        (store, scratch) = TestStore.make()
    }

    @Test func countsSessionsAndWorktreesAndKeepsTheProjects() throws {
        let first = try TestStore.project(in: store, named: "api")
        let second = try TestStore.project(in: store, named: "web")
        let workspace = try #require(store.addWorkspace(name: "Checkout",
                                                        projectIDs: [first.id, second.id],
                                                        leadProjectID: first.id))
        _ = try store.insertSession(in: workspace.id, projects: [
            SessionProject(projectID: first.id, worktreePath: "/worktrees/api", worktreeBranch: "topic"),
            SessionProject(projectID: second.id, worktreePath: nil, worktreeBranch: nil)
        ]).get()

        let dialog = WorkspaceRemoval.confirmation(for: workspace, in: store) {}

        #expect(dialog.title == "Delete Checkout?")
        #expect(dialog.impact?.subject?.kind == .workspace)
        #expect(dialog.impact?.rows.first?.title == "1 session and 1 worktree")
        #expect(dialog.impact?.rows.last?.title == "Its projects stay")
        #expect(dialog.impact?.rows.last?.detail == "\(first.name), \(second.name)")
        #expect(dialog.impact?.rows.last?.kept == true)
        #expect(dialog.impact?.warning == "Session history cannot be restored.")
        #expect(dialog.actions.first?.label == "Delete workspace")
        #expect(dialog.actions.first?.kind == .destructive)
    }

    @Test func emptyWorkspaceHasNoHistoryWarning() throws {
        let first = try TestStore.project(in: store, named: "api")
        let second = try TestStore.project(in: store, named: "web")
        let workspace = try #require(store.addWorkspace(name: "Empty",
                                                        projectIDs: [first.id, second.id],
                                                        leadProjectID: first.id))

        let dialog = WorkspaceRemoval.confirmation(for: workspace, in: store) {}

        #expect(dialog.impact?.rows.first?.detail == "No sessions or worktrees to remove.")
        #expect(dialog.impact?.rows.count == 2)
        #expect(dialog.impact?.warning == nil)
    }
}
