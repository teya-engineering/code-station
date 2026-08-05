import Foundation
import Testing
@testable import MenuBarApp

// The marker that says a session stopped working while the user was elsewhere: what
// sets it, and what is allowed to clear it.
@MainActor
struct FinishedSessionTests {

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

    @Test func marksASessionThatEndedOutOfSight() {
        let store = makeStore()
        let project = project(in: store)
        let background = store.newSession(in: project.id)
        let open = store.newSession(in: project.id)

        store.selection = .session(open.id)
        store.noteTurnEnded(for: background.id)

        #expect(store.hasFinished(background.id))
        #expect(store.finishedCount(in: project.id) == 1)
    }

    // The result of the session being read is already on screen, so there is nothing to
    // come back to.
    @Test func leavesTheSessionOnScreenAlone() {
        let store = makeStore()
        let project = project(in: store)
        let open = store.newSession(in: project.id)

        store.selection = .session(open.id)
        store.noteTurnEnded(for: open.id)

        #expect(store.hasFinished(open.id) == false)
        #expect(store.finishedCount(in: project.id) == 0)
    }

    @Test func openingTheSessionClearsIt() {
        let store = makeStore()
        let project = project(in: store)
        let background = store.newSession(in: project.id)
        let open = store.newSession(in: project.id)

        store.selection = .session(open.id)
        store.noteTurnEnded(for: background.id)
        store.selection = .session(background.id)

        #expect(store.hasFinished(background.id) == false)
        #expect(store.finishedCount(in: project.id) == 0)
    }

    // Nothing else clears it: looking at another session, or at no session at all, is
    // not reading this one.
    @Test func staysUntilThatSessionIsOpened() {
        let store = makeStore()
        let project = project(in: store)
        let background = store.newSession(in: project.id)
        let other = store.newSession(in: project.id)

        store.selection = .session(other.id)
        store.noteTurnEnded(for: background.id)
        store.selection = nil
        store.selection = .session(other.id)

        #expect(store.hasFinished(background.id))
    }

    @Test func deletingTheSessionTakesItsMarkWithIt() {
        let store = makeStore()
        let project = project(in: store)
        let background = store.newSession(in: project.id)
        let open = store.newSession(in: project.id)

        store.selection = .session(open.id)
        store.noteTurnEnded(for: background.id)
        store.removeSession(background.id)

        #expect(store.finishedCount(in: project.id) == 0)
    }
}
