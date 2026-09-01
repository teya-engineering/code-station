import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct PinningTests {

    @Test func persistsPinsForProjectsWorkspacesTasksAndSessions() throws {
        let (store, scratch) = TestStore.make()
        let first = try TestStore.project(in: store, named: "api")
        let second = try TestStore.project(in: store, named: "web")
        let workspace = try #require(store.addWorkspace(
            name: "Checkout",
            projectIDs: [first.id, second.id],
            leadProjectID: first.id))
        let task = try store.addTask(named: "Release", prompt: "Ship it",
                                     in: scratch.path("tasks")).get()
        let session = store.newSession(in: first.id)

        store.setPinned(true, forProject: first.id)
        store.setPinned(true, forWorkspace: workspace.id)
        store.setPinned(true, forProject: task.id)
        store.setPinned(true, forSession: session.id)

        #expect(store.sidebarSession(session.id)?.isPinned == true)
        let loaded = ProjectStore(storeURL: store.storeURL)
        #expect(loaded.project(first.id)?.isPinned == true)
        #expect(loaded.workspace(workspace.id)?.isPinned == true)
        #expect(loaded.project(task.id)?.isPinned == true)
        #expect(loaded.session(session.id)?.isPinned == true)
    }

    @Test func recordsSavedBeforePinningStayUnpinned() throws {
        let projectID = UUID()
        let workspaceID = UUID()
        let project = try JSONDecoder().decode(Project.self, from: Data("""
            {
              "id": "\(projectID.uuidString)",
              "name": "API",
              "path": "/api",
              "kind": "project"
            }
            """.utf8))
        let workspace = try JSONDecoder().decode(ProjectWorkspace.self, from: Data("""
            {
              "id": "\(workspaceID.uuidString)",
              "name": "Checkout",
              "projectIDs": ["\(projectID.uuidString)"],
              "leadProjectID": "\(projectID.uuidString)"
            }
            """.utf8))
        let session = try JSONDecoder().decode(ChatSession.self, from: Data("""
            {
              "id": "\(UUID().uuidString)",
              "projectID": "\(projectID.uuidString)"
            }
            """.utf8))

        #expect(!project.isPinned)
        #expect(!workspace.isPinned)
        #expect(!session.isPinned)
    }
}
