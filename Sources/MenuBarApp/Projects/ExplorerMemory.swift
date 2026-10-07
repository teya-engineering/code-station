import Foundation

// Where each explorer was left, by the folder it shows. The pane is torn down whenever
// another tab takes its place, so without this every trip to Chat and back would shut
// every folder and drop the file that was open, unsaved edits included.
@MainActor
@Observable
final class ExplorerMemory {
    struct Place {
        var expanded: Set<String> = []
        var selected: FileNode?
        var showHidden = true
        var treeWidth = ExplorerSplitLayout.defaultTreeWidth
        var renderingMarkdown = false
        // Only kept while the file has edits that are not on disk. A clean file is read
        // again on return, so it shows whatever an agent has written since.
        var unsaved: UnsavedEdit?
    }

    struct UnsavedEdit {
        let path: String
        let preview: FilePreview
        let draft: String
        let original: String
        let loadedAt: Date?
    }

    private var places: [String: Place] = [:]

    func place(for root: String) -> Place? {
        places[root]
    }

    func remember(_ place: Place, for root: String) {
        places[root] = place
    }
    func unsavedEdit(inside path: String) -> UnsavedEdit? {
        places.values.compactMap(\.unsaved).first {
            $0.path == path || $0.path.hasPrefix(path + "/")
        }
    }

    func moved(from old: String, to new: String) {
        for root in Array(places.keys) {
            guard var place = places[root] else { continue }
            place.expanded = Set(place.expanded.map { FileTree.path($0, afterMoving: old, to: new) })
            if var node = place.selected {
                node.url = URL(fileURLWithPath: FileTree.path(node.path, afterMoving: old, to: new))
                node.name = node.url.lastPathComponent
                place.selected = node
            }
            if let edit = place.unsaved {
                place.unsaved = UnsavedEdit(path: FileTree.path(edit.path, afterMoving: old, to: new),
                                           preview: edit.preview, draft: edit.draft,
                                           original: edit.original, loadedAt: edit.loadedAt)
            }
            places[root] = place
        }
    }

    func removed(_ path: String) {
        for root in Array(places.keys) {
            guard var place = places[root] else { continue }
            place.expanded = place.expanded.filter { $0 != path && !$0.hasPrefix(path + "/") }
            if let selected = place.selected,
               selected.path == path || selected.path.hasPrefix(path + "/") {
                place.selected = nil
                place.unsaved = nil
            }
            places[root] = place
        }
    }

}
