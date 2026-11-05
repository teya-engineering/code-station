import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

struct DesignConversationLayoutTests {
    @Test func panelFitsNarrowAndShortWorkspacesWithTheSameAnchor() {
        for workspace in [CGSize(width: 1200, height: 800), CGSize(width: 480, height: 600),
                          CGSize(width: 280, height: 120), .zero] {
            for expanded in [false, true] {
                for hidden in [false, true] {
                    let size = DesignConversationLayout.size(in: workspace, expanded: expanded, minimized: hidden)
                    let inset = DesignConversationLayout.inset(in: workspace)
                    #expect(size.width >= 0 && size.height >= 0)
                    #expect(size.width + inset * 2 <= workspace.width)
                    #expect(size.height + inset * 2 <= workspace.height)
                }
            }
        }
        let workspace = CGSize(width: 1200, height: 800)
        #expect(DesignConversationLayout.size(in: workspace, expanded: true, minimized: true)
                == DesignConversationLayout.minimizedSize)
        #expect(DesignConversationLayout.size(in: CGSize(width: 180, height: 600), expanded: false, minimized: true)
                == CGSize(width: 156, height: 56))
        #expect(DesignConversationLayout.size(in: workspace, expanded: false)
                == CGSize(width: 880, height: 326))
        #expect(DesignConversationLayout.size(in: workspace, expanded: false, composerHeight: 167, transcriptHeight: 60)
                == CGSize(width: 880, height: 227))
        #expect(DesignConversationLayout.size(in: workspace, expanded: false, minimized: true, minimizedWidth: 260)
                == CGSize(width: 260, height: 56))
        #expect(DesignConversationLayout.size(in: workspace, expanded: false, minimized: true, minimizedWidth: 500)
                == CGSize(width: 320, height: 56))
        #expect(DesignConversationLayout.size(in: workspace, expanded: true, transcriptHeight: 60)
                == CGSize(width: 1156, height: 756))
        #expect(DesignConversationLayout.size(in: workspace, expanded: true)
                == CGSize(width: 1156, height: 756))
        #expect(DesignConversationLayout.size(in: CGSize(width: 600, height: 600), expanded: true)
                == CGSize(width: 576, height: 576))
    }

    // Running and waiting share a colour, so the words are what tell them apart.
    @Test func minimizedTabNamesEachStateInWords() {
        #expect(DesignConversationLayout.minimizedLine(.running, word: "Putting the kettle on", waited: nil)
                == "Putting the kettle on…")
        #expect(DesignConversationLayout.minimizedLine(.waiting, word: "Brewing", waited: "1m 12s")
                == "Waiting… 1m 12s")
        #expect(DesignConversationLayout.minimizedLine(.needsYou, word: "Brewing", waited: nil) == "Needs you")
        #expect(DesignConversationLayout.minimizedLine(.idle, word: "Brewing", waited: nil) == "Done. Hover to expand")
        #expect(DesignConversationLayout.minimizedAccessibilityValue(.running) == "Minimized, working")
        #expect(DesignConversationLayout.minimizedAccessibilityValue(.waiting) == "Minimized, waiting")
        #expect(DesignConversationLayout.minimizedAccessibilityValue(.needsYou) == "Minimized, needs you")
        #expect(DesignConversationLayout.minimizedAccessibilityValue(.idle) == "Minimized")
    }
}

@MainActor
struct DesignConversationDismissalTests {
    @Test func outsideClicksCollapseAndPassThroughWhileInsideClicksDoNothing() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let observer = DesignConversationDismissal.ObserverView(frame: CGRect(x: 20, y: 20, width: 405, height: 144))
        window.contentView?.addSubview(observer)
        defer { observer.stop() }
        var collapses = [Bool]()
        observer.expanded = true
        observer.collapse = { collapses.append($0) }
        func click(_ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let inside = try click(CGPoint(x: 100, y: 100))
        #expect(observer.handle(inside, frontmost: window) === inside)
        #expect(collapses.isEmpty)
        let outside = try click(CGPoint(x: 600, y: 400))
        #expect(observer.handle(outside, frontmost: window) === outside)
        #expect(collapses == [false])
        observer.expanded = false
        #expect(observer.handle(outside, frontmost: window) === outside)
        #expect(collapses == [false, false])
        observer.minimized = true
        #expect(observer.handle(outside, frontmost: window) === outside)
        #expect(observer.handle(inside, frontmost: window) === inside)
        #expect(collapses == [false, false])
        observer.minimized = false
        collapses = []
        observer.expanded = true
        observer.isHidden = true
        #expect(observer.handle(outside, frontmost: window) === outside)
        #expect(collapses.isEmpty)
    }

