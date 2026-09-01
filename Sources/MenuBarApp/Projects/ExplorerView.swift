import AppKit
import SwiftUI

// Every file in a session's folder, as a tree with the file itself beside it. Changes only
// covers what git has something to say about; this is the whole working tree, which is
// what you want when the agent names a file you have never opened.
//
// A text file opens straight into an editor: there is no read mode to leave first, and
// nothing is written until Save. The tree itself stays read-only: nothing here creates,
// renames or deletes anything.
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
    @State private var renderingMarkdown = false
    @State private var showHidden = true
    @State private var language: CodeLanguage?
    @State private var pastingFiles = false
    @FocusState private var treeFocused: Bool

    // The text as loaded sits next to the draft, so "anything to save" and "anything to
    // lose" are both one comparison.
    @State private var draft = ""
    @State private var original = ""
    @State private var saving = false
    // When the file was last written at the moment it was read. An agent works in the same
    // folder, so a pane left open on a file it has since rewritten would save over it.
    @State private var loadedAt: Date?

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
        .background(ExplorerSearchShortcut { showFileSearch() })
        .background(ExplorerFileShortcuts(
            enabled: treeFocused && dialogs.current == nil && !pastingFiles,
            onCopy: copySelected,
            onPaste: pasteFiles))
        .onChange(of: findQuery) {
            findSelection = 0
            refreshFind()
        }
        // Typing moves every match after the caret, so the results are only right for the
        // text as it stands now.
        .onChange(of: draft) { if findPresented { refreshFind() } }
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
                Text(counted(count, "item"))
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
            .appTooltip("Refresh")
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
        .frame(width: 300)
        .contentShape(Rectangle())
        .focusable()
        .focused($treeFocused)
        .focusEffectDisabled()
        .onMoveCommand(perform: moveTreeSelection)
    }

    private func treeRow(_ row: Row) -> some View {
        let node = row.node
        let isOpen = expanded.contains(node.path)
        let isSelected = selected?.path == node.path

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
            .surface(isSelected ? Theme.card : .clear, cornerRadius: 6,
                     border: isSelected ? Theme.border : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appContextMenu {
            [.item("Copy") { copy(node) },
             .item("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) },
             .item("Open with default app") { NSWorkspace.shared.open(node.url) },
             .item("Copy Path") { Pasteboard.copy(node.path) }]
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
                    Spacer()
                    if loadingPreview || saving { ProgressView().controlSize(.small) }
                    if dirty { saveButtons(node) }
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
                               currentMatch: findPresented ? currentFindMatch : nil)
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
            PaneMessage(icon: "exclamationmark.triangle", title: "Could not read this file",
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

    private var findShortcut: some View {
        Button("") { showFind() }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .control)
            .opacity(0)
            .disabled(!isEditable || renderingMarkdown)
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
            .fieldSurface(cornerRadius: 7)

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
                .fieldSurface(cornerRadius: 7)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .appTooltip(help)
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

    private func pasteFiles() -> Bool {
        let sources = Pasteboard.fileURLs()
        guard !sources.isEmpty else { return false }

        let destination = pasteDestination(for: sources)
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

    private func pasteDestination(for sources: [URL]) -> URL {
        guard let selected else { return rootURL }
        guard selected.isDirectory else { return selected.url.deletingLastPathComponent() }
        let selectedURL = selected.url.standardizedFileURL
        let copyingSelection = sources.contains { $0.standardizedFileURL == selectedURL }
        return copyingSelection ? selected.url.deletingLastPathComponent() : selected.url
    }

    // MARK: - Actions

    // The pane is reused as the session changes, so everything the last folder left behind
    // has to go before the new one is read.
    private func openRoot() async {
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
    private func requestSelect(_ node: FileNode) {
        if node.path == selected?.path { return }
        guard dirty else {
            select(node)
            return
        }
        confirmDiscard { select(node) }
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
        Task {
            guard await FileTree.modified(of: node.url) == loadedAt else {
                dialogs.show(.confirm(
                    "The file has changed",
                    message: "\(node.name) was written by something else since it was opened here. Saving replaces what is on disk now.",
                    action: "Save anyway") { write(node) })
                return
            }
            write(node)
        }
    }

    private func write(_ node: FileNode) {
        Task {
            let saved = draft
            saving = true
            let failure = await FileTree.write(saved, to: node.url)
            saving = false
            if let failure {
                dialogs.show(.notice("Could not save", message: failure))
                return
            }
            // The pane is left exactly as it is, caret and scroll included. Only what the
            // file is measured against moves on, so the pane reads as clean again.
            guard selected?.path == node.path else { return }
            original = saved
            loadedAt = await FileTree.modified(of: node.url)
            await reopenFolders()
        }
    }

    private func select(_ node: FileNode) {
        resetFind()
        selected = node
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

private struct ExplorerFileShortcuts: NSViewRepresentable {
    let enabled: Bool
    let onCopy: () -> Bool
    let onPaste: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(enabled: enabled, onCopy: onCopy, onPaste: onPaste)
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

        private var token: Any?

        init(enabled: Bool, onCopy: @escaping () -> Bool, onPaste: @escaping () -> Bool) {
            self.enabled = enabled
            self.onCopy = onCopy
            self.onPaste = onPaste
        }

        func start() {
            guard token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let handled = MainActor.assumeIsolated { self.handle(event) }
                return handled ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard enabled, anchor?.window === NSApp.keyWindow,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
                return false
            }
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
