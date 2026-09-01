import Foundation

// One entry in the explorer: a file or a folder inside a session's working directory.
struct FileNode: Identifiable, Sendable, Equatable {
    var url: URL
    var name: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date?

    var id: String { url.path }
    var path: String { url.path }
    var kind: String { url.pathExtension.lowercased() }
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
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: options) else { return [] }

            var nodes: [FileNode] = []
            for entry in entries where !skipped.contains(entry.lastPathComponent) {
                let values = try? entry.resourceValues(forKeys: Set(keys))
                // A link into a folder that contains it walks forever, so links are leaves:
                // they can be revealed in Finder but not opened in the tree.
                let isLink = values?.isSymbolicLink ?? false
                nodes.append(FileNode(
                    url: entry,
                    name: entry.lastPathComponent,
                    isDirectory: (values?.isDirectory ?? false) && !isLink,
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
        guard let entries = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: options) else { return [] }

        var nodes: [FileNode] = []
        for case let entry as URL in entries {
            if Task.isCancelled { return nodes }
            if skipped.contains(entry.lastPathComponent) {
                entries.skipDescendants()
                continue
            }

            let values = try? entry.resourceValues(forKeys: Set(keys))
            let isLink = values?.isSymbolicLink ?? false
            if isLink { entries.skipDescendants() }
            if values?.isDirectory == true { continue }

            nodes.append(FileNode(
                url: entry,
                name: entry.lastPathComponent,
                isDirectory: false,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate))
        }

        return nodes.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
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
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let attributes else { return .unreadable("This file is no longer there.") }
            if let type = attributes[.type] as? FileAttributeType, type != .typeRegular {
                return .unreadable("This is not a regular file.")
            }

            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { return .empty }
            guard size <= byteLimit else { return .tooLarge(size: size) }
            guard let data = try? Data(contentsOf: url) else {
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
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.value
    }

    // Returns what went wrong, or nil when the write landed.
    static func write(_ text: String, to url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
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
