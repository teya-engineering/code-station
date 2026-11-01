import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct ExplorerPresentationTests {
    @Observable final class Navigation {
        var reveal: ExplorerReveal?
    }

    @Test func restoredDraftFitsWideAndNarrowLayouts() async throws {
        let scratch = ScratchDirectory(prefix: "quiet-navigator")
        let root = scratch.url.resolvingSymlinksInPath()
        let folder = root.appendingPathComponent("Sources/MenuBarApp/Features/Explorer")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = "import SwiftUI\n\nstruct ExampleView: View {\n    var body: some View {\n        Text(\"Hello\")\n    }\n}\n"
        for name in ["ExplorerView.swift", "ExplorerLayout.swift", "ExplorerMemory.swift"] {
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let files = await FileTree.children(of: folder, includeHidden: false)
        let selected = try #require(files.first { $0.name == "ExplorerView.swift" })
        let pinned = try #require(files.first { $0.name == "ExplorerLayout.swift" })
        let draft = text.replacingOccurrences(of: "Hello", with: "Unsaved draft")
        let edit = ExplorerMemory.UnsavedEdit(path: selected.path, preview: .text(text), draft: draft,
                                             original: text, loadedAt: selected.modified)
        let memory = ExplorerMemory()
        memory.remember(.init(expanded: Set(FileTree.ancestorDirectories(of: selected.url, beneath: root)),
                              selected: selected,
                              documents: .init(tabs: [selected, pinned], edits: [selected.path: edit], pinned: [pinned])),
                        for: root.path)
        let navigation = Navigation()
        let dialogs = DialogPresenter()
        let view = ExplorerView(root: root.path, reveal: Binding(get: { navigation.reveal }, set: { navigation.reveal = $0 }))
            .environment(memory).environment(dialogs).appOverlays()
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.center()
        defer { window.close() }
        hosting.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        window.layoutIfNeeded()
        let restored = await waitUntil(timeout: .seconds(5)) {
            textViews(in: hosting.view).contains { $0.string == draft }
        }
        #expect(restored)
        for width: CGFloat in [1100, 600, 400] {
            window.setContentSize(NSSize(width: width, height: 700))
            hosting.view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
            hosting.view.layoutSubtreeIfNeeded()
            #expect(hosting.sizeThatFits(in: CGSize(width: width, height: 700)).width <= width)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(100))
                hosting.view.layoutSubtreeIfNeeded()
                if let destination = ProcessInfo.processInfo.environment["EXPLORER_REVIEW_DIRECTORY"] {
                    let bitmap = try #require(hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds))
                    hosting.view.cacheDisplay(in: hosting.view.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: destination).appendingPathComponent("explorer-\(Int(width))-\(name).png"))
                }
            }
        }
        #expect(try String(contentsOf: selected.url, encoding: .utf8) == text)

        navigation.reveal = ExplorerReveal(path: pinned.path, line: nil)
        #expect(await waitUntil { textViews(in: hosting.view).contains { $0.string == text } })
        #expect(dialogs.current == nil)
        navigation.reveal = ExplorerReveal(path: selected.path, line: nil)
        #expect(await waitUntil { textViews(in: hosting.view).contains { $0.string == draft } })
        #expect(dialogs.current == nil)

        let saveEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                     characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        #expect(window.performKeyEquivalent(with: saveEvent))
        #expect(await waitUntil { (try? String(contentsOf: selected.url, encoding: .utf8)) == draft })
        #expect(await waitUntil { memory.place(for: root.path)?.documents.edits[selected.path] == nil })

        let editor = try #require(textViews(in: hosting.view).first { $0.string == draft })
        editor.selectAll(nil)
        editor.insertText("another draft", replacementRange: editor.selectedRange())
        try "external edit".write(to: selected.url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: selected.path)
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.performKeyEquivalent(with: saveEvent))
        #expect(await waitUntil { dialogs.current?.title == "The file has changed" })
        #expect(try String(contentsOf: selected.url, encoding: .utf8) == "external edit")
        dialogs.dismiss()
    }

    private func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

}
