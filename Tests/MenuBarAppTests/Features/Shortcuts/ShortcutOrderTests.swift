import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct ShortcutOrderTests {
    private let scratch = ScratchDirectory(prefix: "shortcut-order-tests")

    private func store(_ url: URL) -> ShortcutStore {
        ShortcutStore(storageURL: url, siteDefaults: SiteDefaults())
    }

    @Test func movesAnIDToAPosition() {
        #expect(ShortcutStore.moving(3, to: 0, in: [1, 2, 3]) == [3, 1, 2])
        #expect(ShortcutStore.moving(1, to: 2, in: [1, 2, 3]) == [2, 3, 1])
        #expect(ShortcutStore.moving(1, to: 1, in: [1, 2, 3]) == [2, 1, 3])
        #expect(ShortcutStore.moving(2, to: 1, in: [1, 2, 3]) == [1, 2, 3])
        #expect(ShortcutStore.moving(2, to: 9, in: [1, 2, 3]) == [1, 3, 2])
        #expect(ShortcutStore.moving(2, to: -1, in: [1, 2, 3]) == [2, 1, 3])
        #expect(ShortcutStore.moving(4, to: 0, in: [1, 2, 3]) == [1, 2, 3])
    }

    @Test func libraryMoveSetsTheDefaultOrderAndSurvivesReload() throws {
        let url = scratch.path("shortcuts.json")
        let store = store(url)
        let build = try #require(store.add(name: "Build", text: "make"))
        let test = try #require(store.add(name: "Test", text: "make test"))
        let lint = try #require(store.add(name: "Lint", text: "make lint"))

        #expect(store.moveInLibrary(lint, to: 0))
        #expect(store.libraryShortcuts().map(\.id) == [lint, build, test])
        #expect(store.shortcuts(for: UUID()).map(\.id) == [lint, build, test])
        #expect(self.store(url).libraryShortcuts().map(\.id) == [lint, build, test])
    }

    @Test func sessionOrderOverridesProjectOrderWhichOverridesTheDefault() throws {
        let url = scratch.path("shortcuts.json")
        let store = store(url)
        let project = UUID()
        let session = UUID()
        let otherSession = UUID()
        let build = try #require(store.add(name: "Build", text: "make"))
        let test = try #require(store.add(name: "Test", text: "make test"))
        let deploy = try #require(store.add(name: "Deploy", text: "make deploy", projectID: project))

        func order(_ session: UUID) -> [UUID] {
            store.shortcuts(for: [project], session: session).map(\.shortcut.id)
        }

        #expect(order(session) == [build, test, deploy])

        #expect(store.move(deploy, to: 0, in: order(session), for: .project(project)))
        #expect(store.shortcuts(for: project).map(\.id) == [deploy, build, test])
        #expect(order(session) == [deploy, build, test])

        #expect(store.move(test, to: 0, in: order(session), for: .session(session)))
        #expect(order(session) == [test, deploy, build])
        #expect(order(otherSession) == [deploy, build, test])
        #expect(store.libraryShortcuts().map(\.id) == [build, test])

        let reloaded = self.store(url)
        #expect(reloaded.shortcuts(for: [project], session: session).map(\.shortcut.id) == [test, deploy, build])

        #expect(store.resetOrder(for: .session(session)))
        #expect(order(session) == [deploy, build, test])
        #expect(store.resetOrder(for: .project(project)))
        #expect(order(session) == [build, test, deploy])
    }

    @Test func aSessionOrderCanBecomeTheProjectOrder() throws {
        let store = store(scratch.path("shortcuts.json"))
        let project = UUID()
        let session = UUID()
        let build = try #require(store.add(name: "Build", text: "make"))
        let test = try #require(store.add(name: "Test", text: "make test"))

        #expect(store.move(test, to: 0, in: [build, test], for: .session(session)))
        #expect(store.keepSessionOrder(session, for: project))
        #expect(!store.hasOwnOrder(.session(session)))
        #expect(store.shortcuts(for: project).map(\.id) == [test, build])
    }

    @Test func aShortcutAddedLaterFollowsTheSavedOrder() throws {
        let store = store(scratch.path("shortcuts.json"))
        let project = UUID()
        let build = try #require(store.add(name: "Build", text: "make"))
        let test = try #require(store.add(name: "Test", text: "make test"))
        #expect(store.move(test, to: 0, in: [build, test], for: .project(project)))

        let lint = try #require(store.add(name: "Lint", text: "make lint"))
        #expect(store.shortcuts(for: project).map(\.id) == [test, build, lint])
    }

    @Test func followingTheSavedOrderClearsEveryOwnOrder() throws {
        let url = scratch.path("shortcuts.json")
        let store = store(url)
        let project = UUID()
        let session = UUID()
        let build = try #require(store.add(name: "Build", text: "make"))
        let test = try #require(store.add(name: "Test", text: "make test"))
        #expect(!store.hasOwnOrders)
        #expect(store.move(test, to: 0, in: [build, test], for: .project(project)))
        #expect(store.move(test, to: 0, in: [build, test], for: .session(session)))
        #expect(store.hasOwnOrders)

        #expect(store.clearOwnOrders())
        #expect(!store.hasOwnOrders)
        #expect(store.shortcuts(for: [project], session: session).map(\.shortcut.id) == [build, test])
        #expect(!self.store(url).hasOwnOrders)
    }

    @Test func discardingAScopeForgetsItsOrder() throws {
        let store = store(scratch.path("shortcuts.json"))
        let session = UUID()
        let build = try #require(store.add(name: "Build", text: "make"))
        let test = try #require(store.add(name: "Test", text: "make test"))
        #expect(store.move(test, to: 0, in: [build, test], for: .session(session)))

        store.discard(.session(session))
        #expect(!store.hasOwnOrder(.session(session)))
    }

    @Test func restoringABackupMovesProjectOrdersToTheNewProject() throws {
        let url = scratch.path("shortcuts.json")
        let store = store(url)
        let old = UUID()
        let new = UUID()
        let build = try #require(store.add(name: "Build", text: "make"))
        let test = try #require(store.add(name: "Test", text: "make test"))
        #expect(store.move(test, to: 0, in: [build, test], for: .project(old)))

        let data = try ShortcutStore.remappingProjects(in: Data(contentsOf: url), using: [old: new])
        try data.write(to: url)
        let restored = self.store(url)
        #expect(restored.hasOwnOrder(.project(new)))
        #expect(!restored.hasOwnOrder(.project(old)))
        #expect(restored.shortcuts(for: new).map(\.id) == [test, build])
    }
}

