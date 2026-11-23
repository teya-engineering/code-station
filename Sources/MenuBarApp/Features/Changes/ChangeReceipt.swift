import Foundation

// The files a review covers, arranged for the receipt in the ask. A small review is read
// as a flat list. A big one is grouped into a handful of folders, so the shape of the
// change reads before any single file does.
struct ChangeReceipt: Equatable {
    typealias File = SecondOpinionAskFacts.File

    struct Folder: Identifiable, Equatable {
        let id: String
        // The folder inside its repository, empty for files at the top.
        let path: String
        // What the row shows: the path, led by the repository's name when the review
        // spans more than one.
        let title: String
        // Largest first.
        let files: [File]
        let added: Int
        let removed: Int

        var lines: Int { added + removed }

        // A file's place inside the folder, which is all a row under the folder needs.
        func name(of file: File) -> String {
            path.isEmpty ? file.path : String(file.path.dropFirst(path.count + 1))
        }
    }

    // Up to this many files the receipt stays one flat list with no map and no tools.
    static let flatLimit = 12
    static let largestShown = 8
    // Past this many folders the closest ones merge into the folder they share, so the
    // list opens on a few rows however spread out the change is.
    static let folderLimit = 10

    let files: [File]
    let folders: [Folder]
    // A leading part of the path most files share, such as `Sources/App/`. Rows draw it
    // faded, so the part that differs reads first.
    let sharedRoot: String?
    private let folderOfFile: [File.ID: Folder.ID]

    init(files: [File], repositoryNames: [String: String] = [:]) {
        let spansRepositories = Set(files.map(\.root)).count > 1
        var folders: [Folder] = []
        for (key, grouped) in Self.group(files) {
            let name = repositoryNames[key.root] ?? (key.root as NSString).lastPathComponent
            let title: String
            if spansRepositories {
                title = key.path.isEmpty ? name : name + "/" + key.path
            } else {
                title = key.path.isEmpty ? "Top level" : key.path
            }
            let added = grouped.reduce(0) { $0 + $1.added }
            let removed = grouped.reduce(0) { $0 + $1.removed }
            folders.append(Folder(id: key.root + "\u{0}" + key.path, path: key.path, title: title,
                                  files: grouped.sorted(by: Self.largerFirst), added: added, removed: removed))
        }
        folders.sort { $0.lines != $1.lines ? $0.lines > $1.lines : $0.title < $1.title }
        self.files = files
        self.folders = folders
        sharedRoot = Self.sharedRoot(of: folders)
        folderOfFile = Dictionary(folders.flatMap { folder in folder.files.map { ($0.id, folder.id) } },
                                  uniquingKeysWith: { first, _ in first })
    }

    var isFlat: Bool { files.count <= Self.flatLimit }
    var largest: [File] { files.sorted(by: Self.largerFirst) }
    // The line count that fills a whole bar: the biggest file, or the biggest folder
    // when folder rows are drawn on the same scale as the files inside them.
    var fileScale: Int { max(files.map(\.lines).max() ?? 1, 1) }
    var folderScale: Int { max(folders.map(\.lines).max() ?? 1, 1) }

    func folder(of file: File) -> Folder? {
        folderOfFile[file.id].flatMap { id in folders.first { $0.id == id } }
    }

    // Every file whose path holds the words, largest first, whichever arrangement is on.
    func matching(_ query: String) -> [File] {
        let query = query.trimmed
        guard !query.isEmpty else { return largest }
        return largest.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    private static func largerFirst(_ lhs: File, _ rhs: File) -> Bool {
        lhs.lines != rhs.lines ? lhs.lines > rhs.lines : lhs.path < rhs.path
    }

    // MARK: Grouping

    private struct Key: Hashable {
        let root: String
        let path: String

        var depth: Int { path.isEmpty ? 0 : path.split(separator: "/").count }

        // The key itself, then each folder above it, up to the repository's top.
        var lineage: [Key] {
            var keys = [self]
            var path = path
            while !path.isEmpty {
                path = (path as NSString).deletingLastPathComponent
                keys.append(Key(root: root, path: path))
            }
            return keys
        }

        func holds(_ other: Key) -> Bool {
            root == other.root && (path.isEmpty || other.path == path || other.path.hasPrefix(path + "/"))
        }
    }

    // Each file starts in its own folder. While there are too many, the deepest folder
    // that holds two or more of them takes them in, the smallest first on a tie, so
    // close neighbours merge before distant ones.
    private static func group(_ files: [File]) -> [Key: [File]] {
        var groups = Dictionary(grouping: files) { Key(root: $0.root, path: ($0.path as NSString).deletingLastPathComponent) }
        while groups.count > folderLimit {
            var held: [Key: (count: Int, lines: Int)] = [:]
            for (key, files) in groups {
                let lines = files.reduce(0) { $0 + $1.lines }
                for ancestor in key.lineage {
                    held[ancestor, default: (0, 0)].count += 1
                    held[ancestor, default: (0, 0)].lines += lines
                }
            }
            let merge = held.filter { $0.value.count > 1 }.min { lhs, rhs in
                if lhs.key.depth != rhs.key.depth { return lhs.key.depth > rhs.key.depth }
                if lhs.value.lines != rhs.value.lines { return lhs.value.lines < rhs.value.lines }
                return lhs.key.path < rhs.key.path
            }?.key
            guard let merge else { break }
            for key in Array(groups.keys) where merge.holds(key) && key != merge {
                groups[merge, default: []] += groups.removeValue(forKey: key) ?? []
            }
        }
        return groups
    }

    // The leading folder that more than half the files sit under, shared by the most
    // folders, the longest on a tie. A folder that is the root itself is not under it.
    private static func sharedRoot(of folders: [Folder]) -> String? {
        let total = folders.reduce(0) { $0 + $1.files.count }
        var prefixes: Set<String> = []
        for folder in folders {
            var prefix = ""
            for part in folder.title.split(separator: "/").dropLast() {
                prefix += part + "/"
                prefixes.insert(prefix)
            }
        }
        let shared = prefixes.compactMap { prefix -> (prefix: String, folders: Int)? in
            let under = folders.filter { $0.title.hasPrefix(prefix) }
            guard under.count > 1, under.reduce(0, { $0 + $1.files.count }) * 2 > total else { return nil }
            return (prefix, under.count)
        }
        return shared.max { lhs, rhs in
            lhs.folders != rhs.folders ? lhs.folders < rhs.folders : lhs.prefix.count < rhs.prefix.count
        }?.prefix
    }
}
