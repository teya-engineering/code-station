import Foundation
import Testing
@testable import MenuBarApp

// What the header's button and the terminal key ask of the drawer, and where each one
// leaves the cursor. Every screen goes through these, so they decide the behaviour once.
@MainActor
struct TerminalDrawerFocusTests {

    private let scope = TerminalScope.project(UUID())
    private let directory = FileManager.default.temporaryDirectory.path

    // Every shell here is noted in a scratch registry, never in the folder the real app
    // reaps from.
    private func makeStore() -> TerminalStore {
        TerminalStore(registry: ShellRegistry(directory: ShellNotes.scratch()))
    }

    private func closeShells(in store: TerminalStore) {
        for terminal in store.sessions(for: scope) { store.close(terminal, in: scope) }
    }

    @Test func theButtonOpensAShutDrawerIntoTheShell() {
        let store = makeStore()
        defer { closeShells(in: store) }

        #expect(store.toggle(scope, directory: directory) == .shell)
        #expect(store.isOpen(scope))
        #expect(store.sessions(for: scope).count == 1)
    }

    @Test func theButtonShutsAnOpenDrawerAndSendsTheCursorBack() {
        let store = makeStore()
        defer { closeShells(in: store) }
        _ = store.toggle(scope, directory: directory)

        #expect(store.toggle(scope, directory: directory) == .back)
        #expect(!store.isOpen(scope))
    }

    // The key only reaches the screen from outside the shell, so it never shuts the
    // drawer there: it opens a shut one and takes the cursor into an open one.
    @Test func theKeyFromOutsideTheShellAlwaysLandsInTheShell() {
        let store = makeStore()
        defer { closeShells(in: store) }

        #expect(store.reveal(scope, directory: directory) == .shell)
        #expect(store.isOpen(scope))
        #expect(store.reveal(scope, directory: directory) == .shell)
        #expect(store.isOpen(scope))
        #expect(store.sessions(for: scope).count == 1, "an open drawer gets no second shell")
    }

    // Putting the drawer away leaves its shell running, so the next open finds it.
    @Test func dismissingKeepsTheShellForNextTime() {
        let store = makeStore()
        defer { closeShells(in: store) }
        _ = store.reveal(scope, directory: directory)
        let shell = store.sessions(for: scope).first

        #expect(store.dismiss(scope) == .back)
        #expect(!store.isOpen(scope))
        _ = store.reveal(scope, directory: directory)
        #expect(store.sessions(for: scope).first?.id == shell?.id)
    }
}
