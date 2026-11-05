import Foundation

struct ExplorerDocuments {
    var tabs: [FileNode] = []
    var edits: [String: ExplorerMemory.UnsavedEdit] = [:]
    var pinned: [FileNode] = []
    var modes: [String: MarkdownEditorMode] = [:]

    mutating func open(_ node: FileNode) {
        guard !node.isDirectory else { return }
        if let index = tabs.firstIndex(where: { $0.path == node.path }) {
            tabs[index] = node
        } else {
            tabs.append(node)
        }
    }

    mutating func togglePin(_ node: FileNode) {
        guard !node.isDirectory else { return }
        if pinned.contains(where: { $0.path == node.path }) {
            pinned.removeAll { $0.path == node.path }
        } else {
            pinned.append(node)
        }
    }

    mutating func close(_ path: String) {
        tabs.removeAll { $0.path == path }
        edits.removeValue(forKey: path)
        modes.removeValue(forKey: path)
    }

    mutating func moved(from old: String, to new: String) {
        func movedNode(_ node: FileNode) -> FileNode {
            var node = node
            node.url = URL(fileURLWithPath: FileTree.path(node.path, afterMoving: old, to: new))
            node.name = node.url.lastPathComponent
            return node
        }
        tabs = tabs.map(movedNode)
        pinned = pinned.map(movedNode)
        modes = Dictionary(modes.map { (FileTree.path($0.key, afterMoving: old, to: new), $0.value) }, uniquingKeysWith: { _, latest in latest })
        edits = Dictionary(edits.values.map { edit in
            let path = FileTree.path(edit.path, afterMoving: old, to: new)
            return (path, ExplorerMemory.UnsavedEdit(path: path, preview: edit.preview,
                                                   draft: edit.draft, original: edit.original,
                                                   loadedAt: edit.loadedAt))
        }, uniquingKeysWith: { _, latest in latest })
    }

    mutating func removed(_ path: String) {
        func contains(_ candidate: String) -> Bool {
            candidate == path || candidate.hasPrefix(path + "/")
        }
        tabs.removeAll { contains($0.path) }
        pinned.removeAll { contains($0.path) }
        edits = edits.filter { !contains($0.key) }
        modes = modes.filter { !contains($0.key) }
    }
}

struct ExplorerTreeRow: Identifiable {
    let node: FileNode
    let depth: Int
    var name: String
    var compactPaths: [String]
    var id: String { node.path }

    init(node: FileNode, depth: Int, name: String? = nil, compactPaths: [String]? = nil) {
        self.node = node
        self.depth = depth
        self.name = name ?? node.name
        self.compactPaths = compactPaths ?? [node.path]
    }

    static func rows(in directory: String, children: [String: [FileNode]],
                     expanded: Set<String>, depth: Int = 0) -> [Self] {
        var rows: [Self] = []
        for entry in children[directory] ?? [] {
            var node = entry
            var names = [node.name]
            var paths = [node.path]
            var visited: Set<String> = [node.path]
            while node.isDirectory && !node.isLink,
                  let nested = children[node.path], nested.count == 1,
                  let child = nested.first, child.isDirectory, !child.isLink,
                  visited.insert(child.path).inserted {
                node = child
                names.append(node.name)
                paths.append(node.path)
            }
            rows.append(Self(node: node, depth: depth, name: names.joined(separator: " / "), compactPaths: paths))
            if node.isDirectory && expanded.contains(node.path) {
                rows += Self.rows(in: node.path, children: children, expanded: expanded, depth: depth + 1)
            }
        }
        return rows
    }
}
