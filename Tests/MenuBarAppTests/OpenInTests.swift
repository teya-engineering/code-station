import Foundation
import Testing
@testable import CodeStationCore

// The "Open in" button always has to point at an app that is really there, and the menu
// behind it has to list each app once.
@MainActor
struct OpenInTests {
    private func app(_ id: String, _ name: String) -> OpenInApp {
        OpenInApp(bundleID: id, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"))
    }

    private var cursor: OpenInApp { app("com.todesktop.230313mzl4w4u92", "Cursor") }
    private var finder: OpenInApp { app(OpenIn.finderID, "Finder") }
    private var ghostty: OpenInApp { app("com.mitchellh.ghostty", "Ghostty") }

    @Test func opensInTheAppPickedLast() {
        let apps = [cursor, finder, ghostty]
        #expect(OpenIn.chosen(from: apps, saved: ghostty.bundleID) == ghostty)
    }

    @Test func opensInFinderUntilAnotherAppIsPicked() {
        #expect(OpenIn.chosen(from: [cursor, finder], saved: nil) == finder)
    }

    // An app removed after it was picked would leave the button doing nothing.
    @Test func fallsBackToFinderWhenThePickedAppIsGone() {
        #expect(OpenIn.chosen(from: [cursor, finder], saved: "com.example.gone") == finder)
    }

    @Test func listsEditorsThenFinderThenTheTerminal() {
        let apps = OpenIn.ordered(editors: [cursor], finder: finder, terminal: ghostty)
        #expect(apps == [cursor, finder, ghostty])
    }

    @Test func listsAnAppOnlyOnceWhenItIsBothEditorAndTerminal() {
        let apps = OpenIn.ordered(editors: [cursor, ghostty], finder: finder,
                                          terminal: ghostty)
        #expect(apps == [cursor, ghostty, finder])
    }
}