    @Test func pressesOnTheFoldedTranscriptExpandItButNotOnTheCornerButtonComposerOrOutside() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let observer = DesignConversationDismissal.ObserverView(frame: CGRect(x: 20, y: 20, width: 405, height: 144))
        window.contentView?.addSubview(observer)
        defer { observer.stop() }
        var expands = 0
        observer.footerHeight = 50
        observer.expand = { expands += 1 }
        func click(_ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let corner = try click(CGPoint(x: 400, y: 150))
        #expect(observer.handle(corner, frontmost: window) === corner)
        _ = observer.handle(try click(CGPoint(x: 600, y: 400)), frontmost: window)
        let composer = try click(CGPoint(x: 100, y: 40))
        #expect(observer.handle(composer, frontmost: window) === composer)
        #expect(expands == 0)
        let body = try click(CGPoint(x: 100, y: 150))
        #expect(observer.handle(body, frontmost: window) === body)
        #expect(expands == 1)
        observer.enabled = false
        _ = observer.handle(body, frontmost: window)
        observer.enabled = true
        observer.expanded = true
        _ = observer.handle(body, frontmost: window)
        #expect(expands == 1)
    }
}

@MainActor
@Suite(.serialized)
struct DesignConversationViewTests {
    private let testPreferences = TestPreferences()
    @Test(arguments: [false, true])
    func foldingKeepsTheComposerTranscriptAndReadingPosition(reduceMotion: Bool) async throws {
        let (store, scratch) = TestStore.make()
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id, seed: .init(agent: .codex, mode: .design))
        let artifact = try #require(store.designArtifactURL(for: session))
        try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
            <!doctype html><html><style>
            html, body { margin: 0; width: 1440px; height: 1400px; overflow: hidden; }
            </style>
            <body><h1>Design canvas</h1><input value='Keep canvas state'></body></html>
            """
            .write(to: artifact, atomically: true, encoding: .utf8)
        for index in 0..<20 {
            store.append(ChatMessage(role: .assistant, text: "Message \(index)\n\n" +
                String(repeating: "Keep the reader's place in this conversation. ", count: 12)), to: session.id)
        }
        let runner = SessionRunner(preferences: testPreferences.store, paths: [.codex: "/usr/bin/true"])
        runner.composer.editDraft(session.id) { $0.text = "Keep this draft" }
        let preferences = try #require(UserDefaults(suiteName: "design-floating-\(UUID().uuidString)"))
        let hosting = NSHostingController(rootView:
            DesignView(sessionID: session.id)
                .environment(\._accessibilityReduceMotion, reduceMotion)
                .environment(store)
                .environment(runner)
                .environment(AppSettings(agentAvatarURL: scratch.path("avatar.png"), preferences: preferences))
                .environment(ShortcutStore(storageURL: scratch.path("shortcuts.json"), siteDefaults: SiteDefaults()))
                .environment(GlobalCommandPaletteController())
                .background(Theme.background)
                .appOverlays())
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1000, height: 800))
        hosting.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            runner.stopAll()
        }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        func settle() async throws {
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(20))
                hosting.view.layoutSubtreeIfNeeded()
            }
        }
        func click(_ point: CGPoint) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
        }
        try await settle()
        let observer = try #require(descendants(hosting.view).compactMap {
            $0 as? DesignConversationDismissal.ObserverView
        }.first)
        #expect(observer.minimized)
        let openingTab = observer.convert(observer.bounds, to: nil)
        let viewport = try #require(descendants(hosting.view).compactMap { $0 as? DesignCanvasViewport }.first)
        #expect(await waitUntil {
            viewport.layoutSubtreeIfNeeded()
            return viewport.viewport.contentSize.height == 1400
        })
        let canvasFrame = viewport.convert(viewport.bounds, to: nil)
        let artboardFrame = viewport.convert(viewport.viewport.contentFrame, to: nil)
        #expect(abs(openingTab.minY - canvasFrame.minY - 12) < 1)
        #expect(abs(openingTab.maxY - artboardFrame.minY - 56.0 / 3) < 1)
        #expect(abs(canvasFrame.minY - DesignWebView.toolbarHeight) < 1)
        viewport.zoom(by: 1.5, at: CGPoint(x: 400, y: 300))
        viewport.pan(by: CGSize(width: 40, height: 20))
        let manualFrame = viewport.viewport.contentFrame
        try click(CGPoint(x: openingTab.midX, y: openingTab.midY))
        try await settle()
        #expect(!observer.minimized)
        #expect(!observer.expanded)
        #expect(observer.bounds.size == CGSize(width: 880, height: 326))
        #expect(viewport.viewport.contentFrame == manualFrame)
        #expect(viewport.viewport.fitBottomInset == 0)
        let composer = try #require(descendants(hosting.view).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        // The text view sits in its own scroll view, inside the panel's composer area. While
        // the panel resizes, SwiftUI nudges that area's scroll offset by up to half a pixel to
        // keep it sharp, and the last nudge can be left behind. So the composer's place is read
        // from the area itself, which is laid out on whole points.
        let composerArea = try #require(composer.enclosingScrollView?.enclosingScrollView)
        func composerAreaFrame() -> CGRect { composerArea.convert(composerArea.bounds, to: nil) }
        // The area is sized to its content, so it never needs a scroll bar.
        func composerAreaFits() -> Bool {
            (composerArea.documentView?.frame.height ?? .infinity) <= composerArea.contentView.bounds.height
        }
        #expect(composerAreaFits())
        let composerFrame = composerAreaFrame()
        let transcript = try #require(descendants(hosting.view).compactMap { $0 as? NSScrollView }.first {
            !($0.documentView is NSTextView) && $0.contentView.documentRect.height > 1000
        })
        let compactFrame = observer.convert(observer.bounds, to: nil)
        let transcriptPress = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: CGPoint(x: compactFrame.midX, y: compactFrame.maxY - 26),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(observer.handle(transcriptPress, frontmost: window) === transcriptPress)
        try await settle()
        #expect(observer.expanded)
        #expect(viewport.viewport.contentFrame == manualFrame)
        #expect(await waitUntil {
            hosting.view.layoutSubtreeIfNeeded()
            return abs(composerAreaFrame().minY - composerFrame.minY) < 1
        })
        #expect(composerAreaFits())
        #expect(viewport.convert(viewport.bounds, to: nil) == canvasFrame)
        let selectedText = try #require(descendants(transcript).compactMap { $0 as? NSTextView }.first)
        selectedText.setSelectedRange(NSRange(location: 2, length: 4))
        transcript.contentView.scroll(to: CGPoint(x: 0, y: 200))
        transcript.reflectScrolledClipView(transcript.contentView)
        // Only a person's scroll unpins the transcript from its end. Left pinned, it is sent
        // back to the end as the panel grows, racing the restore of the reading position.
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: transcript)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: transcript)
        try await settle()
        let readingPosition = transcript.documentVisibleRect
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        #expect(observer.handle(escape, frontmost: window) == nil)
        try await settle()
        #expect(!observer.expanded)
        #expect(window.firstResponder !== composer)
        store.append(ChatMessage(role: .assistant, text: "A response while the panel is folded."), to: session.id)
        try await settle()
        #expect(!observer.expanded)
        #expect(runner.composer.draft(session.id).text == "Keep this draft")
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let space = try #require(NSEvent.keyEvent(with: type, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: 49))
            window.sendEvent(space)
        }
        try await settle()
        #expect(observer.expanded)
        // The position comes back once the panel has finished growing, which takes longer
        // on a slow machine.
        #expect(await waitUntil { abs(transcript.documentVisibleRect.minY - readingPosition.minY) < 1 })
        #expect(transcript.documentVisibleRect.size == readingPosition.size)
        #expect(descendants(hosting.view).contains { $0 === composer })
        #expect(descendants(hosting.view).contains { $0 === transcript })
        #expect(descendants(hosting.view).contains { $0 === viewport })
        #expect(selectedText.selectedRange() == NSRange(location: 2, length: 4))
        let attachment = Attachment(url: scratch.path("reference.png"))
        runner.composer.attach([attachment], to: session.id)
        try await settle()
        let expandedFrame = observer.convert(observer.bounds, to: nil)
        try click(CGPoint(x: expandedFrame.maxX - 28, y: expandedFrame.maxY - 26))
        try await settle()
        #expect(!observer.expanded)
        #expect(observer.bounds.height == 326)
        let outside = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: CGPoint(x: canvasFrame.minX + 20, y: canvasFrame.maxY - 20),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(observer.handle(outside, frontmost: window) === outside)
        try await settle()
        #expect(!observer.expanded)
        #expect(observer.minimized)
        #expect(viewport.viewport.contentFrame == manualFrame)
        #expect(observer.bounds.height == DesignConversationLayout.minimizedSize.height)
        #expect((DesignConversationLayout.minimizedSize.width...DesignConversationLayout.minimizedMaxWidth)
                .contains(observer.bounds.width))
        #expect(window.firstResponder !== composer)
        #expect(descendants(hosting.view).contains { $0 === composer })
        let tab = observer.convert(observer.bounds, to: nil)
        #expect(abs(tab.minY - canvasFrame.minY - 12) < 1)
        viewport.fit()
        #expect(abs(viewport.viewport.contentFrame.maxY
                    - viewport.bounds.height + DesignConversationLayout.minimizedCanvasGutter) < 1)
        try click(CGPoint(x: tab.midX, y: tab.midY))
        try await settle()
        #expect(!observer.minimized)
        #expect(!observer.expanded)
        #expect(observer.bounds.height == 326)
        #expect(runner.composer.draft(session.id).text == "Keep this draft")
        #expect(runner.composer.draft(session.id).attachments == [attachment])
        for width: CGFloat in [480, 700, 1000] {
            window.setContentSize(CGSize(width: width, height: 800))
            try await settle()
            let panel = observer.convert(observer.bounds, to: nil)
            let canvas = viewport.convert(viewport.bounds, to: nil)
            #expect(panel.minX >= canvas.minX && panel.maxX <= canvas.maxX)
            #expect(panel.minY >= canvas.minY && panel.maxY <= canvas.maxY)
            let outside = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                location: CGPoint(x: canvas.minX + 10, y: canvas.maxY - 10),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            _ = observer.handle(outside, frontmost: window)
            try await settle()
            let pill = observer.convert(observer.bounds, to: nil)
            #expect(observer.minimized)
            #expect(abs(pill.minY - canvas.minY - 12) < 1)
            #expect(pill.minX >= canvas.minX && pill.maxX <= canvas.maxX)
            try click(CGPoint(x: pill.midX, y: pill.midY))
            try await settle()
        }
    }

    @Test(arguments: [false, true])
    func anEmptyDesignKeepsTheConversationOpenUntilTheFirstDesignArrives(hasNotes: Bool) async throws {
        let (store, scratch) = TestStore.make()
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id, seed: .init(agent: .codex, mode: .design))
        let artifact = try #require(store.designArtifactURL(for: session))
        let directory = artifact.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if hasNotes {
            try "Design notes".write(to: directory.appendingPathComponent("handoff.md"),
                                     atomically: true, encoding: .utf8)
        }
        let runner = SessionRunner(preferences: testPreferences.store, paths: [.codex: "/usr/bin/true"])
        let preferences = try #require(UserDefaults(suiteName: "design-empty-\(UUID().uuidString)"))
        let hosting = NSHostingController(rootView:
            DesignView(sessionID: session.id)
                .environment(store)
                .environment(runner)
                .environment(AppSettings(agentAvatarURL: scratch.path("avatar.png"), preferences: preferences))
                .environment(ShortcutStore(storageURL: scratch.path("shortcuts.json"), siteDefaults: SiteDefaults()))
                .environment(GlobalCommandPaletteController())
                .background(Theme.background)
                .appOverlays())
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1000, height: 800))
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            runner.stopAll()
        }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        func settle() async throws {
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(20))
                hosting.view.layoutSubtreeIfNeeded()
            }
        }
        try await settle()
        let observer = try #require(descendants(hosting.view).compactMap {
            $0 as? DesignConversationDismissal.ObserverView
        }.first)
        #expect(observer.expanded)
        #expect(!observer.minimized)
        #expect(!observer.enabled)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        #expect(observer.handle(escape, frontmost: window) === escape)
        try await settle()
        #expect(observer.expanded)

        try "body { color: black; }".write(to: directory.appendingPathComponent("style.css"),
                                           atomically: true, encoding: .utf8)
        let screen = hasNotes ? directory.appendingPathComponent("home.html") : artifact
        try """
            {"screens":[{"id":"home","title":"Home","path":"\(screen.lastPathComponent)"}]}
            """.write(to: directory.appendingPathComponent("design.json"),
                      atomically: true, encoding: .utf8)
        try await settle()
        #expect(observer.expanded)
        #expect(!observer.minimized)
        #expect(!observer.enabled)

        try "<!doctype html><html><body><h1>First design</h1></body></html>"
            .write(to: screen, atomically: true, encoding: .utf8)
        try await settle()
        #expect(!observer.expanded)
        #expect(!observer.minimized)
        #expect(observer.enabled)

        try FileManager.default.removeItem(at: screen)
        try await settle()
        #expect(observer.expanded)
        #expect(!observer.minimized)
        #expect(!observer.enabled)
    }

    // Starting a turn swaps the empty canvas for a "Building" one. The panel over it has to
    // stay the same views, or the composer is built twice and both copies fight over focus.
    @Test func startingATurnKeepsTheConversationPanel() async throws {
        let (store, scratch) = TestStore.make()
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id, seed: .init(agent: .codex, mode: .design))
        let agent = scratch.path("slow-agent")
        try "#!/bin/sh\nsleep 5\n".write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)
        let runner = SessionRunner(preferences: testPreferences.store, paths: [.codex: agent.path])
        let preferences = try #require(UserDefaults(suiteName: "design-turn-\(UUID().uuidString)"))
        let hosting = NSHostingController(rootView:
            DesignView(sessionID: session.id)
                .environment(store)
                .environment(runner)
                .environment(AppSettings(agentAvatarURL: scratch.path("avatar.png"), preferences: preferences))
                .environment(ShortcutStore(storageURL: scratch.path("shortcuts.json"), siteDefaults: SiteDefaults()))
                .environment(GlobalCommandPaletteController())
                .background(Theme.background)
                .appOverlays())
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1000, height: 800))
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            runner.stopAll()
        }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        func composers() -> [NSTextView] {
            descendants(hosting.view).compactMap { $0 as? NSTextView }.filter(\.isEditable)
        }
        func settle() async throws {
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(20))
                hosting.view.layoutSubtreeIfNeeded()
            }
        }
        try await settle()
        let composer = try #require(composers().first)
        let panel = try #require(descendants(hosting.view).compactMap {
            $0 as? DesignConversationDismissal.ObserverView
        }.first)

        runner.send("Improve this screen", sessionID: session.id, store: store)
        try await settle()

        #expect(runner.state(session.id).isBusy)
        #expect(composers().map(ObjectIdentifier.init) == [ObjectIdentifier(composer)])
        #expect(descendants(hosting.view).contains { $0 === panel })
    }
}
