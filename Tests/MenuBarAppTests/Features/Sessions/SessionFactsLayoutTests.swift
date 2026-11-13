import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct SessionFactsLayoutTests {
    @Test(arguments: [false, true])
    func previewFitsAndRoutesToTheWorkingSet(reduceMotion: Bool) async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        defer { app.setActivationPolicy(policy) }
        let (store, scratch) = TestStore.make()
        let project = try TestStore.project(in: store)
        let original = store.newSession(in: project.id, seed: .init(agent: .claudeCode))
        store.append(ChatMessage(role: .user, text: "Tighten keyboard navigation"), to: original.id)
        store.append(ChatMessage(role: .assistant, tools: [
            ToolUse(id: "previous", name: "Read", input: "Keyboard.swift", result: "done")
        ]), to: original.id)
        store.append(ChatMessage(role: .user, text: "Refine the session header"), to: original.id)
        store.append(ChatMessage(role: .assistant, tools: [
            ToolUse(id: "read", name: "Read", input: #"{"file_path":"HeaderRail.swift"}"#, result: "done"),
            ToolUse(id: "edit", name: "Edit", input: "SessionFacts.swift", result: "done"),
            ToolUse(id: "agent", name: "Agent", input: #"{"description":"Check keyboard access","name":"Explore"}"#,
                    result: "Keyboard access verified")
        ]), to: original.id)
        let session = try #require(store.session(original.id))
        let runner = SessionRunner(preferences: scratch.preferences.store, paths: [:])
        let monitor = AccountUsageMonitor(sources: [PreviewUsageSource()])
        await monitor.refresh(.claudeCode)
        let chip = FrameAnchor()
        var openedWorkingSet = false
        let first = PullRequest(number: 482, url: "https://github.com/team/code-station/pull/482")
        let second = PullRequest(number: 96, url: "https://github.com/team/code-station-settings/pull/96")
        let facts = SessionFacts(
            branch: "code-station/f35da721", changes: .init(files: 8, added: 124, removed: 36),
            pullRequests: [first, second],
            pullRequestStatuses: [
                first.url: .init(state: .open, title: "Refine header", headBranch: "topic"),
                second.url: .init(state: .open, title: "Defaults", headBranch: "topic", isDraft: true)
            ], model: "Sonnet", cost: 1.24, context: 0.38)
        let host = NSHostingController(rootView:
            VStack {
                HStack {
                    Text("Session header").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    SessionFactsChip(facts: facts, state: .init(tone: .running, since: .now, ticks: true),
                                     session: session, repositoryCount: 3,
                                     openWorkingSet: { openedWorkingSet = true }, reviewRequest: {},
                                     openChanges: {}, contextActions: { [] }, usageTooltip: { Tooltip(title: "Context") })
                        .background(FrameAnchorView(anchor: chip))
                }
                .padding(20)
                .zIndex(1)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .environment(store).environment(runner).environment(monitor)
            .environment(\._accessibilityReduceMotion, reduceMotion)
            .appOverlays())
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(CGSize(width: 1100, height: 800))
        host.view.frame = CGRect(x: 0, y: 0, width: 1100, height: 800)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close(); runner.stopAll() }
        await settle(host.view)
        try click(try #require(chip.frame()), in: window)
        await settle(host.view)
        #expect(findPreview(in: host.view) != nil)
        try click(try #require(chip.frame()), in: window)
        await settle(host.view)
        #expect(findPreview(in: host.view) == nil)
        try click(try #require(chip.frame()), in: window)
        await settle(host.view)
        let boundary = try #require(findBoundary(in: host.view))
        let outside = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        boundary.mouseDownOutside(outside)
        await settle(host.view)
        #expect(findPreview(in: host.view) == nil)
        try click(try #require(chip.frame()), in: window)
        await settle(host.view)
        let preview = try #require(findPreview(in: host.view))
        let scroll = try #require(findScroll(in: host.view))
        #expect((scroll.documentView?.bounds.height ?? 0) <= scroll.contentView.bounds.height + 1)

        for (name, size, dark) in [
            ("desktop", CGSize(width: 1100, height: 800), false),
            ("minimum", CGSize(width: 960, height: 640), false),
            ("dark", CGSize(width: 1100, height: 800), true)
        ] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(size)
            await settle(host.view)
            let frame = FrameAnchor.fromTop(preview.convert(preview.bounds, to: host.view), in: host.view)
            #expect(frame.minX >= 0)
            #expect(frame.maxX <= size.width)
            #expect(frame.maxY <= size.height)
            #expect(abs(frame.width - 430) < 1)
            if let directory = ProcessInfo.processInfo.environment["GLANCE_REVIEW_DIRECTORY"] {
                let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("\(name)-reduce-\(reduceMotion).png"))
            }
        }

        let frame = FrameAnchor.fromTop(preview.convert(preview.bounds, to: host.view), in: host.view)
        try click(CGRect(x: frame.maxX - 90, y: frame.maxY - 26, width: 1, height: 1), in: window)
        await settle(host.view)
        #expect(openedWorkingSet)
        #expect(findPreview(in: host.view) == nil)
    }

    private func settle(_ view: NSView) async {
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(20))
            view.layoutSubtreeIfNeeded()
        }
    }

    private func findPreview(in view: NSView) -> NSView? {
        if view.identifier?.rawValue == "Working set preview" { return view }
        return view.subviews.lazy.compactMap { findPreview(in: $0) }.first
    }

    private func findBoundary(in view: NSView) -> SessionFactsBoundary.BoundaryView? {
        if let boundary = view as? SessionFactsBoundary.BoundaryView { return boundary }
        return view.subviews.lazy.compactMap { findBoundary(in: $0) }.first
    }

    private func findScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { findScroll(in: $0) }.first
    }

    private func click(_ frame: CGRect, in window: NSWindow) throws {
        let content = try #require(window.contentView)
        let point = content.convert(CGPoint(x: frame.midX,
            y: content.isFlipped ? frame.midY : content.bounds.height - frame.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }
}

private struct PreviewUsageSource: AccountUsageSource {
    let agent = AgentKind.claudeCode

    func read() async -> AccountUsageReading {
        .usage(AccountUsage(windows: [
            AccountUsageWindow(id: "five_hour", title: "5-hour", usedPercent: 62, resetsAt: nil),
            AccountUsageWindow(id: "seven_day", title: "Weekly", usedPercent: 28, resetsAt: nil)
        ], checkedAt: .now))
    }
}
