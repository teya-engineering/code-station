import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct SidebarDestinationTests {
    private let store: ProjectStore
    private let scratch: ScratchDirectory

    init() {
        (store, scratch) = TestStore.make()
    }

    @Test func navigationDistinguishesHomeProjectAndConversation() throws {
        let first = try TestStore.project(in: store, named: "api")
        let second = try TestStore.project(in: store, named: "web")
        let session = store.newSession(in: first.id)

        store.selectProject(second.id)
        #expect(store.sidebarDestination == SidebarDestination(containerID: second.id))

        store.selectSession(session.id)
        #expect(store.sidebarDestination == SidebarDestination(containerID: first.id,
                                                               sessionID: session.id))
        #expect(store.sessionToReveal == session.id)

        store.selectHome()
        #expect(store.sidebarDestination == nil)
    }

    @Test func workspaceConversationMarksItsWorkspaceInsteadOfItsLeadProject() throws {
        let first = try TestStore.project(in: store, named: "api")
        let second = try TestStore.project(in: store, named: "web")
        let workspace = try #require(store.addWorkspace(name: "Checkout",
            projectIDs: [first.id, second.id], leadProjectID: first.id))
        let session = try #require(store.newSession(in: workspace.id, projects: [
            SessionProject(projectID: first.id, worktreePath: nil, worktreeBranch: nil),
            SessionProject(projectID: second.id, worktreePath: nil, worktreeBranch: nil)
        ]))

        store.selectSession(session.id)
        #expect(store.sidebarDestination == SidebarDestination(containerID: workspace.id,
                                                               sessionID: session.id))
        store.selectWorkspace(workspace.id)
        #expect(store.sidebarDestination == SidebarDestination(containerID: workspace.id))
    }

    @Test func openingADesignCompanionRevealsItsUserFacingSession() throws {
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id)
        let companion = try store.startDesign(for: session.id).get()

        store.selectSession(companion.id)

        #expect(store.sidebarDestination == SidebarDestination(containerID: project.id,
                                                               sessionID: session.id))
        #expect(store.sessionToReveal == session.id)
    }

    @Test func openingTheSameSessionAgainRequestsAnotherReveal() throws {
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id)
        store.selectSession(session.id)
        store.sessionToReveal = nil

        store.selectSession(session.id)

        #expect(store.sessionToReveal == session.id)
    }

    @Test func transcriptUpdatesDoNotRequestNavigationOrChangeTheDestination() throws {
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id)
        store.selectSession(session.id)
        let destination = store.sidebarDestination
        store.sessionToReveal = nil

        store.append(ChatMessage(role: .assistant, text: "A streamed answer"), to: session.id)
        store.renameSession(session.id, to: "Updated title")

        #expect(store.sidebarDestination == destination)
        #expect(store.sessionToReveal == nil)
    }
}
