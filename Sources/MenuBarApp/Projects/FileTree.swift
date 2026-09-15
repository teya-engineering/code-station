import Foundation

// One entry in the explorer: a file or a folder inside a session's working directory.
//
// A link is described by what it points at rather than by itself: its size and whether it
// opens as a folder are the target's, since that is the thing the user means to work on.
struct FileNode: Identifiable, Sendable, Equatable {
    var url: URL
    var name: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date?
    // The link as it was written, so "../shared/AGENTS.md" is shown the way it reads on
    // disk instead of as a long absolute path. Nil for everything that is not a link.
    var linkDestination: String?

    var id: String { url.path }
    var path: String { url.path }
    var kind: String { url.pathExtension.lowercased() }
    var isLink: Bool { linkDestination != nil }
    var supportsMarkdownPreview: Bool { kind == "md" || kind == "markdown" }
}

// Navigation is kept separate from the view so the rules stay the same whether a row was
// reached with the mouse or the keyboard. The rows are already flattened in display order,
// and depth is enough to find a parent without rebuilding the tree.
enum FileTreeNavigation {
    struct Row: Equatable {
        let path: String
        let isDirectory: Bool
        let depth: Int
    }

    enum Direction {
        case up
        case down
        case left
        case right
    }

    enum Action: Equatable {
        case select(String)
        case expand(String)
        case collapse(String)
    }

    static func action(for direction: Direction, selectedPath: String?, rows: [Row],
                       expanded: Set<String>) -> Action? {
        guard !rows.isEmpty else { return nil }
        guard let selectedPath,
              let selectedIndex = rows.firstIndex(where: { $0.path == selectedPath }) else {
            return switch direction {
            case .up: .select(rows[rows.count - 1].path)
            default: .select(rows[0].path)
            }
        }

        let selected = rows[selectedIndex]
        switch direction {
        case .up:
            guard selectedIndex > rows.startIndex else { return nil }
            return .select(rows[selectedIndex - 1].path)
        case .down:
            guard selectedIndex < rows.index(before: rows.endIndex) else { return nil }
            return .select(rows[selectedIndex + 1].path)
        case .left:
            if selected.isDirectory, expanded.contains(selected.path) {
                return .collapse(selected.path)
            }
            guard selected.depth > 0 else { return nil }
            let parent = rows[..<selectedIndex].last { $0.depth == selected.depth - 1 }
            return parent.map { .select($0.path) }
        case .right:
            guard selected.isDirectory else { return nil }
            if !expanded.contains(selected.path) { return .expand(selected.path) }
            guard selectedIndex < rows.index(before: rows.endIndex),
                  rows[selectedIndex + 1].depth == selected.depth + 1 else { return nil }
            return .select(rows[selectedIndex + 1].path)
        }
    }
}

// What the explorer can show for one file. A file it cannot draw is still worth an entry:
// knowing a path holds four megabytes of binary is an answer too.
//
// Text arrives exactly as it is on disk, tabs and long lines included. The pane it lands
// in can be typed into, so anything rewritten on the way in would be saved back mangled.
enum FilePreview: Sendable, Equatable {
    case text(String)
    case image(Data)
    case binary(size: Int64)
    case tooLarge(size: Int64)
    case empty
    case unreadable(String)
}

// Reads folders and files for the explorer, and writes a file back when one is edited.
//
// Every call hops off the main thread. A folder with a few thousand entries, or a file
// that turns out to live on a slow disk, is enough to freeze the window otherwise.
enum FileTree {
    struct CopyFailure: Sendable, Equatable {
        let name: String
        let message: String
    }

    struct CopyResult: Sendable, Equatable {
        var copied: [URL] = []
        var failures: [CopyFailure] = []
    }

    // Past this the file is named and sized but not opened. The text view lays out only
    // what is on screen, so length costs little, but the whole file is still held in
    // memory twice over while it is open.
    static let byteLimit: Int64 = 4 << 20

