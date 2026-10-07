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
}

struct FileTextMatches: Equatable, Sendable, Identifiable {
    let file: FileNode
    let lines: [FileTextLine]

    var id: String { file.path }
}

struct FileTextSearchResult: Equatable, Sendable {
    var files: [FileTextMatches] = []
    var hasMore = false

    var lineCount: Int { files.reduce(0) { $0 + $1.lines.count } }

    var summary: String {
        guard !files.isEmpty else { return "No matches" }
        let matches = counted(lineCount, "match", plural: "matches")
        return "\(matches)\(hasMore ? "+" : "") in \(counted(files.count, "file"))"
    }
}

// The same rule as find in the open file: a plain substring, case ignored. A line with
// several hits is listed once, since opening it lands on the line either way.
enum FileTextSearch {
    static let excerptLength = 240
    // How much of the line before the first hit stays in view when a long line is cut.
    private static let leadIn = 40

    static func matches(_ query: String, in documents: [FileTextDocument]) -> FileTextSearchResult {
        guard !query.isBlank else { return FileTextSearchResult() }

        var result = FileTextSearchResult()
        var remaining = FileFind.matchLimit
        for (index, document) in documents.enumerated() {
            if Task.isCancelled { return result }
            let found = lines(matching: query, in: document.text, limit: remaining)
            guard !found.lines.isEmpty else { continue }
            result.files.append(FileTextMatches(file: document.file, lines: found.lines))
            remaining -= found.lines.count
            if found.hasMore {
                result.hasMore = true
                return result
            }
            if remaining == 0 {
                result.hasMore = documents[(index + 1)...].contains {
                    $0.text.range(of: query, options: .caseInsensitive) != nil
                }
                return result
            }
        }
        return result
    }

