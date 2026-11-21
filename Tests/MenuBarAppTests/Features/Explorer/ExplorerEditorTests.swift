import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct ExplorerEditorTests {
    private let scratch = ScratchDirectory(prefix: "explorer-editor")
    private var root: URL { scratch.url.resolvingSymlinksInPath() }
    private let dialogs = DialogPresenter()
    private let memory = ExplorerMemory()

    private func node(_ path: String, text: String) async throws -> FileNode {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let siblings = await FileTree.children(of: url.deletingLastPathComponent(), includeHidden: true)
        return try #require(siblings.first { $0.path == url.path })
    }

    private func editor(showing node: FileNode) async -> ExplorerEditor {
        let editor = ExplorerEditor()
        editor.open(root.path, documents: ExplorerDocuments())
        editor.show(node)
        #expect(await waitUntil { editor.preview != nil })
        return editor
    }

    private func text(of node: FileNode) -> String? {
        try? String(contentsOf: node.url, encoding: .utf8)
    }

    @Test func aFileWrittenBySomethingElseIsNotSavedOverWithoutAsking() async throws {
        let file = try await node("notes.txt", text: "as opened")
        let editor = await editor(showing: file)
        editor.draft = "mine"
        try "theirs".write(to: file.url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)

        var written = 0
        editor.save(file, dialogs: dialogs, memory: memory) { written += 1 }
        #expect(editor.saving)
        #expect(await waitUntil { dialogs.current?.title == "The file has changed" })
        #expect(!editor.saving)
        #expect(editor.dirty)
        #expect(text(of: file) == "theirs")
        #expect(written == 0)

        dialogs.run(try #require(dialogs.current?.actions.first))
        #expect(await waitUntil { !editor.saving && !editor.dirty })
        #expect(text(of: file) == "mine")
        #expect(written == 1)
        #expect(editor.fileWasSaved)
        #expect(editor.documents.edits[file.path] == nil)

        // The save read the file's new date, so the next one has nothing to ask.
        editor.draft = "mine again"
        editor.save(file, dialogs: dialogs, memory: memory) { written += 1 }
        #expect(await waitUntil { !editor.saving && text(of: file) == "mine again" })
        #expect(dialogs.current == nil)
        #expect(written == 2)
    }

    @Test func aSaveAskedForDuringAnotherRunsOnceTheFirstIsDone() async throws {
        let file = try await node("notes.txt", text: "as opened")
        let editor = await editor(showing: file)
        var written = 0
        editor.draft = "one"
        editor.save(file, dialogs: dialogs, memory: memory) { written += 1 }
        editor.draft = "one two"
        editor.save(file, dialogs: dialogs, memory: memory) { written += 1 }

        #expect(await waitUntil { !editor.saving && text(of: file) == "one two" })
        #expect(!editor.dirty)
        #expect(written == 2)
        #expect(dialogs.current == nil)
    }

    @Test func aFailedWriteKeepsTheDraftAndSaysWhy() async throws {
        let file = try await node("locked/notes.txt", text: "as opened")
        let editor = await editor(showing: file)
        editor.draft = "mine"
        let folder = file.url.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }

        var written = 0
        editor.save(file, dialogs: dialogs, memory: memory) { written += 1 }
        #expect(await waitUntil { editor.saveErrors[file.path] != nil })
        #expect(await waitUntil { !editor.saving })
        #expect(editor.draft == "mine")
        #expect(editor.dirty)
        #expect(text(of: file) == "as opened")
        #expect(written == 0)

        editor.revert()
        #expect(editor.draft == "as opened")
        #expect(editor.saveErrors[file.path] == nil)
    }

    @Test func eachOpenFileKeepsItsOwnDraft() async throws {
        let first = try await node("first.txt", text: "first on disk")
        let second = try await node("second.txt", text: "second on disk\nwith a second line")
        let editor = await editor(showing: first)
        editor.draft = "first, edited"

        editor.show(second)
        #expect(await waitUntil { editor.draft == "second on disk\nwith a second line" })
        #expect(!editor.dirty)
        #expect(editor.documents.tabs.map(\.name) == ["first.txt", "second.txt"])
        #expect(editor.documents.edits[first.path]?.draft == "first, edited")
        #expect(editor.hasUnsavedEdit(first))

        // Showing the open file again at a line marks the query there and reads nothing.
        editor.show(second, line: 2, marking: "second")
        #expect(editor.markdownMode == .source)
        #expect(editor.lineToReveal == 2)
        #expect(editor.find.revealedMatches == [NSRange(location: 22, length: 6)])

        editor.show(first)
        #expect(editor.draft == "first, edited")
        #expect(editor.original == "first on disk")
        #expect(editor.loadedAt == first.modified)
        #expect(editor.dirty)
        #expect(editor.find.revealedMatches.isEmpty)
    }

    @Test func theOpenFileAndItsTabsFollowARenamedFolder() async throws {
        let open = try await node("Sources/open.swift", text: "open")
        let behind = try await node("Sources/behind.swift", text: "behind")
        let beside = try await node("SourcesExtra/beside.swift", text: "beside")
        let editor = await editor(showing: behind)
        editor.draft = "behind, edited"
        editor.show(beside)
        editor.show(open)
        #expect(await waitUntil { editor.draft == "open" })
        editor.draft = "open, edited"

        let old = root.appendingPathComponent("Sources").path
        let new = root.appendingPathComponent("Code").path
        editor.moved(from: old, to: new)

        #expect(editor.selected?.path == new + "/open.swift")
        #expect(editor.selected?.name == "open.swift")
        #expect(editor.draft == "open, edited")
        #expect(editor.documents.tabs.map(\.path) == [new + "/behind.swift", beside.path, new + "/open.swift"])
        #expect(editor.documents.edits.keys.sorted() == [new + "/behind.swift"])
        #expect(editor.documents.edits[new + "/behind.swift"]?.draft == "behind, edited")
    }

    @Test func closingTheFrontTabShowsTheOneBehindAndTheLastLeavesNothingOpen() async throws {
        let first = try await node("first.txt", text: "first")
        let second = try await node("second.txt", text: "second")
        let editor = await editor(showing: first)
        editor.show(second)
        #expect(await waitUntil { editor.draft == "second" })
        editor.find.presented = true

        editor.closeTab(second, motion: nil)
        #expect(editor.selected?.path == first.path)
        #expect(!editor.find.presented)
        #expect(await waitUntil { editor.draft == "first" })
        #expect(editor.documents.tabs.map(\.name) == ["first.txt"])

        editor.closeTab(first, motion: nil)
        #expect(editor.selected == nil)
        #expect(editor.preview == nil)
        #expect(editor.draft.isEmpty)
        #expect(!editor.isEditable)
        #expect(editor.documents.tabs.isEmpty)
    }

    @Test func aRemovedFolderClosesTheFilesInsideIt() async throws {
        let inside = try await node("Sources/inside.swift", text: "inside")
        let beside = try await node("SourcesExtra/beside.swift", text: "beside")
        let editor = await editor(showing: beside)
        editor.show(inside)
        #expect(await waitUntil { editor.draft == "inside" })

        editor.removed(root.appendingPathComponent("Sources").path)
        #expect(editor.selected == nil)
        #expect(editor.draft.isEmpty)
        #expect(editor.documents.tabs.map(\.path) == [beside.path])
    }
}
