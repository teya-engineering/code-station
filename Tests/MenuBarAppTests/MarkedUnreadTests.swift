import Foundation
import Testing
@testable import MenuBarApp

// A session the person marked to come back to: what keeps the mark, and what clears it.
@MainActor
struct MarkedUnreadTests {
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let project: Project

    init() throws {
        (store, scratch) = TestStore.make()
        project = try TestStore.project(in: store)
    }

    // The session being read is the one that gets marked, so moving on from it must not
    // count as reading it.
    @Test func leavingTheMarkedSessionKeepsTheMark() {
        let marked = store.newSession(in: project.id)
        let next = store.newSession(in: project.id)

        store.selection = .session(marked.id)
        store.setMarkedUnread(true, for: marked.id)
        store.selection = .session(next.id)
        store.applicationWillResignActive()

        #expect(store.isUnread(marked.id))
        #expect(store.hasFinished(marked.id) == false)
        #expect(store.unreadCount(in: project.id) == 1)
    }

    @Test func openingTheSessionAgainClearsIt() {
        let marked = store.newSession(in: project.id)
        let other = store.newSession(in: project.id)

        store.selection = .session(marked.id)
        store.setMarkedUnread(true, for: marked.id)
        store.selection = .session(other.id)
        store.selection = .session(marked.id)

        #expect(store.isUnread(marked.id) == false)
        #expect(store.session(marked.id)?.isMarkedUnread == false)
    }

    @Test func markingAsReadClearsAnUnseenTurnToo() {
        let background = store.newSession(in: project.id)
        let open = store.newSession(in: project.id)

        store.selection = .session(open.id)
        store.noteTurnEnded(for: background.id)
        store.markRead(background.id)

        #expect(store.isUnread(background.id) == false)
    }

    @Test func theMarkSurvivesARelaunch() throws {
        let marked = store.newSession(in: project.id)
        store.selection = .session(marked.id)
        store.setMarkedUnread(true, for: marked.id)

        Preferences.selectedSessionID = marked.id
        defer { Preferences.selectedSessionID = nil }
        let reloaded = ProjectStore(storeURL: store.storeURL)

        #expect(reloaded.isUnread(marked.id))
        #expect(reloaded.unreadCount(in: project.id) == 1)
    }

    @Test func deletingTheSessionTakesItsMarkWithIt() {
        let marked = store.newSession(in: project.id)
        store.setMarkedUnread(true, for: marked.id)
        store.removeSession(marked.id)

        #expect(store.unreadCount(in: project.id) == 0)
        #expect(store.markedUnread.isEmpty)
    }
}
