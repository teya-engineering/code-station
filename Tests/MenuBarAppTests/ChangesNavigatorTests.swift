import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

struct ChangesNavigatorTests {
    @Test func onlyReadyEmptyRepositoriesAreClean() {
        #expect(ChangesRepository.statusLabel(for: nil) == "Checking")
        for state: GitRepoState in [.notARepo, .missingFolder, .gitMissing, .failed("Cannot read status")] {
            #expect(ChangesRepository.statusLabel(for: GitSnapshot(state: state)) == "Unavailable")
        }
        #expect(ChangesRepository.statusLabel(for: GitSnapshot(state: .ready)) == "Clean")
    }

    @Test func changedRepositoriesCountTheirFiles() {
        let files = ["one", "two"].map {
            GitChange(path: $0, kind: .modified, isStaged: false, isUnstaged: true, isBinary: false)
        }
        #expect(ChangesRepository.statusLabel(for: GitSnapshot(state: .ready, files: [files[0]])) == "1 changed")
        #expect(ChangesRepository.statusLabel(for: GitSnapshot(state: .ready, files: files)) == "2 changed")
    }

    @Test func projectSelectionContrastInBothAppearances() throws {
        for appearance in try appearances() {
            let accent = try swatch(Theme.accent, in: appearance)
            let card = try swatch(Theme.card, in: appearance)
            let selectedProject = accent.faded(to: 0.1).over(card)
            let selectedFile = accent.faded(to: 0.06).over(card)
            #expect(accent.contrast(against: selectedProject) >= 4.5)
            #expect(accent.contrast(against: selectedFile) >= 3)
        }
    }

    @Test func identicalPathsInDifferentRepositoriesRemainDistinct() {
        let first = ChangesNavigatorItem(root: "/first", path: "README.md")
        let second = ChangesNavigatorItem(root: "/second", path: "README.md")
        #expect(first != second)
        #expect(Set([first, second]).count == 2)
    }

    @Test func keyboardNavigationIncludesCleanRepositoriesAndStopsAtEdges() {
        let repository = ChangesNavigatorItem(root: "/first", path: nil)
        let file = ChangesNavigatorItem(root: "/first", path: "README.md")
        let clean = ChangesNavigatorItem(root: "/clean", path: nil)
        let items = [repository, file, clean]
        #expect(ChangesNavigatorItem.next(after: nil, step: 1, in: items) == repository)
        #expect(ChangesNavigatorItem.next(after: repository, step: 1, in: items) == file)
        #expect(ChangesNavigatorItem.next(after: file, step: 1, in: items) == clean)
        #expect(ChangesNavigatorItem.next(after: clean, step: -1, in: items) == file)
        #expect(ChangesNavigatorItem.next(after: clean, step: 1, in: items) == nil)
        #expect(ChangesNavigatorItem.next(after: repository, step: -1, in: items) == nil)
        #expect(ChangesNavigatorItem.next(after: nil, step: 1, in: []) == nil)
    }
}

@MainActor
struct ChangesLayoutTests {
    @Test func returningToChangesKeepsTheSelectedFile() async throws {
        let repo = try GitRepo()
        try repo.write("first.txt", "First change")
        try repo.write("second.txt", "Second change")
        let snapshot = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true)
        let selected = try #require(snapshot.files.last)
        let navigation = ChangesNavigationMemory()
        var selection = ChangeFileSelection()
        selection.select(selected.id, in: snapshot.files.map(\.id), extendingRange: false, toggling: false)
        navigation.selections[repo.path] = selection
        let cache = GitStatsCache()
        let scratch = ScratchDirectory(prefix: "changes-selection")
        let settings = AppSettings(agentAvatarURL: scratch.path("avatar.png"),
                                   preferences: UserDefaults(suiteName: "changes-selection-\(UUID())")!)
        let view = ChangesView(root: repo.path, navigation: navigation)
            .environment(cache).environment(settings).environment(DialogPresenter()).appOverlays()
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.center()
        window.layoutIfNeeded()
        #expect(await waitUntil { cache.snapshot(at: repo.path) != nil })
        #expect(navigation.selections[repo.path]?.activeID == selected.id)
    }

    @Test func longRepositoryAndBranchNamesFitNarrowAndWidePanes() async throws {
        let repo = try GitRepo()
        try repo.git("switch", "-c", "feature/a-long-branch-name-for-workspace-review")
        try repo.write("README.md", "Updated content\n")
        let cache = GitStatsCache()
        let scratch = ScratchDirectory(prefix: "changes-layout")
        let settings = AppSettings(agentAvatarURL: scratch.path("avatar.png"),
                                   preferences: UserDefaults(suiteName: "changes-layout-\(UUID())")!)
        let view = ChangesView(root: repo.path, repositories: [
            ChangesRepository(root: repo.path, name: "a-long-workspace-repository-name"),
            ChangesRepository(root: "/clean", name: "clean-repository")
        ], navigation: ChangesNavigationMemory())
        .environment(cache)
        .environment(settings)
        .environment(DialogPresenter())
        .appOverlays()
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.center()
        window.layoutIfNeeded()
        #expect(await waitUntil { cache.snapshot(at: repo.path) != nil })
        for width: CGFloat in [600, 1000] {
            #expect(hosting.sizeThatFits(in: CGSize(width: width, height: 700)).width <= width)
            if let destination = ProcessInfo.processInfo.environment["WORKSPACE_REVIEW_DIRECTORY"] {
                hosting.view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
                hosting.view.layoutSubtreeIfNeeded()
                let bitmap = try #require(hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds))
                hosting.view.cacheDisplay(in: hosting.view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: destination).appendingPathComponent("changes-\(Int(width)).png"))
            }
        }
    }
}
