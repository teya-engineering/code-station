import Foundation
import Testing
@testable import MenuBarApp

// A session title is either taken from the first prompt or typed by hand. Once it is
// typed, nothing the conversation does may take it back.
@MainActor
struct SessionRenameTests {
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let session: ChatSession

    init() throws {
        (store, scratch) = TestStore.make()
        session = store.newSession(in: try TestStore.project(in: store).id)
    }

    @Test func renamingKeepsTheNameAcrossLaunches() throws {
        store.renameSession(session.id, to: "  Ship the release  ")

        #expect(store.session(session.id)?.title == "Ship the release")
        #expect(store.sidebarSession(session.id)?.title == "Ship the release")
        #expect(store.save())
        #expect(ProjectStore(storeURL: store.storeURL).session(session.id)?.title
                == "Ship the release")
    }

    @Test func anEmptyNameIsNotAName() throws {
        store.renameSession(session.id, to: "Ship the release")

        store.renameSession(session.id, to: "   ")

        #expect(store.session(session.id)?.title == "Ship the release")
    }

    @Test func theFirstPromptLeavesATypedNameAlone() throws {
        store.renameSession(session.id, to: "Ship the release")

        store.append(ChatMessage(role: .user, text: "Fix the flaky login test"), to: session.id)

        #expect(store.session(session.id)?.title == "Ship the release")
    }

    // Pasted terminal output is mostly padding, and a title made of blanks says nothing.
    @Test func aPastedPromptDoesNotBecomeATitleOfBlanks() throws {
        store.append(ChatMessage(role: .user, text: "s%\t   \(String(repeating: " ", count: 40))done"),
                     to: session.id)

        #expect(store.session(session.id)?.title == "s% done")
    }
}
