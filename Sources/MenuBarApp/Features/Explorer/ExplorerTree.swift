import SwiftUI

// The folders of the open projects as they were last read from disk, and which of them
// are open. The view draws its rows from this and never reads a folder itself.
@MainActor
@Observable
final class ExplorerTree {
    // Children are kept per folder rather than as a nested tree, so a folder can be read
    // the moment it is opened and the rows on screen stay a flat list.
    private(set) var children: [String: [FileNode]] = [:]
    var expanded: Set<String> = []
    private(set) var loadingFolders: Set<String> = []
    private(set) var folderErrors: [String: String] = [:]
    // Goes up each time files on disk may have changed, which is when git is asked again.
    var statusRevision = 0
    // The switch itself belongs to the header, so the view hands its value over.
    var showHidden = true

    // `unfolding` is the motion for a folder being opened by hand, so rows read for the
    // first time fold in, while a refresh changes the list without moving anything.
    func load(_ path: String, unfolding: Animation? = nil) async {
        loadingFolders.insert(path)
        let listing = await FileTree.listing(of: URL(fileURLWithPath: path), includeHidden: showHidden)
        loadingFolders.remove(path)
        guard !Task.isCancelled else { return }
        folderErrors[path] = listing.error
        guard listing.error == nil else { return }
        withAnimation(children[path] == nil ? unfolding : nil) {
            children[path] = listing.nodes
        }
        for entry in listing.nodes where entry.isDirectory && !entry.isLink {
            var node = entry
            var chain: [String] = []
            // Follow only single-child folders. Links keep their own row and cannot form a cycle.
            for _ in 0..<32 {
                guard !Task.isCancelled else { return }
                chain.append(node.path)
                let nested = await FileTree.listing(of: node.url, includeHidden: showHidden)
                guard !Task.isCancelled else { return }
                folderErrors[node.path] = nested.error
                guard nested.error == nil else { break }
                children[node.path] = nested.nodes
                guard nested.nodes.count == 1, let child = nested.nodes.first,
                      child.isDirectory, !child.isLink else { break }
                node = child
            }
            if chain.contains(where: expanded.contains) { expanded.insert(node.path) }
        }
    }

    func open(_ path: String, motion: Animation?) {
        withAnimation(motion) { _ = expanded.insert(path) }
        Task { await load(path, unfolding: motion) }
    }

    func openFolders(leadingTo file: URL, beneath root: URL) async {
        for path in FileTree.ancestorDirectories(of: file, beneath: root) {
            expanded.insert(path)
            if children[path] == nil { await load(path) }
        }
    }

    func reopenFolders(roots: [String]) async {
        for path in (roots + expanded) {
            await load(path)
        }
        statusRevision += 1
    }

    // Open folders follow the item to its new name, so they stay open.
    func moved(from old: String, to url: URL) async {
        let new = url.path
        expanded = Set(expanded.map { FileTree.path($0, afterMoving: old, to: new) })
        children = children.filter { !$0.key.isInside(old) }
        let oldParent = (old as NSString).deletingLastPathComponent
        let newParent = url.deletingLastPathComponent().path
        if oldParent != newParent, children[oldParent] != nil { await load(oldParent) }
        await load(newParent)
        for path in expanded.sorted(by: { $0.count < $1.count })
        where path.isInside(new) {
            await load(path)
        }
        statusRevision += 1
    }

    func removed(_ node: FileNode) async {
        expanded = expanded.filter { !$0.isInside(node.path) }
        children = children.filter { !$0.key.isInside(node.path) }
        await load(node.url.deletingLastPathComponent().path)
        statusRevision += 1
    }
}
