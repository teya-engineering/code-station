import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct SessionFactsLayoutTests {
    init() {
        let app = NSApplication.shared
        // A command-line host can start prohibited, but restoring that policy would
        // prevent later UI tests from creating windows.
        if app.activationPolicy() == .prohibited { app.setActivationPolicy(.accessory) }
    }

    @Test(arguments: [false, true])
    func sessionDetailsFitAndDismiss(reduceMotion: Bool) async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        defer { app.setActivationPolicy(policy) }
        let sessionID = UUID()
        let monitor = AccountUsageMonitor(sources: [PreviewUsageSource()])
        await monitor.refresh(.claudeCode)
        let chip = FrameAnchor()
        let first = PullRequest(number: 482, url: "https://github.com/team/code-station/pull/482")
        let second = PullRequest(number: 96, url: "https://github.com/team/code-station-settings/pull/96")
        let facts = SessionFacts(
            branch: "code-station/f35da721", changes: .init(files: 8, added: 124, removed: 36),
            pullRequests: [first, second],
            pullRequestStatuses: [
                first.url: .init(state: .open, title: "Refine header", headBranch: "topic"),
                second.url: .init(state: .open, title: "Defaults", headBranch: "topic", isDraft: true)
            ], model: "Sonnet", cost: 1.24, context: 0.38,
            projects: [
                .init(id: UUID(), name: "code-station", kind: .lead, branch: "code-station/f35da721",
                      changes: .init(files: 8, added: 124, removed: 36)),
                .init(id: UUID(), name: "payments-gateway-acceptance-tests-and-contract-fixtures",
                      kind: .worktree, branch: "code-station/f35da721-with-a-long-branch-name-to-truncate",
                      changes: .init(files: 0, added: 0, removed: 0))
            ], workspace: "code-station + payments-gateway")
        let (window, host) = show(facts: facts, sessionID: sessionID, chip: chip, monitor: monitor,
                                  reduceMotion: reduceMotion)
        defer { window.close() }
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
        let scroll = try #require(findScrolls(in: host.view).first)
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
            try snapshot(host.view, named: "\(name)-reduce-\(reduceMotion)")
        }

        try click(try #require(chip.frame()), in: window)
        await settle(host.view)
        #expect(findPreview(in: host.view) == nil)
    }

    // A session that has opened a long run of pull requests scrolls them in their own
    // section, so the usage under them stays in view and the card itself does not scroll.
    @Test
    func longPullRequestListScrollsInPlace() async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        defer { app.setActivationPolicy(policy) }
        let monitor = AccountUsageMonitor(sources: [PreviewUsageSource()])
        await monitor.refresh(.claudeCode)
        let chip = FrameAnchor()
        let pullRequests = (1...40).map {
            PullRequest(number: $0, url: "https://github.com/team/code-station-\($0 % 4)/pull/\($0)")
        }
        let facts = SessionFacts(
            branch: "code-station/f35da721", changes: .init(files: 3, added: 9, removed: 0),
            pullRequests: pullRequests,
            // The newest two are still open, the way a long-running session usually ends.
            pullRequestStatuses: Dictionary(uniqueKeysWithValues: pullRequests.map {
                ($0.url, PullRequestStatus(state: $0.number >= 39 ? .open : .merged, title: "Change",
                                           headBranch: "topic", isDraft: $0.number == 40))
            }), model: "Opus", context: 0.27)
        let (window, host) = show(facts: facts, sessionID: UUID(), chip: chip, monitor: monitor,
                                  reduceMotion: false)
        defer { window.close() }
        await settle(host.view)
        try click(try #require(chip.frame()), in: window)
        await settle(host.view)

        for size in [CGSize(width: 1100, height: 800), CGSize(width: 960, height: 640)] {
            window.setContentSize(size)
            await settle(host.view)
            let scrolls = findScrolls(in: host.view)
            let body = try #require(scrolls.first { outer in
                scrolls.contains { $0 !== outer && $0.isDescendant(of: outer) }
            })
            let list = try #require(scrolls.first { $0 !== body && $0.isDescendant(of: body) })
            let bodyDocument = try #require(body.documentView).bounds.height
            let listDocument = try #require(list.documentView).bounds.height
            #expect(bodyDocument <= body.contentView.bounds.height + 1)
            #expect(listDocument > list.contentView.bounds.height + 1)
            let preview = try #require(findPreview(in: host.view))
            let frame = FrameAnchor.fromTop(preview.convert(preview.bounds, to: host.view), in: host.view)
            #expect(frame.maxY <= size.height)
            try snapshot(host.view, named: "long-pull-requests-\(Int(size.height))")
        }
    }

    private func show(facts: SessionFacts, sessionID: UUID, chip: FrameAnchor,
                      monitor: AccountUsageMonitor,
                      reduceMotion: Bool) -> (NSWindow, NSHostingController<some View>) {
        let host = NSHostingController(rootView:
            VStack {
                HStack {
                    Text("Session header").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    SessionFactsChip(facts: facts, state: .init(tone: .running, since: .now, ticks: true),
                                     sessionID: sessionID,
                                     openChanges: {}, contextActions: { [] }, usageTooltip: { Tooltip(title: "Context") },
                                     attachProject: {})
                        .background(FrameAnchorView(anchor: chip))
                }
                .padding(20)
                .zIndex(1)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .environment(monitor)
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
        return (window, host)
    }

    // Pictures of the card for a person to look over, written only when asked for.
    private func snapshot(_ view: NSView, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["GLANCE_REVIEW_DIRECTORY"] else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    private func settle(_ view: NSView) async {
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(20))
            view.layoutSubtreeIfNeeded()
        }
    }

    private func findPreview(in view: NSView) -> NSView? {
        if view.identifier?.rawValue == "Session details" { return view }
        return view.subviews.lazy.compactMap { findPreview(in: $0) }.first
    }

    private func findBoundary(in view: NSView) -> SessionFactsBoundary.BoundaryView? {
        if let boundary = view as? SessionFactsBoundary.BoundaryView { return boundary }
        return view.subviews.lazy.compactMap { findBoundary(in: $0) }.first
    }

    private func findScrolls(in view: NSView) -> [NSScrollView] {
        [view as? NSScrollView].compactMap { $0 } + view.subviews.flatMap { findScrolls(in: $0) }
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
