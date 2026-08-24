import Foundation

// Where a deleted checkout waits to be unlinked.
//
// A session that installed dependencies leaves a checkout of hundreds of thousands of
// files behind, and unlinking that takes tens of seconds. Moving the folder costs one
// rename whatever is inside it, so deleting a worktree moves it here and returns, and the
// unlinking runs behind the app where nobody waits for it. This sits beside the checkouts
// it takes, on the same volume, because that is what keeps the move a rename rather than
// a copy of every file.
enum WorktreeTrash {
    private static let folder = "worktrees-trash"
    // One pass at a time: a pass started while another is still unlinking waits for it
    // instead of walking the same folders.
    private static let queue = DispatchQueue(label: "\(AppPaths.bundleID).worktree-trash",
                                             qos: .utility)

    // Reading either path does not create it. A deletion prepares the current directory,
    // while startup can inspect both without reviving an empty legacy directory.
    static var directory: URL {
        GitWorktree.baseDirectory.deletingLastPathComponent()
            .appendingPathComponent(folder, isDirectory: true)
    }

    private static var legacyDirectory: URL {
        AppPaths.support.appendingPathComponent(folder, isDirectory: true)
    }

    // False when the folder could not be moved - a checkout on another volume, a disk with
    // no room for the entry - which leaves the caller to delete it where it stands.
    @discardableResult
    static func accept(_ path: String, into trash: URL = directory) -> Bool {
        let source = URL(fileURLWithPath: path)
        // Named after what it held, with a suffix of its own so two checkouts of the same
        // project can wait here at the same time.
        let destination = trash.appendingPathComponent(
            "\(source.lastPathComponent)-\(UUID().uuidString.prefix(8))")
        do {
            _ = AppPaths.directory(at: trash, backedUp: false)
            try FileManager.default.moveItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }

    // Nothing here is reported. A folder that survives the pass - because the app quit part
    // way through it, because a file was held open - is taken by the pass at the next
    // launch, and until then it costs disk rather than correctness.
    static func empty(_ trash: URL? = nil) {
        let directories = trash.map { [$0] } ?? [directory, legacyDirectory]
        queue.async {
            let files = FileManager.default
            for directory in directories {
                let waiting = (try? files.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)) ?? []
                for folder in waiting { try? files.removeItem(at: folder) }
            }
        }
    }

    // Waits for the unlinking already handed over to finish. Only a test needs this: the
    // app is never worse off for a folder that is still going.
    static func settle() { queue.sync {} }
}
