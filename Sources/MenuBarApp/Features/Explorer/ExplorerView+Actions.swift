import AppKit
import SwiftUI

extension ExplorerView {
    func copyPath(_ node: FileNode) {
        Pasteboard.copy(node.path)
        showNote("Copied the path", icon: "doc.on.doc")
    }

    func revealInFinder(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
        showNote("Showed \(node.name) in Finder")
    }

    func openExternally(_ node: FileNode) {
        NSWorkspace.shared.open(node.url)
        showNote("Opened \(node.name)")
    }

    func isPinned(_ node: FileNode) -> Bool {
        let owner = project(owning: node.path)?.root ?? root
        let pins = owner == root ? editor.documents.pinned : memory.place(for: owner)?.documents.pinned ?? []
        return pins.contains { $0.path == node.path }
    }

    func togglePin(_ node: FileNode) {
        let owner = project(owning: node.path)?.root ?? root
        if owner == root {
            editor.documents.togglePin(node)
            rememberPlace()
        } else {
            var place = memory.place(for: owner) ?? ExplorerMemory.Place()
            place.documents.togglePin(node)
            memory.remember(place, for: owner)
        }
    }

    func copySelected() -> Bool {
        guard let selected = editor.selected else { return false }
        copy(selected)
        return true
    }

    func copy(_ node: FileNode) {
        Pasteboard.copy(node.url)
        showNote("Copied \(node.name)", icon: "doc.on.doc")
    }

    // Into the given item when it is a folder, beside it when it is a file, and at the top
    // with nothing given.
    func pasteFiles(at node: FileNode?) -> Bool {
        let sources = Pasteboard.fileURLs()
        guard !sources.isEmpty else { return false }

        let destination = pasteDestination(for: sources, at: node)
        pastingFiles = true
        Task {
            let result = await FileTree.copy(sources, into: destination)
            pastingFiles = false
            if !result.copied.isEmpty {
                if destination.path != root { tree.expanded.insert(destination.path) }
                await tree.load(destination.path)
                tree.statusRevision += 1
            }
            guard !result.failures.isEmpty else { return }
            dialogs.show(.notice(
                result.failures.count == 1 ? "Could not paste the item" : "Could not paste some items",
                message: result.failures.map { "\($0.name): \($0.message)" }.joined(separator: "\n")))
        }
        return true
    }

    private func pasteDestination(for sources: [URL], at node: FileNode?) -> URL {
        guard let node else { return rootURL }
        guard node.isDirectory else { return node.url.deletingLastPathComponent() }
        let nodeURL = node.url.standardizedFileURL
        let copyingItself = sources.contains { $0.standardizedFileURL == nodeURL }
        return copyingItself ? node.url.deletingLastPathComponent() : node.url
    }

    func trashSelected() -> Bool {
        guard let selected = editor.selected else { return false }
        confirmTrash(selected)
        return true
    }

    func confirmTrash(_ node: FileNode) {
        let rememberedEdit = node.path.isInside(root) ? nil : memory.unsavedEdit(inside: node.path)
        let losesEdits = (editor.dirty && editor.selected?.path.isInside(node.path) == true)
            || editor.documents.edits.keys.contains { $0.isInside(node.path) } || rememberedEdit != nil
        var rows: [Dialog.Impact.Row] = [.init(title: node.name,
                                             detail: node.isDirectory ? "The folder and its contents move to the Trash." : "The file moves to the Trash.")]
        if losesEdits {
            rows.append(.init(title: "Unsaved edits",
                              detail: node.isDirectory ? "Unsaved edits in this folder are lost." : "Edits to \(node.name) are lost."))
        }
        rows.append(.init(title: node.isDirectory ? "Folder can be restored" : "File can be restored",
                          detail: "Put it back from the Trash in Finder.", kept: true))
        let owner = project(owning: node.path)
        dialogs.show(.impact("Move \(node.name) to the Trash?", subject: .init(name: owner?.name ?? rootURL.lastPathComponent), rows: rows,
                             warning: losesEdits ? "Unsaved edits cannot be restored from the Trash." : nil,
                             action: "Move to Trash") { trash(node) })
    }

