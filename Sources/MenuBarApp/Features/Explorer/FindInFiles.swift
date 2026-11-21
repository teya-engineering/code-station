import AppKit
import SwiftUI

// A file read into memory once when the dialog opens, so each keystroke only searches
// text and never goes back to the disk.
struct FileTextDocument: Sendable {
    let file: FileNode
    let text: String
}

// One line that holds the query. The text is trimmed and, for a very long line, cut down
// to the part around the first hit, so a minified file cannot fill the row. Hits are
// UTF-16 ranges into that shortened text.
struct FileTextLine: Equatable, Sendable {
    let number: Int
    let text: String
    let hits: [NSRange]

    // Every hit wears the colour the editor uses for a find match, so the line looks the
    // same here as it will once it is open.
    @MainActor var highlighted: AttributedString {
        let text = text as NSString
        var out = AttributedString()
        var cursor = 0
        for hit in hits where hit.location >= cursor && NSMaxRange(hit) <= text.length {
            out += AttributedString(text.substring(with: NSRange(location: cursor,
                                                                 length: hit.location - cursor)))
            var mark = AttributedString(text.substring(with: hit))
            mark.backgroundColor = Color(nsColor: CodeEditorStyle.match)
            out += mark
            cursor = NSMaxRange(hit)
        }
        out += AttributedString(text.substring(from: cursor))
        return out
    }
}

struct FileTextMatches: Equatable, Sendable, Identifiable {
    let file: FileNode
    let lines: [FileTextLine]

    var id: String { file.path }
}

// Where the next page of a search starts: a document, and a UTF-16 offset into its text
// that falls at the start of a line holding a match.
struct FileTextSearchCursor: Equatable, Sendable {
    var document: Int
    var location: Int
}

struct FileTextSearchResult: Equatable, Sendable {
    var files: [FileTextMatches] = []
    // Set while there are matches left that have not been listed yet.
    var next: FileTextSearchCursor?

    var hasMore: Bool { next != nil }
    var lineCount: Int { files.reduce(0) { $0 + $1.lines.count } }

    var summary: String {
        guard !files.isEmpty else { return "No matches" }
        guard hasMore else {
            return "\(counted(lineCount, "match", plural: "matches")) in \(counted(files.count, "file"))"
        }
        return "\(lineCount)+ matches in \(files.count)+ \(files.count == 1 ? "file" : "files")"
    }

    // A page that carries on from this one. A file cut at the page break goes on in the
    // same group rather than showing up twice.
    mutating func append(_ page: FileTextSearchResult) {
        var pageFiles = page.files[...]
        if let first = pageFiles.first, let last = files.last, first.file.path == last.file.path {
            files[files.count - 1] = FileTextMatches(file: last.file, lines: last.lines + first.lines)
            pageFiles = pageFiles.dropFirst()
        }
        files += pageFiles
        next = page.next
    }
}

// The same rule as find in the open file: a plain substring, case ignored. A line with
// several hits is listed once, since opening it lands on the line either way.
//
// Results come in pages, the way IntelliJ lists them: the first page is cheap even when
// the query is a single letter, and the next one is read only when the reader scrolls
// down to it.
enum FileTextSearch {
    static let pageSize = 200
    static let excerptLength = 240
    // How much of the line before the first hit stays in view when a long line is cut.
    private static let leadIn = 40

    static func matches(_ query: String, in documents: [FileTextDocument],
                        from cursor: FileTextSearchCursor = FileTextSearchCursor(document: 0, location: 0),
                        limit: Int = pageSize) -> FileTextSearchResult {
        guard !query.isBlank else { return FileTextSearchResult() }

        var result = FileTextSearchResult()
        var remaining = limit
        for index in documents.indices where index >= cursor.document {
            if Task.isCancelled { return result }
            let document = documents[index]
            let from = index == cursor.document ? cursor.location : 0
            let found = lines(matching: query, in: document.text, from: from, limit: remaining)
            if !found.lines.isEmpty {
                result.files.append(FileTextMatches(file: document.file, lines: found.lines))
                remaining -= found.lines.count
            }
            if let next = found.next {
                result.next = FileTextSearchCursor(document: index, location: next)
                return result
            }
        }
        return result
    }

