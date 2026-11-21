import SwiftUI

// Find in the open file: the bar, what it found and which match is current.
struct ExplorerFileFind {
    var presented = false
    var query = ""
    var result = FileFindResult()
    var selection = 0
    // The query marked on the line a find in files result opened at. It goes once the
    // text is edited, since the marks would no longer sit on the words they were for.
    var revealedMatches: [NSRange] = []

    var currentMatch: Int? {
        result.matches.indices.contains(selection) ? selection : nil
    }

    mutating func move(by offset: Int) {
        let count = result.matches.count
        guard count > 0 else { return }
        selection = (selection + offset + count) % count
    }
}

// The file in front and the tabs behind it: what was read, what has been typed since,
// and getting that back to disk. The view draws this and asks before anything is lost.
@MainActor
@Observable
final class ExplorerEditor {
    // The folder whose files are open here. It trails the view's root for a moment when
    // the session changes, which is what lets the old folder be remembered before the
    // new one opens.
    private(set) var root: String?
    var documents = ExplorerDocuments()
    private(set) var selected: FileNode?
    // The line the open file should scroll to, when it was opened from a link to one.
    var lineToReveal: Int?
    private(set) var preview: FilePreview?
    private(set) var language: CodeLanguage?
    var markdownMode = MarkdownEditorMode.edit
    var find = ExplorerFileFind()

    // The text as loaded sits next to the draft, so "anything to save" and "anything to
    // lose" are both one comparison.
    var draft = ""
    private(set) var original = ""
    // When the file was last written at the moment it was read. An agent works in the same
    // folder, so a pane left open on a file it has since rewritten would save over it.
    private(set) var loadedAt: Date?
    private(set) var saving = false
    // Save asked for while a save is still running. It runs once that save is done, so a
    // quick second press is never lost.
    private var saveQueued = false
    private(set) var fileWasSaved = false
    private(set) var saveErrors: [String: String] = [:]
    private var previewGeneration = 0

    // Only what reads as text can be typed into. Images, binaries and files past the size
    // limit stay look-but-do-not-touch, and an empty file counts as text.
    var isEditable: Bool {
        switch preview {
        case .text, .empty: true
        default: false
        }
    }

    var dirty: Bool { isEditable && draft != original }

    func hasUnsavedEdit(_ node: FileNode) -> Bool {
        selected?.path == node.path ? dirty : documents.edits[node.path] != nil
    }

    func open(_ root: String, documents: ExplorerDocuments) {
        self.root = root
        self.documents = documents
        clear()
    }

    // Bumping the generation drops a read still on its way for the file that was open.
    func clear() {
        previewGeneration += 1
        selected = nil
        preview = nil
        language = nil
        draft = ""
        original = ""
        loadedAt = nil
        find = ExplorerFileFind()
    }

    // Each open file keeps its own draft, so moving through the tree never discards edits.
    func show(_ node: FileNode, line: Int? = nil, marking query: String? = nil) {
        if node.path == selected?.path {
            if let line {
                markdownMode = .source
                lineToReveal = line
                if let query, !find.presented {
                    find.revealedMatches = FileTextSearch.hits(of: query, onLine: line, in: draft)
                }
            }
            return
        }
        rememberDraft()
        select(node, line: line, marking: query)
    }

    func select(_ node: FileNode, line: Int? = nil, marking query: String? = nil) {
        clear()
        let generation = previewGeneration
        selected = node
        markdownMode = line == nil ? documents.modes[node.path] ?? .edit : .source
        fileWasSaved = false
        documents.open(node)
        lineToReveal = line
        guard !node.isDirectory else { return }
        if let edit = documents.edits[node.path] {
            preview = edit.preview
            draft = edit.draft
            original = edit.original
            loadedAt = edit.loadedAt
            language = CodeLanguage(path: node.name)
            if let query, let line { find.revealedMatches = FileTextSearch.hits(of: query, onLine: line, in: draft) }
            return
        }
        Task {
            let modified = await FileTree.modified(of: node.url)
            let loaded = await FileTree.preview(of: node.url)
            guard !Task.isCancelled, selected?.path == node.path, previewGeneration == generation else { return }
            preview = loaded
            loadedAt = modified
            language = CodeLanguage(path: node.name)
            if case .text(let text) = loaded {
                draft = text
                original = text
                if let query, let line {
                    find.revealedMatches = FileTextSearch.hits(of: query, onLine: line, in: text)
                }
            }
        }
    }

