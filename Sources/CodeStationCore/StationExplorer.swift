import Foundation

// The Explorer tab, as the GUI's `ExplorerView` offers it: the session's checkout as a
// tree read a folder at a time, file name search (the GUI's double Shift), find in files
// (⌃H), and creating, renaming and trashing files. The editor and the HTML preview stay
// in the GUI; a terminal hands a file to `$EDITOR` itself, at the root the folder names.
//
// Every path in these values is relative to the session's working directory (its own
// worktree, or else the project folder), "/"-separated, with "" for the root itself. The
// root is given once, as a path on the host's machine. A path that would leave the root
// is refused.

public struct RemoteFileEntry: Codable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    // A link's size is its target's, and it opens as a folder when that is a folder.
    public let size: Int64
    // The link as it is written, nil for anything that is not a link.
    public let linkDestination: String?

    public init(path: String, name: String, isDirectory: Bool, size: Int64, linkDestination: String? = nil) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.linkDestination = linkDestination
    }
}

// One folder's entries, folders first and then by name as Finder sorts them. `.git` is
// left out; other hidden files are listed, as the GUI's tree lists them by default.
public struct RemoteFolder: Codable, Equatable, Sendable {
    public let sessionID: String
    // The session's working directory on the host's machine.
    public let root: String
    public let path: String
    public let entries: [RemoteFileEntry]

    public init(sessionID: String, root: String, path: String, entries: [RemoteFileEntry]) {
        self.sessionID = sessionID
        self.root = root
        self.path = path
        self.entries = entries
    }
}

// What find in files found: each file with its lines holding the query, case ignored.
// Only the first page comes back (`FileTextSearch.pageSize` lines); `more` says there
// were further matches past it.
public struct RemoteFindInFiles: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let lines: [Line]

        public init(path: String, lines: [Line]) {
            self.path = path
            self.lines = lines
        }
    }

    // A line holding the query, trimmed, and cut around the first hit when it is very
    // long. Hits are UTF-16 ranges into `text`.
    public struct Line: Codable, Equatable, Sendable {
        public let number: Int
        public let text: String
        public let hits: [Hit]

        public init(number: Int, text: String, hits: [Hit]) {
            self.number = number
            self.text = text
            self.hits = hits
        }
    }

    public struct Hit: Codable, Equatable, Sendable {
        public let location: Int
        public let length: Int

        public init(location: Int, length: Int) {
            self.location = location
            self.length = length
        }
    }

    public let query: String
    public let files: [File]
    public let more: Bool
    // Some files were left unread because together they passed the size searched.
    public let limited: Bool

    public init(query: String, files: [File], more: Bool, limited: Bool) {
        self.query = query
        self.files = files
        self.more = more
        self.limited = limited
    }

    public var lineCount: Int { files.reduce(0) { $0 + $1.lines.count } }
}

extension StationCommands {
    // One folder of the session's checkout: "" for the root.
    public func readFolder(_ sessionID: String, path: String) async throws(StationRefusal) -> RemoteFolder {
        let root = try explorerRoot(sessionID)
        let folder = try Self.resolve(path, in: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw path.isEmpty ? .noFolder : StationRefusal("\(path) is no longer a folder in this checkout.")
        }
        let nodes = await FileTree.children(of: folder, includeHidden: true)
        return RemoteFolder(sessionID: sessionID, root: root.path, path: Self.relative(folder, to: root),
                            entries: nodes.map { Self.entry($0, root: root) })
    }

    // Files whose name (or else path) holds the query, best first: the exact name, then
    // names that start with it, then names and paths that hold it. At most
    // `FileNameSearch.resultLimit`.
    public func searchFileNames(_ sessionID: String, query: String) async throws(StationRefusal) -> [RemoteFileEntry] {
        let root = try explorerRoot(sessionID)
        guard !query.isBlank else { return [] }
        let files = await FileTree.files(beneath: root, includeHidden: true)
        return FileNameSearch.matches(query, in: files, beneath: root.path).map { Self.entry($0, root: root) }
    }

