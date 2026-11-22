import SwiftUI

extension ExplorerView {
    // One visible row: the entry and how deep it sits. Folders that are shut contribute
    // nothing, so this is only ever as long as what is actually open.
    private typealias Row = ExplorerTreeRow

    private func rows(in directory: String) -> [Row] {
        Row.rows(in: directory, children: tree.children, expanded: tree.expanded, depth: repositories.isEmpty ? 0 : 1)
            .filter { !markdownOnly || $0.node.isDirectory || $0.node.supportsMarkdownPreview }
    }

    private var rows: [Row] {
        projectRoots.filter { !collapsedProjects.contains($0.root) }.flatMap { rows(in: $0.root) }
    }

    @ViewBuilder var treePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.xs) {
                ChoicePill(title: "All files", selected: !markdownOnly) { markdownOnly = false }
                ChoicePill(title: "Markdown", selected: markdownOnly) { markdownOnly = true }
                Spacer(minLength: 0)
            }.padding(Space.lg)
            if !repositories.isEmpty {
                HStack {
                    Text("Workspace").font(Typography.body.weight(.semibold))
                    Spacer()
                    Text(counted(projectRoots.filter { $0.root != designFilesRoot }.count, "project"))
                        .font(Typography.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, Space.xxl)
                .headerBand(height: Theme.headerHeight)
            }
            if let error = tree.folderErrors[root] {
                VStack(spacing: Space.md) {
                    PaneMessage(icon: "exclamationmark.triangle", title: "Folder unavailable", detail: error)
                    ActionButton(title: "Try again", tone: .outlined, height: ControlHeight.md, size: Typography.Size.detail) { Task { await reopenFolders() } }
                }.padding(Space.lg)
                .transition(AnyTransition.fadeIn.animation(Motion.reveal))
            } else if tree.loadingFolders.contains(root) && tree.children[root] == nil {
                ChangesProgressLabel(title: "Reading files…").foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(AnyTransition.fadeIn.animation(Motion.reveal))
            } else if repositories.isEmpty && tree.children[root]?.isEmpty == true {
                PaneMessage(icon: "folder", title: "Empty folder", detail: showHidden ? "" : "Hidden files are off.")
                    .transition(AnyTransition.fadeIn.animation(Motion.reveal))
            }
            if tree.folderErrors[root] == nil && (!repositories.isEmpty || tree.children[root]?.isEmpty != true) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: repositories.isEmpty ? 1 : 3) {
                            let pins = projectRoots.flatMap { project in
                                project.root == root ? editor.documents.pinned : memory.place(for: project.root)?.documents.pinned ?? []
                            }.filter { !markdownOnly || $0.supportsMarkdownPreview }
                            if !pins.isEmpty {
                                sectionLabel("Pinned files")
                                ForEach(pins) { node in
                                    plainRow(Row(node: node, depth: 0))
                                }
                            }
                            sectionLabel("Project files")
                            ForEach(projectRoots) { project in
                                if !repositories.isEmpty { projectRow(project).id(project.root) }
                                if !collapsedProjects.contains(project.root) {
                                    ForEach(rows(in: project.root)) { row in
                                        treeRow(row).id(row.id).transition(.fold)
                                        if let error = tree.folderErrors[row.node.path], tree.expanded.contains(row.node.path) {
                                            Text(error).font(Typography.caption).foregroundStyle(Theme.attention).padding(Space.md)
                                                .transition(AnyTransition.fadeIn.animation(Motion.reveal))
                                            InlineLink(title: "Try again") { Task { await tree.load(row.node.path) } }
                                                .transition(AnyTransition.fadeIn.animation(Motion.reveal))
                                        }
                                    }
                                }
                            }
                        }.padding(repositories.isEmpty ? 8 : 10)
                    }
                    .onChange(of: editor.selected?.path) {
                        if let path = editor.selected?.path {
                            withAnimation(reduceMotion ? nil : Motion.hover) { proxy.scrollTo(path, anchor: .center) }
                        }
                    }
                    .onChange(of: projectCursor) { _, path in
                        if let path { proxy.scrollTo(path) }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { navigatorFooter }
        .background(Theme.background)
        .overlay {
            if dropHover?.folder == root {
                RoundedRectangle(cornerRadius: Radius.inset).stroke(Theme.accent.opacity(0.65), lineWidth: 1.5)
                    .padding(Space.xxs)
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            drop(urls, into: rootURL)
        } isTargeted: { hoverDrop(key: root, folder: root, $0) }
        .focusable()
        .focused($treeFocused)
        .onChange(of: treeFocused) { _, focused in
            if focused && !repositories.isEmpty && editor.selected == nil && projectCursor == nil {
                projectCursor = root
            }
        }
        .focusEffectDisabled()
        .onMoveCommand(perform: moveTreeSelection)
        .onKeyPress(.return) {
            if let projectCursor { selectRoot(projectCursor); return .handled }
            if let selected = editor.selected, selected.isDirectory { toggle(selected); return .handled }
            return .ignored
        }
    }

    private func projectRow(_ project: ChangesRepository) -> some View {
        WorkspaceProjectRow(name: project.name,
                            detail: tree.children[project.root].map { counted($0.count, "item") },
                            selected: project.root == root,
                            showsCursor: treeFocused && treeCursorVisible && projectCursor == project.root,
                            hasChildren: tree.children[project.root]?.isEmpty == false,
                            collapsed: collapsedProjects.contains(project.root)) {
            withAnimation(treeMotion(opening: collapsedProjects.contains(project.root))) {
                if !collapsedProjects.insert(project.root).inserted { collapsedProjects.remove(project.root) }
            }
        } select: {
            projectCursor = project.root
            treeCursorVisible = false
            treeFocused = true
            selectRoot(project.root)
        }
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
        let isOpen = tree.expanded.contains(node.path)
        let isSelected = editor.selected?.path == node.path
        let isDropTarget = dropHover?.folder == node.path
        let folder = node.isDirectory ? node.url : node.url.deletingLastPathComponent()

        return Button {
            treeFocused = true
            projectCursor = nil
            treeCursorVisible = false
            requestSelect(node)
            if node.isDirectory { toggle(node) }
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .motion(Motion.control, value: isOpen)
                    .frame(width: 10)
                    .opacity(node.isDirectory ? 1 : 0)

                if tree.loadingFolders.contains(node.path) {
                    LoopSpinner(size: 10).frame(width: 14, height: 14)
                } else {
                    Image(systemName: icon(node))
                        .font(Typography.caption)
                        .foregroundStyle(node.isDirectory ? Theme.accent : .secondary)
                        .frame(width: 14)
                }

                Text(row.name)
                    .font(Typography.detail.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                if !node.isDirectory {
                    if editor.hasUnsavedEdit(node) {
                        Text("●").font(Font.system(size: Typography.Size.micro)).foregroundStyle(Theme.attention).accessibilityLabel("Unsaved edits")
                            .transition(markLands)
                    }
                    if isPinned(node) {
                        Image(systemName: "pin").font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary).accessibilityLabel("Pinned")
                            .transition(markLands)
                    }
                    if let status = git.statuses[node.path] { ExplorerStatusMark(status: status) }
                }
            }
            .padding(.vertical, Space.sm)
            .padding(.trailing, Space.md)
            .padding(.leading, CGFloat(row.depth) * 13 + 6)
            .surface(isDropTarget ? Theme.accent.opacity(0.12) : (isSelected ? Theme.accent.opacity(0.1) : .clear),
                     cornerRadius: Radius.inset,
                     border: isDropTarget ? Theme.accent.opacity(0.65) : (isSelected ? Theme.border : .clear))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.inset)
                    .stroke(isSelected && treeFocused && treeCursorVisible && projectCursor == nil ? Theme.accent : .clear,
                            lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.inset)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(row.name)
        .accessibilityValue(node.isDirectory ? (isOpen ? "Expanded" : "Collapsed") : (git.statuses[node.path]?.label ?? "Unchanged"))
        .appTooltip(node.path)
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
                + (node.isDirectory ? [] : [.item(isPinned(node) ? "Unpin file" : "Pin file", icon: "pin") { togglePin(node) }])
                + [.item("Copy Path") { copyPath(node) },
                   .separator,
                   .item("Reveal in Finder") { revealInFinder(node) },
                   .item("Open with default app") { openExternally(node) },
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
        return HStack(spacing: Space.xs) {
            Color.clear.frame(width: 10)
            Image(systemName: icon(node))
                .font(Typography.caption)
                .foregroundStyle(node.isDirectory ? Theme.accent : .secondary)
                .frame(width: 14)
            TextField("Name", text: $renameDraft, selection: $renameSelection)
                .textFieldStyle(.plain)
                .font(Typography.detail)
                .padding(.horizontal, Space.xs)
                .padding(.vertical, 1)
                .fieldSurface(cornerRadius: Radius.tag)
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
        .padding(.vertical, Space.xxs)
        .padding(.trailing, Space.md)
        .padding(.leading, CGFloat(row.depth) * 13 + 6)
    }

    func icon(_ node: FileNode) -> String {
        // A link is drawn as a link whatever sits on the other end. What it points at is
        // spelled out in the header once it is picked, which is where there is room for it.
        if node.isLink { return "arrow.turn.down.right" }
        if node.isDirectory { return tree.expanded.contains(node.path) ? "folder.fill" : "folder" }
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

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(Typography.micro).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Space.sm).padding(.vertical, Space.md)
    }

    private var navigatorFooter: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "folder").accessibilityHidden(true)
            Text(repositories.isEmpty ? "In \(rootURL.lastPathComponent)" : "In this workspace")
                .lineLimit(1).truncationMode(.middle)
                .appTooltip("Find searches \(root)")
            Spacer(minLength: 0)
        }
        .font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary)
        .padding(Space.lg)
        .background(Theme.background)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func toggle(_ node: FileNode) {
        if tree.expanded.contains(node.path) {
            collapseFolder(node.path)
        } else {
            tree.open(node.path, motion: treeMotion(opening: true))
        }
    }

    private func treeMotion(opening: Bool) -> Animation? {
        reduceMotion ? nil : opening ? Motion.reveal : Motion.leave
    }

    private func collapseFolder(_ path: String) {
        withAnimation(treeMotion(opening: false)) {
            tree.expanded.subtract(rows.first(where: { $0.id == path })?.compactPaths ?? [path])
        }
    }

    var openFolderCount: Int {
        rows.filter { $0.node.isDirectory && tree.expanded.contains($0.node.path) }.count
    }

    // The deepest open level shuts first and each level above follows a beat later, so
    // the tree folds up rather than snapping shut. Folders left open inside closed ones
    // are shut at the end too, so nothing springs open again later.
    func collapseAllFolders() {
        guard !reduceMotion else { tree.expanded = []; return }
        let open = rows.filter { $0.node.isDirectory && tree.expanded.contains($0.node.path) }
        let levels = Dictionary(grouping: open, by: \.depth).sorted { $0.key > $1.key }.map(\.value)
        Task {
            for (index, level) in levels.enumerated() {
                if index > 0 { try? await Task.sleep(for: .milliseconds(110)) }
                withAnimation(Motion.leave) { tree.expanded.subtract(level.flatMap(\.compactPaths)) }
            }
            tree.expanded = []
        }
    }

    private func moveTreeSelection(_ direction: MoveCommandDirection) {
        guard dialogs.current == nil else { return }
        treeCursorVisible = true
        let items = projectRoots.flatMap { project in
            (repositories.isEmpty ? [] : [project.root])
                + (collapsedProjects.contains(project.root) ? [] : rows(in: project.root).map(\.id))
        }
        if direction == .up || direction == .down {
            let cursor = projectCursor ?? editor.selected?.path
            guard let next = RowStep.destination(from: cursor.flatMap { items.firstIndex(of: $0) },
                                                 step: direction == .up ? -1 : 1, count: items.count) else { return }
            let path = items[next]
            if projectRoots.contains(where: { $0.root == path }) {
                projectCursor = path
            } else if let node = rows.first(where: { $0.id == path })?.node {
                projectCursor = nil
                requestSelect(node)
            }
            return
        }
        if let projectCursor {
            if direction == .left { collapsedProjects.insert(projectCursor) }
            if direction == .right { collapsedProjects.remove(projectCursor) }
            return
        }
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
            selectedPath: editor.selected?.path,
            rows: visibleRows,
            expanded: tree.expanded) else { return }

        switch action {
        case .select(let path):
            guard let node = rows.first(where: { $0.node.path == path })?.node else { return }
            requestSelect(node)
        case .expand(let path):
            guard let node = rows.first(where: { $0.node.path == path })?.node else { return }
            toggle(node)
        case .collapse(let path):
            collapseFolder(path)
        }
    }
}
