import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct ExplorerHeaderTests {
    @Test(arguments: [false, true])
    func longNamesAndSourceLinesStayInsideTheEditor(reduceMotion: Bool) async throws {
        let scratch = ScratchDirectory(prefix: "explorer-header")
        let root = scratch.url.resolvingSymlinksInPath()
        let name = String(repeating: "LongFilename", count: 10) + "ChartTool.java"
        let url = root.appendingPathComponent(name)
        let original = "class ChartTool {\n    // " + String(repeating: "source ", count: 200) + "\n}\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        let node = try #require(await FileTree.children(of: root, includeHidden: false).first)
        let draft = original + "// unsaved\n"
        let memory = ExplorerMemory()
        memory.remember(.init(selected: node, documents: .init(tabs: [node], edits: [node.path: .init(
            path: node.path, preview: .text(original), draft: draft, original: original, loadedAt: node.modified)])),
                        for: root.path)
        let dialogs = DialogPresenter()
        let hosting = NSHostingController(rootView: ExplorerView(root: root.path)
            .environment(\._accessibilityReduceMotion, reduceMotion)
            .environment(memory).environment(dialogs).appOverlays())
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.center()
        defer { window.close() }
        window.orderFront(nil)
        window.layoutIfNeeded()
        #expect(await waitUntil { self.editor(in: hosting.view)?.string == draft })

        try await Task.sleep(for: .seconds(Motion.revealDuration))

        func verify(width: CGFloat, suffix: String = "") throws {
            window.setContentSize(NSSize(width: width, height: 700))
            hosting.view.frame.size = NSSize(width: width, height: 700)
            hosting.view.layoutSubtreeIfNeeded()
            let textView = try #require(editor(in: hosting.view))
            let scroll = try #require(textView.enclosingScrollView)
            let viewport = scroll.convert(scroll.bounds, to: hosting.view)
            let title = try #require(views(in: hosting.view).first {
                $0.identifier?.rawValue == name
                    && $0.convert($0.bounds, to: hosting.view).minX >= viewport.minX
                    && $0.convert($0.bounds, to: hosting.view).minY > 78
            })
            let titleFrame = title.convert(title.bounds, to: hosting.view)
            let compact = viewport.width < 530
            let inset: CGFloat = compact ? 16 : 20
            let padding: CGFloat = compact ? 5 : 4
            let toolbarHeight: CGFloat = compact ? 64 : 36
            let breadcrumbs = try #require(views(in: hosting.view).compactMap { $0 as? NSScrollView }
                .map { $0.convert($0.bounds, to: hosting.view) }
                .filter { $0.minX == viewport.minX && $0.width == viewport.width && $0.maxY < viewport.minY }
                .max { $0.maxY < $1.maxY })
            #expect(abs(viewport.minY - breadcrumbs.maxY - toolbarHeight) < 0.01)
            #expect(titleFrame.minX >= viewport.minX + inset)
            #expect(titleFrame.maxX <= viewport.maxX - inset + 1)
            #expect(titleFrame.width > 0)
            #expect(titleFrame.minY >= breadcrumbs.maxY + padding)
            #expect(titleFrame.maxY <= viewport.minY - padding)
            for label in ["Find in file (Cmd+F or Ctrl+F)", "Pin file", "File details", "File actions"] {
                let action = try #require(views(in: hosting.view).first { $0.identifier?.rawValue == label })
                let frame = action.convert(action.bounds, to: hosting.view)
                #expect(frame.minX >= viewport.minX + inset)
                #expect(frame.maxX <= viewport.maxX - inset + 1)
                #expect(frame.size == NSSize(width: 28, height: 28))
                #expect(abs(frame.maxY - (viewport.minY - padding)) < 0.01)
                if compact { #expect(frame.minY >= titleFrame.maxY + 3) }
                else { #expect(abs(frame.midY - titleFrame.midY) < 1) }
            }
            let footer = NSRect(x: viewport.minX, y: viewport.maxY,
                                width: viewport.width, height: hosting.view.bounds.maxY - viewport.maxY)
            #expect(footer.height >= 46 - 0.01)
            let before = try snapshot(hosting.view, rect: footer)
            scroll.contentView.scroll(to: NSPoint(x: 600, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            hosting.view.layoutSubtreeIfNeeded()
            #expect(scroll.contentView.bounds.minX > 0)
            #expect(title.convert(title.bounds, to: hosting.view) == titleFrame)
            #expect(try snapshot(hosting.view, rect: footer) == before)
            if let destination = ProcessInfo.processInfo.environment["EXPLORER_REVIEW_DIRECTORY"] {
                try snapshot(hosting.view, rect: hosting.view.bounds)
                    .write(to: URL(fileURLWithPath: destination).appendingPathComponent(
                        "long-name-\(Int(width))\(suffix)\(reduceMotion ? "-reduced-motion" : "").png"))
            }
        }
        for width: CGFloat in [1100, 831, 830, 600, 541, 540, 400, 320, 280] {
            try verify(width: width)
        }
        try verify(width: 1100)
        try click("File details", in: hosting.view, window: window)
        try #require(await waitUntil(timeout: .seconds(3)) {
            self.views(in: hosting.view).contains { $0.identifier?.rawValue == "Close file details" }
        })
        try await Task.sleep(for: .seconds(Motion.revealDuration))
        try verify(width: 1100, suffix: "-details")
        try verify(width: 1000, suffix: "-details")
        try verify(width: 871, suffix: "-details")
        try click("Close file details", in: hosting.view, window: window)
        #expect(await waitUntil { !self.views(in: hosting.view).contains { $0.identifier?.rawValue == "Close file details" } })
        try click("Focus editor", in: hosting.view, window: window)
        #expect(await waitUntil { self.views(in: hosting.view).contains { $0.identifier?.rawValue == "Exit focus mode" } })
        try verify(width: 871, suffix: "-focus")

        let save = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "s",
            charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        #expect(window.performKeyEquivalent(with: save))
        #expect(await waitUntil { memory.place(for: root.path)?.documents.edits[node.path] == nil })
        #expect(try String(contentsOf: url, encoding: .utf8) == draft)
        try await Task.sleep(for: .seconds(Motion.revealDuration))
        #expect(!window.performKeyEquivalent(with: save))
        try verify(width: 320, suffix: "-saved")
    }

    private func click(_ label: String, in view: NSView, window: NSWindow) throws {
        let anchor = try #require(views(in: view).first { $0.identifier?.rawValue == label })
        let rect = anchor.convert(anchor.bounds, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: rect.midX, y: rect.midY), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    private func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    private func editor(in view: NSView) -> NSTextView? {
        views(in: view).compactMap { $0 as? NSTextView }.first
    }

    private func snapshot(_ view: NSView, rect: NSRect) throws -> Data {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