    public func findInFiles(_ sessionID: String, query: String) async throws(StationRefusal) -> RemoteFindInFiles {
        let root = try explorerRoot(sessionID)
        guard !query.isBlank else { return RemoteFindInFiles(query: query, files: [], more: false, limited: false) }
        let files = await FileTree.files(beneath: root, includeHidden: true)
        let loaded = await FileTextSearch.documents(for: files)
        let result = await FileTextSearch.matches(query, in: loaded.documents,
                                                  from: FileTextSearchCursor(document: 0, location: 0))
        return RemoteFindInFiles(
            query: query,
            files: result.files.map { group in
                RemoteFindInFiles.File(path: Self.relative(group.file.url, to: root), lines: group.lines.map {
                    RemoteFindInFiles.Line(number: $0.number, text: $0.text,
                                           hits: $0.hits.map { .init(location: $0.location, length: $0.length) })
                })
            },
            more: result.hasMore, limited: loaded.limited)
    }

    // A new empty file, or folder, called `name` in the folder at `folder`. A name
    // already taken there is refused rather than numbered: the person typed it.
    public func createFile(_ sessionID: String, in folder: String, name: String,
                           isFolder: Bool) async throws(StationRefusal) -> RemoteFileEntry {
        let root = try explorerRoot(sessionID)
        let directory = try Self.resolve(folder, in: root)
        switch await FileTree.create(named: name, folder: isFolder, in: directory) {
        case .created(let url):
            return RemoteFileEntry(path: Self.relative(url, to: root), name: url.lastPathComponent,
                                   isDirectory: isFolder, size: 0)
        case .failed(let message):
            throw StationRefusal(message)
        }
    }

    // Gives the file or folder at `path` a new name in the same folder. Answers with the
    // entry as it now is.
    public func renameFile(_ sessionID: String, path: String, to name: String) async throws(StationRefusal) -> RemoteFileEntry {
        let root = try explorerRoot(sessionID)
        let url = try Self.resolve(path, in: root)
        guard !path.isEmpty else { throw StationRefusal("The checkout itself cannot be renamed here.") }
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { throw .noFile(path) }
        let renamed: URL
        switch await FileTree.rename(url, to: name) {
        case .renamed(let destination): renamed = destination
        case .unchanged: renamed = url
        case .failed(let message): throw StationRefusal(message)
        }
        let values = try? renamed.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        return RemoteFileEntry(path: Self.relative(renamed, to: root), name: renamed.lastPathComponent,
                               isDirectory: values?.isDirectory ?? false, size: Int64(values?.fileSize ?? 0))
    }

    // Moves the file or folder at `path` to the Trash, so a slip can be undone from Finder.
    public func trashFile(_ sessionID: String, path: String) async throws(StationRefusal) {
        let root = try explorerRoot(sessionID)
        let url = try Self.resolve(path, in: root)
        guard !path.isEmpty else { throw StationRefusal("The checkout itself cannot be trashed here.") }
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { throw .noFile(path) }
        if let message = await FileTree.trash(url, using: trash) { throw StationRefusal(message) }
    }

    // MARK: - Paths

    private func explorerRoot(_ sessionID: String) throws(StationRefusal) -> URL {
        guard let id = UUID(uuidString: sessionID), let session = store.session(id) else { throw .noSession }
        guard let root = store.workingDirectory(for: session) else { throw .noFolder }
        return URL(fileURLWithPath: root).standardizedFileURL
    }

    // The URL a relative path names under the root, refused when it would leave it.
    static func resolve(_ path: String, in root: URL) throws(StationRefusal) -> URL {
        guard !path.hasPrefix("/") else { throw .outsideCheckout }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.contains("..") else { throw .outsideCheckout }
        let url = parts.filter { $0 != "." }.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { throw .outsideCheckout }
        return url
    }

    static func relative(_ url: URL, to root: URL) -> String {
        url.standardizedFileURL.path.pathRelative(to: root.path) ?? url.path
    }

    private static func entry(_ node: FileNode, root: URL) -> RemoteFileEntry {
        RemoteFileEntry(path: relative(node.url, to: root), name: node.name, isDirectory: node.isDirectory,
                        size: node.size, linkDestination: node.linkDestination)
    }
}

extension StationRefusal {
    static let noFolder = StationRefusal("This session's folder is no longer there.")
    static let outsideCheckout = StationRefusal("That path is outside this session's checkout.")
    static func noFile(_ path: String) -> StationRefusal {
        StationRefusal("\(path) is no longer in this checkout.")
    }
}
