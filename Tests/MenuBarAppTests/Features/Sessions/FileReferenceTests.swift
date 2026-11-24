import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct FileReferenceTests {
    @Test func resolvesRelativePathsAndKeepsLineAndHeadingTargets() throws {
        let reference = try #require(TranscriptLink.fileReference(
            for: URL(string: "docs/../README.md#L42")!, relativeTo: "/work/app", fileExists: { _ in false }))
        #expect(reference.url.path == "/work/app/README.md")
        #expect(reference.line == 42)
        #expect(reference.destination.fragment == "L42")
        let heading = try #require(TranscriptLink.fileReference(
            for: URL(string: "docs/guide.md#setup")!, relativeTo: "/work/app"))
        #expect(heading.fragment == "setup")
        #expect(heading.line == nil)
        let linked = AttributedString.inlineMarkdown("[read more](/work/app/README.md#setup)")
        #expect(linked.runs.compactMap(\.link).first?.fragment == "setup")
        #expect(TranscriptLink.fileReference(for: URL(string: "https://example.com/doc.md")!, relativeTo: "/work/app") == nil)
        #expect(TranscriptLink.fileReference(for: URL(string: "//example.com/doc.md")!, relativeTo: "/work/app") == nil)
    }

    @Test func missingFilesRetainTheirRealPathAndLineForRetry() throws {
        let file = try #require(TranscriptLink.fileReference(
            for: URL(fileURLWithPath: "/work/app/gone.swift:12:4"), relativeTo: "/work/app", fileExists: { _ in false }))
        #expect(file.url.path == "/work/app/gone.swift")
        #expect(file.line == 12)
        #expect(file.explorerBlockedReason(in: ["/work/app"]) == "File is unavailable")
        #expect(file.explorerBlockedReason(in: ["/another"]) == "Outside this worktree")
    }

    @Test func canonicalMembershipIncludesAttachedRootsAndRejectsEscapingSymlinks() throws {
        let scratch = ScratchDirectory()
        let root = scratch.path("checkout")
        let attached = scratch.path("attached")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: attached, withIntermediateDirectories: true)
        let outside = scratch.path("outside.md")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.md"), withDestinationURL: outside)
        let escaped = try #require(TranscriptLink.fileReference(
            for: URL(string: "escape.md")!, relativeTo: root.path))
        #expect(escaped.explorerRoot(in: [root.path]) == nil)
        #expect(TranscriptLink.explorerTarget(for: root.appendingPathComponent("escape.md"), roots: [root.path]) == nil)
        let attachedFile = attached.appendingPathComponent("AGENTS.md")
        try "attached".write(to: attachedFile, atomically: true, encoding: .utf8)
        let target = try #require(TranscriptLink.explorerTarget(for: attachedFile, roots: [root.path, attached.path]))
        #expect(target.root == attached.path)
        #expect(target.path == attachedFile.path)
        let alias = scratch.path("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: attached)
        let aliased = try #require(TranscriptLink.explorerTarget(for: attachedFile, roots: [alias.path]))
        #expect(aliased.root == alias.path)
        #expect(aliased.path == alias.appendingPathComponent("AGENTS.md").path)
    }

    @Test func theMenuIsCompactAndPreviewDoesNotDependOnExplorerEligibility() throws {
        let dialogs = DialogPresenter()
        let reference = FileReference(url: URL(fileURLWithPath: "/private/tmp/proposal.md"), line: nil, fragment: nil)
        let actions = FileReferenceActions(reference: reference, roots: ["/work/app"], dialogs: dialogs,
                                           textScale: 1, openExplorer: { _ in false }, note: { _, _ in })
        let entries = actions.entries { nil }
        let items = entries.compactMap { if case .item(let item) = $0 { item } else { nil } }
        #expect(items.map(\.label) == ["Preview", "Open in Explorer", "Reveal in Finder", "Copy path"])
        #expect(items.allSatisfy { $0.subtitle == nil && $0.detail == nil })
        #expect(items[1].isDisabled)
        #expect(items[1].help == "Outside this worktree")
        #expect(items[1].handler == nil)
        items[0].handler?()
        #expect(dialogs.current?.isModal == true)
        #expect(dialogs.current?.framesItself == true)
        dialogs.dismiss()
    }

    @Test func outlineUsesMarkdownHeadingsAndDisambiguatesDuplicates() {
        let outline = FileReferenceDocument.outline("""
        # A **proposal**
        Intro
        ```markdown
        # Not a heading
        ```
        ## Same name
        content
        ## Same name
        other

        Underlined title
        ---------------
        """)
        #expect(outline.map(\.title) == ["A proposal", "Same name", "Same name", "Underlined title"])
        #expect(outline.map(\.fragment) == ["a-proposal", "same-name", "same-name-1", "underlined-title"])
        #expect(Set(outline.map(\.id)).count == 4)
    }

    @Test func documentFindStartsAtTheFirstVisibleTextMatchAndClearsMissingResults() throws {
        let find = TranscriptFind()
        let id = UUID()
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.string = "First needle. Second needle."
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.center()
        defer { window.close() }
        find.register(view, messageID: id)
        find.searchDocument("needle", messageID: id)
        #expect(find.result.matches.count == 2)
        #expect(find.selection == 0)
        #expect(find.placeCurrent()?.range.location == 6)
        find.move(by: 1)
        #expect(find.placeCurrent()?.range.location == 21)
        find.searchDocument("absent", messageID: id)
        #expect(find.summary == "No matches")
        #expect(find.highlights(in: view).all.isEmpty)
        find.close()
        #expect(!find.isPresented)
    }

    @Test func sourcePreviewIsReadOnlyAndKeepsItsLinkedLine() throws {
        let text = "one\ntwo\nthree\n"
        let source = CodeEditorView(documentID: "read-only", text: .constant(text), language: nil,
                                    matches: [], currentMatch: nil, revealLine: 2, isEditable: false)
        let coordinator = CodeEditorView.Coordinator(source)
        let pane = coordinator.makePane()
        pane.frame = CGRect(x: 0, y: 0, width: 500, height: 300)
        let window = NSWindow(contentRect: pane.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        window.center()
        defer { CodeEditorView.dismantleNSView(pane, coordinator: coordinator); window.close() }
        pane.layoutSubtreeIfNeeded()
        coordinator.apply(source)
        let textView = try #require(pane.scrollView.documentView as? NSTextView)
        #expect(!textView.isEditable)
        #expect(textView.isSelectable)
        #expect(textView.string == text)
        #expect(textView.selectedRange().location == 4)
    }

    @Test func readerFitsAllReferenceWidthsAndAppearancesWithoutChangingTheFile() async throws {
        let scratch = ScratchDirectory(prefix: "file-reader")
        let file = scratch.path("architecture-catalog-proposal.md")
        let text = """
        # Architecture catalog proposal
        A read-only proposal with **formatted text**, a [local reference](AGENTS.md) and a table.

        ## Proposed contract
        | Field | Purpose |
        | --- | --- |
        | `source` | Link to the ingested declaration |
        | `dependencies` | Record the connected services |

        > Keep the last valid catalog when a refresh fails.

        ## Example declaration
        ```yaml
        dependencies:
          - name: account-service
        ```

        ## Validation
        - [x] Resolve the exact checkout
        - [ ] Read the remaining proposal
        """
        try text.write(to: file, atomically: true, encoding: .utf8)
        for reduced in [false, true] {
            let dialogs = DialogPresenter()
            dialogs.show(Dialog(title: file.lastPathComponent, actions: [], isModal: true))
            let preview = FileReferencePreview(reference: FileReference(url: file, line: nil, fragment: nil),
                                               roots: [], origin: nil, openExplorer: { _ in false })
                .environment(dialogs).environment(MenuPresenter()).environment(TooltipPresenter())
                .environment(\._accessibilityReduceMotion, reduced)
            let host = NSHostingController(rootView: preview)
            host.sizingOptions = []
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1080, height: 800),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            window.center()
            window.orderFront(nil)
            defer { dialogs.dismiss(); window.close() }
            #expect(await waitUntil(timeout: .seconds(5)) {
                textViews(host.view).contains { $0.string.contains("Architecture catalog proposal") }
            })
            for width: CGFloat in [1080, 688, 358] {
                window.setContentSize(CGSize(width: width, height: 800))
                host.view.frame = CGRect(x: 0, y: 0, width: width, height: 800)
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    window.appearance = NSAppearance(named: appearance)
                    try await Task.sleep(for: .milliseconds(100))
                    host.view.layoutSubtreeIfNeeded()
                    #expect(host.sizeThatFits(in: CGSize(width: width, height: 800)).width <= width)
                    #expect(textViews(host.view).allSatisfy { !$0.isEditable })
                    if let directory = ProcessInfo.processInfo.environment["FILE_REFERENCE_REVIEW_DIRECTORY"] {
                        let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                        try #require(bitmap.representation(using: .png, properties: [:]))
                            .write(to: URL(fileURLWithPath: directory)
                                .appendingPathComponent("reader-\(Int(width))-\(name)-\(reduced).png"))
                    }
                }
            }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
    }

    @Test func linkedTextOpensTheAnchoredMenuThenPreviewAndRestoresFocus() async throws {
        let scratch = ScratchDirectory(prefix: "file-actions")
        let file = scratch.path("proposal.md")
        try "# Proposal\n\nRead this document.\n".write(to: file, atomically: true, encoding: .utf8)
        let dialogs = DialogPresenter()
        let menus = MenuPresenter()
        let tooltips = TooltipPresenter()
        let message = ChatMessage(role: .assistant, text: "Read the [concrete proposal](\(file.path)).")
        let view = MessageView(message: message, projectPath: scratch.url.path, textScale: 1)
            .padding(Space.pane)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.background)
            .disabled(dialogs.current != nil)
            .overlay { DialogHost() }
            .overlay { ContextMenuHost() }
            .environment(dialogs).environment(menus).environment(tooltips)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(CGSize(width: 900, height: 700))
        host.view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        window.center()
        window.makeKeyAndOrderFront(nil)
        host.view.layoutSubtreeIfNeeded()
        defer { menus.dismiss(); dialogs.dismiss(); window.close() }
        #expect(await waitUntil { !textViews(host.view).isEmpty })
        let text = try #require(textViews(host.view).first)
        let layout = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        layout.ensureLayout(for: container)
        let range = (text.string as NSString).range(of: "concrete proposal")
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
        let point = text.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 0))
            if type == .leftMouseDown { text.mouseDown(with: event) } else { text.mouseUp(with: event) }
        }
        #expect(menus.isOpen)
        #expect(menus.width == FileReferenceMetrics.menuWidth)
        let anchor = FrameAnchor.fromTop(text.convert(rect, to: host.view), in: host.view)
        #expect(abs(menus.origin.x - anchor.minX) < 1)
        #expect(abs(menus.origin.y - anchor.maxY - Space.sm) < 1)
        try await Task.sleep(for: .milliseconds(300))
        try capture(host.view, name: "file-menu")
        let preview = try #require(menus.entries.compactMap { entry -> MenuItem? in
            if case .item(let item) = entry, item.label == "Preview" { return item }
            return nil
        }.first)
        menus.run(preview)
        #expect(dialogs.current?.isModal == true)
        #expect(!menus.isOpen)
        #expect(await waitUntil { textViews(host.view).contains { $0.string.contains("Read this document") } })
        try await Task.sleep(for: .milliseconds(400))
        try capture(host.view, name: "opened-preview")
        #expect(textViews(host.view).allSatisfy { !$0.isEditable })
        if ProcessInfo.processInfo.environment["FILE_REFERENCE_INTERACTIVE"] == "1" {
            _ = await waitUntil(timeout: .seconds(300)) { dialogs.current == nil }
        }
        dialogs.dismiss()
        #expect(await waitUntil { window.firstResponder === text })
        #expect(try String(contentsOf: file, encoding: .utf8) == "# Proposal\n\nRead this document.\n")
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["FILE_REFERENCE_REVIEW_DIRECTORY"] else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }

    private func textViews(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }
}
