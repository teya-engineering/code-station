import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor struct MarkdownEditorPresentationTests {
    @Observable final class Draft {
        var source = "# A place for thoughts\n\nWrite beside your project files.\n\n## Next steps\n\n- [ ] Keep the draft\n- [x] Review the plan\n"
        var mode = MarkdownEditorMode.edit
    }

    @Test(arguments: [false, true]) func modesShareTheDraftAndFitNarrowWindows(reduceMotion: Bool) async throws {
        let draft = Draft()
        let original = draft.source
        let view = MarkdownEditor(documentID: "draft.md",
                                  source: Binding(get: { draft.source }, set: { draft.source = $0 }),
                                  mode: Binding(get: { draft.mode }, set: { draft.mode = $0 }))
            .environment(\._accessibilityReduceMotion, reduceMotion)
            .appOverlays()
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.center()
        window.orderFront(nil)
        defer { window.close() }
        #expect(await waitUntil { self.textViews(host.view).contains { $0 is NoteTextView } })
        for width: CGFloat in [1100, 600, 400] {
            window.setContentSize(NSSize(width: width, height: 700))
            for mode in MarkdownEditorMode.allCases {
                draft.mode = mode
                try await Task.sleep(for: .milliseconds(350))
                host.view.layoutSubtreeIfNeeded()
                #expect(host.sizeThatFits(in: CGSize(width: width, height: 700)).width <= width)
                #expect(draft.source == original)
                if mode == .preview { #expect(textViews(host.view).allSatisfy { !$0.isEditable }) }
                if let directory = ProcessInfo.processInfo.environment["EXPLORER_REVIEW_DIRECTORY"] {
                    window.appearance = NSAppearance(named: reduceMotion ? .darkAqua : .aqua)
                    try await Task.sleep(for: .milliseconds(60))
                    let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                    host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                        URL(fileURLWithPath: directory).appendingPathComponent("markdown-\(mode.rawValue)-\(Int(width))-reduce-\(reduceMotion).png"))
                }
            }
        }
        draft.mode = .edit
        #expect(await waitUntil { self.textViews(host.view).contains { $0 is NoteTextView } })
        let editor = try #require(textViews(host.view).first { $0 is NoteTextView })
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("Edited ", replacementRange: editor.selectedRange())
        #expect(await waitUntil { draft.source.contains("Edited") })
        let edited = draft.source
        for mode in [MarkdownEditorMode.source, .preview, .edit, .source, .edit] { draft.mode = mode; await Task.yield() }
        #expect(await waitUntil { self.textViews(host.view).contains { $0 is NoteTextView && $0.string.contains("Edited") } })
        #expect(draft.source == edited)
        draft.source = original
        #expect(await waitUntil { self.textViews(host.view).contains { $0 is NoteTextView && !$0.string.contains("Edited") } })
        draft.source = "| Keep unsupported Markdown |"
        #expect(await waitUntil { draft.mode == .source })
        draft.source = "# Supported again"
        try await Task.sleep(for: .milliseconds(50))
        #expect(draft.mode == .source)
    }

    @Test(arguments: [false, true]) func personalNotesUseTheSharedNotebook(reduceMotion: Bool) async throws {
        let scratch = ScratchDirectory(prefix: "explorer-notes-ui")
        let notebook = NotebookStore(directory: scratch.url)
        let preferences = TestPreferences()
        let dictation = Dictation(preferences: preferences.store)
        let id = try #require(notebook.create(scope: "workspace:test"))
        notebook.update(id) { $0.title = "A home for thoughts" }
        let originalSource = "Remember the next step.\n\n\n"
        notebook.updateMarkdown(id, source: originalSource)
        let note = ExplorerPersonalNote(id: id, projects: [.init(root: scratch.url.path, name: "Project")],
                                        moved: { _ in }, close: {}, notify: { _ in })
        for (name, content) in [("personal", AnyView(note))] {
            let host = NSHostingController(rootView: content.environment(notebook).environment(dictation)
                .environment(\._accessibilityReduceMotion, reduceMotion).appOverlays())
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            window.setContentSize(NSSize(width: 430, height: 700))
            host.view.frame = NSRect(x: 0, y: 0, width: 430, height: 700)
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.appearance = NSAppearance(named: reduceMotion ? .darkAqua : .aqua)
            try await Task.sleep(for: .milliseconds(350))
            host.view.layoutSubtreeIfNeeded()
            #expect(host.sizeThatFits(in: CGSize(width: 430, height: 700)).width <= 430)
            if name == "personal" {
                #expect(textViews(host.view).contains { $0.string == "Remember the next step." })
                #expect(notebook.note(id)?.scopeID == "workspace:test")
                let file = scratch.path("next-step.txt")
                try Data("Attachment stays with the personal note.".utf8).write(to: file)
                let editor = try #require(textViews(host.view).first { $0 is NoteTextView } as? NoteTextView)
                let original = NoteDocument(editor.attributedString())
                editor.setSelectedRange(NSRange(location: original.text.utf16.count, length: 0))
                let take = NoteDictation(note: try #require(notebook.note(id)), store: notebook, view: editor, document: original)
                take.binding.wrappedValue.text = original.text + " Together."
                #expect(notebook.note(id)?.body.text.contains("Together.") == true)
                take.binding.wrappedValue.text = original.text
                #expect(notebook.note(id)?.bodyMarkdown == originalSource)
                editor.onFiles?([file])
                #expect(await waitUntil { notebook.note(id)?.attachments.count == 1 })
                try await Task.sleep(for: .milliseconds(350))
                #expect(host.sizeThatFits(in: CGSize(width: 430, height: 700)).width <= 430)
            }
            if let directory = ProcessInfo.processInfo.environment["EXPLORER_REVIEW_DIRECTORY"] {
                let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("\(name)-reduce-\(reduceMotion).png"))
            }
            if name == "personal" {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    window.sendEvent(try #require(NSEvent.mouseEvent(
                        with: type, location: NSPoint(x: 100, y: 75), modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
                }
                try await Task.sleep(for: .milliseconds(350))
                #expect(window.attachedSheet == nil)
                #expect(textViews(host.view).allSatisfy { !$0.isEditable })
                if let directory = ProcessInfo.processInfo.environment["EXPLORER_REVIEW_DIRECTORY"] {
                    let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                    host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                        URL(fileURLWithPath: directory).appendingPathComponent("attachment-preview-reduce-\(reduceMotion).png"))
                }
            }
            window.close()
        }
    }

    private func textViews(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }
}