    static func matches(_ query: String, in documents: [FileTextDocument],
                        from cursor: FileTextSearchCursor) async -> FileTextSearchResult {
        let task = Task.detached(priority: .userInitiated) { () -> FileTextSearchResult in
            matches(query, in: documents, from: cursor)
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    // The lines holding the query, from an offset on. Once `limit` lines are listed, `next`
    // is where the following match sits, or nil when there is none.
    static func lines(matching query: String, in text: String, from start: Int = 0,
                      limit: Int = pageSize) -> (lines: [FileTextLine], next: Int?) {
        guard !query.isEmpty else { return ([], nil) }

        let document = text as NSString
        var index: LineIndex?
        var lines: [FileTextLine] = []
        var location = start
        while location < document.length {
            if Task.isCancelled { return (lines, nil) }
            let hit = document.range(of: query, options: .caseInsensitive,
                                     range: NSRange(location: location, length: document.length - location))
            guard hit.location != NSNotFound, hit.length > 0 else { break }
            let lineIndex = index ?? LineIndex(document)
            index = lineIndex
            let line = lineIndex.line(at: hit.location)
            let lineRange = lineIndex.range(of: line, length: document.length)
            if lines.count == limit { return (lines, lineRange.location) }

            // Hits past the excerpt could never be seen, so a huge minified line is not
            // searched to its end.
            let end = min(NSMaxRange(lineRange), hit.location + excerptLength)
            var hits = [hit]
            var after = NSMaxRange(hit)
            while after < end {
                let more = document.range(of: query, options: .caseInsensitive,
                                          range: NSRange(location: after, length: end - after))
                guard more.location != NSNotFound, more.length > 0 else { break }
                hits.append(more)
                after = NSMaxRange(more)
            }
            lines.append(excerpt(of: line, hits: hits, index: lineIndex, in: document))
            location = max(NSMaxRange(lineRange), NSMaxRange(hit))
        }
        return (lines, nil)
    }

    // The hits of the query on one line of the text, as ranges into the whole text. Used to
    // mark the query on the line a match opens at.
    static func hits(of query: String, onLine number: Int, in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let document = text as NSString
        let index = LineIndex(document)
        guard number >= 1, number <= index.count else { return [] }
        let line = index.range(of: number - 1, length: document.length)
        return FileFind.search(query, in: document.substring(with: line)).matches.map {
            NSRange(location: $0.location + line.location, length: $0.length)
        }
    }

    // Images, binaries, empty files and anything past the size the editor opens are left
    // out: a match there could not be shown.
    struct LoadedDocuments: Sendable {
        var documents: [FileTextDocument] = []
        var limited = false
    }

    static let byteLimit = 32 * 1024 * 1024

    // Inside a git repository, what git ignores is left out. Installed packages and build
    // output are rarely what the reader is after, and in a web project they hold far more
    // text than the budget, so the files that matter would never be read. The paths are
    // relative to `root`. Nil outside a repository, where every file is searched.
    static func unignoredPaths(beneath root: String, tool: Git.Tool) async -> Set<String>? {
        await Git.offMain(lane: .interactive) {
            let output = Git.run(
                tool, ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
                in: URL(fileURLWithPath: root), captureByteLimit: 64 << 20)
            guard output.ok, !output.truncated else { return nil }
            return Set(output.text.split(separator: "\0").map(String.init))
        }
    }

    static func unignored(_ files: [FileNode], root: String, paths: Set<String>?) -> [FileNode] {
        guard let paths else { return files }
        return files.filter { file in
            file.path.pathRelative(to: root).map(paths.contains) ?? true
        }
    }

    static func documents(for files: [FileNode], byteLimit: Int = byteLimit) async -> LoadedDocuments {
        guard !Task.isCancelled else { return LoadedDocuments() }
        let task = Task.detached(priority: .userInitiated) {
            var loaded = LoadedDocuments()
            var remaining = byteLimit
            for file in files {
                if Task.isCancelled { break }
                guard !FileTree.imageKinds.contains(file.kind),
                      file.size > 0, file.size <= FileTree.byteLimit else { continue }
                guard file.size <= remaining else { loaded.limited = true; continue }
                guard let handle = try? FileHandle(forReadingFrom: file.url.resolvingSymlinksInPath()) else { continue }
                // Metadata can be stale if a file grows while the search is opening.
                let data = try? handle.read(upToCount: min(remaining, Int(FileTree.byteLimit)) + 1)
                try? handle.close()
                guard let data, !data.isEmpty, !data.looksBinary else { continue }
                guard data.count <= remaining else { loaded.limited = true; continue }
                guard data.count <= FileTree.byteLimit else { continue }
                remaining -= data.count
                loaded.documents.append(FileTextDocument(file: file, text: String(decoding: data, as: UTF8.self)))
            }
            return loaded
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private static func excerpt(of line: Int, hits: [NSRange], index: LineIndex,
                                in document: NSString) -> FileTextLine {
        let range = index.range(of: line, length: document.length)
        var start = range.location
        var end = NSMaxRange(range)
        while end > start, isBlank(document.character(at: end - 1)) { end -= 1 }
        while start < end, isBlank(document.character(at: start)) { start += 1 }

        var window = NSRange(location: start, length: end - start)
        if window.length > excerptLength {
            let firstHit = hits.first.map { $0.location } ?? start
            let from = firstHit + (hits.first?.length ?? 0) - start <= excerptLength
                ? start
                : max(start, firstHit - leadIn)
            window = document.rangeOfComposedCharacterSequences(
                for: NSRange(location: from, length: min(excerptLength, end - from)))
        }

        let lead = window.location > start ? "…" : ""
        let tail = NSMaxRange(window) < end ? "…" : ""
        let shift = (lead as NSString).length - window.location
        let shown = hits.compactMap { hit -> NSRange? in
            let visible = NSIntersectionRange(hit, window)
            guard visible.length > 0 else { return nil }
            return NSRange(location: visible.location + shift, length: visible.length)
        }
        return FileTextLine(number: line + 1,
                            text: lead + document.substring(with: window) + tail,
                            hits: shown)
    }

    private static func isBlank(_ unit: unichar) -> Bool {
        unit == 32 || unit == 9 || unit == 10 || unit == 13
    }
}

struct FindInFilesMatch: Equatable, Identifiable {
    let file: FileNode
    let line: FileTextLine

    var id: String { "\(file.path):\(line.number)" }
}

@MainActor
@Observable
final class FindInFilesModel {
    let root: String
    let includeHidden: Bool

    var query: String {
        didSet { if query != oldValue { search() } }
    }
    private(set) var result = FileTextSearchResult()
    private(set) var matches: [FindInFilesMatch] = []
    private(set) var selectedIndex: Int?
    private(set) var limited = false
    private(set) var loading = true
    private(set) var loadingMore = false
    // The query the result belongs to. Typing runs ahead of the search for a moment, and
    // the old result stays on screen meanwhile rather than flashing empty.
    private(set) var searchedQuery: String?

    private var documents: [FileTextDocument] = []
    private var searchTask: Task<Void, Never>?
    private var moreTask: Task<Void, Never>?

    init(root: String, includeHidden: Bool, query: String = "") {
        self.root = root
        self.includeHidden = includeHidden
        self.query = query
    }

    var selected: FindInFilesMatch? {
        guard let selectedIndex, matches.indices.contains(selectedIndex) else { return nil }
        return matches[selectedIndex]
    }

    func load() async {
        let tool = Git.tool()
        async let walked = FileTree.files(
            beneath: URL(fileURLWithPath: root), includeHidden: includeHidden)
        var paths: Set<String>?
        if let tool { paths = await FileTextSearch.unignoredPaths(beneath: root, tool: tool) }
        let files = FileTextSearch.unignored(await walked, root: root, paths: paths)
        guard !Task.isCancelled else { return }
        let loaded = await FileTextSearch.documents(for: files)
        guard !Task.isCancelled else { return }
        documents = loaded.documents
        limited = loaded.limited
        loading = false
        search()
    }

    func select(_ index: Int) {
        guard matches.indices.contains(index) else { return }
        selectedIndex = index
    }

    // Wraps at both ends, so the last match is one step up from the first.
    func moveSelection(by offset: Int) {
        guard !matches.isEmpty else { return }
        selectedIndex = ((selectedIndex ?? 0) + offset % matches.count + matches.count) % matches.count
    }

    func loadMore() {
        guard !loadingMore, let next = result.next, let query = searchedQuery, query == self.query else { return }
        loadingMore = true
        let documents = documents
        moreTask = Task {
            let page = await FileTextSearch.matches(query, in: documents, from: next)
            guard !Task.isCancelled else { return }
            loadingMore = false
            var result = result
            result.append(page)
            apply(result, for: query)
        }
    }

    private func search() {
        searchTask?.cancel()
        moreTask?.cancel()
        loadingMore = false
        guard !loading else { return }
        let query = query
        guard !query.isBlank else {
            apply(FileTextSearchResult(), for: query)
            return
        }
        let documents = documents
        searchTask = Task {
            let result = await FileTextSearch.matches(
                query, in: documents, from: FileTextSearchCursor(document: 0, location: 0))
            guard !Task.isCancelled else { return }
            apply(result, for: query)
        }
    }

    // The selection is kept rather than reset, the way find in the open file keeps it, so
    // refining the query does not throw the reader back to the top.
    private func apply(_ result: FileTextSearchResult, for query: String) {
        self.result = result
        matches = result.files.flatMap { group in
            group.lines.map { FindInFilesMatch(file: group.file, line: $0) }
        }
        searchedQuery = query
        selectedIndex = matches.isEmpty ? nil : min(selectedIndex ?? 0, matches.count - 1)
    }
}
