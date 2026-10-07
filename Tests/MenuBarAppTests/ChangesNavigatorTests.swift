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
        ])
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
        }
    }
}
