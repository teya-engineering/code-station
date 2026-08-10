import AppKit
import SwiftUI

// Every file in a session's folder, as a tree with a preview beside it. Changes only
// covers what git has something to say about; this is the whole working tree, which is
// what you want when the agent names a file you have never opened.
//
// A text file can be edited in place. The tree itself stays read-only: nothing here
// creates, renames or deletes anything.
struct ExplorerView: View {
    let root: String

    @Environment(DialogPresenter.self) private var dialogs

    // Children are kept per folder rather than as a nested tree, so a folder can be read
    // the moment it is opened and the rows on screen stay a flat list.
    @State private var children: [String: [FileNode]] = [:]
    @State private var expanded: Set<String> = []
    @State private var loadingFolders: Set<String> = []
    @State private var selected: FileNode?
    @State private var preview: FilePreview?
    @State private var loadingPreview = false
    @State private var showHidden = true
    @State private var textWidth: CGFloat = 0

    // Editing keeps the text as loaded next to the draft, so "anything to save" and
    // "anything to lose" are both one comparison.
    @State private var editing = false
    @State private var draft = ""
    @State private var original = ""
    @State private var saving = false

    @State private var findPresented = false
    @State private var findQuery = ""
    @State private var findResult = FileFindResult()
    @State private var findSelection = 0
    @FocusState private var findFocused: Bool

