import AppKit
import SwiftUI

// Every file in a session's folder, as a tree with the file itself beside it. Changes only
// covers what git has something to say about; this is the whole working tree, which is
// what you want when the agent names a file you have never opened.
//
// A text file opens straight into an editor: there is no read mode to leave first, and
// nothing is written until Save. The tree itself can create, copy, paste, rename, drag to
// move and move items to the Trash.
// Says that a file being read has taken Cmd+F. It travels up to the window so the sidebar
// can stop naming that stroke as the way into its own filter while the file answers for it.
struct FileFindShortcutKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

// A file another pane wants shown, with the line to land on when it names one.
struct ExplorerReveal: Equatable {
    let path: String
    let line: Int?
}

struct ExplorerView: View {
    let root: String
    // Taken and cleared once the file is shown, so coming back to the pane later
    // finds it where it was left rather than back on this file.
    var reveal: Binding<ExplorerReveal?> = .constant(nil)

    @Environment(DialogPresenter.self) private var dialogs
    @Environment(ExplorerMemory.self) private var memory

    // Children are kept per folder rather than as a nested tree, so a folder can be read
    // the moment it is opened and the rows on screen stay a flat list.
    @State private var children: [String: [FileNode]] = [:]
    @State private var expanded: Set<String> = []
    @State private var loadingFolders: Set<String> = []
    @State private var selected: FileNode?
    // The line the open file should scroll to, when it was opened from a link to one.
    @State private var lineToReveal: Int?
    @State private var preview: FilePreview?
    @State private var loadingPreview = false
    @State private var renderingMarkdown = false
    @State private var showHidden = true
    @State private var language: CodeLanguage?
    @State private var pastingFiles = false
    @State private var treeWidth = ExplorerSplitLayout.defaultTreeWidth
    @State private var dragStartTreeWidth: CGFloat?
    @FocusState private var treeFocused: Bool
    // The row being renamed, by path. The name is edited in place, the way Finder does it.
    @State private var renaming: String?
    @State private var renameDraft = ""
    @State private var renameSelection: TextSelection?
    @State private var renameCancelled = false
    @FocusState private var renameFocused: Bool
    // What a drag is over, and the folder a drop there would land in. A file row hands the
    // drop to the folder it sits in, so that folder is what lights up.
    @State private var dropHover: DropHover?
    // The folder the pane holds now. It trails `root` for a moment when the session
    // changes, which is what lets the old folder be remembered before the new one opens.
    @State private var openedRoot: String?

    // The text as loaded sits next to the draft, so "anything to save" and "anything to
    // lose" are both one comparison.
    @State private var draft = ""
    @State private var original = ""
    @State private var saving = false
    // When the file was last written at the moment it was read. An agent works in the same
    // folder, so a pane left open on a file it has since rewritten would save over it.
    @State private var loadedAt: Date?

    @State private var findPresented = false
    // Both of the strokes a person tries for find. Cmd+F searches whatever is being read
    // on a Mac, and with a file open that is the file rather than the sidebar's filter.
    // They are caught with monitors because a SwiftUI shortcut is only offered the stroke
    // after the window's own shortcuts have had it, and the sidebar's filter takes Cmd+F.
    @State private var findMonitor = WindowKeyMonitor(.control, "f")
    @State private var commandFindMonitor = WindowKeyMonitor(.command, "f")
    @State private var findQuery = ""
    @State private var findResult = FileFindResult()
    @State private var findSelection = 0
    @FocusState private var findFocused: Bool

    private var rootURL: URL { URL(fileURLWithPath: root) }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                let width = ExplorerSplitLayout.treeWidth(
                    treeWidth, availableWidth: geometry.size.width)