    func rememberDraft() {
        guard let selected, !selected.isDirectory else { return }
        documents.modes[selected.path] = markdownMode
        if dirty, let preview {
            documents.edits[selected.path] = .init(path: selected.path, preview: preview, draft: draft,
                                                   original: original, loadedAt: loadedAt)
        } else {
            documents.edits.removeValue(forKey: selected.path)
        }
    }

    // Typing moves every match after the caret, so the results are only right for the
    // text as it stands now.
    func draftChanged() {
        fileWasSaved = false
        if find.presented { refreshFind() }
        if draft != original { find.revealedMatches = [] }
    }

    func refreshFind() {
        find.result = FileFind.search(find.query, in: draft)
        // The selection is kept rather than reset: typing shifts the matches around it,
        // and being thrown back to the first one on every keystroke reads as a bug.
        find.selection = min(find.selection, max(0, find.result.matches.count - 1))
    }

    func revert() {
        draft = original
        if let selected {
            documents.edits.removeValue(forKey: selected.path)
            saveErrors.removeValue(forKey: selected.path)
        }
    }

    func closeTab(_ node: FileNode, motion: Animation?) {
        withAnimation(motion) { documents.close(node.path) }
        if selected?.path == node.path {
            if let next = documents.tabs.last { select(next) }
            else { clear() }
        }
    }

    // The tabs and the open file follow an item to its new name, so an open file keeps
    // its unsaved edits.
    func moved(from old: String, to new: String) {
        documents.moved(from: old, to: new)
        if var current = selected, current.path.isInside(old) {
            current.url = URL(fileURLWithPath: FileTree.path(current.path, afterMoving: old, to: new))
            current.name = current.url.lastPathComponent
            selected = current
            language = CodeLanguage(path: current.name)
        }
    }

    func removed(_ path: String) {
        documents.removed(path)
        if let selected, selected.path.isInside(path) { clear() }
    }

    // `written` runs after a save into the folder still open here, before the save counts
    // as over. A save that lands after the pane has moved to another folder only updates
    // what is remembered of the folder it left.
    func save(_ node: FileNode, dialogs: DialogPresenter, memory: ExplorerMemory,
              then written: @escaping @MainActor () async -> Void) {
        guard dirty else { return }
        guard !saving else {
            saveQueued = true
            return
        }
        saveQueued = false
        let saved = draft
        let expectedModification = loadedAt
        saving = true
        Task {
            let modified = await FileTree.modified(of: node.url)
            guard selected?.path == node.path else {
                saving = false
                saveQueued = false
                return
            }
            guard modified == expectedModification else {
                saving = false
                saveQueued = false
                dialogs.show(.confirm(
                    "The file has changed",
                    message: "\(node.name) was written by something else since it was opened here. Saving replaces what is on disk now.",
                    action: "Save anyway") { self.write(node, text: saved, dialogs: dialogs, memory: memory, then: written) })
                return
            }
            write(node, text: saved, dialogs: dialogs, memory: memory, then: written)
        }
    }

    private func write(_ node: FileNode, text saved: String, dialogs: DialogPresenter, memory: ExplorerMemory,
                       then written: @escaping @MainActor () async -> Void) {
        let writtenRoot = root
        saving = true
        Task {
            defer {
                saving = false
                if saveQueued, let selected, selected.path == node.path {
                    save(selected, dialogs: dialogs, memory: memory, then: written)
                }
                saveQueued = false
            }
            let failure = await FileTree.write(saved, to: node.url)
            if let failure {
                saveQueued = false
                saveErrors[node.path] = failure
                announceEditorStatus("Could not save \(node.name). Your edits are still here. Retry or export a copy.")
                return
            }
            saveErrors.removeValue(forKey: node.path)
            let modified = await FileTree.modified(of: node.url)
            let fresh = await FileTree.children(of: node.url.deletingLastPathComponent(), includeHidden: true)
                .first(where: { $0.path == node.path })
            if root == writtenRoot {
                if selected?.path == node.path {
                    original = saved
                    fileWasSaved = draft == saved
                    loadedAt = modified
                    if let fresh { selected = fresh }
                    rememberDraft()
                } else if var edit = documents.edits[node.path] {
                    edit.original = saved
                    edit.loadedAt = modified
                    documents.edits[node.path] = edit.draft == saved ? nil : edit
                }
                await written()
            } else if let writtenRoot, var place = memory.place(for: writtenRoot), var edit = place.documents.edits[node.path] {
                edit.original = saved
                edit.loadedAt = modified
                place.documents.edits[node.path] = edit.draft == saved ? nil : edit
                place.unsaved = place.selected.flatMap { place.documents.edits[$0.path] }
                memory.remember(place, for: writtenRoot)
            }
        }
    }
}
