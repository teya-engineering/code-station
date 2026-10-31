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
    @Test func historyDetailFitsNarrowPanesWithLargeDiffText() async throws {
        let repo = try GitRepo()
        try repo.write("README.md", "Updated content\nAnother line\n")
        try repo.commit("Preserve the summary while reading commit details")
        let commit = try #require(await GitInspector.recentCommits(at: repo.path).commits.first)
        let navigation = ChangesNavigationMemory()
        navigation.showingHistory = true
        navigation.history(for: repo.path).select(commit)
        let scratch = ScratchDirectory(prefix: "history-layout")
        let settings = AppSettings(agentAvatarURL: scratch.path("avatar.png"),
                                   preferences: UserDefaults(suiteName: "history-layout-\(UUID())")!)
        settings.textSize = .larger
        let host = NSHostingController(rootView: ChangesView(root: repo.path, navigation: navigation)
            .environment(GitStatsCache()).environment(settings).environment(DialogPresenter()).appOverlays())
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = host
        window.center()
        window.layoutIfNeeded()
        #expect(await waitUntil { navigation.history(for: repo.path).parent != nil })
        for width: CGFloat in [1000, 600] {
            let size = CGSize(width: width, height: 700)
            window.setContentSize(size)
            try await Task.sleep(for: .milliseconds(200))
            host.view.layoutSubtreeIfNeeded()
            #expect(host.sizeThatFits(in: size).width <= width)
            #expect(navigation.history(for: repo.path).commit?.id == commit.id)
            if let folder = ProcessInfo.processInfo.environment["WORKSPACE_REVIEW_DIRECTORY"] {
                let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent("history-large-\(Int(width)).png"))
            }
        }
        window.contentViewController = nil
    }

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

    @Test func pickingAFileInAnotherProjectKeepsTheNavigatorWhereItWas() async throws {
        let first = try GitRepo()
        for index in 0..<40 { try first.write("file-\(index).txt", "Change \(index)") }
        let second = try GitRepo()
        try second.write("README.md", "Updated content\n")
        let cache = GitStatsCache()
        cache.store(await GitInspector.snapshot(at: second.path, comparingToLastCommit: true), at: second.path)
        let navigation = ChangesNavigationMemory()
        let switcher = ProjectSwitcher(root: first.path)
        let scratch = ScratchDirectory(prefix: "changes-switch")
        let settings = AppSettings(agentAvatarURL: scratch.path("avatar.png"),
                                   preferences: UserDefaults(suiteName: "changes-switch-\(UUID())")!)
        let view = SwitchingChangesView(switcher: switcher, navigation: navigation, repositories: [
            ChangesRepository(root: first.path, name: "first"),
            ChangesRepository(root: second.path, name: "second")
        ])
        .environment(cache).environment(settings).environment(DialogPresenter()).appOverlays()
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.center()
        window.layoutIfNeeded()
        #expect(await waitUntil { navigation.selections[first.path]?.activeID != nil })

        func navigator() -> NSScrollView? {
            scrollViews(in: hosting.view).first { $0.convert($0.bounds, to: nil).minX < 100 && $0.bounds.width > 200 }
        }
        #expect(await waitUntil(timeout: .seconds(3)) {
            hosting.view.layoutSubtreeIfNeeded()
            return navigator().map { $0.documentView!.frame.height > 1000 } ?? false
        })
        let scrollView = try #require(navigator())
        func bottom() -> CGFloat { scrollView.documentView!.frame.height - scrollView.contentView.bounds.height }
        #expect(bottom() > 200)
        let wheelEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                              wheelCount: 1, wheel1: -200, wheel2: 0, wheel3: 0))
        let wheel = try #require(NSEvent(cgEvent: wheelEvent))
        // The list is lazy, so rows get their real height only as they come into view and the
        // end moves while the list is scrolled down. It moves further with the always-shown
        // scroll bars a Mac without a trackpad uses, because they make the rows narrower.
        var lastBottom = -1.0
        #expect(await waitUntil(timeout: .seconds(3)) {
            for _ in 0..<20 { scrollView.scrollWheel(with: wheel) }
            hosting.view.layoutSubtreeIfNeeded()
            let settled = bottom() == lastBottom && abs(scrollView.contentView.bounds.origin.y - bottom()) < 1
            lastBottom = bottom()
            return settled
        })
        // At the end of the list, where the other project's file is in view.
        let offset = scrollView.contentView.bounds.origin.y

        switcher.request = ChangesNavigatorItem(root: second.path, path: "README.md")
        switcher.root = second.path
        #expect(await waitUntil { navigation.selections[second.path]?.activeID == "README.md" })
        try await Task.sleep(for: .milliseconds(200))
        hosting.view.layoutSubtreeIfNeeded()

        let after = try #require(navigator())
        #expect(after === scrollView)
        // The end of a lazy list can move by a point as its rows are measured again. A list
        // left at its end that now sits at the new end is still where the person left it.
        let afterOffset = after.contentView.bounds.origin.y
        #expect(abs(afterOffset - offset) < 1 || abs(afterOffset - bottom()) < 1,
                "offset \(offset) became \(afterOffset), end is \(bottom())")
        window.contentViewController = nil
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

@MainActor @Observable
private final class ProjectSwitcher {
    var root: String
    var request: ChangesNavigatorItem?
    init(root: String) { self.root = root }
}

// Picks projects the way a session's Changes tab does: the screen is told which project is
// open and which file was asked for in it.
private struct SwitchingChangesView: View {
    let switcher: ProjectSwitcher
    let navigation: ChangesNavigationMemory
    let repositories: [ChangesRepository]

    var body: some View {
        ChangesView(root: switcher.root, repositories: repositories,
                    requestedPath: switcher.request?.root == switcher.root ? switcher.request?.path : nil,
                    navigation: navigation) { root, path in
            switcher.request = ChangesNavigatorItem(root: root, path: path)
            switcher.root = root
        }
    }
}

@MainActor
private func scrollViews(in view: NSView) -> [NSScrollView] {
    let own = (view as? NSScrollView).map { [$0] } ?? []
    return own + view.subviews.flatMap { scrollViews(in: $0) }
}

