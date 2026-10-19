import Foundation

// One entry in the explorer: a file or a folder inside a session's working directory.
//
// A link is described by what it points at rather than by itself: its size and whether it
// opens as a folder are the target's, since that is the thing the user means to work on.
public struct FileNode: Identifiable, Sendable, Equatable {
    public var url: URL
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?
    // The link as it was written, so "../shared/AGENTS.md" is shown the way it reads on
    // disk instead of as a long absolute path. Nil for everything that is not a link.
    public var linkDestination: String?

    public init(url: URL, name: String, isDirectory: Bool, size: Int64, modified: Date? = nil,
                linkDestination: String? = nil) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.linkDestination = linkDestination
    }

    public var id: String { url.path }
    public var path: String { url.path }
    public var kind: String { url.pathExtension.lowercased() }
    public var isLink: Bool { linkDestination != nil }
    public var supportsMarkdownPreview: Bool { kind == "md" || kind == "markdown" }
}

// Navigation is kept separate from the view so the rules stay the same whether a row was
// reached with the mouse or the keyboard. The rows are already flattened in display order,
// and depth is enough to find a parent without rebuilding the tree.
public enum FileTreeNavigation {
    public struct Row: Equatable {
        public let path: String
        public let isDirectory: Bool
        public let depth: Int

        public init(path: String, isDirectory: Bool, depth: Int) {
            self.path = path
            self.isDirectory = isDirectory
            self.depth = depth
        }
    }

    public enum Direction {
        case up
        case down
        case left
        case right
    }

    public enum Action: Equatable {
        case select(String)
        case expand(String)
        case collapse(String)
    }