                HStack(spacing: 0) {
                    tree
                        .frame(width: width)
                        .clipped()
                    Rectangle().fill(Theme.hairline)
                        .frame(width: ExplorerSplitLayout.dividerWidth)
                    detail
                        .frame(width: max(0, geometry.size.width - width
                                          - ExplorerSplitLayout.dividerWidth))
                        .clipped()
                }
                .overlay(alignment: .leading) {
                    splitHandle(treeWidth: width, availableWidth: geometry.size.width)
                        .offset(x: width + (ExplorerSplitLayout.dividerWidth
                                           - ExplorerSplitLayout.handleWidth) / 2)
                }
            }
        }
        .background(Theme.background)
        .background(ExplorerSearchShortcut { showFileSearch() })
        .background(ExplorerFileShortcuts(
            enabled: treeFocused && dialogs.current == nil && !pastingFiles,
            onCopy: copySelected,
            onPaste: { pasteFiles(at: selected) },
            onTrash: trashSelected,
            onRename: renameSelected))
        .background(WindowAnchor(monitor: findMonitor))
        .background(WindowAnchor(monitor: commandFindMonitor))
        .preference(key: FileFindShortcutKey.self, value: canFind)
        .onChange(of: canFind, initial: true) { _, canFind in
            for monitor in findMonitors {
                guard canFind else { monitor.stop(); continue }
                monitor.start {
                    showFind()
                    return true
                }
            }
        }
        .onDisappear {
            findMonitors.forEach { $0.stop() }
            rememberPlace()
        }
        .onChange(of: findQuery) {
            findSelection = 0
            refreshFind()
        }
        // Typing moves every match after the caret, so the results are only right for the
        // text as it stands now.
        .onChange(of: draft) { if findPresented { refreshFind() } }
        .task(id: root) { await openRoot() }
        .onChange(of: reveal.wrappedValue) {
            if openedRoot == root { Task { await showRequestedFile() } }
        }
    }

    private func splitHandle(treeWidth: CGFloat, availableWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: ExplorerSplitLayout.handleWidth)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartTreeWidth ?? treeWidth
                        dragStartTreeWidth = start
                        self.treeWidth = ExplorerSplitLayout.treeWidth(
                            start + value.translation.width, availableWidth: availableWidth)
                    }
                    .onEnded { _ in dragStartTreeWidth = nil })
            .cursorOnHover(.resizeLeftRight)
            .appTooltip("Drag to resize")
            .accessibilityElement()
            .accessibilityLabel("Resize file explorer")
            .accessibilityValue("\(Int(treeWidth)) points wide")
            .accessibilityAdjustableAction { direction in
                let change: CGFloat = switch direction {
                case .increment: 32
                case .decrement: -32
                @unknown default: 0
                }
                self.treeWidth = ExplorerSplitLayout.treeWidth(
                    treeWidth + change, availableWidth: availableWidth)
            }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 12))
                Text(rootURL.lastPathComponent).font(.mono(13, .medium))
            }

            if let count = children[root]?.count {
                Text(counted(count, "item"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Hidden files", isOn: $showHidden)
                .toggleStyle(.appCheckbox)
                .font(.system(size: 12))
                .onChange(of: showHidden) { Task { await reopenFolders() } }

            headerIcon("doc.badge.plus", tooltip: "New file") {
                create(folder: false, in: newItemDestination())
            }
            headerIcon("folder.badge.plus", tooltip: "New folder") {
                create(folder: true, in: newItemDestination())
            }

            Button {
                Task { await reopenFolders() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .hoverLift(amount: Motion.smallLift)
            .foregroundStyle(Theme.accent)
            .appTooltip("Refresh")
        }
        .padding(.horizontal, 20)
        .headerBand(height: Theme.subHeaderHeight)
    }

    private func headerIcon(_ symbol: String, tooltip: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift(amount: Motion.smallLift)
        .foregroundStyle(Theme.accent)
        .appTooltip(tooltip)
    }

    // MARK: - Tree

    // One visible row: the entry and how deep it sits. Folders that are shut contribute
    // nothing, so this is only ever as long as what is actually open.
    private struct DropHover: Equatable {
        let key: String
        let folder: String
    }

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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(rows) { row in
                                treeRow(row)
                                    .id(row.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: selected?.path) {
                        if let path = selected?.path {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(path, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if dropHover?.folder == root {
                RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.65), lineWidth: 1.5)
                    .padding(2)
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            drop(urls, into: rootURL)
        } isTargeted: { hoverDrop(key: root, folder: root, $0) }
        .focusable()
        .focused($treeFocused)
        .focusEffectDisabled()
        .onMoveCommand(perform: moveTreeSelection)
    }

    @ViewBuilder private func treeRow(_ row: Row) -> some View {
        if renaming == row.node.path {
            renameRow(row)
        } else {
            plainRow(row)
        }
    }

    private func plainRow(_ row: Row) -> some View {
        let node = row.node
        let isOpen = expanded.contains(node.path)
        let isSelected = selected?.path == node.path
        let isDropTarget = dropHover?.folder == node.path
        let folder = node.isDirectory ? node.url : node.url.deletingLastPathComponent()

        return Button {
            treeFocused = true
            requestSelect(node)
            if node.isDirectory { toggle(node) }
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
            .surface(isDropTarget ? Theme.accent.opacity(0.12) : (isSelected ? Theme.card : .clear),
                     cornerRadius: 6,
                     border: isDropTarget ? Theme.accent.opacity(0.65)
                         : (isSelected ? Theme.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 6)
        .draggable(node.url)
        .dropDestination(for: URL.self) { urls, _ in
            drop(urls, into: folder)
        } isTargeted: { hoverDrop(key: node.path, folder: folder.path, $0) }
        .appContextMenu {
            // Paste is only offered when the clipboard holds files, since the menu has no
            // way to show an item that is there but cannot be used.
            let paste: [MenuEntry] = Pasteboard.fileURLs().isEmpty || pastingFiles
                ? []
                : [.item("Paste", detail: "⌘V", action: { _ = pasteFiles(at: node) })]
            return [.item("New File") { create(folder: false, in: folder) },
                    .item("New Folder") { create(folder: true, in: folder) },
                    .separator,
                    .item("Copy", detail: "⌘C", action: { copy(node) })]
                + paste
                + [.item("Copy Path") { Pasteboard.copy(node.path) },
                   .separator,
                   .item("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) },
                   .item("Open with default app") { NSWorkspace.shared.open(node.url) },
                   .separator,
                   .item("Rename…", detail: "↩", action: { startRename(node) }),
                   .item("Move to Trash", kind: .destructive, detail: "⌘⌫",
                         action: { confirmTrash(node) })]
        }
    }

    // The same row with a field where the name was. Clicking away keeps the new name, the
    // way Finder does, and Escape is the only way to throw it away.
    private func renameRow(_ row: Row) -> some View {
        let node = row.node
        return HStack(spacing: 5) {
            Color.clear.frame(width: 10)
            Image(systemName: icon(node))
                .font(.system(size: 11))
                .foregroundStyle(node.isDirectory ? Theme.accent : .secondary)
                .frame(width: 14)
            TextField("Name", text: $renameDraft, selection: $renameSelection)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .fieldSurface(cornerRadius: 4)
                .focused($renameFocused)
                .onSubmit { commitRename(node) }
                .onExitCommand {
                    renameCancelled = true
                    endRename()
                }
                .onAppear { focusRenameField(node) }
                .onChange(of: renameFocused) { _, focused in
                    guard !focused, renaming == node.path, !renameCancelled else { return }
                    commitRename(node)
                }
        }
        .padding(.vertical, 2)
        .padding(.trailing, 8)
        .padding(.leading, CGFloat(row.depth) * 13 + 6)
    }

    private func icon(_ node: FileNode) -> String {
        // A link is drawn as a link whatever sits on the other end. What it points at is
        // spelled out in the header once it is picked, which is where there is room for it.
        if node.isLink { return "arrow.turn.down.right" }
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

    // MARK: - The file

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
                    if let destination = node.linkDestination {
                        Text("→ \(destination)")
                            .font(.mono(11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .appTooltip("Opening or saving this file goes to \(destination)")
                    }
                    Spacer()
                    if loadingPreview || saving { ProgressView().controlSize(.small) }
                    if dirty { saveButtons(node) }
                    if isEditable && !renderingMarkdown {
                        InlineLink(title: "Find", action: showFind)
                            .appTooltip("Find in file (Cmd+F or Ctrl+F)")
                    }
                    if node.supportsMarkdownPreview {
                        InlineLink(title: renderingMarkdown ? "Edit" : "Preview") {
                            resetFind()
                            renderingMarkdown.toggle()
                        }
                    }
                    InlineLink(title: "Open") { NSWorkspace.shared.open(node.url) }
                    InlineLink(title: "Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([node.url])
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                if findPresented {
                    findBar
                }

                fileBody(node)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Pick a file").font(.serif(17, .semibold))
                    HStack(spacing: 6) {
                        Image(systemName: "shift")
                            .font(.system(size: 12, weight: .medium))
                        Text("Tap shift key twice to search")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card)
    }

    @ViewBuilder private func fileBody(_ node: FileNode) -> some View {
        switch preview {
        case .text, .empty:
            if renderingMarkdown, node.supportsMarkdownPreview {
                ScrollView {
                    MarkdownDocumentView(text: draft,
                                         basePath: node.url.deletingLastPathComponent().path,
                                         textScale: 1)
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Theme.background)
            } else {
                CodeEditorView(documentID: node.path,
                               text: $draft,
                               language: language,
                               matches: findPresented ? findResult.matches : [],
                               currentMatch: findPresented ? currentFindMatch : nil,
                               findQuery: findQuery,
                               revealLine: lineToReveal,
                               onFind: showFind)
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
            PaneMessage(icon: "doc.badge.ellipsis", title: "Too big to open",
                        detail: "\(size.formatted(.byteCount(style: .file))). Open it in an editor instead.")
        case .unreadable(let reason):
            PaneMessage(icon: "exclamationmark.triangle",
                        title: node.isLink ? "Could not follow this link" : "Could not read this file",
                        detail: reason)
        case nil:
            if node.isDirectory {
                PaneMessage(icon: "folder", title: "Folder selected",
                            detail: "Use the left and right arrow keys to close and open folders.")
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Editing

    // Only what reads as text can be typed into. Images, binaries and files past the size
    // limit stay look-but-do-not-touch, and an empty file counts as text.
    private var isEditable: Bool {
        switch preview {
        case .text, .empty: true
        default: false
        }
    }

    private var dirty: Bool { isEditable && draft != original }

    // MARK: - Find

    private var currentFindMatch: Int? {
        findResult.matches.indices.contains(findSelection) ? findSelection : nil
    }

    private var findBar: some View {
        FindBar(placeholder: "Find in file",
                query: $findQuery,
                summary: FindSummary.text(query: findQuery,
                                          matchCount: findResult.matches.count,
                                          hasMore: findResult.hasMore,
                                          selection: findSelection),
                hasMatches: !findResult.matches.isEmpty,
                focused: $findFocused,
                move: { moveFind(by: $0) },
                close: closeFind)
    }

    // A file worth searching is open and nothing is in front of it. While this is false
    // both strokes are left alone, so Cmd+F still opens the sidebar's filter.
    private var canFind: Bool {
        isEditable && !renderingMarkdown && dialogs.current == nil
    }

    private var findMonitors: [WindowKeyMonitor] { [findMonitor, commandFindMonitor] }

    private func showFind() {
        guard canFind else { return }
        findPresented = true
        refreshFind()
        findFocused = true
    }

    private func closeFind() {
        findPresented = false
        findFocused = false
    }

    private func refreshFind() {
        findResult = FileFind.search(findQuery, in: draft)
        // The selection is kept rather than reset: typing shifts the matches around it,
        // and being thrown back to the first one on every keystroke reads as a bug.
        findSelection = min(findSelection, max(0, findResult.matches.count - 1))
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

    // MARK: - File search

    private func showFileSearch() {
        guard dialogs.current == nil else { return }
        let model = ExplorerSearchModel(root: root, includeHidden: showHidden)
        let open: (FileNode) -> Void = { node in
            dialogs.dismiss()
            revealAndSelect(node)
        }
        dialogs.show(Dialog(
            title: "Search files",
            content: AnyView(ExplorerSearchDialog(model: model, onOpen: open)),
            actions: [
                .init(label: "Open", kind: .primary, handler: {
                    if let node = model.selected { revealAndSelect(node) }
                }, isEnabled: { model.selected != nil }),
                .init(label: "Cancel", kind: .cancel)
            ],
            width: 560))
    }

    private func revealAndSelect(_ node: FileNode) {
        Task {
            for path in FileTree.ancestorDirectories(of: node.url, beneath: rootURL) {
                expanded.insert(path)
                if children[path] == nil { await load(path) }
            }
            requestSelect(node)
            treeFocused = true
        }
    }

    // Save only appears once there is something to save, which is also the only time the
    // pane holds anything that could be lost.
    private func saveButtons(_ node: FileNode) -> some View {
        HStack(spacing: 8) {
            ActionButton(title: "Revert", tone: .outlined, height: 26, size: 12) { revert() }
            ActionButton(title: "Save", tone: .green, height: 26, size: 12,
                         keyboardShortcut: KeyboardShortcut("s", modifiers: .command)) {
                save(node)
            }
            .disabled(saving)
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private func relativePath(_ node: FileNode) -> String {
        node.path.pathRelative(to: root) ?? node.path
    }

    private func copySelected() -> Bool {
        guard let selected else { return false }
        copy(selected)
        return true
    }

    private func copy(_ node: FileNode) {
        Pasteboard.copy(node.url)
    }

    // Into the given item when it is a folder, beside it when it is a file, and at the top
    // with nothing given.
    private func pasteFiles(at node: FileNode?) -> Bool {
        let sources = Pasteboard.fileURLs()
        guard !sources.isEmpty else { return false }

        let destination = pasteDestination(for: sources, at: node)
        let rootAtStart = root
        pastingFiles = true
        Task {
            let result = await FileTree.copy(sources, into: destination)
            pastingFiles = false
            guard root == rootAtStart else { return }

            if !result.copied.isEmpty {
                if destination.path != root { expanded.insert(destination.path) }
                await load(destination.path)
            }
            guard !result.failures.isEmpty else { return }
            dialogs.show(.notice(
                result.failures.count == 1 ? "Could not paste the item" : "Could not paste some items",
                message: result.failures.map { "\($0.name): \($0.message)" }.joined(separator: "\n")))
        }
        return true
    }

    private func trashSelected() -> Bool {
        guard let selected else { return false }
        confirmTrash(selected)
        return true
    }

    private func confirmTrash(_ node: FileNode) {
        let losesEdits = dirty && selected.map { contains(node, $0.path) } == true
        var rows: [Dialog.Impact.Row] = []
        if losesEdits {
            rows.append(.init(title: "Unsaved edits",
                              detail: "Edits to \(selected?.name ?? "the open file") are lost."))
        }
        rows.append(.init(title: node.isDirectory ? "Folder can be restored" : "File can be restored",
                          detail: "Put it back from the Trash in Finder.", kept: true))
        dialogs.show(.impact("Move \(node.name) to the Trash?", rows: rows,
                             action: "Move to Trash") { trash(node) })
    }

    private func trash(_ node: FileNode) {
        let rootAtStart = root
        Task {
            if let failure = await FileTree.trash(node.url) {
                dialogs.show(.notice("Could not move \(node.name) to the Trash", message: failure))
                return
            }
            guard root == rootAtStart else { return }

            expanded = expanded.filter { !contains(node, $0) }
            children = children.filter { !contains(node, $0.key) }
            if let selected, contains(node, selected.path) {
                resetFind()
                self.selected = nil
                preview = nil
                loadingPreview = false
                renderingMarkdown = false
                language = nil
                draft = ""
                original = ""
                loadedAt = nil
            }
            await load(node.url.deletingLastPathComponent().path)
        }
    }

    // Next to what is selected: inside it when it is a folder, beside it when it is a file.
    private func newItemDestination() -> URL {
        guard let selected else { return rootURL }
        return selected.isDirectory ? selected.url : selected.url.deletingLastPathComponent()
    }

    private func create(folder: Bool, in directory: URL) {
        let rootAtStart = root
        Task {
            switch await FileTree.create(folder: folder, in: directory) {
            case .failed(let failure):
                dialogs.show(.notice(folder ? "Could not create a folder" : "Could not create a file",
                                     message: failure))
            case .created(let url):
                guard root == rootAtStart else { return }
                for path in FileTree.ancestorDirectories(of: url, beneath: rootURL) {
                    expanded.insert(path)
                    if children[path] == nil { await load(path) }
                }
                await load(directory.path)
                guard let node = children[directory.path]?.first(where: { $0.path == url.path })
                else { return }
                // A new file opens at once, ready to type into. With unsaved edits in the
                // pane it is only named, so the edits are not put at risk.
                if !dirty { select(node) }
                startRename(node)
            }
        }
    }

    private func renameSelected() -> Bool {
        guard let selected else { return false }
        startRename(selected)
        return true
    }

    // The name is picked without its extension, so typing replaces just the part people
    // usually mean to change.
    private func startRename(_ node: FileNode) {
        renameDraft = node.name
        renameCancelled = false
        renaming = node.path
    }

    // Focus selects the whole field, so the shorter selection is set after it lands.
    private func focusRenameField(_ node: FileNode) {
        renameFocused = true
        let stem = node.isDirectory ? node.name : (node.name as NSString).deletingPathExtension
        let end = stem.isEmpty ? node.name.endIndex : node.name.index(
            node.name.startIndex, offsetBy: stem.count)
        DispatchQueue.main.async {
            renameSelection = TextSelection(range: node.name.startIndex..<end)
        }
    }

    private func endRename() {
        renaming = nil
        renameFocused = false
        treeFocused = true
    }

    private func commitRename(_ node: FileNode) {
        let name = renameDraft
        endRename()
        let rootAtStart = root
        Task {
            switch await FileTree.rename(node.url, to: name) {
            case .unchanged:
                return
            case .failed(let failure):
                dialogs.show(.notice("Could not rename \(node.name)", message: failure))
            case .renamed(let url):
                guard root == rootAtStart else { return }
                await moved(from: node.path, to: url)
            }
        }
    }

    // Everything the pane knows by path follows the item to its new name, so open folders
    // stay open and an open file keeps its unsaved edits.
    private func moved(from old: String, to url: URL) async {
        let new = url.path
        expanded = Set(expanded.map { FileTree.path($0, afterMoving: old, to: new) })
        children = children.filter { !isInside($0.key, old) }
        if var current = selected, isInside(current.path, old) {
            current.url = URL(fileURLWithPath: FileTree.path(current.path, afterMoving: old, to: new))
            current.name = current.url.lastPathComponent
            selected = current
            language = CodeLanguage(fileExtension: current.kind)
        }
        let oldParent = (old as NSString).deletingLastPathComponent
        let newParent = url.deletingLastPathComponent().path
        if oldParent != newParent, children[oldParent] != nil { await load(oldParent) }
        await load(newParent)
        for path in expanded.sorted(by: { $0.count < $1.count })
        where isInside(path, new) {
            await load(path)
        }
    }

    // Rows above and below can both report a drag at once as it crosses between them, so a
    // row only clears the highlight it set itself.
    private func hoverDrop(key: String, folder: String, _ targeted: Bool) {
        if targeted {
            dropHover = DropHover(key: key, folder: folder)
        } else if dropHover?.key == key {
            dropHover = nil
        }
    }

    // Items from inside this folder move. Anything from outside is copied in, the way a
    // paste is, so dragging a file in never takes it away from where it lives.
    private func drop(_ urls: [URL], into folder: URL) -> Bool {
        dropHover = nil
        guard !urls.isEmpty else { return false }
        let rootPath = rootURL.standardizedFileURL.path
        let local = urls.filter { isInside($0.standardizedFileURL.path, rootPath) }
        let outside = urls.filter { !isInside($0.standardizedFileURL.path, rootPath) }

        let rootAtStart = root
        Task {
            var failures: [FileTree.CopyFailure] = []
            if !local.isEmpty {
                let result = await FileTree.move(local, into: folder)
                guard root == rootAtStart else { return }
                for move in result.moved {
                    await moved(from: move.from.path, to: move.to)
                }
                failures += result.failures
            }
            if !outside.isEmpty {
                let result = await FileTree.copy(outside, into: folder)
                guard root == rootAtStart else { return }
                if !result.copied.isEmpty { await load(folder.path) }
                failures += result.failures
            }
            if folder.path != root { expanded.insert(folder.path) }
            if children[folder.path] == nil { await load(folder.path) }

            guard !failures.isEmpty else { return }
            dialogs.show(.notice(
                failures.count == 1 ? "Could not move the item" : "Could not move some items",
                message: failures.map { "\($0.name): \($0.message)" }.joined(separator: "\n")))
        }
        return true
    }

    private func contains(_ node: FileNode, _ path: String) -> Bool {
        isInside(path, node.path)
    }

    private func isInside(_ path: String, _ item: String) -> Bool {
        path == item || path.hasPrefix(item + "/")
    }

    private func pasteDestination(for sources: [URL], at node: FileNode?) -> URL {
        guard let node else { return rootURL }
        guard node.isDirectory else { return node.url.deletingLastPathComponent() }
        let nodeURL = node.url.standardizedFileURL
        let copyingItself = sources.contains { $0.standardizedFileURL == nodeURL }
        return copyingItself ? node.url.deletingLastPathComponent() : node.url
    }

    // MARK: - Actions

    // The pane is reused as the session changes, so everything the last folder left behind
    // has to go before the new one is read.
    private func openRoot() async {
        rememberPlace()
        openedRoot = root
        let place = memory.place(for: root) ?? ExplorerMemory.Place()
        children = [:]
        expanded = []
        selected = nil
        preview = nil
        loadingPreview = false
        renderingMarkdown = false
        language = nil
        draft = ""
        original = ""
        loadedAt = nil
        resetFind()
        showHidden = place.showHidden
        treeWidth = place.treeWidth
        await load(root)
        await restore(place)
        await showRequestedFile()
    }

    private func showRequestedFile() async {
        guard let request = reveal.wrappedValue,
              request.path.pathRelative(to: root) != nil else { return }
        reveal.wrappedValue = nil

        let url = URL(fileURLWithPath: request.path)
        let ancestors = FileTree.ancestorDirectories(of: url, beneath: rootURL)
        for path in ancestors {
            expanded.insert(path)
            if children[path] == nil { await load(path) }
        }
        guard !Task.isCancelled,
              let node = children[ancestors.last ?? root]?.first(where: { $0.path == url.path })
        else { return }
        requestSelect(node, line: request.line)
        treeFocused = true
    }

    private func rememberPlace() {
        guard let openedRoot else { return }
        var unsaved: ExplorerMemory.UnsavedEdit?
        if dirty, let selected, let preview {
            unsaved = .init(path: selected.path, preview: preview, draft: draft,
                            original: original, loadedAt: loadedAt)
        }
        memory.remember(.init(expanded: expanded,
                              selected: selected,
                              showHidden: showHidden,
                              treeWidth: treeWidth,
                              renderingMarkdown: renderingMarkdown,
                              unsaved: unsaved),
                        for: openedRoot)
    }

    // Folders and files may have gone while the pane was away, so only what is still on
    // disk is opened again. Parents are read before their children.
    private func restore(_ place: ExplorerMemory.Place) async {
        let fileManager = FileManager.default
        for path in place.expanded.sorted(by: { $0.count < $1.count })
        where fileManager.fileExists(atPath: path) {
            guard !Task.isCancelled else { return }
            expanded.insert(path)
            await load(path)
        }
        guard !Task.isCancelled, let node = place.selected,
              fileManager.fileExists(atPath: node.path) else { return }

        if let edit = place.unsaved, edit.path == node.path {
            selected = node
            preview = edit.preview
            draft = edit.draft
            original = edit.original
            loadedAt = edit.loadedAt
            language = CodeLanguage(fileExtension: node.kind)
        } else {
            select(node)
        }
        renderingMarkdown = place.renderingMarkdown && node.supportsMarkdownPreview
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

    private func moveTreeSelection(_ direction: MoveCommandDirection) {
        guard dialogs.current == nil else { return }
        let navigationDirection: FileTreeNavigation.Direction
        switch direction {
        case .up: navigationDirection = .up
        case .down: navigationDirection = .down
        case .left: navigationDirection = .left
        case .right: navigationDirection = .right
        @unknown default: return
        }
        let visibleRows = rows.map {
            FileTreeNavigation.Row(path: $0.node.path,
                                   isDirectory: $0.node.isDirectory,
                                   depth: $0.depth)
        }
        guard let action = FileTreeNavigation.action(
            for: navigationDirection,
            selectedPath: selected?.path,
            rows: visibleRows,
            expanded: expanded) else { return }

        switch action {
        case .select(let path):
            guard let node = rows.first(where: { $0.node.path == path })?.node else { return }
            requestSelect(node)
        case .expand(let path):
            guard let node = rows.first(where: { $0.node.path == path })?.node else { return }
            toggle(node)
        case .collapse(let path):
            expanded.remove(path)
        }
    }

    // Moving to another file throws the draft away, so unsaved work is worth a question
    // first. A clean pane just moves, and a click on the file already open leaves it alone.
    private func requestSelect(_ node: FileNode, line: Int? = nil) {
        if node.path == selected?.path {
            if line != nil { lineToReveal = line }
            return
        }
        guard dirty else {
            select(node, line: line)
            return
        }
        confirmDiscard { select(node, line: line) }
    }

    private func revert() {
        confirmDiscard { draft = original }
    }

    private func confirmDiscard(then discard: @escaping () -> Void) {
        dialogs.show(.confirm("Discard changes?",
                              message: "Edits to \(selected?.name ?? "this file") have not been saved.",
                              action: "Discard", cancel: "Keep editing", handler: discard))
    }

    private func save(_ node: FileNode) {
        let saved = draft
        let expectedModification = loadedAt
        Task {
            let modified = await FileTree.modified(of: node.url)
            guard selected?.path == node.path else { return }
            guard modified == expectedModification else {
                dialogs.show(.confirm(
                    "The file has changed",
                    message: "\(node.name) was written by something else since it was opened here. Saving replaces what is on disk now.",
                    action: "Save anyway") { write(node, text: saved) })
                return
            }
            write(node, text: saved)
        }
    }

    private func write(_ node: FileNode, text saved: String) {
        Task {
            saving = true
            let failure = await FileTree.write(saved, to: node.url)
            saving = false
            if let failure {
                dialogs.show(.notice("Could not save", message: failure))
                return
            }
            // The pane is left exactly as it is, caret and scroll included. Only what the
            // file is measured against moves on, so the pane reads as clean again.
            let modified = await FileTree.modified(of: node.url)
            guard selected?.path == node.path else { return }
            original = saved
            loadedAt = modified
            await reopenFolders()
        }
    }

    private func select(_ node: FileNode, line: Int? = nil) {
        resetFind()
        selected = node
        lineToReveal = line
        preview = nil
        renderingMarkdown = false
        language = nil
        draft = ""
        original = ""
        loadedAt = nil
        guard !node.isDirectory else {
            loadingPreview = false
            return
        }
        loadingPreview = true
        Task {
            let loaded = await FileTree.preview(of: node.url)
            let modified = await FileTree.modified(of: node.url)
            guard !Task.isCancelled, selected?.path == node.path else { return }
            loadingPreview = false
            preview = loaded
            loadedAt = modified
            language = CodeLanguage(fileExtension: node.kind)
            if case .text(let text) = loaded {
                draft = text
                original = text
            }
        }
    }
}

enum ExplorerSplitLayout {
    static let defaultTreeWidth: CGFloat = 300
    static let minimumTreeWidth: CGFloat = 220
    static let minimumDetailWidth: CGFloat = 320
    static let dividerWidth: CGFloat = 1
    static let handleWidth: CGFloat = 9

    static func treeWidth(_ proposedWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let paneWidth = max(0, availableWidth - dividerWidth)
        let halfWidth = paneWidth / 2
        let minimum = min(minimumTreeWidth, halfWidth)
        let maximum = max(minimum, paneWidth - min(minimumDetailWidth, halfWidth))
        return min(max(proposedWidth, minimum), maximum)
    }
}

private struct ExplorerFileShortcuts: NSViewRepresentable {
    let enabled: Bool
    let onCopy: () -> Bool
    let onPaste: () -> Bool
    let onTrash: () -> Bool
    let onRename: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(enabled: enabled, onCopy: onCopy, onPaste: onPaste, onTrash: onTrash,
                    onRename: onRename)
    }

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        context.coordinator.anchor = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.anchor = view
        context.coordinator.enabled = enabled
        context.coordinator.onCopy = onCopy
        context.coordinator.onPaste = onPaste
        context.coordinator.onTrash = onTrash
        context.coordinator.onRename = onRename
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var anchor: NSView?
        var enabled: Bool
        var onCopy: () -> Bool
        var onPaste: () -> Bool
        var onTrash: () -> Bool
        var onRename: () -> Bool

        private var token: Any?

        init(enabled: Bool, onCopy: @escaping () -> Bool, onPaste: @escaping () -> Bool,
             onTrash: @escaping () -> Bool, onRename: @escaping () -> Bool) {
            self.enabled = enabled
            self.onCopy = onCopy
            self.onPaste = onPaste
            self.onTrash = onTrash
            self.onRename = onRename
        }

        func start() {
            guard token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let handled = MainActor.assumeIsolated { self.handle(event) }
                return handled ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard enabled, anchor?.window === NSApp.keyWindow else { return false }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Return renames and Cmd+Delete moves to the Trash, as they do in Finder.
            if modifiers.isEmpty, event.keyCode == 36 { return onRename() }
            guard modifiers == .command else { return false }
            if event.keyCode == 51 { return onTrash() }
            return switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": onCopy()
            case "v": onPaste()
            default: false
            }
        }

        func stop() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
        }
    }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
