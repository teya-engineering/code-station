import AppKit
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

@MainActor
struct WorktreeOpenerAddedAppTests {
    private let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    private let textEditID = "com.apple.TextEdit"

    @Test(arguments: [false, true])
    func anUnregisteredAppIsListedAndChosen(alreadySaved: Bool) throws {
        let saved = (Preferences.openInBundleID(), Preferences.openInAddedBundleIDs(),
                     Preferences.openInAddedAppPaths())
        defer {
            Preferences.setOpenInBundleID(saved.0)
            Preferences.setOpenInAddedBundleIDs(saved.1)
            Preferences.setOpenInAddedAppPaths(saved.2)
            WorktreeOpener.refresh()
        }
        let scratch = ScratchDirectory(prefix: "open-in-app")
        let url = scratch.path("Editor.app")
        let contents = url.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/editor")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let id = "com.example.open-in-\(UUID().uuidString.lowercased())"
        let info = ["CFBundleIdentifier": id, "CFBundleName": "Editor",
                    "CFBundleExecutable": "editor", "CFBundlePackageType": "APPL",
                    "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        #expect(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil)
        Preferences.setOpenInAddedBundleIDs(alreadySaved ? [id] : [])
        WorktreeOpener.refresh()
        #expect(!WorktreeOpener.apps.contains { $0.bundleID == id })

        let added = try #require(WorktreeOpener.add(appAt: url))

        #expect(added.bundleID == id)
        #expect(added.url.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path)
        #expect(Preferences.openInAddedBundleIDs().filter { $0 == id }.count == 1)
        #expect(WorktreeOpener.addedApps.contains { $0.bundleID == id })
        WorktreeOpener.refresh()
        #expect(WorktreeOpener.current?.bundleID == id)
        try FileManager.default.removeItem(at: url)
        WorktreeOpener.refresh()
        #expect(WorktreeOpener.current?.bundleID == WorktreeOpener.finderID)
        WorktreeOpener.remove(id)
        #expect(Preferences.openInAddedAppPaths()[id] == nil)
        #expect(!WorktreeOpener.apps.contains { $0.bundleID == id })
    }

    @Test func anInvalidAppKeepsTheCurrentChoice() {
        let saved = (Preferences.openInBundleID(), Preferences.openInAddedBundleIDs(),
                     Preferences.openInAddedAppPaths())
        let scratch = ScratchDirectory(prefix: "open-in-invalid-app")

        #expect(WorktreeOpener.add(appAt: scratch.path("Missing.app")) == nil)
        #expect(Preferences.openInBundleID() == saved.0)
        #expect(Preferences.openInAddedBundleIDs() == saved.1)
        #expect(Preferences.openInAddedAppPaths() == saved.2)
    }

    @Test func anAddedAppIsListedAndChosen() {
        let saved = (Preferences.openInBundleID(), Preferences.openInAddedBundleIDs(),
                     Preferences.openInAddedAppPaths())
        defer {
            Preferences.setOpenInBundleID(saved.0)
            Preferences.setOpenInAddedBundleIDs(saved.1)
            Preferences.setOpenInAddedAppPaths(saved.2)
            WorktreeOpener.refresh()
        }

        let added = WorktreeOpener.add(appAt: textEdit)

        #expect(added?.bundleID == textEditID)
        #expect(WorktreeOpener.apps.contains { $0.bundleID == textEditID })
        #expect(WorktreeOpener.current?.bundleID == textEditID)
    }

    @Test func removingTheChosenAppFallsBackToFinder() {
        let saved = (Preferences.openInBundleID(), Preferences.openInAddedBundleIDs(),
                     Preferences.openInAddedAppPaths())
        defer {
            Preferences.setOpenInBundleID(saved.0)
            Preferences.setOpenInAddedBundleIDs(saved.1)
            Preferences.setOpenInAddedAppPaths(saved.2)
            WorktreeOpener.refresh()
        }

        WorktreeOpener.add(appAt: textEdit)
        WorktreeOpener.remove(textEditID)

        #expect(!WorktreeOpener.apps.contains { $0.bundleID == textEditID })
        #expect(WorktreeOpener.current?.bundleID == WorktreeOpener.finderID)
    }
}
