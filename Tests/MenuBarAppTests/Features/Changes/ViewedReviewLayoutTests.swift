import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct ViewedReviewLayoutTests {
    @Test func anOpenReviewUpdatesAfterAnEdit() async throws {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let repo = try GitRepo()
        try repo.write("README.md", "first edit\n")
        let navigation = ChangesNavigationMemory()
        let stats = GitStatsCache()
        let reviews = ReviewCommentStore(url: nil)
        let session = UUID()
        let scratch = ScratchDirectory(prefix: "viewed-review-layout")
        let settings = AppSettings(agentAvatarURL: scratch.path("avatar.png"), preferences: scratchDefaults())
        let host = NSHostingController(rootView: ChangesView(
            root: repo.path, navigation: navigation,
            review: ReviewTarget(sessionID: session, agent: .claudeCode, reviews: reviews))
            .environment(stats).environment(settings).environment(DialogPresenter()).appOverlays())
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.center()
        window.layoutIfNeeded()
        defer { window.close() }
        let folder = ProcessInfo.processInfo.environment["WORKSPACE_REVIEW_DIRECTORY"]
        if folder != nil { window.orderFront(nil) }

        #expect(await waitUntil { navigation.viewedTally == ViewedTally(viewed: 0, total: 1) })
        let snapshot = try #require(navigation.snapshots[repo.path])
        let initial = try #require(snapshot.reviewChanges["README.md"])
        let key = ViewedFileStore.key(root: snapshot.root, path: "README.md")
        reviews.viewed.mark(key, change: initial, text: "first edit\n", in: session)
        #expect(await waitUntil { navigation.viewedTally?.isDone == true })
        navigation.hideViewed = true
        try await Task.sleep(for: .milliseconds(300))
        try capture("viewed")

        try repo.write("README.md", "other edit\n")
        stats.store(await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true), at: repo.path)
        #expect(await waitUntil { navigation.viewedTally == ViewedTally(viewed: 0, total: 1) })
        let edited = try #require(navigation.snapshots[repo.path]?.reviewChanges["README.md"])
        #expect(edited != initial)
        #expect(reviews.viewed.state(key, change: edited, in: session).isEdited)
        try await Task.sleep(for: .milliseconds(300))
        try capture("edited")

        navigation.showingHistory = true
        #expect(await waitUntil { navigation.history(for: repo.path).commit != nil })
        try repo.write("README.md", "third edit\n")
        navigation.showingHistory = false
        #expect(await waitUntil { navigation.snapshots[repo.path]?.reviewChanges["README.md"]?.after.blob ==
            FileVersion.blobID(Data("third edit\n".utf8)) })
        #expect(navigation.selections[repo.path]?.activeID == "README.md")
        window.contentViewController = nil

        func capture(_ state: String) throws {
            guard let folder else { return }
            host.view.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: folder)
                    .appendingPathComponent("review-\(state)-reduce-motion-\(reduceMotion).png"))
        }
    }
}