@MainActor
struct ShortcutLibraryOrderTests {
    private let scratch = ScratchDirectory(prefix: "shortcut-library-order-tests")

    // Settings shows only the shared shortcuts, so a move there must not shift a
    // project's own shortcut out of its place in the saved file.
    @Test func libraryMovesLeaveProjectShortcutsInPlace() throws {
        let store = ShortcutStore(storageURL: scratch.path("shortcuts.json"), siteDefaults: SiteDefaults())
        let project = UUID()
        let build = try #require(store.add(name: "Build", text: "make"))
        let deploy = try #require(store.add(name: "Deploy", text: "make deploy", projectID: project))
        let test = try #require(store.add(name: "Test", text: "make test"))

        #expect(store.moveInLibrary(test, to: 0))
        #expect(store.shortcuts.map(\.id) == [test, deploy, build])
        #expect(store.libraryShortcuts().map(\.id) == [test, build])
        #expect(!store.moveInLibrary(test, to: 0))
    }

    // Stars kept shortcuts on top before order decided the button, so the first load
    // puts the starred ones first and stops writing stars.
    @Test func starsBecomeOrderOnceAndAreNotWrittenAgain() throws {
        let url = scratch.path("shortcuts.json")
        let build = UUID(), review = UUID(), lint = UUID()
        try Data("""
        {"shortcuts":[
          {"id":"\(build)","name":"Build","command":"make"},
          {"id":"\(review)","name":"Review","command":"Review this","kind":"prompt","favorite":true},
          {"id":"\(lint)","name":"Lint","command":"make lint","favorite":false}
        ]}
        """.utf8).write(to: url)

        let store = ShortcutStore(storageURL: url, siteDefaults: SiteDefaults())
        #expect(store.libraryShortcuts().map(\.id) == [review, build, lint])
        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(!saved.contains("favorite"))

        #expect(store.moveInLibrary(lint, to: 0))
        let reloaded = ShortcutStore(storageURL: url, siteDefaults: SiteDefaults())
        #expect(reloaded.libraryShortcuts().map(\.id) == [lint, review, build])
    }

    // The dragged row lands where its middle passes a neighbour's middle, and the rows it
    // passes make exactly its own room.
    @Test func liveReorderTargetsAndShifts() {
        let a = UUID(), b = UUID(), c = UUID()
        var state = LiveReorder()
        state.measure(a, height: 40)
        state.measure(b, height: 40)
        state.measure(c, height: 40)
        state.begin(a, in: [a, b, c], spacing: 8)

        state.follow(20)
        #expect(state.target == 0)
        #expect(state.preview([a, b, c]) == [a, b, c])
        state.follow(30)
        #expect(state.target == 1)
        #expect(state.shift(of: b) == -48)
        #expect(state.shift(of: c) == 0)
        #expect(state.preview([a, b, c]) == [b, a, c])
        state.follow(80)
        #expect(state.target == 2)
        #expect(state.shift(of: c) == -48)
        state.follow(-30)
        #expect(state.target == 0)

        state.end()
        #expect(!state.isDragging)
        #expect(state.shift(of: b) == 0)
    }
}