    private func trash(_ node: FileNode) {
        Task {
            if let failure = await FileTree.trash(node.url) {
                dialogs.show(.notice("Could not move \(node.name) to the Trash", message: failure))
                return
            }
            memory.removed(node.path)
            editor.removed(node.path)
            await tree.removed(node)
        }
    }

    func create(folder: Bool, in directory: URL) {
        dialogs.show(Dialog(title: folder ? "New folder" : "New file",
                            content: AnyView(ExplorerCreateDialog(folder: folder, directory: directory) { url in
            Task {
                await tree.openFolders(leadingTo: url, beneath: rootURL)
                await tree.load(directory.path)
                guard let node = tree.children[directory.path]?.first(where: { $0.path == url.path }) else { return }
                requestSelect(node)
                if folder { tree.expanded.insert(node.path); await tree.load(node.path) }
                await git.refresh(roots: projectRoots.map(\.root))
            }
        }), actions: [], width: 460, isModal: true))
    }

    func renameSelected() -> Bool {
        guard let selected = editor.selected else { return false }
        startRename(selected)
        return true
    }

    func startRename(_ node: FileNode) {
        renameDraft = node.name
        renameCancelled = false
        renaming = node.path
    }

    // The name is picked without its extension, so typing replaces just the part people
    // usually mean to change. Focus selects the whole field, so the shorter selection is
    // set after it lands.
    func focusRenameField(_ node: FileNode) {
        renameFocused = true
        let stem = node.isDirectory ? node.name : (node.name as NSString).deletingPathExtension
        let end = stem.isEmpty ? node.name.endIndex : node.name.index(
            node.name.startIndex, offsetBy: stem.count)
        DispatchQueue.main.async {
            renameSelection = TextSelection(range: node.name.startIndex..<end)
        }
    }

    func endRename() {
        renaming = nil
        renameFocused = false
        treeFocused = true
    }

    func commitRename(_ node: FileNode) {
        let name = renameDraft
        endRename()
        Task {
            switch await FileTree.rename(node.url, to: name) {
            case .unchanged:
                return
            case .failed(let failure):
                dialogs.show(.notice("Could not rename \(node.name)", message: failure))
            case .renamed(let url):
                await moved(from: node.path, to: url)
            }
        }
    }

    // Everything the pane knows by path follows the item to its new name, so open folders
    // stay open and an open file keeps its unsaved edits.
    private func moved(from old: String, to url: URL) async {
        let new = url.path
        memory.moved(from: old, to: new)
        editor.moved(from: old, to: new)
        await tree.moved(from: old, to: url)
    }

    // Rows above and below can both report a drag at once as it crosses between them, so a
    // row only clears the highlight it set itself.
    func hoverDrop(key: String, folder: String, _ targeted: Bool) {
        if targeted {
            dropHover = DropHover(key: key, folder: folder)
        } else if dropHover?.key == key {
            dropHover = nil
        }
    }

    // Items from inside this folder move. Anything from outside is copied in, the way a
    // paste is, so dragging a file in never takes it away from where it lives.
    func drop(_ urls: [URL], into folder: URL) -> Bool {
        dropHover = nil
        guard !urls.isEmpty else { return false }
        let destinationRoot = project(owning: folder.path)?.root ?? root
        let local = urls.filter { $0.standardizedFileURL.path.isInside(destinationRoot) }
        let outside = urls.filter { !$0.standardizedFileURL.path.isInside(destinationRoot) }

        Task {
            var failures: [FileTree.CopyFailure] = []
            if !local.isEmpty {
                let result = await FileTree.move(local, into: folder)
                for move in result.moved {
                    await moved(from: move.from.path, to: move.to)
                }
                failures += result.failures
            }
            if !outside.isEmpty {
                let result = await FileTree.copy(outside, into: folder)
                if !result.copied.isEmpty { await tree.load(folder.path) }
                failures += result.failures
            }
            if folder.path != root { tree.expanded.insert(folder.path) }
            if tree.children[folder.path] == nil { await tree.load(folder.path) }
            tree.statusRevision += 1

            guard !failures.isEmpty else { return }
            dialogs.show(.notice(
                failures.count == 1 ? "Could not move the item" : "Could not move some items",
                message: failures.map { "\($0.name): \($0.message)" }.joined(separator: "\n")))
        }
        return true
    }
}
