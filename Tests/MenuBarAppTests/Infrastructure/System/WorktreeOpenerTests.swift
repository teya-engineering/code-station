import Foundation
import Testing
@testable import MenuBarApp

// The "Open in" button always has to point at an app that is really there, and the menu
// behind it has to list each app once.
@MainActor
struct WorktreeOpenerTests {
    private func app(_ id: String, _ name: String) -> WorktreeApp {
        WorktreeApp(bundleID: id, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"))
    }

    private var cursor: WorktreeApp { app("com.todesktop.230313mzl4w4u92", "Cursor") }
    private var finder: WorktreeApp { app(WorktreeOpener.finderID, "Finder") }
    private var ghostty: WorktreeApp { app("com.mitchellh.ghostty", "Ghostty") }

    @Test func opensInTheAppPickedLast() {
        let apps = [cursor, finder, ghostty]
        #expect(WorktreeOpener.chosen(from: apps, saved: ghostty.bundleID) == ghostty)
    }

    @Test func opensInFinderUntilAnotherAppIsPicked() {
        #expect(WorktreeOpener.chosen(from: [cursor, finder], saved: nil) == finder)
    }

    // An app removed after it was picked would leave the button doing nothing.
    @Test func fallsBackToFinderWhenThePickedAppIsGone() {
        #expect(WorktreeOpener.chosen(from: [cursor, finder], saved: "com.example.gone") == finder)
    }

    @Test func listsEditorsThenFinderThenTheTerminal() {
        let apps = WorktreeOpener.ordered(editors: [cursor], finder: finder, terminal: ghostty)
        #expect(apps == [cursor, finder, ghostty])
    }

    @Test func listsAnAppOnlyOnceWhenItIsBothEditorAndTerminal() {
        let apps = WorktreeOpener.ordered(editors: [cursor, ghostty], finder: finder,
                                          terminal: ghostty)
        #expect(apps == [cursor, ghostty, finder])
    }
}
