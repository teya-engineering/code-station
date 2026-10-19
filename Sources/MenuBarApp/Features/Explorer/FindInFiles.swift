import AppKit
import SwiftUI
import CodeStationCore

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
        let files = await FileTree.files(
            beneath: URL(fileURLWithPath: root), includeHidden: includeHidden)
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

    func moveSelection(by offset: Int) {
        guard !matches.isEmpty else { return }
        selectedIndex = min(max((selectedIndex ?? 0) + offset, 0), matches.count - 1)
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

            if model.limited {
                Text("Some files were left out because this folder has more than 32 MB of text.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

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
                            // Rows are keyed by file and line, not by place in the list. The lazy
                            // stack keeps rows by key, and a place reused by the next query would
                            // show the old query's line.
                            let rows = starts[group]..<(starts[group] + matches.lines.count)
                            ForEach(Array(zip(rows, model.matches[rows])), id: \.1.id) { index, match in
                                matchRow(match.line, in: match.file, index: index)
                            }
                        }
                        if model.result.hasMore {
                            loadingMoreRow
                                // Keyed on the count, so a page too short to push this row
                                // out of view still asks for the one after it.
                                .task(id: model.matches.count) { model.loadMore() }
                        }
                    }
                    .padding(5)
                }
                .onChange(of: model.selectedIndex) {
                    if let selected = model.selected {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(selected.id, anchor: .center)
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

    private var loadingMoreRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Finding more...")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
    }

    private func matchRow(_ line: FileTextLine, in file: FileNode, index: Int) -> some View {
        let selected = model.selectedIndex == index

        return Button {
            model.select(index)
        } label: {
            HStack(spacing: 10) {
                Text(verbatim: "\(line.number)")
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
