import AppKit
import Synchronization
import Testing
@testable import MenuBarApp

@MainActor struct NotebookTests {
    private let scratch = ScratchDirectory(prefix: "notebook-tests")

    @Test func editsPinsSelectionAndFormattingSurviveReload() throws {
        let store = NotebookStore(directory: scratch.url)
        let first = try #require(store.create())
        store.update(first) {
            $0.title = "Planning"
            $0.body = NoteDocument(runs: [.init(text: "Keep this", bold: true), .init(text: "\n☑ Done", block: .checklist)])
        }
        store.togglePin(first)
        let second = try #require(store.create())
        store.update(second) { $0.title = "Another thought" }
        #expect(store.saving)
        #expect(store.savedCount == 0)
        #expect(store.flush())

        let reloaded = NotebookStore(directory: scratch.url)
        #expect(reloaded.notes == store.notes)
        #expect(reloaded.selectedID == second)
        #expect(reloaded.savedCount == 2)
        #expect(reloaded.matching().map(\.id) == [first, second])
        #expect(reloaded.matching("KEEP").map(\.id) == [first])
        #expect(reloaded.matching("thought", pinnedOnly: true).isEmpty)
    }

    @Test func duplicateKeepsTheBodyButGetsItsOwnIdentityAndEditHistory() throws {
        let store = NotebookStore(directory: scratch.url)
        let id = try #require(store.create())
        store.update(id) { $0.title = "Ideas"; $0.body = .init(runs: [.init(text: "one")]) }
        store.togglePin(id)
        let copyID = try #require(store.duplicate(id))
        let copy = try #require(store.note(copyID))
        #expect(copy.title == "Ideas (copy)")
        #expect(copy.body == store.note(id)?.body)
        #expect(!copy.pinned)
        store.update(copyID) { $0.body = .init(runs: [.init(text: "two")]) }
        #expect(store.note(id)?.body.text == "one")
        #expect(store.flush())
    }

    @Test func importsCopyFilesAndStayWithTheirOriginalNote() async throws {
        let store = NotebookStore(directory: scratch.path("notebook"))
        let first = try #require(store.create())
        let original = scratch.path("release plan.txt")
        try Data("ship it".utf8).write(to: original)
        let second = try #require(store.create())
        try await store.attach(original, to: first)
        let attachment = try #require(store.note(first)?.attachments.first)
        #expect(store.note(second)?.attachments.isEmpty == true)
        #expect(store.selectedID == second)
        try FileManager.default.removeItem(at: original)
        #expect(try String(contentsOf: store.attachmentURL(attachment), encoding: .utf8) == "ship it")
        #expect(store.matching("release plan").map(\.id) == [first])
        let duplicate = try #require(store.duplicate(first))
        #expect(store.note(duplicate)?.attachments == [attachment])
        #expect(store.flush())
        #expect(NotebookStore(directory: store.directory).note(first)?.attachments == [attachment])
    }

    @Test func invalidAttachmentsLeaveTheNoteIntact() async throws {
        let store = NotebookStore(directory: scratch.path("notebook"))
        let id = try #require(store.create())
        await #expect(throws: (any Error).self) { try await store.attach(scratch.url, to: id) }
        await #expect(throws: (any Error).self) { try await store.attach(scratch.path("missing"), to: id) }
        #expect(store.note(id)?.attachments.isEmpty == true)
        #expect(store.flush())
    }

    @Test func failedSavesKeepEditsForRetry() throws {
        let fails = Mutex(false)
        var files = PersistentFileClient.live
        files.write = { data, url in
            if fails.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
            try PersistentFile.write(data, to: url)
        }
        let store = NotebookStore(directory: scratch.url, files: files)
        let id = try #require(store.create())
        #expect(store.flush())
        fails.withLock { $0 = true }
        store.update(id) { $0.title = "Do not lose me" }
        #expect(!store.flush())
        #expect(store.saveError != nil)
        #expect(store.note(id)?.title == "Do not lose me")
        fails.withLock { $0 = false }
        #expect(store.flush())
        #expect(store.saveError == nil)
        #expect(NotebookStore(directory: scratch.url).note(id)?.title == "Do not lose me")
    }

    @Test(arguments: ["not JSON", #"{"version":2,"notes":[]}"#])
    func unreadableNotebooksAreNeverOverwritten(_ original: String) throws {
        let url = scratch.path("notebook.json")
        try Data(original.utf8).write(to: url)
        let store = NotebookStore(directory: scratch.url)
        #expect(store.loadError != nil)
        #expect(store.create() == nil)
        #expect(!store.flush())
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }

    @Test func autosaveCompletesWithoutClosingTheEditor() async throws {
        let store = NotebookStore(directory: scratch.url)
        let id = try #require(store.create())
        store.update(id) { $0.title = "Autosaved" }
        #expect(await waitUntil { !store.saving })
        #expect(NotebookStore(directory: scratch.url).note(id)?.title == "Autosaved")
    }

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
