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

    private func textViews(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }
}