    public static func action(for direction: Direction, selectedPath: String?, rows: [Row],
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
public enum FilePreview: Sendable, Equatable {
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
public enum FileTree {
    public struct CopyFailure: Sendable, Equatable {
        public let name: String
        public let message: String

        public init(name: String, message: String) {
            self.name = name
            self.message = message
        }
    }

    public struct CopyResult: Sendable, Equatable {
        public var copied: [URL] = []
        public var failures: [CopyFailure] = []

        public init(copied: [URL] = [], failures: [CopyFailure] = []) {
            self.copied = copied
            self.failures = failures
        }
    }

    public struct Move: Sendable, Equatable {
        public let from: URL
        public let to: URL

        public init(from: URL, to: URL) {
            self.from = from
            self.to = to
        }
    }

    public struct MoveResult: Sendable, Equatable {
        public var moved: [Move] = []
        public var failures: [CopyFailure] = []

        public init(moved: [Move] = [], failures: [CopyFailure] = []) {
            self.moved = moved
            self.failures = failures
        }
    }

    // Past this the file is named and sized but not opened. The text view lays out only
    // what is on screen, so length costs little, but the whole file is still held in
    // memory twice over while it is open.
    public static let byteLimit: Int64 = 4 << 20

    // Skipped whatever the hidden-files setting says. It is machine state rather than the
    // user's work, and it is deep and wide enough on its own to make the tree unusable.
    private static let skipped: Set<String> = [".git"]

    public static func children(of url: URL, includeHidden: Bool) async -> [FileNode] {
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

    public static func files(beneath url: URL, includeHidden: Bool) async -> [FileNode] {
        guard !Task.isCancelled else { return [] }
        let task = Task.detached(priority: .userInitiated) {
            filesOnCurrentThread(beneath: url, includeHidden: includeHidden)
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
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

    public static func ancestorDirectories(of file: URL, beneath root: URL) -> [String] {
        guard let relativePath = file.path.pathRelative(to: root.path) else { return [] }
        let parent = (relativePath as NSString).deletingLastPathComponent
        guard parent != ".", !parent.isEmpty else { return [] }

        var directory = root.standardizedFileURL
        return parent.split(separator: "/").map { component in
            directory.appendPathComponent(String(component), isDirectory: true)
            return directory.path
        }
    }

    public static func copy(_ sources: [URL], into directory: URL) async -> CopyResult {
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

    // The Trash rather than a real delete, so a slip in the tree can be undone from Finder.
    // Returns why it failed, or nil once the item is gone.
    public static func trash(_ url: URL, using trash: FileTrash = .system) async -> String? {
        await Task.detached(priority: .userInitiated) {
            do {
                try trash.move(url)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
    }

    // Unlike a copy, a move never picks a new name: the item is meant to arrive as itself,
    // so a name already taken in the folder is refused rather than replaced.
    public static func move(_ sources: [URL], into directory: URL) async -> MoveResult {
        await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            let target = directory.standardizedFileURL.path
            var result = MoveResult()
            for source in sources {
                let path = source.standardizedFileURL.path
                let name = source.lastPathComponent
                // Let go where it started, or on itself: nothing to do.
                if target == path
                    || source.deletingLastPathComponent().standardizedFileURL.path == target {
                    continue
                }
                guard !target.hasPrefix(path + "/") else {
                    result.failures.append(CopyFailure(
                        name: name, message: "A folder cannot be moved into itself."))
                    continue
                }
                let destination = directory.appendingPathComponent(name)
                // Read without following links, so a broken link already sitting there
                // still counts as taken.
                guard (try? files.attributesOfItem(atPath: destination.path)) == nil else {
                    result.failures.append(CopyFailure(
                        name: name, message: "Something called \(name) is already in that folder."))
                    continue
                }
                do {
                    try files.moveItem(at: source, to: destination)
                    result.moved.append(Move(from: source, to: destination))
                } catch {
                    result.failures.append(CopyFailure(name: name,
                                                       message: error.localizedDescription))
                }
            }
            return result
        }.value
    }

    public enum CreateResult: Equatable, Sendable {
        case created(URL)
        case failed(String)
    }

    // A placeholder name, the way Finder does it, so the item exists at once and is then
    // renamed in place. A name already in use gets a number.
    public static func create(folder: Bool, in directory: URL) async -> CreateResult {
        await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            let base = folder ? "untitled folder" : "untitled"
            var url = directory.appendingPathComponent(base, isDirectory: folder)
            var number = 2
            while files.fileExists(atPath: url.path) {
                url = directory.appendingPathComponent("\(base) \(number)", isDirectory: folder)
                number += 1
            }
            do {
                if folder {
                    try files.createDirectory(at: url, withIntermediateDirectories: false)
                } else {
                    try Data().write(to: url, options: .withoutOverwriting)
                }
                return .created(url)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value
    }

    // A new empty file or folder with the name given, for a front end that asks for the
    // name first. A name already in use is refused, as a rename refuses it.
    public static func create(named name: String, folder: Bool, in directory: URL) async -> CreateResult {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failed("A name cannot be empty.") }
        guard name != ".", name != "..", !name.contains("/") else {
            return .failed("A name cannot contain \"/\" or be \".\" or \"..\".")
        }
        return await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            let url = directory.appendingPathComponent(name, isDirectory: folder)
            guard (try? files.attributesOfItem(atPath: url.path)) == nil else {
                return .failed("Something called \(name) is already in this folder.")
            }
            do {
                if folder {
                    try files.createDirectory(at: url, withIntermediateDirectories: false)
                } else {
                    try Data().write(to: url, options: .withoutOverwriting)
                }
                return .created(url)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value
    }

    public enum RenameResult: Equatable, Sendable {
        case renamed(URL)
        case unchanged
        case failed(String)
    }

    public static func rename(_ url: URL, to name: String) async -> RenameResult {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != url.lastPathComponent else { return .unchanged }
        guard !name.isEmpty else { return .failed("A name cannot be empty.") }
        guard name != ".", name != "..", !name.contains("/") else {
            return .failed("A name cannot contain \"/\" or be \".\" or \"..\".")
        }

        return await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            let destination = url.deletingLastPathComponent().appendingPathComponent(name)
            // On a disk that ignores case, a change of case alone finds the item itself.
            let onlyCaseChanges = name.lowercased() == url.lastPathComponent.lowercased()
            if !onlyCaseChanges, files.fileExists(atPath: destination.path) {
                return .failed("Something called \(name) is already in this folder.")
            }
            do {
                if onlyCaseChanges {
                    // Moving straight onto a name the disk already counts as taken can be
                    // refused, so the item steps through a name nothing else can have.
                    let step = url.deletingLastPathComponent()
                        .appendingPathComponent(".\(UUID().uuidString)")
                    try files.moveItem(at: url, to: step)
                    do {
                        try files.moveItem(at: step, to: destination)
                    } catch {
                        try? files.moveItem(at: step, to: url)
                        throw error
                    }
                } else {
                    try files.moveItem(at: url, to: destination)
                }
                return .renamed(destination)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value
    }

    // Where a path ends up once the item at `old` is called `new`: the item itself and
    // everything inside it move, anything else stays put.
    public static func path(_ path: String, afterMoving old: String, to new: String) -> String {
        if path == old { return new }
        guard path.hasPrefix(old + "/") else { return path }
        return new + path.dropFirst(old.count)
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

    public static func preview(of url: URL) async -> FilePreview {
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
            if GitInspector.imageKinds.contains(url.pathExtension.lowercased()) { return .image(data) }
            guard !data.looksBinary else { return .binary(size: size) }

            return .text(String(decoding: data, as: UTF8.self))
        }.value
    }

    // When the file was last written, so a pane that has held a file open for a while can
    // tell whether anyone else has been at it.
    public static func modified(of url: URL) async -> Date? {
        await Task.detached(priority: .userInitiated) {
            try? url.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.value
    }

    // Returns what went wrong, or nil when the write landed.
    public static func write(_ text: String, to url: URL) async -> String? {
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
