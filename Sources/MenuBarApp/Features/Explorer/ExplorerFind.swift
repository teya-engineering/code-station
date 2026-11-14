import SwiftUI

enum ExplorerSearchMode: CaseIterable {
    case names, contents

    var title: String {
        switch self {
        case .names: "File names"
        case .contents: "Contents"
        }
    }

    // The stroke that opens the dialog straight in this mode.
    var keys: String {
        switch self {
        case .names: "⇧⇧"
        case .contents: "⌃H"
        }
    }
}

// One dialog for both kinds of search. Each mode keeps the model it had as a dialog of
// its own, and the query is handed across on a switch, so switching never loses what
// was typed. Each model reads the disk only the first time its mode is shown.
@MainActor
@Observable
final class ExplorerFindModel {
    enum ResultsState: Equatable {
        case prompt
        case loading
        case empty
        case matches
    }

    enum Result {
        case file(FileNode)
        case line(FindInFilesMatch)
    }

    let names: ExplorerSearchModel
    let contents: FindInFilesModel
    private(set) var mode: ExplorerSearchMode
    var query: String {
        didSet { handOver() }
    }

    @ObservationIgnored private var loads: [ExplorerSearchMode: Task<Void, Never>] = [:]

    init(root: String, includeHidden: Bool, mode: ExplorerSearchMode, query: String) {
        names = ExplorerSearchModel(root: root, includeHidden: includeHidden)
        contents = FindInFilesModel(root: root, includeHidden: includeHidden)
        self.mode = mode
        self.query = query
        handOver()
    }

    var root: String { names.root }
    var includeHidden: Bool { names.includeHidden }

    func show(_ mode: ExplorerSearchMode) {
        self.mode = mode
        handOver()
        prepare()
    }

    func prepare() {
        guard loads[mode] == nil else { return }
        let names = names, contents = contents
        loads[mode] = switch mode {
        case .names: Task { await names.load() }
        case .contents: Task { await contents.load() }
        }
    }

    func cancel() {
        loads.values.forEach { $0.cancel() }
    }

    func moveSelection(by offset: Int) {
        switch mode {
        case .names: names.moveSelection(by: offset)
        case .contents: contents.moveSelection(by: offset)
        }
    }

    var selected: Result? {
        switch mode {
        case .names: names.selected.map(Result.file)
        case .contents: contents.selected.map(Result.line)
        }
    }

    var resultsState: ResultsState {
        if query.isBlank { return .prompt }
        switch mode {
        case .names:
            if names.loading { return .loading }
            return names.matches.isEmpty ? .empty : .matches
        case .contents:
            if contents.loading || (contents.searchedQuery != contents.query && contents.matches.isEmpty) {
                return .loading
            }
            return contents.matches.isEmpty ? .empty : .matches
        }
    }

    // What the field says on its right once there is an answer to give.
    var summary: String? {
        guard resultsState == .matches || resultsState == .empty else { return nil }
        switch mode {
        case .names: return names.matches.isEmpty ? "No files" : counted(names.matches.count, "file")
        case .contents: return contents.result.summary
        }
    }

    // Only the model on screen is searched, so typing in one mode does not run the
    // other mode's search in the background.
    private func handOver() {
        switch mode {
        case .names: names.query = query
        case .contents: contents.query = query
        }
    }
}

struct ExplorerFindDialog: View {
    @Bindable var model: ExplorerFindModel
    let open: (ExplorerFindModel.Result) -> Void
    let close: () -> Void

