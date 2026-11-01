import Foundation
import Synchronization
import Testing
@testable import MenuBarApp

@MainActor struct NotebookExplorerTests {
    private let scratch = ScratchDirectory(prefix: "notebook-explorer")

    @Test func existingNotebooksLoadWithoutWorkspaceFields() throws {
        let note = QuickNote(title: "Existing note", body: NoteDocument(runs: [.init(text: "Keep this")]))
        let data = try PersistentFile.makeEncoder(dates: .deferredToDate).encode([note])
        let notes = try JSONSerialization.jsonObject(with: data)
        let archive = try JSONSerialization.data(withJSONObject: ["version": 1, "notes": notes])
        try archive.write(to: scratch.path("notebook.json"))
        let store = NotebookStore(directory: scratch.url)
        #expect(store.loadError == nil)
        #expect(store.notes == [note])
        #expect(store.notes.first?.scopeID == nil)
    }

    @Test func newNotesBelongToTheirWorkspaceAndSurviveReload() throws {
        let store = NotebookStore(directory: scratch.url)
        let id = try #require(store.create(scope: "workspace:one"))
        #expect(store.selectedID == id)
        #expect(store.flush())
        #expect(NotebookStore(directory: scratch.url).note(id)?.scopeID == "workspace:one")
    }

    @Test func sourceOnlyNotesPersistWithoutLosingUnsupportedSyntax() throws {
        let store = NotebookStore(directory: scratch.url)
        let id = try #require(store.create())
        let source = "| A | B |\n|---|---|\n| 1 | 2 |\n"
        store.updateMarkdown(id, source: source)
        #expect(store.flush())
        let note = try #require(NotebookStore(directory: scratch.url).note(id))
        #expect(note.bodyMarkdown == source)
        #expect(note.markdown.contains(source))
    }

    @Test func moveCreatesMarkdownBeforeRemovingPersonalNote() throws {
        let store = NotebookStore(directory: scratch.path("notebook"))
        let id = try #require(store.create())
        store.update(id) { $0.title = "Plan"; $0.body = NoteDocument(runs: [.init(text: "Think first", bold: true)]) }
        let markdown = try #require(store.note(id)?.markdown)
        let destination = try store.moveToProject(id, root: scratch.url, relativePath: "docs/notes/plan.md")
        #expect(try String(contentsOf: destination, encoding: .utf8) == markdown)
        #expect(store.note(id) == nil)
        #expect(NotebookStore(directory: store.directory).note(id) == nil)
    }

    @Test func conflictsAttachmentsAndInvalidPathsKeepPersonalNote() throws {
        let store = NotebookStore(directory: scratch.path("notebook"))
        let id = try #require(store.create())
        try "Existing".write(to: scratch.path("existing.md"), atomically: true, encoding: .utf8)
        for path in ["../outside.md", "/tmp/outside.md", "docs//idea.md", "idea.txt", "existing.md"] {
            #expect(throws: (any Error).self) { try store.moveToProject(id, root: scratch.url, relativePath: path) }
            #expect(store.note(id) != nil)
        }
        #expect(try String(contentsOf: scratch.path("existing.md"), encoding: .utf8) == "Existing")
        store.update(id) { $0.attachments = [.init(name: "photo", byteCount: 1, image: true)] }
        #expect(throws: (any Error).self) { try store.moveToProject(id, root: scratch.url, relativePath: "new.md") }
        #expect(!FileManager.default.fileExists(atPath: scratch.path("new.md").path))
    }

    @Test func linkedFoldersCannotEscapeTheSelectedProject() throws {
        let outside = ScratchDirectory(prefix: "note-move-outside")
        try FileManager.default.createSymbolicLink(at: scratch.path("linked"), withDestinationURL: outside.url)
        #expect(throws: (any Error).self) { try NotebookProjectMove.destination(root: scratch.url, relativePath: "linked/note.md") }
    }

    @Test func notebookFailureAfterFileCreationKeepsBothCopies() throws {
        let fails = Mutex(false)
        var files = PersistentFileClient.live
        files.write = { data, url in
            if fails.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
            try PersistentFile.write(data, to: url)
        }
        let store = NotebookStore(directory: scratch.path("notebook"), files: files)
        let id = try #require(store.create())
        store.update(id) { $0.title = "Preserve me" }
        #expect(store.flush())
        fails.withLock { $0 = true }
        #expect(throws: (any Error).self) { try store.moveToProject(id, root: scratch.url, relativePath: "note.md") }
        #expect(store.note(id)?.title == "Preserve me")
        #expect(try String(contentsOf: scratch.path("note.md"), encoding: .utf8).contains("Preserve me"))
        #expect(NotebookStore(directory: store.directory).note(id) != nil)
    }
}
