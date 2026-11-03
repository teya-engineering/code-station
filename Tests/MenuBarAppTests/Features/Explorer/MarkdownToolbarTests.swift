import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct MarkdownToolbarTests {
    @Test(arguments: [false, true])
    func modesAndFileActionsKeepTheDraft(reduceMotion: Bool) async throws {
        let repo = try GitRepo()
        let original = "# Saved document\n\nText on disk.\n"
        try repo.write("README.md", original)
        let node = try #require(await FileTree.children(of: repo.url, includeHidden: false).first { $0.name == "README.md" })
        let draft = original + "\nUnsaved writing.\n"
        let fixture = Fixture(root: repo.path, node: node, original: original, draft: draft, reduceMotion: reduceMotion)
        defer { fixture.close() }
        try #require(await waitUntil { fixture.textViews.contains { $0 is NoteTextView } })

        try await fixture.openMenu("Markdown mode")
        #expect(fixture.items.map(\.label) == ["Edit", "Source", "Preview"])
        #expect(fixture.items.map(\.subtitle) == ["Formatted writing", "Markdown syntax", "Read-only document"])
        #expect(fixture.items.first?.checked == true)
        try await fixture.snapshot("mode-menu")
        let escape = try fixture.key("\u{1b}", code: 53)
        try #require(await waitUntil { fixture.window.performKeyEquivalent(with: escape) })
        #expect(!fixture.menus.isOpen)
        try await fixture.openMenu("Markdown mode")
        try fixture.choose("Source")
        try #require(await waitUntil { fixture.textViews.contains { !($0 is NoteTextView) && $0.string == draft } })
        try await fixture.openMenu("Markdown mode")
        #expect(fixture.items.first { $0.label == "Source" }?.checked == true)
        try fixture.choose("Preview")
        try #require(await waitUntil { fixture.textViews.allSatisfy { !$0.isEditable } })
        #expect(repo.read("README.md") == original)

        try await fixture.openMenu("File actions")
        #expect(fixture.items.map(\.label) == ["Pin file", "File details", "Revert changes", "Copy path",
                                             "Export Markdown copy", "Open externally", "Reveal in Finder"])
        #expect(fixture.items.first { $0.label == "Revert changes" }?.isDisabled == false)
        try await fixture.snapshot("file-menu")
        try fixture.choose("Pin file")
        #expect(await waitUntil { fixture.memory.place(for: repo.path)?.documents.pinned.contains(node) == true })
        try await fixture.openMenu("File actions")
        #expect(fixture.items.first?.label == "Unpin file")
        #expect(fixture.items.first?.checked == true)
        try fixture.choose("File details")
        #expect(await waitUntil { fixture.anchor("Close file details") != nil })
        try fixture.click("Close file details")

        try await fixture.openMenu("File actions")
        try fixture.choose("Revert changes")
        #expect(fixture.dialogs.current?.title == "Revert your changes?")
        #expect(fixture.dialogs.current?.isModal == true)
        try await Task.sleep(for: .seconds(Motion.controlDuration))
        #expect(fixture.window.performKeyEquivalent(with: try fixture.key("\u{1b}", code: 53)))
        #expect(fixture.dialogs.current == nil)
        try await fixture.openMenu("Markdown mode")
        try fixture.choose("Source")
        #expect(await waitUntil { fixture.textViews.contains { $0.string == draft } })
        try await fixture.openMenu("Markdown mode")
        try fixture.choose("Preview")

        let save = try fixture.key("s", code: 1, modifiers: .command)
        try await Task.sleep(for: .seconds(Motion.controlDuration))
        #expect(fixture.window.performKeyEquivalent(with: save))
        #expect(await waitUntil { repo.read("README.md") == draft })
        #expect(await waitUntil { fixture.memory.place(for: repo.path)?.documents.edits[node.path] == nil })
        #expect(try repo.git("status", "--porcelain") == "M README.md")
        #expect(!fixture.window.performKeyEquivalent(with: save))
        try await fixture.openMenu("File actions")
        #expect(fixture.items.first { $0.label == "Revert changes" }?.isDisabled == true)
        fixture.menus.dismiss()
        try await fixture.snapshot("saved-preview")

        try await fixture.openMenu("Markdown mode")
        try fixture.choose("Source")
        try #require(await waitUntil { fixture.textViews.contains { $0.string == draft && $0.isEditable } })
        let editor = try #require(fixture.textViews.first { $0.isEditable })
        editor.selectAll(nil)
        editor.insertText("Discard this edit", replacementRange: editor.selectedRange())
        try await fixture.openMenu("File actions")
        try fixture.choose("Revert changes")
        let revert = try #require(fixture.dialogs.current?.actions.first { $0.label == "Revert changes" })
        fixture.dialogs.run(revert)
        #expect(await waitUntil { fixture.textViews.contains { $0.string == draft } })
        #expect(repo.read("README.md") == draft)
    }

    @Test(arguments: [false, true])
    func longNamesUnavailableEditAndEmptyPreview(reduceMotion: Bool) async throws {
        let scratch = ScratchDirectory(prefix: "markdown-toolbar")
        let name = String(repeating: "workspace-guide-", count: 10) + ".md"
        let original = "# Windows document\r\n\r\nKeep these line endings.\r\n"
        let url = scratch.url.appendingPathComponent(name)
        try original.write(to: url, atomically: true, encoding: .utf8)
        let node = try #require(await FileTree.children(of: scratch.url, includeHidden: false).first)
        let fixture = Fixture(root: scratch.url.path, node: node, original: original, draft: original, reduceMotion: reduceMotion)
        defer { fixture.close() }
        try #require(await waitUntil { fixture.textViews.contains { $0.string == original } })
        try await fixture.openMenu("Markdown mode")
        #expect(fixture.items.first?.isDisabled == true)
        #expect(fixture.items.first?.subtitle?.contains("Windows line endings") == true)
        #expect(fixture.items.first { $0.label == "Source" }?.checked == true)
        fixture.menus.dismiss()

        for width: CGFloat in [1100, 831, 830, 600, 540, 400, 320, 280] {
            fixture.window.setContentSize(NSSize(width: width, height: 700))
            fixture.host.view.frame.size = NSSize(width: width, height: 700)
            fixture.host.view.layoutSubtreeIfNeeded()
            #expect(fixture.host.sizeThatFits(in: CGSize(width: width, height: 700)).width <= width)
            let editor = try #require(fixture.textViews.first?.enclosingScrollView)
            let viewport = editor.convert(editor.bounds, to: fixture.host.view)
            for label in [name, "Markdown mode", "Find in file (Cmd+F or Ctrl+F)", "File actions"] {
                let anchor = try #require(fixture.anchor(label))
                let frame = anchor.convert(anchor.bounds, to: fixture.host.view)
                #expect(frame.width > 0)
                #expect(frame.minX >= viewport.minX)
                #expect(frame.maxX <= viewport.maxX)
            }
            try await fixture.snapshot("long-name-\(Int(width))")
        }
        fixture.window.setContentSize(NSSize(width: 600, height: 700))
        let editor = try #require(fixture.textViews.first { $0.isEditable })
        editor.selectAll(nil)
        editor.insertText("", replacementRange: editor.selectedRange())
        try await fixture.openMenu("Markdown mode")
        #expect(fixture.items.first?.isDisabled == false)
        try fixture.choose("Preview")
        try await fixture.snapshot("empty-preview")
        try await fixture.openMenu("Markdown mode")
        try fixture.choose("Source")
        #expect(await waitUntil { fixture.textViews.contains { $0.string.isEmpty && $0.isEditable } })
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }

    @Test func failedSaveRetainsTheDraftAndCanBeSavedAgain() async throws {
        let scratch = ScratchDirectory(prefix: "markdown-save-failure")
        let url = scratch.url.appendingPathComponent("README.md")
        let original = "# Saved document\n"
        let draft = original + "\nKeep my writing.\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        let node = try #require(await FileTree.children(of: scratch.url, includeHidden: false).first)
        let fixture = Fixture(root: scratch.url.path, node: node, original: original, draft: draft, reduceMotion: false)
        defer { fixture.close() }
        try #require(await waitUntil { fixture.textViews.contains { $0 is NoteTextView } })
        try await fixture.openMenu("Markdown mode")
        try fixture.choose("Preview")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: scratch.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.url.path) }
        try fixture.click("Save changes (Cmd+S)")
        try await fixture.openMenu("File actions")
        #expect(fixture.items.first { $0.label == "Revert changes" }?.isDisabled == false)
        fixture.menus.dismiss()
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
        try await fixture.snapshot("save-error")
        try await fixture.openMenu("Markdown mode")
        try fixture.choose("Source")
        #expect(await waitUntil { fixture.textViews.contains { $0.string == draft && $0.isEditable } })
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.url.path)
        try fixture.click("Save changes (Cmd+S)")
        #expect(await waitUntil { (try? String(contentsOf: url, encoding: .utf8)) == draft })
        try await fixture.openMenu("File actions")
        #expect(fixture.items.first { $0.label == "Revert changes" }?.isDisabled == true)
        fixture.menus.dismiss()
        try await fixture.snapshot("recovered-save")
    }

    @MainActor private final class Fixture {
        let memory = ExplorerMemory()
        let menus = MenuPresenter()
        let dialogs = DialogPresenter()
        let host: NSHostingController<AnyView>
        let window: NSWindow
        let reduceMotion: Bool

        init(root: String, node: FileNode, original: String, draft: String, reduceMotion: Bool) {
            self.reduceMotion = reduceMotion
            memory.remember(.init(selected: node, documents: .init(tabs: [node], edits: draft == original ? [:] : [
                node.path: .init(path: node.path, preview: .text(original), draft: draft,
                                 original: original, loadedAt: node.modified)
            ])), for: root)
            host = NSHostingController(rootView: AnyView(ToolbarHost(root: root, memory: memory,
                                                                   menus: menus, dialogs: dialogs,
                                                                   reduceMotion: reduceMotion)))
            host.sizingOptions = []
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            window.setContentSize(NSSize(width: 1100, height: 700))
            host.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
            window.appearance = NSAppearance(named: reduceMotion ? .darkAqua : .aqua)
            window.center()
            window.orderFront(nil)
        }

        func close() {
            window.close()
        }

        var items: [MenuItem] { menus.entries.compactMap { if case .item(let item) = $0 { item } else { nil } } }
        var textViews: [NSTextView] { views(host.view).compactMap { $0 as? NSTextView } }

        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func anchor(_ label: String) -> NSView? { views(host.view).first { $0.identifier?.rawValue == label } }

        func openMenu(_ label: String) async throws {
            try await Task.sleep(for: .seconds(Motion.controlDuration))
            try click(label)
            try #require(await waitUntil(timeout: .seconds(3)) { menus.isOpen })
        }

        func choose(_ label: String) throws {
            let item = try #require(items.first { $0.label == label })
            try #require(!item.isDisabled)
            menus.run(item)
        }

        func click(_ label: String) throws {
            // Not named `anchor`: the swift-testing on CI expands #require into a closure
            // that calls `anchor(...)`, where the new constant would shadow the method.
            let target = try #require(anchor(label))
            let rect = target.convert(target.bounds, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: rect.midX, y: rect.midY), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0)))
            }
        }

        func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }

        func snapshot(_ name: String) async throws {
            guard let directory = ProcessInfo.processInfo.environment["EXPLORER_REVIEW_DIRECTORY"] else { return }
            try await Task.sleep(for: .seconds(Motion.controlDuration))
            host.view.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("toolbar-\(name)-reduce-\(reduceMotion).png"))
        }
    }

    private struct ToolbarHost: View {
        let root: String
        let memory: ExplorerMemory
        let menus: MenuPresenter
        let dialogs: DialogPresenter
        let reduceMotion: Bool
        @State private var tooltips = TooltipPresenter()

        var body: some View {
            ExplorerView(root: root)
                .disabled(dialogs.current?.isModal == true)
                .accessibilityHidden(dialogs.current?.isModal == true)
                .overlay { DialogHost() }.overlay { ContextMenuHost() }
                .environment(memory).environment(menus).environment(dialogs).environment(tooltips)
                .environment(\._accessibilityReduceMotion, reduceMotion)
        }
    }
}