    static let imageKinds: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "bmp", "tiff", "tif", "webp", "icns", "svg"
    ]

    // Skipped whatever the hidden-files setting says. It is machine state rather than the
    // user's work, and it is deep and wide enough on its own to make the tree unusable.
    private static let skipped: Set<String> = [".git"]

    static func children(of url: URL, includeHidden: Bool) async -> [FileNode] {
        await Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [
                .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
            ]
            let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
            let listed = url.resolvingSymlinksInPath()
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: listed, includingPropertiesForKeys: keys, options: options) else { return [] }

            var nodes: [FileNode] = []
            for entry in entries where !skipped.contains(entry.lastPathComponent) {
                let values = try? entry.resourceValues(forKeys: Set(keys))
                let visible = pathWalkedIn(to: entry, listed: listed, asked: url)
                if values?.isSymbolicLink == true {
                    nodes.append(linkNode(at: visible, keys: keys))
                    continue
                }
                nodes.append(FileNode(
                    url: visible,
                    name: entry.lastPathComponent,
                    isDirectory: values?.isDirectory ?? false,
                    size: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate))
            }

            // Folders first, then by name the way Finder sorts it, so "file10" follows
            // "file9" instead of "file1".
            return nodes.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }.value
    }

    static func files(beneath url: URL, includeHidden: Bool) async -> [FileNode] {
        await Task.detached(priority: .userInitiated) {
            filesOnCurrentThread(beneath: url, includeHidden: includeHidden)
        }.value
    }

    // DirectoryEnumerator uses a synchronous iterator, so it stays in a synchronous helper
    // even though the helper itself runs on the detached file-system task above.
    private static func filesOnCurrentThread(beneath url: URL, includeHidden: Bool) -> [FileNode] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
        ]
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        let listed = url.resolvingSymlinksInPath()
        guard let entries = FileManager.default.enumerator(
            at: listed, includingPropertiesForKeys: keys, options: options) else { return [] }

        var nodes: [FileNode] = []
        for case let entry as URL in entries {
            if Task.isCancelled { return nodes }
            if skipped.contains(entry.lastPathComponent) {
                entries.skipDescendants()
                continue
            }

            let values = try? entry.resourceValues(forKeys: Set(keys))
            let visible = pathWalkedIn(to: entry, listed: listed, asked: url)
            if values?.isSymbolicLink == true {
                // The tree opens a folder link a level at a time, so a link that points back
                // up its own branch costs nothing there. This walk reads everything at once,
                // where the same link would never finish, so it stops at the link itself.
                entries.skipDescendants()
                let node = linkNode(at: visible, keys: keys)
                if !node.isDirectory { nodes.append(node) }
                continue
            }
            if values?.isDirectory == true { continue }

            nodes.append(FileNode(
                url: visible,
                name: entry.lastPathComponent,
                isDirectory: false,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate))
        }

        return nodes.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    // Neither the folder listing nor the recursive walk will look through a folder link, so
    // both are pointed at what the link resolves to. What they find is then put back on the
    // path it was reached by, so a row reads as the way the user walked in rather than as
    // wherever the link happened to land.
    private static func pathWalkedIn(to entry: URL, listed: URL, asked: URL) -> URL {
        guard listed.path != asked.path,
              let relativePath = entry.path.pathRelative(to: listed.path) else { return entry }
        return asked.appendingPathComponent(relativePath)
    }

    // A link is measured through to its target, so it lists with the size of the file it
    // points at and opens as a folder when that is what is on the other end. A link with
    // nothing at the end is still listed: a name in the tree is how the user finds it.
    private static func linkNode(at url: URL, keys: [URLResourceKey]) -> FileNode {
        let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: Set(keys))
        return FileNode(
            url: url,
            name: url.lastPathComponent,
            isDirectory: target?.isDirectory ?? false,
            size: Int64(target?.fileSize ?? 0),
            modified: target?.contentModificationDate,
            linkDestination: destination ?? "")
    }

    static func ancestorDirectories(of file: URL, beneath root: URL) -> [String] {
        guard let relativePath = file.path.pathRelative(to: root.path) else { return [] }
        let parent = (relativePath as NSString).deletingLastPathComponent
        guard parent != ".", !parent.isEmpty else { return [] }

        var directory = root.standardizedFileURL
        return parent.split(separator: "/").map { component in
            directory.appendPathComponent(String(component), isDirectory: true)
            return directory.path
        }
    }

    static func copy(_ sources: [URL], into directory: URL) async -> CopyResult {
        await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            var destinationIsDirectory: ObjCBool = false
            guard files.fileExists(atPath: directory.path, isDirectory: &destinationIsDirectory),
                  destinationIsDirectory.boolValue else {
                return CopyResult(failures: sources.map {
                    CopyFailure(name: $0.lastPathComponent,
                                message: "The destination folder is no longer there.")
                })
            }

            var result = CopyResult()
            for source in sources {
                do {
                    let values = try source.resourceValues(forKeys: [.isDirectoryKey,
                                                                      .isSymbolicLinkKey])
                    let isDirectory = values.isDirectory == true && values.isSymbolicLink != true
                    guard !isDirectory || !directory.isInside(source) else {
                        result.failures.append(CopyFailure(
                            name: source.lastPathComponent,
                            message: "A folder cannot be copied into itself."))
                        continue
                    }

                    let destination = availableCopyURL(for: source,
                                                       isDirectory: isDirectory,
                                                       in: directory,
                                                       files: files)
                    try files.copyItem(at: source, to: destination)
                    result.copied.append(destination)
                } catch {
                    result.failures.append(CopyFailure(name: source.lastPathComponent,
                                                       message: error.localizedDescription))
                }
            }
            return result
        }.value
    }

    private static func availableCopyURL(for source: URL, isDirectory: Bool,
                                         in directory: URL, files: FileManager) -> URL {
        let original = directory.appendingPathComponent(source.lastPathComponent,
                                                        isDirectory: isDirectory)
        guard files.fileExists(atPath: original.path) else { return original }

        let fileExtension = isDirectory ? "" : source.pathExtension
        let baseName = isDirectory || fileExtension.isEmpty
            ? source.lastPathComponent
            : source.deletingPathExtension().lastPathComponent
        var copyNumber = 1
        while true {
            let suffix = copyNumber == 1 ? " copy" : " copy \(copyNumber)"
            let name = fileExtension.isEmpty
                ? baseName + suffix
                : baseName + suffix + "." + fileExtension
            let candidate = directory.appendingPathComponent(name, isDirectory: isDirectory)
            if !files.fileExists(atPath: candidate.path) { return candidate }
            copyNumber += 1
        }
    }

    static func preview(of url: URL) async -> FilePreview {
        await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            // fileExists follows a link, so this is also what tells a link with nothing on
            // the other end apart from a file that has been deleted underneath the pane.
            guard files.fileExists(atPath: url.path) else {
                guard let destination = try? files.destinationOfSymbolicLink(atPath: url.path) else {
                    return .unreadable("This file is no longer there.")
                }
                return .unreadable("This link points at \(destination), which is not there.")
            }

            let target = url.resolvingSymlinksInPath()
            let attributes = try? files.attributesOfItem(atPath: target.path)
            guard let attributes else { return .unreadable("This file is no longer there.") }
            if let type = attributes[.type] as? FileAttributeType, type != .typeRegular {
                return .unreadable("This is not a regular file.")
            }

            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { return .empty }
            guard size <= byteLimit else { return .tooLarge(size: size) }
            guard let data = try? Data(contentsOf: target) else {
                return .unreadable("Could not read this file.")
            }

            // Decoding is the view's job, so a file that claims to be an image but is not
            // falls back to the binary message rather than being checked twice.
            if imageKinds.contains(url.pathExtension.lowercased()) { return .image(data) }
            guard !data.looksBinary else { return .binary(size: size) }

            return .text(String(decoding: data, as: UTF8.self))
        }.value
    }

    // When the file was last written, so a pane that has held a file open for a while can
    // tell whether anyone else has been at it.
    static func modified(of url: URL) async -> Date? {
        await Task.detached(priority: .userInitiated) {
            try? url.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.value
    }

    // Returns what went wrong, or nil when the write landed.
    static func write(_ text: String, to url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            do {
                // An atomic write renames a fresh file over the path it is given, which
                // would leave a copy where a link used to be. Saving through to the target
                // keeps the link, which is the whole point of having made one.
                try Data(text.utf8).write(to: url.resolvingSymlinksInPath(), options: .atomic)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
    }
}

private extension URL {
    func isInside(_ directory: URL) -> Bool {
        let parent = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let child = resolvingSymlinksInPath().standardizedFileURL.path
        return child == parent || child.hasPrefix(parent + "/")
    }
}

extension Data {
    // git only looks for a NUL byte, but anything that is not valid UTF-8 would render as
    // a wall of replacement characters, so treat that as binary too.
    var looksBinary: Bool {
        let head = prefix(8000)
        if head.contains(0) { return true }
        // A multi-byte character can straddle the cut, so allow a few bytes of slack.
        for drop in 0...3 where head.count > drop {
            if String(data: head.dropLast(drop), encoding: .utf8) != nil { return false }
        }
        return true
    }
}
