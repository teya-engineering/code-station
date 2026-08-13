import Foundation
import Testing
@testable import MenuBarApp

// A session title is either taken from the first prompt or typed by hand. Once it is
// typed, nothing the conversation does may take it back.
@MainActor
struct SessionRenameTests {

    private func makeStore() -> ProjectStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-tests-\(UUID().uuidString).json").path
        setenv("CONDUCTOR_STORE", path, 1)
        return ProjectStore()
    }

    private func project(in store: ProjectStore) -> Project {
        store.addProject(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("project-\(UUID().uuidString)"))!
    }

    @Test func renamingKeepsTheNameAcrossLaunches() throws {
        let store = makeStore()
        let session = store.newSession(in: project(in: store).id)

        store.renameSession(session.id, to: "  Ship the release  ")

        #expect(store.session(session.id)?.title == "Ship the release")
        #expect(store.sidebarSession(session.id)?.title == "Ship the release")
        #expect(store.save())
        #expect(ProjectStore(storeURL: store.storeURL).session(session.id)?.title
                == "Ship the release")
    }

    @Test func anEmptyNameIsNotAName() throws {
        let store = makeStore()
        let session = store.newSession(in: project(in: store).id)
        store.renameSession(session.id, to: "Ship the release")

        store.renameSession(session.id, to: "   ")

        #expect(store.session(session.id)?.title == "Ship the release")
    }

    @Test func theFirstPromptLeavesATypedNameAlone() throws {
        let store = makeStore()
        let session = store.newSession(in: project(in: store).id)
        store.renameSession(session.id, to: "Ship the release")

        store.append(ChatMessage(role: .user, text: "Fix the flaky login test"), to: session.id)

        #expect(store.session(session.id)?.title == "Ship the release")
    }

    // Pasted terminal output is mostly padding, and a title made of blanks says nothing.
    @Test func aPastedPromptDoesNotBecomeATitleOfBlanks() throws {
        let store = makeStore()
        let session = store.newSession(in: project(in: store).id)

        store.append(ChatMessage(role: .user, text: "s%\t   \(String(repeating: " ", count: 40))done"),
                     to: session.id)

        #expect(store.session(session.id)?.title == "s% done")
    }
}
