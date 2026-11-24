import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct ProjectFolderActionsTests {
    @Test(arguments: [false, true])
    func repositoryActionsOpenTheProjectsTerminal(reduceMotion: Bool) async throws {
        _ = NSApplication.shared
        let repo = try GitRepo()
        let (store, scratch) = TestStore.make()
        let project = try #require(store.addProject(at: repo.url))
        let scope = TerminalScope.project(project.id)
        let terminals = TerminalStore(registry: ShellRegistry(directory: ShellNotes.scratch()))
        let menus = MenuPresenter()
        let settings = AppSettings(agentAvatarURL: scratch.path("avatar.png"),
                                   preferences: scratch.preferences.store)
        let view = ProjectDetailView(projectID: project.id)
            .overlay { TooltipHost() }
            .overlay { ContextMenuHost() }
            .environment(store)
            .environment(SessionRunner(store: store, preferences: scratch.preferences.store,
                                       persistentAgentSessions: false, paths: [:]))
            .environment(ShortcutStore(storageURL: scratch.path("shortcuts.json")))
            .environment(WorkingTreeWatch(inspect: { _ in 0 }))
            .environment(OrphanedWorktreeMonitor(preferences: scratch.preferences.store))
            .environment(terminals).environment(GitStatsCache()).environment(settings)
            .environment(DialogPresenter()).environment(menus).environment(TooltipPresenter())
            .environment(\._accessibilityReduceMotion, reduceMotion)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1100, height: 760))
        host.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
        window.appearance = NSAppearance(named: reduceMotion ? .darkAqua : .aqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer {
            terminals.discard(scope)
            window.close()
        }

        var items: [MenuItem] {
            menus.entries.compactMap { if case .item(let item) = $0 { item } else { nil } }
        }

        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutSubtreeIfNeeded()
        try click(NSPoint(x: 728, y: 730))
        try #require(await waitUntil { fetchButton() != nil })
        try await capture("changes")
        try await openActions()
        let terminalAction = try #require(items.first { $0.label == "Terminal here" })
        try await capture("menu")
        menus.run(terminalAction)

        try #require(await waitUntil { terminals.isOpen(scope) })
        let terminal = try #require(terminals.selection(for: scope))
        #expect(terminal.isRunning, "\(terminal.failure ?? "No shell failure")")
        #expect(terminal.directory == repo.path)
        #expect(terminals.sessions(for: scope).count == 1)
        try #require(await waitUntil { window.firstResponder === terminal.surface })
        terminal.send("[ \"$PWD\" -ef \(repo.path.shellQuoted) ] && printf 'project-directory-%s\\n' 'ok'\r")
        #expect(await waitUntil { terminal.screenText().contains("project-directory-ok") },
                "\(terminal.screenText())")
        try await capture("terminal")

        try await openActions()
        let copy = try #require(items.first { $0.label == "Copy path" })
        let pasteboard = NSPasteboard.general
        let previous = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(previous)
        }
        menus.run(copy)
        #expect(pasteboard.string(forType: .string) == repo.path)
        try await capture("copied")

        func fetchButton() -> NSView? {
            views(host.view).first { $0.identifier?.rawValue == "Fetch from origin" }
        }

        func views(_ root: NSView) -> [NSView] {
            [root] + root.subviews.flatMap(views)
        }

        func openActions() async throws {
            // Git loading disables this button before the first snapshot is ready.
            let deadline = ContinuousClock.now + .seconds(30)
            while !menus.isOpen, ContinuousClock.now < deadline {
                try await Task.sleep(for: .seconds(Motion.controlDuration))
                host.view.layoutSubtreeIfNeeded()
                let fetch = try #require(fetchButton())
                let rect = fetch.convert(fetch.bounds, to: nil)
                try click(NSPoint(x: rect.maxX + 20, y: rect.midY))
            }
            try #require(menus.isOpen)
        }

        func click(_ point: NSPoint) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0)))
            }
        }

        func capture(_ name: String) async throws {
            guard let directory = ProcessInfo.processInfo.environment["PROJECT_FOLDER_ACTIONS_REVIEW_DIRECTORY"]
            else { return }
            try await Task.sleep(for: .seconds(Motion.controlDuration))
            host.view.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("project-\(name)-reduce-\(reduceMotion).png"))
        }
    }
}