    @FocusState private var fieldFocused: Bool
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.mode == .names ? "Find a file" : "Find in files")
                    .font(Typography.title)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                (Text("esc").font(Font.mono(Typography.Size.micro)) + Text(" to close"))
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .arrives(after: 0.04, rising: 4)

            HStack(spacing: Space.xs) {
                ForEach(ExplorerSearchMode.allCases, id: \.self) { mode in
                    ChoicePill(title: "\(mode.title)  \(mode.keys)", selected: model.mode == mode, thumb: thumb) {
                        model.show(mode)
                        fieldFocused = true
                    }
                    .accessibilityLabel(mode.title)
                    .accessibilityHint(mode == .names ? "Shift twice" : "Control H")
                    .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
                }
            }
            .motion(Motion.control, value: model.mode)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Search by")
            .arrives(after: 0.08, rising: 4)

            field
                .arrives(after: 0.12, rising: 4)

            results
                .frame(height: 320)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.field.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.border))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                .motion(Motion.reveal, value: model.resultsState)
                .motion(Motion.reveal, value: model.mode)
                .arrives(after: 0.16, rising: 4)

            HStack(spacing: Space.lg) {
                (Text("↑ ↓").font(Font.mono(Typography.Size.micro)) + Text(" to move"))
                (Text("↩").font(Font.mono(Typography.Size.micro)) + Text(" to open"))
                Spacer(minLength: 0)
            }
            .font(Typography.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            .arrives(after: 0.2)
        }
        .padding(Space.xxl)
        .onExitCommand(perform: close)
        .task {
            fieldFocused = true
            model.prepare()
        }
        .onDisappear { model.cancel() }
    }

    private var field: some View {
        let placeholder = model.mode == .names ? "Search files" : "Find in files"
        return HStack(spacing: Space.md) {
            Image(systemName: "magnifyingglass")
                .font(Typography.label)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .focused($fieldFocused)
                .onSubmit { if let selected = model.selected { open(selected) } }
                .onMoveCommand { direction in
                    switch direction {
                    case .up: model.moveSelection(by: -1)
                    case .down: model.moveSelection(by: 1)
                    default: break
                    }
                }
                .onExitCommand(perform: close)
                .accessibilityLabel(placeholder)
            if let summary = model.summary {
                Text(summary)
                    .font(Font.mono(Typography.Size.micro))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.fadeIn)
            }
        }
        .padding(.horizontal, Space.lg)
        .frame(height: ControlHeight.lg)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(fieldFocused ? Theme.accent : Theme.border))
    }

    // MARK: - Results

    @ViewBuilder private var results: some View {
        switch model.resultsState {
        case .prompt:
            message(model.mode == .names ? "Start typing to find a file" : "Start typing to find text in files",
                    detail: model.mode == .names ? "Matches the name and the folders above it." : "Case does not matter.")
                .transition(.fadeIn)
        case .loading:
            HStack(spacing: Space.md) {
                LoopSpinner(size: 14)
                Text("Reading files...")
            }
            .font(Typography.detail)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.fadeIn)
        case .empty:
            message(model.mode == .names ? "No matching files" : "No matches for “\(model.query.trimmed)”",
                    detail: emptyDetail)
                .transition(.fadeIn)
        case .matches:
            Group {
                switch model.mode {
                case .names: nameResults
                case .contents: contentResults
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Results")
            .transition(.fadeIn)
        }
    }

    private var emptyDetail: String? {
        var notes: [String] = []
        if !model.includeHidden {
            notes.append("Hidden files are off. Turn them on in the ••• menu to search those too.")
        }
        if model.mode == .contents && model.contents.limited {
            notes.append("Some files were left out because this folder has more than 32 MB of text.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }

    private var nameResults: some View {
        let names = model.names
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Space.xxs) {
                    ForEach(Array(names.matches.enumerated()), id: \.element.path) { index, node in
                        nameRow(node, index: index).id(node.path)
                    }
                }
                .padding(Space.xs)
            }
            .onChange(of: names.selectedIndex) {
                if let path = names.selected?.path {
                    withAnimation(reduceMotion ? nil : Motion.hover) { proxy.scrollTo(path, anchor: .center) }
                }
            }
        }
    }

    private func nameRow(_ node: FileNode, index: Int) -> some View {
        let selected = model.names.selectedIndex == index
        let path = node.path.pathRelative(to: model.root) ?? node.path
        let directory = (path as NSString).deletingLastPathComponent
        // The name is marked the way a line is, so a hit reads the same in both modes.
        let name = FileTextLine(number: 0, text: node.name,
                                hits: FileFind.search(model.query.trimmed, in: node.name).matches)

        return Button {
            model.names.select(index)
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: "doc")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(name.highlighted)
                    .font(Typography.detail.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !directory.isEmpty && directory != "." {
                    Text(directory)
                        .font(Font.mono(Typography.Size.micro))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, Space.md)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Radius.inset).fill(selected ? Theme.card : .clear))
            .overlay(RoundedRectangle(cornerRadius: Radius.inset).stroke(selected ? Theme.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.inset)
        .simultaneousGesture(TapGesture(count: 2).onEnded { open(.file(node)) })
        .accessibilityLabel(directory.isEmpty || directory == "." ? node.name : "\(node.name), in \(directory)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var contentResults: some View {
        let contents = model.contents
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xxs) {
                    let starts = groupStarts
                    ForEach(Array(contents.result.files.enumerated()), id: \.element.id) { group, matches in
                        fileRow(matches)
                            .padding(.top, group == 0 ? 0 : 4)
                        // Rows are keyed by file and line, not by place in the list. The lazy
                        // stack keeps rows by key, and a place reused by the next query would
                        // show the old query's line.
                        let rows = starts[group]..<(starts[group] + matches.lines.count)
                        ForEach(Array(zip(rows, contents.matches[rows])), id: \.1.id) { index, match in
                            lineRow(match, index: index)
                        }
                    }
                    if contents.result.hasMore {
                        loadingMoreRow
                            // Keyed on the count, so a page too short to push this row
                            // out of view still asks for the one after it.
                            .task(id: contents.matches.count) { contents.loadMore() }
                    }
                    if contents.limited {
                        Text("Some files were left out because this folder has more than 32 MB of text.")
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                            .padding(Space.md)
                    }
                }
                .padding(Space.xs)
            }
            .onChange(of: contents.selectedIndex) {
                if let selected = contents.selected {
                    withAnimation(reduceMotion ? nil : Motion.hover) { proxy.scrollTo(selected.id, anchor: .center) }
                }
            }
        }
    }

    // Where each file's lines start in the flat list the selection moves through.
    private var groupStarts: [Int] {
        var next = 0
        return model.contents.result.files.map { group in
            defer { next += group.lines.count }
            return next
        }
    }

    private func fileRow(_ matches: FileTextMatches) -> some View {
        let path = matches.file.path.pathRelative(to: model.root) ?? matches.file.path
        let directory = (path as NSString).deletingLastPathComponent

        return HStack(spacing: Space.md) {
            Image(systemName: "doc")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(matches.file.name)
                .font(Typography.detail.weight(.medium))
                .lineLimit(1)
                .layoutPriority(1)
            if !directory.isEmpty && directory != "." {
                Text(directory)
                    .font(Font.mono(Typography.Size.micro))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text("\(matches.lines.count)")
                .font(Font.mono(Typography.Size.micro))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.md)
        .frame(height: 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(matches.file.name), \(counted(matches.lines.count, "match", plural: "matches"))")
        .accessibilityAddTraits(.isHeader)
    }

    private var loadingMoreRow: some View {
        HStack(spacing: Space.md) {
            LoopSpinner(size: 14)
            Text("Finding more...")
        }
        .font(Typography.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
    }

    private func lineRow(_ match: FindInFilesMatch, index: Int) -> some View {
        let selected = model.contents.selectedIndex == index
        let line = match.line

        return Button {
            model.contents.select(index)
        } label: {
            HStack(spacing: Space.md) {
                Text(verbatim: "\(line.number)")
                    .font(Font.mono(Typography.Size.micro, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 36, alignment: .trailing)
                Text(line.highlighted)
                    .font(Typography.data)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.md)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Radius.inset).fill(selected ? Theme.card : .clear))
            .overlay(RoundedRectangle(cornerRadius: Radius.inset).stroke(selected ? Theme.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.inset)
        .simultaneousGesture(TapGesture(count: 2).onEnded { open(.line(match)) })
        .accessibilityLabel("Line \(line.number) in \(match.file.name): \(line.text)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func message(_ text: String, detail: String?) -> some View {
        VStack(spacing: Space.sm) {
            Text(text)
                .font(Typography.detail)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
