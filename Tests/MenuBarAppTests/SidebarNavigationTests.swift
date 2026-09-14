import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct SidebarNavigationTests {
    @Test func restoresRevealsAndCollapsesTheCurrentConversation() async throws {
        let expansion = Preferences.sidebarExpansion()
        let groups = Preferences.collapsedSidebarGroups()
        defer {
            Preferences.setSidebarExpansion(expansion)
            Preferences.setCollapsedSidebarGroups(groups)
        }
        let harness = try SidebarHarness()
        defer { harness.close() }
        let project = try TestStore.project(in: harness.store, named: "japan")
        harness.store.renameProject(project.id, to: "japan")
        let session = harness.store.newSession(in: project.id)
        let title = "fetch prices for today for taycan. then commit the changes"
        harness.store.renameSession(session.id, to: title)
        for index in 1...8 {
            let other = harness.store.newSession(in: project.id)
            harness.store.renameSession(other.id, to: "Other conversation \(index)")
        }
        harness.store.selection = .session(session.id)
        Preferences.setSidebarExpansion([project.id: false])
        Preferences.setCollapsedSidebarGroups([.projects])
        harness.mount()
        await harness.settle()

        #expect(Preferences.sidebarExpansion()[project.id] == true)
        #expect(!Preferences.collapsedSidebarGroups().contains(.projects))
        try harness.snapshot("expanded-light")

        try harness.click(x: 289, yFromTop: 179)
        await harness.settle()
        #expect(harness.store.selection == .session(session.id))
        #expect(Preferences.sidebarExpansion()[project.id] == false)
        try harness.snapshot("collapsed-light")

        try harness.click(x: 289, yFromTop: 179)
        await harness.settle()
        #expect(harness.store.selection == .session(session.id))
        #expect(Preferences.sidebarExpansion()[project.id] == true)
        try harness.click(x: 289, yFromTop: 179)
        await harness.settle()

        harness.store.append(ChatMessage(role: .assistant, text: "Streaming continues"), to: session.id)
        await harness.settle()
        #expect(Preferences.sidebarExpansion()[project.id] == false)

        harness.store.selectSession(session.id)
        await harness.settle()
        #expect(Preferences.sidebarExpansion()[project.id] == true)
        harness.window?.appearance = NSAppearance(named: .darkAqua)
        await harness.settle()
        try harness.snapshot("expanded-dark")

        try harness.click(x: 100, yFromTop: 179)
        await harness.settle()
        #expect(harness.store.selection == nil)
        #expect(harness.store.selectedProjectID == project.id)
        #expect(Preferences.sidebarExpansion()[project.id] == true)
        // A click on the row is already where the eye is, so nothing is pointed out.
        #expect(harness.store.sidebarHighlight == nil)
    }

    @Test func aWorkspaceOpenedFromElsewhereIsScrolledToAndPointedOut() async throws {
        let expansion = Preferences.sidebarExpansion()
        let groups = Preferences.collapsedSidebarGroups()
        defer {
            Preferences.setSidebarExpansion(expansion)
            Preferences.setCollapsedSidebarGroups(groups)
        }
        let harness = try SidebarHarness()
        defer { harness.close() }
        var projects: [Project] = []
        for index in 1...18 {
            projects.append(try TestStore.project(in: harness.store, named: "a-project-\(index)"))
        }
        let workspace = try #require(harness.store.addWorkspace(name: "z-workspace",
            projectIDs: [projects[0].id, projects[1].id], leadProjectID: projects[0].id))
        harness.settings.projectGrouping = .flat
        harness.store.selectHome()
        harness.mount()
        await harness.settle()
        #expect(try #require(harness.scrollView).documentVisibleRect.minY == 0)

        // What the command palette does: the row is chosen from a screen of its own, so
        // the rail has to travel to it.
        harness.store.selectWorkspace(workspace.id)
        // Caught inside the first blink, so the snapshot shows the row wearing its green.
        try? await Task.sleep(for: .milliseconds(120))
        harness.hosting?.view.layoutSubtreeIfNeeded()
        try harness.snapshot("workspace-pointed-out")

        await harness.settle()
        let scroll = try #require(harness.scrollView)
        let document = try #require(scroll.documentView)
        // The workspace sorts last, so the rail has to travel to the bottom of the list.
        #expect(scroll.documentVisibleRect.maxY >= document.bounds.maxY - 14)
        #expect(harness.store.sidebarHighlight == workspace.id)

        #expect(await waitUntil { harness.store.sidebarHighlight == nil })
    }

    @Test func externalWorkspaceNavigationRevealsItsParentAndRecoversFromAFilter() async throws {
        let expansion = Preferences.sidebarExpansion()
        let groups = Preferences.collapsedSidebarGroups()
        defer {
            Preferences.setSidebarExpansion(expansion)
            Preferences.setCollapsedSidebarGroups(groups)
        }
        let harness = try SidebarHarness()
        defer { harness.close() }
        var projects: [Project] = []
        for index in 1...18 {
            projects.append(try TestStore.project(in: harness.store, named: "a-project-\(index)"))
        }
        let workspace = try #require(harness.store.addWorkspace(name: "z-workspace",
            projectIDs: [projects[0].id, projects[1].id], leadProjectID: projects[0].id))
        let session = try #require(harness.store.newSession(in: workspace.id, projects: [
            SessionProject(projectID: projects[0].id, worktreePath: nil, worktreeBranch: nil),
            SessionProject(projectID: projects[1].id, worktreePath: nil, worktreeBranch: nil)
        ]))
        harness.store.renameSession(session.id, to: "Review frontend and platform changes")
        harness.settings.projectGrouping = .flat
        harness.store.selectHome()
        Preferences.setSidebarExpansion([workspace.id: false])
        harness.mount()
        await harness.settle()

        harness.store.selectSession(session.id)
        await harness.settle()
        #expect(Preferences.sidebarExpansion()[workspace.id] == true)
        let scroll = try #require(harness.scrollView)
        #expect(scroll.documentVisibleRect.minY > 0)
        let document = try #require(scroll.documentView)
        // The card is the last row; only the rail's bottom padding can remain below it.
        #expect(scroll.documentVisibleRect.maxY >= document.bounds.maxY - 14)
        try harness.snapshot("workspace-revealed")

        harness.settings.projectSort = .lastUsed
        harness.settings.projectGrouping = .kind
        await harness.settle()
        #expect(harness.store.sidebarDestination == SidebarDestination(containerID: workspace.id,
                                                                        sessionID: session.id))
        try harness.openFilter()
        await harness.settle()
        let editor = try #require(harness.window?.firstResponder as? NSTextView)
        editor.insertText("no-such-project", replacementRange: NSRange(location: NSNotFound, length: 0))
        await harness.settle()
        #expect(harness.scrollView == nil)
        try harness.snapshot("filtered-out")

        try harness.click(x: 100, yFromTop: 172)
        await harness.settle()
        #expect(harness.scrollView != nil)
        #expect(harness.store.selection == .session(session.id))
        #expect(Preferences.sidebarExpansion()[workspace.id] == true)
    }
}

