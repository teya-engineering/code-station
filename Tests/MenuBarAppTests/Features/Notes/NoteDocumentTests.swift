import AppKit
import Testing
@testable import MenuBarApp

@MainActor struct NoteDocumentTests {
    @Test func markdownPreservesSupportedFormattingAndEscapesLiteralSyntax() {
        let document = NoteDocument(runs: [
            .init(text: "Heading\n", block: .heading),
            .init(text: "bold", bold: true), .init(text: " and "), .init(text: "italic\n", italic: true),
            .init(text: "☑ Finished\n", block: .checklist),
            .init(text: "• Item\n", block: .bullet), .init(text: "1. First\n", block: .numbered),
            .init(text: "A quote\n", block: .quote), .init(text: "let x = `value`\n", block: .code),
            .init(text: "link", link: "https://example.com"), .init(text: " [literal]")
        ])
        let markdown = document.markdown
        #expect(markdown.contains("## Heading"))
        #expect(markdown.contains("**bold** and *italic*"))
        #expect(markdown.contains("- [x] Finished"))
        #expect(markdown.contains("- Item"))
        #expect(markdown.contains("1. First"))
        #expect(markdown.contains("> A quote"))
        #expect(markdown.contains("```\nlet x = `value`\n```"))
        #expect(markdown.contains("[link](<https://example.com>)"))
        #expect(markdown.contains("\\[literal\\]"))
    }

    @Test func richTextRoundTripKeepsUnicodeTraitsBlocksAndLinks() {
        let original = NoteDocument(runs: [
            .init(text: "Hello 🌍 ", bold: true, italic: true),
            .init(text: "Link\n", link: "https://example.com"),
            .init(text: "☐ Finish", block: .checklist)
        ])
        let restored = NoteDocument(original.attributed)
        #expect(restored.text == original.text)
        #expect(restored.runs.first?.bold == true)
        #expect(restored.runs.first?.italic == true)
        #expect(restored.runs.last?.block == .checklist)
        #expect(restored.markdown == original.markdown)
        #expect(NoteDocument.safeLink("javascript:alert(1)") == nil)
        #expect(NoteDocument.safeLink("file:///etc/passwd") == nil)
    }

    @Test func toolbarFormattingAndChecklistsCanBeUndone() throws {
        let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let controller = NoteEditorController()
        controller.view = view
        view.controller = controller
        view.isRichText = true
        view.allowsUndo = true
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.center()
        window.contentView = view
        window.makeFirstResponder(view)
        let undo = try #require(view.undoManager)
        undo.groupsByEvent = false
        view.textStorage?.setAttributedString(NoteDocument(runs: [.init(text: "Keep this")]).attributed)
        view.setSelectedRange(NSRange(location: 0, length: 4))
        controller.readSelection()
        undo.beginUndoGrouping()
        controller.toggleTrait(.boldFontMask)
        undo.endUndoGrouping()
        #expect(NoteDocument(view.attributedString()).runs.first?.bold == true)
        undo.undo()
        #expect(NoteDocument(view.attributedString()).runs.first?.bold == false)

        view.setSelectedRange(NSRange(location: 0, length: 0))
        undo.beginUndoGrouping()
        controller.setBlock(.checklist)
        undo.endUndoGrouping()
        #expect(view.string == "☐ Keep this")
        undo.beginUndoGrouping()
        controller.toggleChecklist()
        undo.endUndoGrouping()
        #expect(view.string == "☑ Keep this")
        view.breakUndoCoalescing()
        undo.undo()
        #expect(view.string == "☐ Keep this")
        window.orderOut(nil)
    }

    @Test func formattingAtTheCursorUpdatesTypingStateWithoutChangingExistingText() {
        let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let controller = NoteEditorController()
        controller.view = view
        view.textStorage?.setAttributedString(NoteDocument(runs: [.init(text: "A thought")]).attributed)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.typingAttributes = NoteDocument.attributes()
        controller.readSelection()
        controller.toggleTrait(.boldFontMask)
        #expect(controller.bold)
        controller.toggleTrait(.italicFontMask)
        #expect(controller.bold && controller.italic)
        #expect(NoteDocument(view.attributedString()).runs.first?.bold == false)
        #expect(view.string == "A thought")
    }
}
