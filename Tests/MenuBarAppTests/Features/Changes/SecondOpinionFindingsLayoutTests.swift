import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct SecondOpinionFindingsLayoutTests {
    @Test func findingsAndReceiptFitNarrowAndWideSurfaces() async throws {
        let repo = try GitRepo()
        try repo.write("README.md", "changed\n")
        let reviews = ReviewCommentStore(url: nil)
        let session = UUID()
        let reviewer = SecondOpinion.Reviewer(agent: .claudeCode, model: "sonnet", effort: "high")
        reviews.startSecondOpinion(session, reviewer: reviewer,
            request: .init(repositories: [.init(root: repo.path, name: "App")], executable: "/usr/bin/false"))
        #expect(await waitUntil { reviews.runs(session).first?.isRunning == false })
        let finding = ReviewComment(root: repo.path, path: "README.md", anchor: .init(side: .new, line: 1),
                                    excerpt: "changed", body: "Keep the payment key when retrying a pending charge.",
                                    author: .agent(.claudeCode), status: .pending, severity: .should)
        reviews.finishSecondOpinion(session, reviewer: reviewer, outcome: .success([finding]))
        let review = ReviewTarget(sessionID: session, agent: .codex, reviews: reviews)
        for width: CGFloat in [390, ReviewMetrics.findingsWidth] {
            for dark in [false, true] {
                let view = SecondOpinionFindingsView(review: review, selected: finding.id, send: { _ in })
                    .environment(DialogPresenter()).environment(MenuPresenter()).environment(TooltipPresenter())
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\._accessibilityReduceMotion, true)
                let host = NSHostingController(rootView: view)
                host.sizingOptions = []
                let size = CGSize(width: width, height: 680)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentViewController = host
                window.setContentSize(size)
                window.center()
                host.view.frame = NSRect(origin: .zero, size: size)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                #expect(host.view.fittingSize.width <= width)
                if let folder = ProcessInfo.processInfo.environment["WORKSPACE_REVIEW_DIRECTORY"] {
                    let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                    host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: folder).appendingPathComponent(
                            "findings-\(Int(width))-\(dark ? "dark" : "light").png"))
                }
                window.contentViewController = nil
                window.close()
            }
        }
    }
}