    private var rootURL: URL { URL(fileURLWithPath: root) }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                tree
                Divider().overlay(Theme.hairline)
                detail
            }
        }
        .background(Theme.background)
        .background(findShortcut)
        .onChange(of: findQuery) { refreshFind() }
        .task(id: root) { await openRoot() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 12))
                Text(rootURL.lastPathComponent).font(.mono(13, .medium))
            }

            if let count = children[root]?.count {
                Text("\(count) item\(count == 1 ? "" : "s")")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Hidden files", isOn: $showHidden)
                .toggleStyle(.appCheckbox)
                .font(.system(size: 12))
                .onChange(of: showHidden) { Task { await reopenFolders() } }

            Button {
                Task { await reopenFolders() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .help("Refresh")
        }
        .padding(.horizontal, 20)
        .headerBand(height: Theme.subHeaderHeight)
    }

    // MARK: - Tree

    // One visible row: the entry and how deep it sits. Folders that are shut contribute
    // nothing, so this is only ever as long as what is actually open.
    private struct Row: Identifiable {
        let node: FileNode
        let depth: Int
        var id: String { node.path }
    }

    private var rows: [Row] {
        var out: [Row] = []
        func walk(_ path: String, depth: Int) {
            for node in children[path] ?? [] {
                out.append(Row(node: node, depth: depth))
                if node.isDirectory && expanded.contains(node.path) {
                    walk(node.path, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        return out
    }

    @ViewBuilder private var tree: some View {
        VStack(spacing: 0) {
            if children[root]?.isEmpty == true {
                PaneMessage(icon: "folder", title: "Empty folder",
                            detail: showHidden ? "" : "Hidden files are off.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(rows) { row in
                            treeRow(row)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(width: 300)
    }

    private func treeRow(_ row: Row) -> some View {
        let node = row.node
        let isOpen = expanded.contains(node.path)
        let isSelected = selected?.path == node.path

        return Button {
            if node.isDirectory { toggle(node) } else { requestSelect(node) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 10)
                    .opacity(node.isDirectory ? 1 : 0)

                if loadingFolders.contains(node.path) {
                    ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 14)
                } else {
                    Image(systemName: icon(node))
                        .font(.system(size: 11))
                        .foregroundStyle(node.isDirectory ? Theme.accent : .secondary)
                        .frame(width: 14)
                }

                Text(node.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                if !node.isDirectory {
                    Text(node.size.formatted(.byteCount(style: .file)))
                        .font(.mono(10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 3)
            .padding(.trailing, 8)
            .padding(.leading, CGFloat(row.depth) * 13 + 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Theme.card : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Theme.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appContextMenu {
            [.item("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) },
             .item("Open with default app") { NSWorkspace.shared.open(node.url) },
             .item("Copy Path") {
                 NSPasteboard.general.clearContents()
                 NSPasteboard.general.setString(node.path, forType: .string)
             }]
        }
    }

    private func icon(_ node: FileNode) -> String {
        if node.isDirectory { return expanded.contains(node.path) ? "folder.fill" : "folder" }
        if FileTree.imageKinds.contains(node.kind) { return "photo" }
        return switch node.kind {
        case "swift", "kt", "java", "rs", "go", "py", "rb", "js", "ts", "c", "h", "cpp": "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "toml", "xml", "plist", "lock": "curlybraces"
        case "md", "markdown", "txt", "rtf": "doc.text"
        case "sh", "zsh", "bash", "fish": "terminal"
        case "pdf": "doc.richtext"
        case "zip", "gz", "tar", "jar": "shippingbox"
        default: "doc"
        }
    }

    // MARK: - Preview

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let node = selected {
                HStack(spacing: 10) {
                    Text(node.name).font(.serif(15, .semibold)).lineLimit(1)
                    Text(relativePath(node))
                        .font(.mono(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    if loadingPreview || saving { ProgressView().controlSize(.small) }
                    if editing {
                        editButtons(node)
                    } else {
                        if canEdit {
                            Button("Edit") { beginEdit(node) }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        Button("Open") { NSWorkspace.shared.open(node.url) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([node.url])
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                if findPresented {
                    findBar
                }

                if editing {
                    editor
                } else {
                    previewBody(node)
                }
            } else {
                PaneMessage(icon: "sidebar.left", title: "Pick a file",
                            detail: "Its contents show up here. Folders open in place.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card)
    }

    @ViewBuilder private func previewBody(_ node: FileNode) -> some View {
        switch preview {
        case .text(let lines, let truncated, let total):
            fileText(lines)
            if truncated {
                Text("Showing the first \(lines.count) lines of \(total). Open the file to see the rest.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.field)
            }
        case .image(let data):
            if let image = NSImage(data: data) {
                VStack(spacing: 10) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                    Text("\(Int(image.size.width)) × \(Int(image.size.height)) · \(node.size.formatted(.byteCount(style: .file)))")
                        .font(.mono(11))
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PaneMessage(icon: "photo", title: "Cannot draw this image",
                            detail: node.size.formatted(.byteCount(style: .file)))
            }
        case .binary(let size):
            PaneMessage(icon: "doc.zipper", title: "Binary file",
                        detail: "\(size.formatted(.byteCount(style: .file))) of data this app cannot show as text.")
        case .tooLarge(let size):
            PaneMessage(icon: "doc.badge.ellipsis", title: "Too big to preview",
                        detail: "\(size.formatted(.byteCount(style: .file))). Open it in an editor instead.")
        case .empty:
            PaneMessage(icon: "doc", title: "Empty file", detail: "0 bytes.")
        case .unreadable(let reason):
            PaneMessage(icon: "exclamationmark.triangle", title: "Could not read this file",
                        detail: reason)
        case nil:
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Editing

    // Only what already previews as text can be edited. Images, binaries and files past
    // the size limit stay look-but-do-not-touch, and an empty file counts as text.
    private var canEdit: Bool {
        switch preview {
        case .text, .empty: true
        default: false
        }
    }

    private var dirty: Bool { draft != original }

    // MARK: - Find

    private var previewLines: [String]? {
        guard case .text(let lines, _, _) = preview else { return nil }
        return lines
    }

    private var currentFindMatch: FileFindMatch? {
        guard findResult.matches.indices.contains(findSelection) else { return nil }
        return findResult.matches[findSelection]
    }

    private var findShortcut: some View {
        Button("") { showFind() }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .control)
            .opacity(0)
            .disabled(previewLines == nil || editing)
            .accessibilityHidden(true)
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Find in file", text: $findQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($findFocused)
                    .onSubmit { moveFind(by: 1) }
                    .onExitCommand(perform: closeFind)
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 90, idealWidth: 260, maxWidth: 260)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))

            Text(findSummary)
                .font(.mono(10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 55, idealWidth: 82, alignment: .trailing)

            findButton("chevron.up", help: "Previous match", disabled: findResult.matches.isEmpty) {
                moveFind(by: -1)
            }
            findButton("chevron.down", help: "Next match", disabled: findResult.matches.isEmpty) {
                moveFind(by: 1)
            }
            findButton("xmark", help: "Close find") { closeFind() }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .onAppear { findFocused = true }
    }

    private var findSummary: String {
        guard !findQuery.isEmpty else { return "" }
        guard !findResult.matches.isEmpty else { return "No matches" }
        let total = "\(findResult.matches.count)\(findResult.hasMore ? "+" : "")"
        return "\(findSelection + 1) of \(total)"
    }

    private func findButton(_ systemName: String, help: String, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.accent.opacity(disabled ? 0.3 : 1))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func showFind() {
        findPresented = true
        refreshFind()
        findFocused = true
    }

    private func closeFind() {
        findPresented = false
        findFocused = false
    }

    private func refreshFind() {
        guard let previewLines else {
            findResult = FileFindResult()
            findSelection = 0
            return
        }
        findResult = FileFind.search(findQuery, in: previewLines)
        findSelection = 0
    }

    private func moveFind(by offset: Int) {
        let count = findResult.matches.count
        guard count > 0 else { return }
        findSelection = (findSelection + offset + count) % count
    }

    private func resetFind() {
        findPresented = false
        findFocused = false
        findQuery = ""
        findResult = FileFindResult()
        findSelection = 0
    }

    private func editButtons(_ node: FileNode) -> some View {
        HStack(spacing: 8) {
            Button { cancelEdit() } label: {
                Text("Cancel")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.card))
                    .overlay(Capsule().stroke(Theme.border))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Button { save(node) } label: {
                Text("Save")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.accentFill))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!dirty || saving)
            .opacity(dirty ? 1 : 0.4)
        }
    }

    // The field background marks the pane as writable, the way every other input in the
    // app sits on a field.
    private var editor: some View {
        TextEditor(text: $draft)
            .font(.mono(11))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(Theme.field)
    }

    // Line numbers and text are two columns of one monospaced font, so the rows line up
    // without measuring anything per line. Both scroll together, the gutter included:
    // pinning it would cost a second scroll view kept in step with this one.
    private func fileText(_ lines: [String]) -> some View {
        let gutter = MonoMetrics.width(of: "\(lines.count)") + 8
        let shownMatches = findPresented ? findResult.matches : []
        let content = chunks(lines, matches: shownMatches)
        return GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(content) { chunk in
                            HStack(alignment: .top, spacing: 12) {
                                Text(chunk.numbers)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: gutter, alignment: .trailing)
                                Text(highlightedText(chunk))
                                    .textSelection(.enabled)
                                    .frame(width: max(textWidth, geometry.size.width - gutter - 36),
                                           alignment: .leading)
                            }
                            .font(.mono(11))
                            .id(chunk.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    // A scroll view centres content that does not fill it, so a short file would
                    // float in the middle of the pane. Growing to the full height pins it to the top.
                    .frame(minHeight: geometry.size.height, alignment: .topLeading)
                }
                .onChange(of: currentFindMatch) { _, match in
                    guard findPresented, let match else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        scroll.scrollTo(match.line, anchor: .center)
                    }
                }
            }
        }
    }

    // Runs of lines drawn as one Text each. A file is far too many views one line at a
    // time, and a single Text holding all of it lays the whole file out before the first
    // screen of it appears.
    private struct Chunk: Identifiable {
        let id: Int
        let numbers: String
        let text: String
        let matches: [ChunkMatch]
    }

    private struct ChunkMatch {
        let resultIndex: Int
        let range: NSRange
    }

    // Matching lines stand alone so navigation can scroll to the exact line. Everything
    // else stays in larger chunks, preserving the preview's low view count.
    private func chunks(_ lines: [String], matches: [FileFindMatch], size: Int = 100) -> [Chunk] {
        let matchesByLine = Dictionary(grouping: matches.indices) { matches[$0].line }
        let matchingLines = matchesByLine.keys.sorted()
        var matchingLineIndex = 0
        var start = 0
        var result: [Chunk] = []

        while start < lines.count {
            let isMatchingLine = matchingLineIndex < matchingLines.count
                && matchingLines[matchingLineIndex] == start
            let end: Int
            let chunkMatches: [ChunkMatch]
            if isMatchingLine {
                end = start + 1
                chunkMatches = (matchesByLine[start] ?? []).map { index in
                    let match = matches[index]
                    return ChunkMatch(resultIndex: index,
                                      range: NSRange(location: match.location, length: match.length))
                }
                matchingLineIndex += 1
            } else {
                let nextMatch = matchingLineIndex < matchingLines.count
                    ? matchingLines[matchingLineIndex]
                    : lines.count
                end = min(start + size, nextMatch)
                chunkMatches = []
            }

            result.append(Chunk(
                id: start,
                numbers: (start..<end).map { "\($0 + 1)" }.joined(separator: "\n"),
                text: lines[start..<end].joined(separator: "\n"),
                matches: chunkMatches))
            start = end
        }
        return result
    }

    private func highlightedText(_ chunk: Chunk) -> AttributedString {
        guard !chunk.matches.isEmpty else { return AttributedString(chunk.text) }
        let text = NSMutableAttributedString(string: chunk.text)
        let ordinary = NSColor(Theme.secret).withAlphaComponent(0.24)
        let selected = NSColor(Theme.secret).withAlphaComponent(0.52)
        for match in chunk.matches {
            text.addAttribute(.backgroundColor,
                              value: match.resultIndex == findSelection ? selected : ordinary,
                              range: match.range)
        }
        return AttributedString(text)
    }

    private func relativePath(_ node: FileNode) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return node.path.hasPrefix(prefix) ? String(node.path.dropFirst(prefix.count)) : node.path
    }

    // MARK: - Actions

    // The pane is reused as the session changes, so everything the last folder left behind
    // has to go before the new one is read.
    private func openRoot() async {
        children = [:]
        expanded = []
        selected = nil
        preview = nil
        editing = false
        draft = ""
        original = ""
        resetFind()
        await load(root)
    }

    private func load(_ path: String) async {
        loadingFolders.insert(path)
        let nodes = await FileTree.children(of: URL(fileURLWithPath: path), includeHidden: showHidden)
        loadingFolders.remove(path)
        guard !Task.isCancelled else { return }
        children[path] = nodes
    }

    // Everything already open is read again. Anything still shut is left alone: it will be
    // read when it is opened, which is late enough to pick the change up anyway.
    private func reopenFolders() async {
        for path in ([root] + expanded) where children[path] != nil {
            await load(path)
        }
    }

    private func toggle(_ node: FileNode) {
        if expanded.contains(node.path) {
            expanded.remove(node.path)
        } else {
            expanded.insert(node.path)
            if children[node.path] == nil { Task { await load(node.path) } }
        }
    }

    // Moving to another file throws the draft away, so a dirty one is worth a question
    // first. A clean draft just moves, and a click on the file already being edited
    // leaves the editor alone.
    private func requestSelect(_ node: FileNode) {
        if editing && node.path == selected?.path { return }
        guard editing, dirty else {
            editing = false
            select(node)
            return
        }
        dialogs.show(Dialog(
            title: "Discard changes?",
            message: "Edits to \(selected?.name ?? "this file") have not been saved.",
            actions: [
                .init(label: "Discard", kind: .destructive) {
                    editing = false
                    select(node)
                },
                .init(label: "Keep editing", kind: .cancel)
            ]))
    }

    private func beginEdit(_ node: FileNode) {
        resetFind()
        Task {
            loadingPreview = true
            let text = await FileTree.fullText(of: node.url)
            loadingPreview = false
            guard selected?.path == node.path else { return }
            guard let text else {
                dialogs.show(Dialog(
                    title: "Could not open for editing",
                    message: "The file could not be read as text.",
                    actions: [.init(label: "OK", kind: .cancel)]))
                return
            }
            original = text
            draft = text
            editing = true
        }
    }

    private func cancelEdit() {
        guard dirty else { editing = false; return }
        dialogs.show(Dialog(
            title: "Discard changes?",
            message: "Edits to \(selected?.name ?? "this file") have not been saved.",
            actions: [
                .init(label: "Discard", kind: .destructive) { editing = false },
                .init(label: "Keep editing", kind: .cancel)
            ]))
    }

    private func save(_ node: FileNode) {
        Task {
            saving = true
            let failure = await FileTree.write(draft, to: node.url)
            saving = false
            if let failure {
                dialogs.show(Dialog(
                    title: "Could not save",
                    message: failure,
                    actions: [.init(label: "OK", kind: .cancel)]))
            } else {
                editing = false
                select(node)
                await reopenFolders()
            }
        }
    }

    private func select(_ node: FileNode) {
        resetFind()
        selected = node
        preview = nil
        textWidth = 0
        Task {
            loadingPreview = true
            let loaded = await FileTree.preview(of: node.url)
            loadingPreview = false
            guard !Task.isCancelled, selected?.path == node.path else { return }
            preview = loaded
            if case .text(let lines, _, _) = loaded {
                textWidth = MonoMetrics.width(ofLongestIn: lines) + 24
            }
        }
    }
}

// Monospaced text is as wide as its longest line, so one measurement sizes a whole file
// without laying any of it out first.
enum MonoMetrics {
    static func width(of text: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func width(ofLongestIn lines: [String]) -> CGFloat {
        guard let longest = lines.max(by: { $0.count < $1.count }) else { return 0 }
        return width(of: longest)
    }
}
