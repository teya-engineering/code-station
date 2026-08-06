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
}

// What the explorer can show for one file. A file it cannot draw is still worth an entry:
// knowing a path holds four megabytes of binary is an answer too.
enum FilePreview: Sendable, Equatable {
    case text(lines: [String], truncated: Bool, totalLines: Int)
    case image(Data)
    case binary(size: Int64)
    case tooLarge(size: Int64)
    case empty
    case unreadable(String)
}

// Reads folders and files for the explorer, always read-only.
//
// Every call hops off the main thread. A folder with a few thousand entries, or a file
// that turns out to live on a slow disk, is enough to freeze the window otherwise.
enum FileTree {
    // A file longer than this is shown from the top and cut off. Nobody reads to the end
    // of a 4000 line file in a preview pane, and laying one out costs real time.
    static let previewLineLimit = 4000
    static let previewByteLimit: Int64 = 4 << 20
    // Minified sources are one line holding the whole file, which lays out slowly and
    // says nothing once it is wider than the pane.
    private static let lineCharacterLimit = 2000

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

    static func preview(of url: URL) async -> FilePreview {
        await Task.detached(priority: .userInitiated) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let attributes else { return .unreadable("This file is no longer there.") }
            if let type = attributes[.type] as? FileAttributeType, type != .typeRegular {
                return .unreadable("This is not a regular file.")
            }

            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { return .empty }
            guard size <= previewByteLimit else { return .tooLarge(size: size) }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return .unreadable("Could not read this file.")
            }

            // Decoding is the view's job, so a file that claims to be an image but is not
            // falls back to the binary message rather than being checked twice.
            if imageKinds.contains(url.pathExtension.lowercased()) { return .image(data) }
            guard !data.looksBinary else { return .binary(size: size) }

            var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            // A trailing newline ends the last line rather than starting an empty one.
            if lines.last == "" { lines.removeLast() }
            let total = lines.count
            lines = Array(lines.prefix(previewLineLimit)).map { line in
                var text = line.replacingOccurrences(of: "\t", with: "    ")
                    .replacingOccurrences(of: "\r", with: "")
                if text.count > lineCharacterLimit {
                    text = String(text.prefix(lineCharacterLimit)) + " …"
                }
                return text
            }
            return .text(lines: lines, truncated: total > previewLineLimit, totalLines: total)
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