    static func matches(_ query: String, in documents: [FileTextDocument]) async -> FileTextSearchResult {
        let task = Task.detached(priority: .userInitiated) { () -> FileTextSearchResult in
            matches(query, in: documents)
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    static func lines(matching query: String, in text: String,
                      limit: Int = FileFind.matchLimit) -> (lines: [FileTextLine], hasMore: Bool) {
        let found = FileFind.search(query, in: text)
        guard !found.matches.isEmpty, limit > 0 else { return ([], !found.matches.isEmpty) }

        let document = text as NSString
        let index = LineIndex(document)
        var lines: [FileTextLine] = []
        var current: (line: Int, hits: [NSRange])?
        for match in found.matches {
            let line = index.line(at: match.location)
            if let open = current, open.line != line {
                lines.append(excerpt(of: open.line, hits: open.hits, index: index, in: document))
                current = nil
                if lines.count == limit { return (lines, true) }
            }
            current = (line, (current?.hits ?? []) + [match])
        }
        if let open = current {
            lines.append(excerpt(of: open.line, hits: open.hits, index: index, in: document))
        }
        return (lines, found.hasMore)
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
    static func documents(for files: [FileNode]) async -> [FileTextDocument] {
        await Task.detached(priority: .userInitiated) {
            var documents: [FileTextDocument] = []
            for file in files {
                if Task.isCancelled { return documents }
                guard !FileTree.imageKinds.contains(file.kind),
                      file.size > 0, file.size <= FileTree.byteLimit,
                      let data = try? Data(contentsOf: file.url.resolvingSymlinksInPath()),
                      !data.isEmpty, !data.looksBinary else { continue }
                documents.append(FileTextDocument(file: file, text: String(decoding: data, as: UTF8.self)))
            }
            return documents
        }.value
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

struct FindInFilesMatch: Equatable {
    let file: FileNode
    let line: FileTextLine
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
    private(set) var loading = true
    // The query the result belongs to. Typing runs ahead of the search for a moment, and
    // the old result stays on screen meanwhile rather than flashing empty.
    private(set) var searchedQuery: String?

    private var documents: [FileTextDocument] = []
    private var searchTask: Task<Void, Never>?

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
        let files = await FileTree.files(
            beneath: URL(fileURLWithPath: root), includeHidden: includeHidden)
        let documents = await FileTextSearch.documents(for: files)
        guard !Task.isCancelled else { return }
        self.documents = documents
        loading = false
        search()
    }

    func select(_ index: Int) {
        guard matches.indices.contains(index) else { return }
        selectedIndex = index
    }

    func moveSelection(by offset: Int) {
        guard !matches.isEmpty else { return }
        selectedIndex = min(max((selectedIndex ?? 0) + offset, 0), matches.count - 1)
    }

    private func search() {
        searchTask?.cancel()
        guard !loading else { return }
        let query = query
        guard !query.isBlank else {
            apply(FileTextSearchResult(), for: query)
            return
        }
        let documents = documents
        searchTask = Task {
            let result = await FileTextSearch.matches(query, in: documents)
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

struct FindInFilesDialog: View {
    private enum ResultsState: Equatable {
        case prompt
        case loading
        case empty
        case matches
    }

    @Bindable var model: FindInFilesModel
    // Kept by the pane, so the next opening starts from the last query.
    @Binding var rememberedQuery: String
    let onOpen: (FindInFilesMatch) -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Find in files", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onMoveCommand { direction in
                        switch direction {
                        case .up: model.moveSelection(by: -1)
                        case .down: model.moveSelection(by: 1)
                        default: break
                        }
                    }
                if resultsState == .matches || resultsState == .empty {
                    Text(model.result.summary)
                        .font(.mono(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))

            results
                .frame(height: 320)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        }
        .onChange(of: model.query) { _, query in rememberedQuery = query }
        .task {
            searchFocused = true
            await model.load()
        }
    }

    @ViewBuilder private var results: some View {
        switch resultsState {
        case .prompt:
            message("Start typing to find text in files",
                    detail: "Case does not matter. Use ↑ ↓ to move and ↩ to open.")
                .transition(.fadeIn)
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading files...")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.fadeIn)
        case .empty:
            message("No matches for “\(model.query.trimmed)”",
                    detail: model.includeHidden
                        ? nil : "Hidden files are off. Turn them on in the header to search those too.")
                .transition(.fadeIn)
        case .matches:
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let starts = groupStarts
                        ForEach(Array(model.result.files.enumerated()), id: \.element.id) { group, matches in
                            fileRow(matches)
                                .padding(.top, group == 0 ? 0 : 4)
                            ForEach(Array(matches.lines.enumerated()), id: \.element.number) { offset, line in
                                matchRow(line, in: matches.file, index: starts[group] + offset)
                                    .id(starts[group] + offset)
                            }
                        }
                    }
                    .padding(5)
                }
                .onChange(of: model.selectedIndex) {
                    if let index = model.selectedIndex {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
            }
            .transition(.fadeIn)
        }
    }

    private var resultsState: ResultsState {
        if model.query.isBlank { return .prompt }
        if model.loading || (model.searchedQuery != model.query && model.matches.isEmpty) {
            return .loading
        }
        return model.matches.isEmpty ? .empty : .matches
    }

    // Where each file's lines start in the flat list the selection moves through.
    private var groupStarts: [Int] {
        var next = 0
        return model.result.files.map { group in
            defer { next += group.lines.count }
            return next
        }
    }

    private func fileRow(_ matches: FileTextMatches) -> some View {
        let path = matches.file.path.pathRelative(to: model.root) ?? matches.file.path
        let directory = (path as NSString).deletingLastPathComponent

        return HStack(spacing: 9) {
            Image(systemName: "doc")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(matches.file.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .layoutPriority(1)
            if !directory.isEmpty && directory != "." {
                Text(directory)
                    .font(.mono(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text("\(matches.lines.count)")
                .font(.mono(10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(matches.file.name), \(counted(matches.lines.count, "match", plural: "matches"))")
        .accessibilityAddTraits(.isHeader)
    }

    private func matchRow(_ line: FileTextLine, in file: FileNode, index: Int) -> some View {
        let selected = model.selectedIndex == index

        return Button {
            model.select(index)
        } label: {
            HStack(spacing: 10) {
                Text("\(line.number)")
                    .font(.mono(10, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 36, alignment: .trailing)
                Text(marked(line))
                    .font(.mono(11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Theme.card : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Theme.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 6)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if model.matches.indices.contains(index) { onOpen(model.matches[index]) }
        })
        .accessibilityLabel("Line \(line.number) in \(file.name): \(line.text)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // Every hit wears the colour the editor uses for a find match, so the line looks the
    // same here as it will once it is open.
    private func marked(_ line: FileTextLine) -> AttributedString {
        let text = line.text as NSString
        var out = AttributedString()
        var cursor = 0
        for hit in line.hits where hit.location >= cursor && NSMaxRange(hit) <= text.length {
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

    private func message(_ text: String, detail: String?) -> some View {
        VStack(spacing: 6) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
