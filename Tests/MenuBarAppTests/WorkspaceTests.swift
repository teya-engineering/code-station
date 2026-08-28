import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct WorkspaceTests {
    private let store: ProjectStore
    private let scratch: ScratchDirectory

    init() {
        (store, scratch) = TestStore.make()
    }

    @Test func olderWorkspacesKeepTheExistingWorktreeDefault() throws {
        let first = UUID()
        let second = UUID()
        let id = UUID()
        let data = Data("""
            {
              "id": "\(id.uuidString)",
              "name": "Payments",
              "projectIDs": ["\(first.uuidString)", "\(second.uuidString)"],
              "leadProjectID": "\(first.uuidString)"
            }
            """.utf8)

        let workspace = try JSONDecoder().decode(ProjectWorkspace.self, from: data)

        #expect(workspace.worktreeProjectIDs == [first, second])
    }

    @Test func selectingAWorkspaceClosesTheOpenConversation() throws {
        let first = try TestStore.project(in: store, named: "api")
        let second = try TestStore.project(in: store, named: "web")
        let workspace = try #require(store.addWorkspace(name: "Checkout",
                                                        projectIDs: [first.id, second.id],
                                                        leadProjectID: first.id))
        let session = store.newSession(in: first.id)
        store.append(ChatMessage(role: .user, text: "hello"), to: session.id)

        store.selectWorkspace(workspace.id)
        // The messages go once the write they owe lands, not inside the click.
        #expect(store.save())

        #expect(store.selection == .workspace(workspace.id))
        #expect(!store.isTranscriptLoaded(session.id))
    }

    @Test func updatesWorkspaceDefaultsAndMembership() throws {
        let first = try TestStore.project(in: store, named: "api")
        let second = try TestStore.project(in: store, named: "web")
        let third = try TestStore.project(in: store, named: "docs")
        let workspace = try #require(store.addWorkspace(name: "Checkout",
                                                        projectIDs: [first.id, second.id],
                                                        leadProjectID: first.id))

        store.addProject(third.id, toWorkspace: workspace.id)
        store.setLeadProject(second.id, inWorkspace: workspace.id)
        store.setUsesWorktree(true, for: second.id, inWorkspace: workspace.id)
        store.removeProject(first.id, fromWorkspace: workspace.id)

        let updated = try #require(store.workspace(workspace.id))
        #expect(updated.projectIDs == [second.id, third.id])
        #expect(updated.leadProjectID == second.id)
        #expect(updated.worktreeProjectIDs.contains(second.id))
        #expect(!updated.worktreeProjectIDs.contains(first.id))
    }

    @Test func deletingAWorkspaceDropsItsSessionsAndKeepsTheProjects() throws {
        let first = try TestStore.project(in: store, named: "api")
        let second = try TestStore.project(in: store, named: "web")
        let workspace = try #require(store.addWorkspace(name: "Checkout",
                                                        projectIDs: [first.id, second.id],
                                                        leadProjectID: first.id))
        let shared = try #require(store.newSession(
            in: workspace.id,
            projects: [SessionProject(projectID: first.id, worktreePath: nil, worktreeBranch: nil),
                       SessionProject(projectID: second.id, worktreePath: nil, worktreeBranch: nil)]))
        let standalone = store.newSession(in: first.id)
        store.selectWorkspace(workspace.id)

        store.removeWorkspace(workspace.id)

        #expect(store.workspace(workspace.id) == nil)
        #expect(store.session(shared.id) == nil)
        #expect(store.session(standalone.id) != nil)
        #expect(store.projects.map(\.id) == [first.id, second.id])
        #expect(store.selection == nil)
    }

    @Test func keepsAtLeastTwoProjectsInAWorkspace() throws {
        let first = try TestStore.project(in: store, named: "api")
        let second = try TestStore.project(in: store, named: "web")
        let workspace = try #require(store.addWorkspace(name: "Checkout",
                                                        projectIDs: [first.id, second.id],
                                                        leadProjectID: first.id))

        store.removeProject(second.id, fromWorkspace: workspace.id)

        #expect(store.workspace(workspace.id)?.projectIDs == [first.id, second.id])
    }

    @Test func excludesTasksFromWorkspaces() throws {
        let first = try TestStore.project(in: store, named: "api")
        let second = try TestStore.project(in: store, named: "web")
        let task = try store.addTask(
            named: "Reply as a bot",
            prompt: "Reply to the message.",
            in: scratch.path("tasks"))
            .get()

        #expect(store.regularProjects.map(\.id) == [first.id, second.id])
        let workspace = try #require(store.addWorkspace(
            name: "Checkout",
            projectIDs: [first.id, task.id, second.id],
            leadProjectID: first.id))
        #expect(workspace.projectIDs == [first.id, second.id])

        store.addProject(task.id, toWorkspace: workspace.id)

        #expect(store.workspace(workspace.id)?.projectIDs == [first.id, second.id])
    }
}
