import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct BranchBrowserLayoutTests {
    @Test func branchBrowserAndMergePreviewFitShortWindowsWithoutChangingTheCheckout() async throws {
        let repo = try GitRepo()
        let source = "feature/preserve-workspace-selection-when-reopening-a-session-with-several-projects"
        try repo.git("switch", "-c", source)
        try repo.write("feature.txt", "Incoming change\n")
        try repo.commit("Keep workspace selection when reopening a session")
        try repo.git("switch", "main")
        try repo.write("README.md", "Uncommitted work\n")
        let head = repo.head
        let status = try repo.git("status", "--porcelain")
        for merging in [false, true] {
            let dialogs = DialogPresenter()
            let content = BranchBrowserView(root: repo.path, repository: "code-station", mergeInitially: merging, changed: {})
            dialogs.show(Dialog(title: "Branches", content: AnyView(content), actions: [], width: 780,
                                isModal: true, framesItself: true, fitsWindow: true))
            let hosting = NSHostingController(rootView: Theme.background
                .overlay { DialogHost() }.overlay { ContextMenuHost() }
                .environment(dialogs).environment(MenuPresenter()).environment(TooltipPresenter()))
            hosting.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentViewController = hosting
            window.center()
            window.layoutIfNeeded()
            for _ in 0..<8 {
                _ = await Git.offMain { true }
                try await Task.sleep(for: .milliseconds(100))
                hosting.view.layoutSubtreeIfNeeded()
            }
            for height: CGFloat in [760, 540] {
                window.setContentSize(NSSize(width: 1000, height: height))
                hosting.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let size = hosting.sizeThatFits(in: CGSize(width: 1000, height: height))
                #expect(size.width <= 1000)
                #expect(size.height <= height)
                if let path = ProcessInfo.processInfo.environment["WORKSPACE_REVIEW_DIRECTORY"] {
                    let bitmap = try #require(hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds))
                    hosting.view.cacheDisplay(in: hosting.view.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: path).appendingPathComponent("branches-\(merging ? "merge" : "browser")-\(Int(height)).png"))
                }
            }
            dialogs.dismiss()
            window.contentViewController = nil
        }
        #expect(repo.head == head)
        #expect(try repo.git("status", "--porcelain") == status)
    }
}
