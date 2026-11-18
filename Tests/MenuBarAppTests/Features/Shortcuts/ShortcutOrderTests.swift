import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct ShortcutOrderTests {
    private let scratch = ScratchDirectory(prefix: "shortcut-order-tests")

    private func store(_ url: URL) -> ShortcutStore {
        ShortcutStore(storageURL: url, siteDefaults: SiteDefaults())
    }

    @Test func movesAnIDBeforeOrAfterAnother() {
        #expect(ShortcutStore.moving(3, beside: 1, after: false, in: [1, 2, 3]) == [3, 1, 2])
        #expect(ShortcutStore.moving(1, beside: 3, after: true, in: [1, 2, 3]) == [2, 3, 1])
        #expect(ShortcutStore.moving(1, beside: 3, after: false, in: [1, 2, 3]) == [2, 1, 3])
        #expect(ShortcutStore.moving(2, beside: 2, after: true, in: [1, 2, 3]) == [1, 2, 3])
        #expect(ShortcutStore.moving(4, beside: 1, after: false, in: [1, 2, 3]) == [1, 2, 3])
    }

    @Test func libraryMoveSetsTheDefaultOrderAndSurvivesReload() throws {
        let url = scratch.path("shortcuts.json")
        let store = store(url)
        let build = try #require(store.add(name: "Build", text: "make"))
        let test = try #require(store.add(name: "Test", text: "make test"))
        let lint = try #require(store.add(name: "Lint", text: "make lint"))

        #expect(store.moveInLibrary(lint, beside: build, after: false))
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

        #expect(store.move(deploy, beside: build, after: false, in: order(session),
                           for: .project(project)))
        #expect(store.shortcuts(for: project).map(\.id) == [deploy, build, test])
        #expect(order(session) == [deploy, build, test])

        #expect(store.move(test, beside: deploy, after: false, in: order(session),
                           for: .session(session)))
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

        #expect(store.move(test, beside: build, after: false, in: [build, test], for: .session(session)))
        #expect(store.keepSessionOrder(session, for: project))
        #expect(!store.hasOwnOrder(.session(session)))
        #expect(store.shortcuts(for: project).map(\.id) == [test, build])
    }

    @Test func aShortcutAddedLaterFollowsTheSavedOrder() throws {
        let store = store(scratch.path("shortcuts.json"))
        let project = UUID()
        let build = try #require(store.add(name: "Build", text: "make"))
        let test = try #require(store.add(name: "Test", text: "make test"))
        #expect(store.move(test, beside: build, after: false, in: [build, test], for: .project(project)))

        let lint = try #require(store.add(name: "Lint", text: "make lint"))
        #expect(store.shortcuts(for: project).map(\.id) == [test, build, lint])
    }

    @Test func discardingAScopeForgetsItsOrder() throws {
        let store = store(scratch.path("shortcuts.json"))
        let session = UUID()
        let build = try #require(store.add(name: "Build", text: "make"))
        let test = try #require(store.add(name: "Test", text: "make test"))
        #expect(store.move(test, beside: build, after: false, in: [build, test], for: .session(session)))

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
        #expect(store.move(test, beside: build, after: false, in: [build, test], for: .project(old)))

        let data = try ShortcutStore.remappingProjects(in: Data(contentsOf: url), using: [old: new])
        try data.write(to: url)
        let restored = self.store(url)
        #expect(restored.hasOwnOrder(.project(new)))
        #expect(!restored.hasOwnOrder(.project(old)))
        #expect(restored.shortcuts(for: new).map(\.id) == [test, build])
    }
}
