import Foundation
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct NavigationHistoryTests {
    private let store: ProjectStore
    private let scratch: ScratchDirectory

    init() {
        (store, scratch) = TestStore.make()
        Preferences.selectedSessionID = nil
        Preferences.selectedWorkspaceID = nil
        Preferences.selectedProjectID = nil
    }

    @Test func retracesTheTrailAndGoesForwardAgain() throws {
        let first = try TestStore.project(in: store, named: "api")
        let second = try TestStore.project(in: store, named: "web")
        let session = store.newSession(in: first.id)

        store.selectProject(first.id)
        store.selectSession(session.id)
        store.selectProject(second.id)

        #expect(store.canGoBack)
        #expect(!store.canGoForward)

        #expect(store.goBack())
        #expect(store.selection == .session(session.id))
        #expect(store.goBack())
        #expect(store.selection == nil)
        #expect(store.selectedProjectID == first.id)

        #expect(store.canGoForward)
        #expect(store.goForward())
        #expect(store.selection == .session(session.id))
        #expect(store.goForward())
        #expect(store.selectedProjectID == second.id)
        #expect(!store.canGoForward)
    }

    @Test func arrivingSomewhereNewDropsWhatWasAhead() throws {
        let project = try TestStore.project(in: store, named: "api")
        let first = store.newSession(in: project.id)
        let second = store.newSession(in: project.id)
        let third = store.newSession(in: project.id)

        store.selectSession(first.id)
        store.selectSession(second.id)
        #expect(store.goBack())
        #expect(store.selection == .session(first.id))

        store.selectSession(third.id)
        #expect(!store.canGoForward)
        #expect(store.goBack())
        #expect(store.selection == .session(first.id))
    }

    // Opening what is already open is not a move, so the trail must not fill with copies
    // of it and swallow the way back.
    @Test func openingTheSamePlaceTwiceIsNotAMove() throws {
        let project = try TestStore.project(in: store, named: "api")
        let first = store.newSession(in: project.id)
        let second = store.newSession(in: project.id)

        store.selectSession(first.id)
        store.selectSession(second.id)
        store.selectSession(second.id)
        store.selectSession(second.id)

        #expect(store.goBack())
        #expect(store.selection == .session(first.id))
    }

    @Test func walksPastPlacesThatHaveLeftTheApp() throws {
        let project = try TestStore.project(in: store, named: "api")
        let kept = store.newSession(in: project.id)
        let deleted = store.newSession(in: project.id)
        let latest = store.newSession(in: project.id)

        store.selectSession(kept.id)
        store.selectSession(deleted.id)
        store.selectSession(latest.id)
        _ = store.removeSession(deleted.id)
        #expect(store.session(deleted.id) == nil)

        #expect(store.goBack())
        #expect(store.selection == .session(kept.id))
    }

    @Test func aTrailWithNothingLeftInItGoesNowhere() throws {
        let project = try TestStore.project(in: store, named: "api")
        let session = store.newSession(in: project.id)

        store.selectSession(session.id)
        #expect(!store.goBack())
        #expect(!store.goForward())
        #expect(store.selection == .session(session.id))
    }

    @Test func theTrailIsCappedAtItsLimit() {
        var history = NavigationHistory()
        for _ in 0..<(NavigationHistory.limit + 50) {
            history.visit(.session(UUID()))
        }
        #expect(history.back.count == NavigationHistory.limit)
    }
}
