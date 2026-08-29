import Foundation
import Testing
@testable import MenuBarApp

// The marker that says a session stopped working while the user was elsewhere: what
// sets it, and what is allowed to clear it.
@MainActor
struct FinishedSessionTests {
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let project: Project

    init() throws {
        (store, scratch) = TestStore.make()
        project = try TestStore.project(in: store)
    }

    @Test func marksASessionThatEndedOutOfSight() {
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
        let open = store.newSession(in: project.id)

        store.selection = .session(open.id)
        store.noteTurnEnded(for: open.id)

        #expect(store.hasFinished(open.id) == false)
        #expect(store.finishedCount(in: project.id) == 0)
    }

    @Test func marksTheSelectedSessionWhenTheAppIsInactive() {
        let open = store.newSession(in: project.id)

        store.applicationWillResignActive()
        store.noteTurnEnded(for: open.id)

        #expect(store.hasFinished(open.id))
        #expect(store.finishedCount(in: project.id) == 1)
    }

    @Test func openingTheSessionClearsIt() {
        let background = store.newSession(in: project.id)
        let open = store.newSession(in: project.id)

        store.selection = .session(open.id)
        store.noteTurnEnded(for: background.id)
        store.selection = .session(background.id)

        #expect(store.hasFinished(background.id) == false)
        #expect(store.finishedCount(in: project.id) == 0)
    }

    @Test func openingAReviewCarriesItsDestination() {
        let session = store.newSession(in: project.id)

        store.selectHome()
        store.selectSession(session.id, destination: .changes)

        #expect(store.selection == .session(session.id))
        #expect(store.sessionOpenRequest
            == SessionOpenRequest(sessionID: session.id, destination: .changes))
    }

    @Test func openingAnOrdinarySessionTargetsTheConversation() {
        let first = store.newSession(in: project.id)
        let second = store.newSession(in: project.id)

        store.selectSession(first.id, destination: .changes)
        store.selectSession(second.id)

        #expect(store.sessionOpenRequest
            == SessionOpenRequest(sessionID: second.id, destination: .conversation))
    }

    @Test func leavesASessionBeingReadOnMobileAlone() {
        let session = store.newSession(in: project.id)

        store.hold(session.id, for: .remote)
        store.noteTurnEnded(for: session.id)

        #expect(store.hasFinished(session.id) == false)
        #expect(store.finishedCount(in: project.id) == 0)
    }

    @Test func openingTheSessionOnMobileClearsIt() {
        let session = store.newSession(in: project.id)

        store.noteTurnEnded(for: session.id)
        store.hold(session.id, for: .remote)

        #expect(store.hasFinished(session.id) == false)
        #expect(store.finishedCount(in: project.id) == 0)
    }

    // Looking at another session, or at no session at all, is not reading this one.
    @Test func staysUntilThatSessionIsOpened() {
        let background = store.newSession(in: project.id)
        let other = store.newSession(in: project.id)

        store.selection = .session(other.id)
        store.noteTurnEnded(for: background.id)
        store.selection = nil
        store.selection = .session(other.id)

        #expect(store.hasFinished(background.id))
    }

    @Test func deletingTheSessionTakesItsMarkWithIt() {
        let background = store.newSession(in: project.id)
        let open = store.newSession(in: project.id)

        store.selection = .session(open.id)
        store.noteTurnEnded(for: background.id)
        store.removeSession(background.id)

        #expect(store.finishedCount(in: project.id) == 0)
    }
}
