import Foundation

public enum FileNameSearch {
    public static let resultLimit = 200

    public static func matches(_ query: String, in files: [FileNode], beneath root: String) -> [FileNode] {
        let query = normalized(query.trimmed)
        guard !query.isEmpty else { return [] }

        return files.compactMap { node -> (node: FileNode, rank: Int, path: String)? in
            let path = node.path.pathRelative(to: root) ?? node.path
            let name = normalized(node.name)
            let normalizedPath = normalized(path)
            let rank: Int
            if name == query {
                rank = 0
            } else if name.hasPrefix(query) {
                rank = 1
            } else if name.contains(query) {
                rank = 2
            } else if normalizedPath.contains(query) {
                rank = 3
            } else {
                return nil
            }
            return (node, rank, path)
        }
        .sorted { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            return left.path.localizedStandardCompare(right.path) == .orderedAscending
        }
        .prefix(resultLimit)
        .map(\.node)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

public struct FileFindResult: Equatable, Sendable {
    public var matches: [NSRange] = []
    public var hasMore = false

    public init(matches: [NSRange] = [], hasMore: Bool = false) {
        self.matches = matches
        self.hasMore = hasMore
    }
}

// Search over the whole document rather than line by line. Ranges are UTF-16 offsets into
// the text, which is what the text view wants back when a match has to be coloured in or
// scrolled to, including when the text before it uses emoji.
public enum FileFind {
    public static let matchLimit = 10_000

    public static func search(_ query: String, in text: String) -> FileFindResult {
        guard !query.isEmpty else { return FileFindResult() }

        let document = text as NSString
        var matches: [NSRange] = []
        var remaining = NSRange(location: 0, length: document.length)
        while remaining.length > 0 {
            let range = document.range(of: query, options: .caseInsensitive, range: remaining)
            guard range.location != NSNotFound, range.length > 0 else { break }
            if matches.count == matchLimit {
                return FileFindResult(matches: matches, hasMore: true)
            }
            matches.append(range)
            let next = NSMaxRange(range)
            remaining = NSRange(location: next, length: document.length - next)
        }
        return FileFindResult(matches: matches)
    }
}

// Character offsets where each line starts, so the gutter can name a line and the
// highlighter can find one without counting newlines from the top of the file each time.
// Offsets are UTF-16, which is the unit the text view counts in.
public struct LineIndex: Equatable {
    private var starts: [Int]

    public init(_ text: NSString) {
        var starts = [0]
        var from = 0
        while from < text.length {
            let found = text.range(of: "\n", options: .literal,
                                   range: NSRange(location: from, length: text.length - from))
            guard found.location != NSNotFound else { break }
            from = found.location + 1
            starts.append(from)
        }
        self.starts = starts
    }

    // A file that ends in a newline has an empty last line. The text view draws it, so it
    // is counted and numbered here too.
    public var count: Int { starts.count }

    public func start(of line: Int) -> Int { starts[min(max(line, 0), starts.count - 1)] }

    // The line an offset falls on, clamped at both ends so a stale offset cannot trap.
    public func line(at offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    // One whole line including its newline, which is the unit the highlighter works in: a
    // token can only be read from the start of the line that holds it.
    public func range(of line: Int, length: Int) -> NSRange {
        guard line >= 0, line < count else { return NSRange(location: length, length: 0) }
        let from = start(of: line)
        let to = line + 1 < count ? start(of: line + 1) : length
        return NSRange(location: from, length: max(0, min(to, length) - from))
    }
}

// A file read into memory once when the dialog opens, so each keystroke only searches
// text and never goes back to the disk.
public struct FileTextDocument: Sendable {
    public let file: FileNode
    public let text: String

    public init(file: FileNode, text: String) {
        self.file = file
        self.text = text
    }
}

// One line that holds the query. The text is trimmed and, for a very long line, cut down
// to the part around the first hit, so a minified file cannot fill the row. Hits are
// UTF-16 ranges into that shortened text.
public struct FileTextLine: Equatable, Sendable {
    public let number: Int
    public let text: String
    public let hits: [NSRange]

    public init(number: Int, text: String, hits: [NSRange]) {
        self.number = number
        self.text = text
        self.hits = hits
    }
}

public struct FileTextMatches: Equatable, Sendable, Identifiable {
    public let file: FileNode
    public let lines: [FileTextLine]

    public init(file: FileNode, lines: [FileTextLine]) {
        self.file = file
        self.lines = lines
    }

    public var id: String { file.path }
}

// Where the next page of a search starts: a document, and a UTF-16 offset into its text
// that falls at the start of a line holding a match.
public struct FileTextSearchCursor: Equatable, Sendable {
    public var document: Int
    public var location: Int

    public init(document: Int, location: Int) {
        self.document = document
        self.location = location
    }
}

public struct FileTextSearchResult: Equatable, Sendable {
    public var files: [FileTextMatches] = []
    // Set while there are matches left that have not been listed yet.
    public var next: FileTextSearchCursor?

    public init(files: [FileTextMatches] = [], next: FileTextSearchCursor? = nil) {
        self.files = files
        self.next = next
    }

    public var hasMore: Bool { next != nil }
    public var lineCount: Int { files.reduce(0) { $0 + $1.lines.count } }

    public var summary: String {
        guard !files.isEmpty else { return "No matches" }
        guard hasMore else {
            return "\(counted(lineCount, "match", plural: "matches")) in \(counted(files.count, "file"))"
        }
        return "\(lineCount)+ matches in \(files.count)+ \(files.count == 1 ? "file" : "files")"
    }

    // A page that carries on from this one. A file cut at the page break goes on in the
    // same group rather than showing up twice.
    public mutating func append(_ page: FileTextSearchResult) {
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
public enum FileTextSearch {
    public static let pageSize = 200
    public static let excerptLength = 240
    // How much of the line before the first hit stays in view when a long line is cut.
    private static let leadIn = 40

    public static func matches(_ query: String, in documents: [FileTextDocument],
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

    public static func matches(_ query: String, in documents: [FileTextDocument],
                        from cursor: FileTextSearchCursor) async -> FileTextSearchResult {
        let task = Task.detached(priority: .userInitiated) { () -> FileTextSearchResult in
            matches(query, in: documents, from: cursor)
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    // The lines holding the query, from an offset on. Once `limit` lines are listed, `next`
    // is where the following match sits, or nil when there is none.
    public static func lines(matching query: String, in text: String, from start: Int = 0,
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
    public static func hits(of query: String, onLine number: Int, in text: String) -> [NSRange] {
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
    public struct LoadedDocuments: Sendable {
        public var documents: [FileTextDocument] = []
        public var limited = false

        public init(documents: [FileTextDocument] = [], limited: Bool = false) {
            self.documents = documents
            self.limited = limited
        }
    }

    public static let byteLimit = 32 * 1024 * 1024

    public static func documents(for files: [FileNode], byteLimit: Int = byteLimit) async -> LoadedDocuments {
        guard !Task.isCancelled else { return LoadedDocuments() }
        let task = Task.detached(priority: .userInitiated) {
            var loaded = LoadedDocuments()
            var remaining = byteLimit
            for file in files {
                if Task.isCancelled { break }
                guard !GitInspector.imageKinds.contains(file.kind),
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
