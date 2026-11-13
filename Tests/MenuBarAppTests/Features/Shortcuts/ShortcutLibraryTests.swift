import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct ShortcutLibraryTests {
    private let scratch = ScratchDirectory(prefix: "shortcut-library-tests")

    @Test func favoritesKeepSavedOrderAcrossSearchAndReloads() throws {
        let url = scratch.path("shortcuts.json")
        let store = ShortcutStore(storageURL: url, siteDefaults: SiteDefaults())
        let first = Shortcut(name: "Build", text: "make")
        let second = Shortcut(name: "Rebuild", text: "make clean build")
        let third = Shortcut(name: "Tests", text: "make test")
        for shortcut in [first, second, third] { #expect(store.saveShortcut(shortcut)) }

        #expect(store.toggleFavorite(third.id))
        #expect(store.toggleFavorite(second.id))
        #expect(store.libraryShortcuts().map(\.id) == [second.id, third.id, first.id])
        #expect(store.libraryShortcuts(query: "build").map(\.id) == [second.id, first.id])
        #expect(store.shortcuts.map(\.id) == [first.id, second.id, third.id])

        let reloaded = ShortcutStore(storageURL: url, siteDefaults: SiteDefaults())
        #expect(reloaded.libraryShortcuts().map(\.id) == [second.id, third.id, first.id])
        #expect(reloaded.toggleFavorite(third.id))
        #expect(reloaded.libraryShortcuts().map(\.id) == [second.id, first.id, third.id])
    }

    @Test func favoriteChangesDoNotOverwriteAnOpenDraft() {
        let store = ShortcutStore(storageURL: scratch.path("shortcuts.json"), siteDefaults: SiteDefaults())
        let shortcut = Shortcut(name: "Tests", text: "make test")
        #expect(store.saveShortcut(shortcut))
        let draft = ShortcutDraft(request: ShortcutEditorRequest(shortcut: shortcut))
        draft.value.text = "make test-all"
        #expect(store.toggleFavorite(shortcut.id))
        #expect(draft.isDirty)
        #expect(draft.value.text == "make test-all")
        #expect(store.saveShortcut(draft.shortcut))
        #expect(store.shortcut(shortcut.id)?.favorite == true)
        #expect(store.shortcut(shortcut.id)?.text == "make test-all")
    }

    @Test func oldCommandsAreNotFavorites() throws {
        let data = Data("""
        {"id":"\(UUID())", "name":"Build", "command":"make"}
        """.utf8)
        let shortcut = try JSONDecoder().decode(Shortcut.self, from: data)
        #expect(!shortcut.favorite)
    }

    @Test func draftPreservesItsIdentityAndPrivateScope() {
        let project = UUID()
        let original = Shortcut(name: "Build", text: "make", projectID: project)
        let draft = ShortcutDraft(request: ShortcutEditorRequest(shortcut: original))
        draft.value.name = "  Tests  "
        draft.value.text = "  make test  "
        draft.value.availableInAllProjects = true
        #expect(draft.shortcut.projectID == nil)
        #expect(draft.shortcut.id == original.id)
        #expect(draft.shortcut.name == "Tests")
        #expect(draft.shortcut.text == "make test")
        draft.value.availableInAllProjects = false
        #expect(draft.shortcut.projectID == project)
        draft.reset()
        #expect(draft.value == original)
        #expect(!draft.isDirty)
    }

    @Test func theListPreviewsEditsBeforeTheyAreSaved() {
        let qwen = Shortcut(name: "Qwen", text: "ollama run qwen")
        let maven = Shortcut(name: "Maven", text: "./mvnw verify", availableInAllProjects: true)
        var draft = qwen
        draft.name = "Renamed"
        draft.availableInAllProjects = true
        let previewed = ShortcutsView.previewing(draft, in: [qwen, maven])
        #expect(previewed.map(\.availableInAllProjects) == [true, true])
        #expect(previewed[0].name == "Renamed")
        #expect(ShortcutsView.previewing(nil, in: [qwen, maven]) == [qwen, maven])
    }

    @Test func theScopePickerNamesTheNarrowChoiceAfterItsProject() {
        #expect(ShortcutScopePicker.narrowTitle(projectName: nil) == "Shortcuts window only")
        #expect(ShortcutScopePicker.narrowTitle(projectName: "Billing") == "Billing only")
        #expect(ShortcutScopePicker.help(availableInAllProjects: false, projectName: nil)
                == "Only listed here. Projects and sessions do not show it.")
        #expect(ShortcutScopePicker.help(availableInAllProjects: true, projectName: "Billing")
                .hasPrefix("Shows in every project"))
    }

    @Test func aNamedNewDraftStartsCleanAndWaitsForACommand() {
        let draft = ShortcutDraft(request: ShortcutEditorRequest(name: "New Shortcut"))
        #expect(draft.isNew)
        #expect(draft.value.name == "New Shortcut")
        #expect(!draft.isDirty)
        #expect(!draft.canSave)
        draft.value.text = "make"
        #expect(draft.canSave)
    }

    @Test func failedSaveKeepsTheLibraryAndDraftIntact() throws {
        let url = scratch.path("shortcuts.json")
        try Data("invalid".utf8).write(to: url)
        let store = ShortcutStore(storageURL: url, siteDefaults: SiteDefaults())
        let draft = ShortcutDraft(request: ShortcutEditorRequest())
        draft.value.name = "Build"
        draft.value.text = "make"
        #expect(!store.saveShortcut(draft.shortcut))
        #expect(store.shortcuts.isEmpty)
        #expect(draft.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "invalid")
    }

    @Test func switchingTypesKeepsSeparateBuffersAndTheName() {
        let project = UUID()
        let draft = ShortcutDraft(request: ShortcutEditorRequest(projectID: project,
                                                                 text: "Review the diff", kind: .prompt))
        draft.value.name = "Review"
        draft.selectKind(.command)
        #expect(draft.value.text.isEmpty)
        #expect(!draft.canSave)
        draft.value.text = "make test"
        draft.selectKind(.prompt)
        #expect(draft.value.text == "Review the diff")
        #expect(draft.value.name == "Review")
        #expect(draft.shortcut.projectID == project)
        draft.selectKind(.command)
        #expect(draft.value.text == "make test")
        draft.reset()
        draft.selectKind(.command)
        #expect(draft.value.text.isEmpty)
    }

    @Test func savedDraftNeedsChangesAndGlobalDraftsAreAlwaysShared() {
        let shortcut = Shortcut(name: "Review", text: "Review the diff", kind: .prompt)
        let draft = ShortcutDraft(request: ShortcutEditorRequest(shortcut: shortcut))
        #expect(!draft.canSave)
        #expect(draft.shortcut.availableInAllProjects)
        draft.value.text += " and tests"
        #expect(draft.canSave)
        draft.accept(draft.shortcut)
        #expect(!draft.canSave)
    }

    @Test func typeFiltersSearchBothNamesAndBodiesAndKeepFavoritesFirst() {
        let store = ShortcutStore(storageURL: scratch.path("shortcuts.json"), siteDefaults: SiteDefaults())
        let command = Shortcut(name: "Review", text: "make review")
        let prompt = Shortcut(name: "Review changes", text: "Review the diff", kind: .prompt)
        let favorite = Shortcut(name: "Explain", text: "Review this code", kind: .prompt, favorite: true)
        for shortcut in [command, prompt, favorite] { #expect(store.saveShortcut(shortcut)) }
        #expect(store.libraryShortcuts(query: "review", kind: .prompt).map(\.id) == [favorite.id, prompt.id])
        #expect(store.libraryShortcuts(kind: .command).map(\.id) == [command.id])
        #expect(store.libraryShortcuts(query: "missing").isEmpty)
    }

    @Test(arguments: [ShortcutKind.command, .prompt], [ColorScheme.light, .dark])
    func sheetKeepsItsWidthOverANarrowWindow(kind: ShortcutKind, appearance: ColorScheme) throws {
        let store = ShortcutStore(storageURL: scratch.path("shortcuts.json"), siteDefaults: SiteDefaults())
        let examples = [
            Shortcut(name: kind == .prompt ? "Review changes" : "Qwen 3",
                     text: kind == .prompt ? "Review the current diff for bugs, missing edge cases, and unclear behavior."
                         : "ollama run qwen3.8:27b-mlx", kind: kind, icon: kind.icon),
            Shortcut(name: "Teleport", text: "./teleport.sh", icon: "cylinder.split.1x2", availableInAllProjects: true),
            Shortcut(name: "Maven Build", text: "./mvnw clean verify", icon: "hammer", availableInAllProjects: true),
            Shortcut(name: "Tests", text: "./mvnw test", icon: "ladybug", availableInAllProjects: true)
        ]
        for shortcut in examples { #expect(store.saveShortcut(shortcut)) }
        let host = NSHostingView(rootView: ShortcutsView()
            .environment(\.colorScheme, appearance)
            .environment(store)
            .appOverlays())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 780),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.center()
        window.contentView = host
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == 960)
        #expect(host.frame.height <= 780)
        if let directory = ProcessInfo.processInfo.environment["SHORTCUT_SNAPSHOTS"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("shortcuts-\(kind.rawValue)-\(appearance == .dark ? "dark" : "light").png"))
        }
    }
}
