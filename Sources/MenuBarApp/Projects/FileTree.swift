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
