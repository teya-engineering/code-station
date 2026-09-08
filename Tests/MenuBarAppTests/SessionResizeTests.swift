import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct SessionResizeTests {
    @Test func narrowingTheWindowKeepsTheSidebarAndSessionInsideItsBounds() async throws {
        let (store, scratch) = TestStore.make()
        let project = try TestStore.project(in: store, named: "A project with a long name")
        let session = store.newSession(in: project.id,
                                       worktreeBranch: "code-station/a-long-branch-name",
                                       seed: .init(agent: .claudeCode))
        store.setAgentSessionID("resize-fixture", agent: .claudeCode, for: session.id)
        _ = try store.startDesign(for: session.id).get()
        let preferences = try #require(UserDefaults(suiteName: "resize-\(UUID().uuidString)"))
        let settings = AppSettings(agentAvatarURL: scratch.path("avatar.png"),
                                   preferences: preferences)
        let runner = SessionRunner(paths: [:])
        store.append(ChatMessage(role: .assistant, text: String(repeating:
            "The conversation should wrap to the space left beside the sidebar. ", count: 8)),
                     to: session.id)
        runner.editDraft(session.id) {
            $0.text = "Check the window layout while narrowing and widening the app."
        }
        let sidebar = FrameAnchor()
        let detail = FrameAnchor()
        let hosting = NSHostingController(rootView:
            HStack(spacing: 0) {
                Color.clear.frame(width: 318)
                    .background(FrameAnchorView(anchor: sidebar))
                Divider()
                SessionView(sessionID: session.id)
                    .background(FrameAnchorView(anchor: detail))
            }
            .environment(store)
            .environment(runner)
            .environment(TerminalStore())
            .environment(settings)
            .environment(GitStatsCache())
            .environment(ShortcutStore(storageURL: scratch.path("shortcuts.json"),
                                       siteDefaults: SiteDefaults()))
            .environment(GlobalCommandPaletteController())
            .appOverlays())
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = hosting
        defer { runner.stopAll() }

        for width: CGFloat in [1400, 1180, 960, 1050, 1400, 960] {
            window.setContentSize(NSSize(width: width, height: 700))
            for _ in 0..<4 {
                try await Task.sleep(for: .milliseconds(20))
                hosting.view.layoutSubtreeIfNeeded()
            }
            let sidebarFrame = try #require(sidebar.frame())
            let detailFrame = try #require(detail.frame())
            #expect(abs(sidebarFrame.minX) < 1)
            #expect(sidebarFrame.width == 318)
            #expect(abs(detailFrame.maxX - width) < 1)
            #expect(abs(detailFrame.width - (width - 319)) < 1)
        }
    }
}