@MainActor
private final class SidebarHarness {
    let scratch: ScratchDirectory
    let store: ProjectStore
    let runner = SessionRunner(paths: [:])
    let settings: AppSettings
    let preferences: UserDefaults
    var window: NSWindow?
    var hosting: NSHostingController<AnyView>?

    init() throws {
        (store, scratch) = TestStore.make()
        preferences = try #require(UserDefaults(suiteName: "sidebar-ui-\(UUID().uuidString)"))
        settings = AppSettings(agentAvatarURL: scratch.path("avatar.png"), preferences: preferences)
        settings.sidebarSessionLimit = 2
        settings.projectGrouping = .kind
        settings.projectSort = .name
    }

    func mount() {
        let stats = GitStatsCache()
        let view = AppSidebar(
            skills: SkillsManager(cacheURL: scratch.path("skills.json"), preferences: preferences),
            tools: ToolsMenuActions(configureServers: {}, openSkills: {}, openDocker: {},
                                    openDispatch: {}, openShortcuts: {}, openTroubleshoot: {},
                                    openSettings: {}),
            oldSessionDeletionAt: nil, onReviewOldSessions: {})
            .environment(store)
            .environment(runner)
            .environment(settings)
            .environment(ShortcutStore(storageURL: scratch.path("shortcuts.json"),
                                       siteDefaults: SiteDefaults()))
            .environment(AppUpdateChecker(installedVersion: nil, preferences: preferences))
            .environment(WorkingTreeWatch(inspect: { _ in 0 }))
            .environment(OrphanedWorktreeMonitor())
            .environment(MobileAccessController(store: store, runner: runner, gitStats: stats))
            .environment(GlobalCommandPaletteController())
            .environment(ConfigStore(configURL: scratch.path("config.json")))
            .environment(DockerService())
            .environment(DispatchAuthStore(storeURL: scratch.path("dispatch-auth.json"),
                                           keychain: KeychainClient(read: { [:] }, write: { _ in }),
                                           siteDefaults: SiteDefaults()))
            .transaction { $0.disablesAnimations = true }
            .appOverlays()
        let hosting = NSHostingController(rootView: AnyView(view))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 318, height: 820),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 318, height: 820))
        hosting.view.frame = NSRect(x: 0, y: 0, width: 318, height: 820)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        self.hosting = hosting
        self.window = window
    }

    func settle() async {
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(20))
            hosting?.view.layoutSubtreeIfNeeded()
        }
    }

    func close() {
        window?.orderOut(nil)
        window?.contentViewController = nil
        hosting = nil
        window = nil
        runner.stopAll()
    }

    func click(x: CGFloat, yFromTop: CGFloat) throws {
        let window = try #require(window)
        let point = NSPoint(x: x, y: 820 - yFromTop)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    func openFilter() throws {
        let window = try #require(window)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false,
            keyCode: 3))
        #expect(window.performKeyEquivalent(with: event))
    }

    var scrollView: NSScrollView? {
        func find(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return hosting.flatMap { find(in: $0.view) }
    }

    func snapshot(_ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SIDEBAR_SNAPSHOT_DIRECTORY"],
              let view = hosting?.view else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

}
