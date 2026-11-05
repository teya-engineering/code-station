import AppKit
import SwiftUI

// Every file in a session's folder, as a tree with the file itself beside it. Changes only
// covers what git has something to say about; this is the whole working tree, which is
// what you want when the agent names a file you have never opened.
//
// A text file opens straight into an editor: there is no read mode to leave first, and
// nothing is written until Save. The tree itself can create, copy, paste, rename, drag to
// move and move items to the Trash.
// Says that a pane with a find of its own, a file or the chat, has taken Cmd+F. It travels
// up to the window so the sidebar can stop naming that stroke as the way into its own
// filter while the pane answers for it.
struct PaneFindShortcutKey: PreferenceKey {
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

// One of the header's actions, asked for by a header that lives outside the pane. Find
// without a mode opens in the mode used last.
enum ExplorerCommand: Equatable {
    case find(ExplorerSearchMode?)
    case newFile
    case newFolder
    case toggleHidden
    case collapseFolders
    case refresh
}

struct ExplorerView: View {
    let root: String
    // Taken and cleared once the file is shown, so coming back to the pane later
    // finds it where it was left rather than back on this file.
    var reveal: Binding<ExplorerReveal?> = .constant(nil)

    // Commands from the session header are taken and cleared once done, like `reveal`.
    var command: Binding<ExplorerCommand?>?
    private let sharedShowHidden: Binding<Bool>?
    // Handed up so the header's menu can say how many folders are open.
    private let openFolders: Binding<Int>?
    // Called with the number of items listed once a refresh has read the folders again.
    private let refreshed: (Int) -> Void

    var repositories: [ChangesRepository] = []
    var designFilesRoot: String?
    @Binding var collapsedProjects: Set<String>
    var selectRoot: (String) -> Void = { _ in }
    // The project row the keyboard is on. The keyboard lands on a file by selecting it,
    // so with this nil the cursor sits on the selected file.
    @State private var projectCursor: String?
    // A click already highlights the row it picks, so the cursor ring only shows while
    // the keyboard is driving the tree.
    @State private var treeCursorVisible = false

    init(root: String, reveal: Binding<ExplorerReveal?> = .constant(nil),
         command: Binding<ExplorerCommand?>? = nil, showHidden: Binding<Bool>? = nil,
         openFolders: Binding<Int>? = nil, refreshed: @escaping (Int) -> Void = { _ in },
         repositories: [ChangesRepository] = [], designFilesRoot: String? = nil,
         collapsedProjects: Binding<Set<String>> = .constant([]),
         selectRoot: @escaping (String) -> Void = { _ in }) {
        self.root = root
        self.reveal = reveal
        self.command = command
        self.sharedShowHidden = showHidden
        self.openFolders = openFolders
        self.refreshed = refreshed
        self.repositories = repositories
        self.designFilesRoot = designFilesRoot
        self._collapsedProjects = collapsedProjects
        self.selectRoot = selectRoot
    }

    private var projectRoots: [ChangesRepository] {
        repositories.isEmpty ? [ChangesRepository(root: root, name: rootURL.lastPathComponent)] : repositories
    }

    @Environment(DialogPresenter.self) private var dialogs
    @Environment(ExplorerMemory.self) private var memory
    @Environment(MenuPresenter.self) private var menus
    @State private var markdownOnly = false
    @State private var markdownMode = MarkdownEditorMode.edit
    @State private var markdownCanEdit = true
    @State private var saveErrors: [String: String] = [:]

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
    @State private var previewGeneration = 0
    @State private var ownShowHidden = true
    @State private var language: CodeLanguage?
    @State private var pastingFiles = false
    @State private var treeWidth = ExplorerSplitLayout.defaultTreeWidth
    @State private var documents = ExplorerDocuments()
    @State private var git = ExplorerGitStatus()
    @State private var statusRevision = 0
    @State private var folderErrors: [String: String] = [:]
    @State private var focusEditor = false
    @State private var narrowNavigator = false
    @State private var detailsPresented = false
    @Namespace private var tabUnderline
    // A click whose work happens outside the window, such as opening Finder, moves
    // nothing in it, so a short note is all the window shows of it.
    @State private var note: String?
    @State private var noteIcon = "arrow.up.forward.app"
    @State private var notes = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var fileWasSaved = false
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
    // Cmd+H hides the app on a Mac, so find in files takes Ctrl+H, next to Ctrl+F.
    @State private var findInFilesMonitor = WindowKeyMonitor(.control, "h")
    @State private var escapeMonitor = WindowKeyMonitor([], "\u{1b}")
    // Closes the file in front, the way Cmd+W closes a tab in an editor. With no file
    // open the stroke goes on to close the window as usual.
    @State private var closeTabMonitor = WindowKeyMonitor(.command, "w")
    // The query marked on the line a find in files result opened at. It goes once the
    // text is edited, since the marks would no longer sit on the words they were for.
    @State private var revealedMatches: [NSRange] = []
    // The Find dialog while it is open, and what it held when it was last closed, so the
    // next opening starts from the same mode and query.
    @State private var finder: ExplorerFindModel?
    @State private var finderDialog: UUID?
    @State private var finderMode = ExplorerSearchMode.names
    @State private var finderQuery = ""

    private var rootURL: URL { URL(fileURLWithPath: root) }

    private var showHiddenBinding: Binding<Bool> { sharedShowHidden ?? $ownShowHidden }

    private var showHidden: Bool {
        get { showHiddenBinding.wrappedValue }
        nonmutating set { showHiddenBinding.wrappedValue = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let sideBySide = geometry.size.width >= ExplorerSplitLayout.minimumSplitWidth
            let showsTree = !focusEditor && (sideBySide || selected == nil || narrowNavigator)
            let width = sideBySide
                ? ExplorerSplitLayout.treeWidth(treeWidth, availableWidth: geometry.size.width, keepsDetailMinimum: true)
                : min(ExplorerSplitLayout.defaultTreeWidth, geometry.size.width)

            HStack(spacing: 0) {
                if showsTree && sideBySide {
                    tree.frame(width: width).clipped()
                        .transition(AnyTransition.fadeIn.animation(Motion.reveal))
                    Rectangle().fill(Theme.hairline).frame(width: ExplorerSplitLayout.dividerWidth)
                }
                detail(navigatorVisible: showsTree)
                    .frame(width: max(0, geometry.size.width - (showsTree && sideBySide ? width + ExplorerSplitLayout.dividerWidth : 0)))
                    .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .leading) {
                // The ZStack stays put so each layer inside it can take its own transition.
                ZStack(alignment: .leading) {
                    if showsTree && !sideBySide {
                        Theme.background.opacity(0.6).onTapGesture { narrowNavigator = false; focusEditor = true }
                            .transition(scrim)
                        tree.frame(width: width).background(Theme.background)
                            .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
                            .transition(.drawer(from: .leading, reduceMotion: reduceMotion))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .clipped()
            }
            // A bare `if` beside other views in an overlay loses the overlay's alignment
            // and lands in the middle, so the handle gets a leading frame of its own.
            .overlay {
                ZStack(alignment: .leading) {
                    if showsTree && sideBySide {
                        splitHandle(treeWidth: width, availableWidth: geometry.size.width)
                            .offset(x: width + (ExplorerSplitLayout.dividerWidth - ExplorerSplitLayout.handleWidth) / 2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .background(Theme.background)
        .overlay(alignment: .topTrailing) {
            ZStack {
                if let note {
                    HeaderNote(icon: noteIcon, text: note)
                        .padding(.top, 50).padding(.trailing, 14)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
                }
            }
            .motion(Motion.reveal, value: note)
        }
        .background(ExplorerSearchShortcut { showFinder(.names) })
        .background(ExplorerFileShortcuts(
            enabled: treeFocused && projectCursor == nil && dialogs.current == nil && !pastingFiles,
            onCopy: copySelected,
            onPaste: { pasteFiles(at: selected) },
            onTrash: trashSelected,
            onRename: renameSelected))
        .background(WindowAnchor(monitor: findMonitor))
        .background(WindowAnchor(monitor: commandFindMonitor))
        .background(WindowAnchor(monitor: findInFilesMonitor))
        .background(WindowAnchor(monitor: escapeMonitor))
        .background(WindowAnchor(monitor: closeTabMonitor))
        .onAppear {
            closeTabMonitor.start {
                guard dialogs.current == nil, renaming == nil else { return false }
                guard
                      let open = documents.tabs.first(where: { $0.path == selected?.path }) ?? documents.tabs.last
                else { return false }
                closeTab(open)
                return true
            }
            escapeMonitor.start {
                guard dialogs.current == nil, renaming == nil else { return false }
                if detailsPresented { detailsPresented = false; return true }
                if findPresented { closeFind(); return true }
                if focusEditor || narrowNavigator { focusEditor = false; narrowNavigator = false; return true }
                return false
            }
        }
        .preference(key: PaneFindShortcutKey.self, value: canFind)
        .onChange(of: canFind, initial: true) { _, canFind in
            for monitor in findMonitors {
                guard canFind else { monitor.stop(); continue }
                monitor.start {
                    showFind()
                    return true
                }
            }
        }
        // Left running while the Find dialog is open, so the stroke switches its mode.
        .onChange(of: dialogs.current == nil || finderIsOpen, initial: true) { _, free in
            guard free else { findInFilesMonitor.stop(); return }
            findInFilesMonitor.start {
                showFinder(.contents)
                return true
            }
        }
        .onDisappear {
            findMonitors.forEach { $0.stop() }
            findInFilesMonitor.stop()
            escapeMonitor.stop()
            closeTabMonitor.stop()
            rememberPlace()
        }
        .onChange(of: findQuery) {
            findSelection = 0
            refreshFind()
        }
        // Typing moves every match after the caret, so the results are only right for the
        // text as it stands now.
        .onChange(of: draft) {
            fileWasSaved = false
            if findPresented { refreshFind() }
            if draft != original { revealedMatches = [] }
        }
        .onChange(of: markdownMode) { _, mode in
            if let selected { documents.modes[selected.path] = mode }
            if mode != .source { resetFind() }
        }
        .onChange(of: showHidden) { Task { await reopenFolders() } }
        .onChange(of: openFolderCount, initial: true) { _, count in openFolders?.wrappedValue = count }
        .task(id: projectRoots.map(\.root) + [String(statusRevision)]) {
            await git.refresh(roots: projectRoots.map(\.root))
        }
        .onChange(of: command?.wrappedValue) { _, requested in
            guard let requested else { return }
            command?.wrappedValue = nil
            perform(requested)
        }
        .task(id: root) { await openRoot() }
        .onChange(of: reveal.wrappedValue) {
            if openedRoot == root { Task { await showRequestedFile() } }
        }
    }

    // The dimmed layer behind a panel that covers the pane.
    private var scrim: AnyTransition {
        .asymmetric(insertion: .opacity.animation(Motion.reveal), removal: .opacity.animation(Motion.leave))
    }

    // A small mark landing on a row or a tab, such as the dot for unsaved edits.
    private var markLands: AnyTransition {
        reduceMotion
            ? .opacity.animation(Motion.reveal)
            : .scale(scale: 0.5).combined(with: .opacity).animation(Motion.pop)
    }

    // A second click keeps the note up rather than letting the first one's timer take it
    // down early.
    private func showNote(_ text: String, icon: String = "arrow.up.forward.app") {
        notes += 1
        let shown = notes
        noteIcon = icon
        note = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.9))
            if notes == shown { note = nil }
        }
    }

    private func copyPath(_ node: FileNode) {
        Pasteboard.copy(node.path)
        showNote("Copied the path", icon: "doc.on.doc")
    }

    private func revealInFinder(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
        showNote("Showed \(node.name) in Finder")
    }

    private func openExternally(_ node: FileNode) {
        NSWorkspace.shared.open(node.url)
        showNote("Opened \(node.name)")
    }

    private func splitHandle(treeWidth: CGFloat, availableWidth: CGFloat) -> some View {
        WorkspaceSplitHandle(width: $treeWidth, displayedWidth: treeWidth, availableWidth: availableWidth,
                             label: "Resize file navigator", keyboardResizing: true, keepsDetailMinimum: true)
    }

    private func perform(_ command: ExplorerCommand) {
        switch command {
        case .find(let mode): showFinder(mode)
        case .newFile: create(folder: false, in: newItemDestination())
        case .newFolder: create(folder: true, in: newItemDestination())
        case .toggleHidden: showHidden.toggle()
        case .collapseFolders: collapseAllFolders()
        case .refresh:
            Task {
                await reopenFolders()
                refreshed(projectRoots.reduce(0) { $0 + (children[$1.root]?.count ?? 0) })
            }
        }
    }

    private var navigatorFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").accessibilityHidden(true)
            Text(repositories.isEmpty ? "In \(rootURL.lastPathComponent)" : "In this workspace")
                .lineLimit(1).truncationMode(.middle)
                .appTooltip("Find searches \(root)")
            Spacer(minLength: 0)
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(12)
        .background(Theme.background)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 7).padding(.vertical, 9)
    }

    // MARK: - Tree

    // One visible row: the entry and how deep it sits. Folders that are shut contribute
    // nothing, so this is only ever as long as what is actually open.
    private struct DropHover: Equatable {
        let key: String
        let folder: String
    }

    private typealias Row = ExplorerTreeRow

    private func rows(in directory: String) -> [Row] {
        Row.rows(in: directory, children: children, expanded: expanded, depth: repositories.isEmpty ? 0 : 1)
            .filter { !markdownOnly || $0.node.isDirectory || $0.node.supportsMarkdownPreview }
    }

    private var rows: [Row] {
        projectRoots.filter { !collapsedProjects.contains($0.root) }.flatMap { rows(in: $0.root) }
    }

    private func projectRow(_ project: ChangesRepository) -> some View {
        WorkspaceProjectRow(name: project.name,
                            detail: children[project.root].map { counted($0.count, "item") },
                            selected: project.root == root,
                            showsCursor: treeFocused && treeCursorVisible && projectCursor == project.root,
                            hasChildren: children[project.root]?.isEmpty == false,
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

    @ViewBuilder private var tree: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ChoicePill(title: "All files", selected: !markdownOnly) { markdownOnly = false }
                ChoicePill(title: "Markdown", selected: markdownOnly) { markdownOnly = true }
                Spacer(minLength: 0)
            }.padding(12)
            if !repositories.isEmpty {
                HStack {
                    Text("Workspace").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(counted(projectRoots.filter { $0.root != designFilesRoot }.count, "project"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .headerBand(height: Theme.headerHeight)
            }
            if let error = folderErrors[root] {
                VStack(spacing: 10) {
                    PaneMessage(icon: "exclamationmark.triangle", title: "Folder unavailable", detail: error)
                    ActionButton(title: "Try again", tone: .outlined, height: 28, size: 12) { Task { await reopenFolders() } }
                }.padding(12)
                .transition(AnyTransition.fadeIn.animation(Motion.reveal))
            } else if loadingFolders.contains(root) && children[root] == nil {
                ChangesProgressLabel(title: "Reading files…").foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(AnyTransition.fadeIn.animation(Motion.reveal))
            } else if repositories.isEmpty && children[root]?.isEmpty == true {
                PaneMessage(icon: "folder", title: "Empty folder", detail: showHidden ? "" : "Hidden files are off.")
                    .transition(AnyTransition.fadeIn.animation(Motion.reveal))
            }
            if folderErrors[root] == nil && (!repositories.isEmpty || children[root]?.isEmpty != true) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: repositories.isEmpty ? 1 : 3) {
                            let pins = projectRoots.flatMap { project in
                                project.root == root ? documents.pinned : memory.place(for: project.root)?.documents.pinned ?? []
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
                                        if let error = folderErrors[row.node.path], expanded.contains(row.node.path) {
                                            Text(error).font(.system(size: 11)).foregroundStyle(Theme.attention).padding(8)
                                                .transition(AnyTransition.fadeIn.animation(Motion.reveal))
                                            InlineLink(title: "Try again") { Task { await load(row.node.path) } }
                                                .transition(AnyTransition.fadeIn.animation(Motion.reveal))
                                        }
                                    }
                                }
                            }
                        }.padding(repositories.isEmpty ? 8 : 10)
                    }
                    .onChange(of: selected?.path) {
                        if let path = selected?.path {
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
        .onChange(of: treeFocused) { _, focused in
            if focused && !repositories.isEmpty && selected == nil && projectCursor == nil {
                projectCursor = root
            }
        }
        .focusEffectDisabled()
        .onMoveCommand(perform: moveTreeSelection)
        .onKeyPress(.return) {
            if let projectCursor { selectRoot(projectCursor); return .handled }
            if let selected, selected.isDirectory { toggle(selected); return .handled }
            return .ignored
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
        let isOpen = expanded.contains(node.path)
        let isSelected = selected?.path == node.path
        let isDropTarget = dropHover?.folder == node.path
        let folder = node.isDirectory ? node.url : node.url.deletingLastPathComponent()

        return Button {
            treeFocused = true
            projectCursor = nil
            treeCursorVisible = false
            requestSelect(node)
            if node.isDirectory { toggle(node) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .motion(Motion.control, value: isOpen)
                    .frame(width: 10)
                    .opacity(node.isDirectory ? 1 : 0)

                if loadingFolders.contains(node.path) {
                    LoopSpinner(size: 10).frame(width: 14, height: 14)
                } else {
                    Image(systemName: icon(node))
                        .font(.system(size: 11))
                        .foregroundStyle(node.isDirectory ? Theme.accent : .secondary)
                        .frame(width: 14)
                }

                Text(row.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                if !node.isDirectory {
                    if hasUnsavedEdit(node) {
                        Text("●").font(.system(size: 9)).foregroundStyle(Theme.attention).accessibilityLabel("Unsaved edits")
                            .transition(markLands)
                    }
                    if isPinned(node) {
                        Image(systemName: "pin").font(.system(size: 10)).foregroundStyle(.secondary).accessibilityLabel("Pinned")
                            .transition(markLands)
                    }
                    if let status = git.statuses[node.path] { ExplorerStatusMark(status: status) }
                }
            }
            .padding(.vertical, 6)
            .padding(.trailing, 8)
            .padding(.leading, CGFloat(row.depth) * 13 + 6)
            .surface(isDropTarget ? Theme.accent.opacity(0.12) : (isSelected ? Theme.accent.opacity(0.1) : .clear),
                     cornerRadius: 6,
                     border: isDropTarget ? Theme.accent.opacity(0.65) : (isSelected ? Theme.border : .clear))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected && treeFocused && treeCursorVisible && projectCursor == nil ? Theme.accent : .clear,
                            lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 6)
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

    private func detail(navigatorVisible: Bool) -> some View {
        GeometryReader { geometry in
            let inlineDetails = ExplorerSplitLayout.showsInlineDetails(availableWidth: geometry.size.width)
            let editorWidth = max(0, geometry.size.width
                - (detailsPresented && selected != nil && inlineDetails ? ExplorerSplitLayout.detailsWidth : 0))
            let compact = editorWidth < 530
            let inset: CGFloat = compact ? 16 : 20
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    editorTabs(navigatorVisible: navigatorVisible)
                    if let node = selected {
                        breadcrumbs(node, inset: inset)
                        let header = compact
                            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 3))
                            : AnyLayout(HStackLayout(spacing: 16))
                        header {
                            fileTitle(node, compact: compact)
                            fileActions(node, compact: compact)
                        }
                        .padding(.horizontal, inset)
                        .padding(.vertical, node.supportsMarkdownPreview ? 10 : compact ? 5 : 4)
                        .frame(minWidth: 0, maxWidth: .infinity,
                               minHeight: node.supportsMarkdownPreview ? (compact ? 80 : 52) : (compact ? 65 : 36),
                               alignment: .leading)
                        if findPresented {
                            findBar.transition(reduceMotion ? AnyTransition.opacity.animation(Motion.reveal) : .fold)
                        }
                        if let error = saveErrors[node.path] {
                            EditorSaveError(message: error, retry: { save(node) }, export: {
                                exportMarkdown(draft, name: node.name, dialogs: dialogs, notify: { showNote($0) })
                            }).transition(.fadeIn)
                        }
                        // Keyed on what kind of body is showing rather than on the file, so
                        // moving between two text files keeps the same editor.
                        fileBody(node)
                            .id(node.supportsMarkdownPreview ? node.path : bodyKind(node))
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            .clipped()
                            .transition(.headerPage(reduceMotion: reduceMotion))
                        if isEditable { editStatus(node, width: editorWidth, inset: inset) }
                    } else {
                        PaneMessage(icon: "sidebar.left", title: "Pick a file",
                                    detail: "Choose one from the list, or press Shift twice to find it.")
                    }
                }
                // Source lines and long names must not set the minimum width of the header and footer.
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(width: editorWidth, alignment: .leading)
                if detailsPresented, let node = selected, inlineDetails {
                    fileDetails(node).frame(width: ExplorerSplitLayout.detailsWidth)
                        .transition(.popover(reduceMotion: reduceMotion))
                }
            }
            .overlay(alignment: .trailing) {
                let overlaid = detailsPresented && selected != nil && !inlineDetails
                ZStack(alignment: .trailing) {
                    if overlaid {
                        Color.black.opacity(0.12).onTapGesture { detailsPresented = false }
                            .transition(scrim)
                    }
                    if overlaid, let node = selected {
                        fileDetails(node).frame(width: min(ExplorerSplitLayout.detailsWidth, geometry.size.width))
                            .shadow(color: .black.opacity(0.08), radius: 12, x: -4)
                            .transition(.popover(reduceMotion: reduceMotion))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
        .background(Theme.card)
        .motion(Motion.reveal, value: selected?.path)
    }

    private func editorTabs(navigatorVisible: Bool) -> some View {
        HStack(spacing: 4) {
            ExplorerIcon(symbol: "sidebar.left", label: "Toggle file navigator") {
                focusEditor = navigatorVisible
                narrowNavigator = !navigatorVisible
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(documents.tabs) { node in
                            HStack(spacing: 5) {
                                Button { requestSelect(node) } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: icon(node)).foregroundStyle(Theme.accent)
                                        Text(node.name).lineLimit(1).truncationMode(.middle)
                                        if hasUnsavedEdit(node) {
                                            Text("●").foregroundStyle(Theme.attention).accessibilityLabel("Unsaved edits")
                                                .transition(markLands)
                                        } else if isPinned(node) {
                                            Image(systemName: "pin").foregroundStyle(.secondary).accessibilityLabel("Pinned")
                                                .transition(markLands)
                                        }
                                    }
                                    .font(.system(size: 11, weight: node.path == selected?.path ? .semibold : .regular))
                                    .padding(.leading, 10).frame(height: 40).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(node.path == selected?.path ? .isSelected : [])
                                ExplorerIcon(symbol: "xmark", label: "Close \(node.name)") { closeTab(node) }
                            }
                            .frame(maxWidth: 230)
                            .background(node.path == selected?.path ? Theme.card : .clear)
                            .hoverFill(cornerRadius: 0)
                            .overlay(alignment: .bottom) {
                                if node.path == selected?.path {
                                    Rectangle().fill(Theme.accent).frame(height: 2)
                                        .matchedGeometryEffect(id: "underline", in: tabUnderline)
                                }
                            }
                            .appTooltip(relativePath(node))
                            .id(node.path)
                            .transition(.asymmetric(insertion: .opacity.animation(Motion.reveal), removal: .opacity))
                        }
                    }
                    .motion(Motion.draw, value: selected?.path)
                }.scrollIndicators(.hidden)
                .onChange(of: selected?.path) { _, path in if let path { proxy.scrollTo(path) } }
            }
            ExplorerIcon(symbol: focusEditor ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         label: focusEditor ? "Exit focus mode" : "Focus editor", selected: focusEditor) {
                focusEditor.toggle()
                narrowNavigator = false
            }
        }
        .padding(.horizontal, 6).frame(height: 42)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func breadcrumbs(_ node: FileNode, inset: CGFloat) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                let parts = relativePath(node).split(separator: "/").map(String.init)
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).accessibilityHidden(true) }
                    Text(part).foregroundStyle(index == parts.count - 1 ? Color.primary : .secondary)
                }
                if let target = node.linkDestination { Text("→ \(target)").foregroundStyle(.secondary) }
            }
            .font(.system(size: 11)).padding(.horizontal, inset).frame(height: 36)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .combine)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func fileTitle(_ node: FileNode, compact: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(node)).foregroundStyle(Theme.accent).accessibilityHidden(true)
            HStack(spacing: 8) {
                Text(node.name)
                    .font(.system(size: compact ? 14 : 15, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityLabel(node.name)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("explorer.fileTitle")
                    .appTooltip(node.name)
                if node.supportsMarkdownPreview {
                    if dirty {
                        Circle().fill(Theme.attention).frame(width: 6, height: 6)
                            .accessibilityLabel("Unsaved changes")
                            .appTooltip("Unsaved changes")
                            .transition(.opacity)
                    }
                    if isPinned(node) {
                        Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned").transition(.opacity)
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .motion(Motion.control, value: dirty)
            .motion(Motion.control, value: isPinned(node))
            if let status = git.statuses[node.path] {
                ExplorerStatusMark(status: status, spelledOut: !compact)
                    .fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
            }
            // A narrow header keeps the mode beside the title and the file actions below it.
            if compact { markdownModes(node) }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: compact ? 24 : nil, alignment: .leading)
    }

    private func fileActions(_ node: FileNode, compact: Bool) -> some View {
        HStack(spacing: compact ? 2 : 5) {
            if !compact { markdownModes(node) }
            if isEditable {
                if node.supportsMarkdownPreview { markdownSave(node) }
                else { saveButtons(node) }
            }
            if node.supportsMarkdownPreview {
                Rectangle().fill(Theme.border).frame(width: 1, height: 20)
                    .padding(.horizontal, compact ? 5 : 8).accessibilityHidden(true)
            }
            ExplorerIcon(symbol: "magnifyingglass", label: "Find in file (Cmd+F or Ctrl+F)", action: showFind)
                .disabled(!canFind)
            if !node.supportsMarkdownPreview {
                if !node.isDirectory {
                    ExplorerIcon(symbol: isPinned(node) ? "pin.fill" : "pin", label: isPinned(node) ? "Unpin file" : "Pin file",
                                 selected: isPinned(node)) { togglePin(node) }
                }
                ExplorerIcon(symbol: "info.circle", label: "File details", selected: detailsPresented) { detailsPresented.toggle() }
            }
            ExplorerIcon(symbol: "ellipsis", label: "File actions")
                .appMenu(showsFocusRing: true) {
                    var items: [MenuEntry] = []
                    if node.supportsMarkdownPreview {
                        items += [
                            .item(isPinned(node) ? "Unpin file" : "Pin file", icon: "pin", checked: isPinned(node)) { togglePin(node) },
                            .item("File details", icon: "info.circle", checked: detailsPresented) { detailsPresented.toggle() },
                            .separator,
                            .item("Revert changes", icon: "arrow.uturn.backward", disabled: !dirty || saving) { revert() },
                            .separator,
                            .item("Copy path", icon: "doc.on.doc") { copyPath(node) },
                            .item("Export Markdown copy", icon: "square.and.arrow.up", disabled: !isEditable) {
                                exportMarkdown(draft, name: node.name, dialogs: dialogs, notify: { showNote($0) })
                            }
                        ]
                    } else {
                        items.append(.item("Copy path") { copyPath(node) })
                    }
                    return items + [.item("Open externally") { openExternally(node) },
                                    .item("Reveal in Finder") { revealInFinder(node) }]
                }
        }.fixedSize()
    }

    @ViewBuilder private func markdownModes(_ node: FileNode) -> some View {
        switch preview {
        case .text, .empty:
            if node.supportsMarkdownPreview {
                MarkdownModeMenu(mode: $markdownMode, canEdit: markdownCanEdit)
                    .padding(.trailing, 6).transition(.fadeIn)
            }
        default: EmptyView()
        }
    }

    private var editStatusMessage: String {
        if saving { return "Saving changes…" }
        if dirty { return "Your edits are kept here until you save." }
        if fileWasSaved { return "Saved. Your file is up to date." }
        return "Changes are written only when you save."
    }

    private func editStatus(_ node: FileNode, width: CGFloat, inset: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: dirty ? "info.circle" : "checkmark.circle").accessibilityHidden(true)
                .contentTransition(.symbolEffect(.replace))
            Text(editStatusMessage)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .contentTransition(.interpolate)
                .accessibilityIdentifier("explorer.saveMessage")
                .onChange(of: editStatusMessage) { _, message in
                    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                         userInfo: [.announcement: message,
                                                    .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }
            HStack(spacing: 14) {
                if node.supportsMarkdownPreview && width >= 530 {
                    Text("\(draft.split(whereSeparator: \.isWhitespace).count) words")
                        .contentTransition(.numericText())
                }
                if width >= 530, !node.kind.isEmpty {
                    Text(node.kind.uppercased()).foregroundStyle(Theme.secondaryText)
                }
                if width >= 650 { Text("UTF-8").foregroundStyle(Theme.secondaryText) }
                if saving { LoopSpinner(size: 10).transition(.fadeIn) }
                Text(node.supportsMarkdownPreview && markdownMode == .preview ? "Read only" : "⌘ S")
                    .font(.mono(10)).accessibilityLabel(markdownMode == .preview ? "Read only preview" : "Save, Command-S")
            }
            .font(.system(size: 10)).fixedSize()
        }
        .motion(Motion.reveal, value: editStatusMessage)
        .font(.system(size: 11)).foregroundStyle(dirty ? Theme.attention : Theme.accent)
        .padding(.horizontal, inset).padding(.vertical, 11)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(Theme.statusBand)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func fileDetails(_ node: FileNode) -> some View {
        let current = children[node.url.deletingLastPathComponent().path]?.first { $0.path == node.path } ?? node
        return ExplorerFileDetails(node: current, path: relativePath(node), status: git.statuses[node.path],
                                   text: isEditable ? draft : nil,
                                   copyPath: { copyPath(node) },
                                   openExternally: { openExternally(node) },
                                   revealInFinder: { revealInFinder(node) },
                                   close: { detailsPresented = false })
    }

    private func hasUnsavedEdit(_ node: FileNode) -> Bool {
        selected?.path == node.path ? dirty : documents.edits[node.path] != nil
    }

    private func isPinned(_ node: FileNode) -> Bool {
        let owner = projectRoots.filter { isInside(node.path, $0.root) }.max { $0.root.count < $1.root.count }?.root ?? root
        let pins = owner == root ? documents.pinned : memory.place(for: owner)?.documents.pinned ?? []
        return pins.contains { $0.path == node.path }
    }

    private func togglePin(_ node: FileNode) {
        let owner = projectRoots.filter { isInside(node.path, $0.root) }.max { $0.root.count < $1.root.count }?.root ?? root
        if owner == root {
            documents.togglePin(node)
            rememberPlace()
        } else {
            var place = memory.place(for: owner) ?? ExplorerMemory.Place()
            place.documents.togglePin(node)
            memory.remember(place, for: owner)
        }
    }

    private func closeTab(_ node: FileNode) {
        let close = {
            withAnimation(reduceMotion ? nil : Motion.leave) { documents.close(node.path) }
            if selected?.path == node.path {
                if let next = documents.tabs.last { select(next) }
                else { selected = nil; preview = nil; draft = ""; original = ""; resetFind() }
            }
            rememberPlace()
        }
        if hasUnsavedEdit(node) {
            var dialog = Dialog.confirm("Close unsaved file?", message: "Edits to \(node.name) have not been saved.",
                                        action: "Discard and close", cancel: "Keep editing", handler: close)
            dialog.isModal = true
            dialogs.show(dialog)
        } else { close() }
    }

    private func noteLinkOpened(_ url: URL) {
        if url.isFileURL { openLinkedFile(url); return }
        showNote(url.scheme == "mailto"
                 ? "Opened your mail app"
                 : "Opened \(url.host() ?? "the link") in your browser")
    }

    // A linked file in this project opens here. A folder, or a file outside the project,
    // has no place in the tree, so Finder shows it instead.
    private func openLinkedFile(_ url: URL) {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            showNote("Could not find \(url.lastPathComponent)", icon: "questionmark.folder")
            return
        }
        guard !isFolder.boolValue, url.path.pathRelative(to: root) != nil else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            showNote("Showed \(url.lastPathComponent) in Finder")
            return
        }
        Task {
            let siblings = await FileTree.children(of: url.deletingLastPathComponent(), includeHidden: true)
            if let node = siblings.first(where: { $0.url.standardizedFileURL.path == url.path }) {
                revealAndSelect(node)
            }
        }
    }

    private func bodyKind(_ node: FileNode) -> String {
        switch preview {
        case .text, .empty: "text"
        case .image: "image"
        case .binary: "binary"
        case .tooLarge: "too large"
        case .unreadable: "unreadable"
        case nil: "reading"
        }
    }

    @ViewBuilder private func fileBody(_ node: FileNode) -> some View {
        switch preview {
        case .text, .empty:
            if node.supportsMarkdownPreview {
                MarkdownEditor(documentID: node.path, source: $draft, mode: $markdownMode,
                               basePath: node.url.deletingLastPathComponent().path, onLink: noteLinkOpened,
                               sourceEditor: AnyView(CodeEditorView(documentID: node.path, text: $draft, language: language,
                                                                   matches: findPresented ? findResult.matches : revealedMatches,
                                                                   currentMatch: findPresented ? currentFindMatch : nil,
                                                                   findQuery: findQuery, revealLine: lineToReveal, onFind: showFind)),
                               onOutline: { lineToReveal = $0 }, canEdit: $markdownCanEdit)
            } else {
                CodeEditorView(documentID: node.path,
                               text: $draft,
                               language: language,
                               matches: findPresented ? findResult.matches : revealedMatches,
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
            VStack(spacing: 12) {
                PaneMessage(icon: "exclamationmark.triangle",
                            title: node.isLink ? "Could not follow this link" : "Could not read this file", detail: reason)
                ActionButton(title: "Try again", tone: .outlined, height: 28, size: 12) { select(node) }
            }.padding(20)
        case nil:
            if node.isDirectory {
                PaneMessage(icon: "folder", title: "Folder selected",
                            detail: "Use the left and right arrow keys to close and open folders.")
            } else {
                ChangesProgressLabel(title: "Reading file…").foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
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
        isEditable && dialogs.current == nil
    }

    private var findMonitors: [WindowKeyMonitor] { [findMonitor, commandFindMonitor] }

    private func showFind() {
        guard canFind else { return }
        markdownMode = .source
        withAnimation(reduceMotion ? nil : Motion.reveal) { findPresented = true }
        refreshFind()
        $findFocused.request()
    }

    private func closeFind() {
        withAnimation(reduceMotion ? nil : Motion.leave) { findPresented = false }
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
        revealedMatches = []
    }

    // MARK: - Find dialog

    private var finderIsOpen: Bool {
        finderDialog != nil && dialogs.current?.id == finderDialog
    }

    // The keys pick a mode, and the header's button passes none to reopen the last one.
    // Pressed again while the dialog is open, they switch it to their mode.
    private func showFinder(_ requested: ExplorerSearchMode?) {
        if finderIsOpen, let finder {
            if let requested { finder.show(requested) }
            return
        }
        guard dialogs.current == nil else { return }
        let model = ExplorerFindModel(root: root, includeHidden: showHidden,
                                      mode: requested ?? finderMode, query: finderQuery)
        let dialog = Dialog(
            title: "Find files or text",
            content: AnyView(ExplorerFindDialog(model: model,
                                                open: { openFound($0, query: model.query) },
                                                close: { dialogs.dismiss() })
                .onDisappear { dialogs.restoreFocus() }),
            actions: [],
            onCancel: {
                finderMode = model.mode
                finderQuery = model.query
                finder = nil
                finderDialog = nil
            },
            width: 500, isModal: true, framesItself: true)
        finder = model
        finderDialog = dialog.id
        dialogs.show(dialog)
    }

    private func openFound(_ result: ExplorerFindModel.Result, query: String) {
        dialogs.dismiss()
        focusEditor = false
        collapsedProjects.remove(root)
        switch result {
        case .file(let node): revealAndSelect(node)
        case .line(let match): revealAndSelect(match.file, line: match.line.number, marking: query)
        }
    }

    private func revealAndSelect(_ node: FileNode, line: Int? = nil, marking query: String? = nil) {
        Task {
            for path in FileTree.ancestorDirectories(of: node.url, beneath: rootURL) {
                expanded.insert(path)
                if children[path] == nil { await load(path) }
            }
            requestSelect(node, line: line, marking: query)
            narrowNavigator = false
            treeFocused = true
        }
    }

    private func saveButtons(_ node: FileNode) -> some View {
        HStack(spacing: 8) {
            ActionButton(title: "Revert", tone: .outlined, height: 26, size: 12) { revert() }
                .disabled(!dirty || saving)
            ActionButton(title: "Save", tone: .green, height: 26, size: 12,
                         keyboardShortcut: KeyboardShortcut("s", modifiers: .command)) {
                save(node)
            }
            .disabled(!dirty || saving)
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private func markdownSave(_ node: FileNode) -> some View {
        ZStack {
            if dirty || saving {
                ActionButton(title: saving ? "Saving…" : "Save", tone: .green, height: 30, size: 12,
                             shortcut: saving ? nil : "⌘S",
                             keyboardShortcut: KeyboardShortcut("s", modifiers: .command)) { save(node) }
                    .disabled(!dirty || saving)
                    .accessibilityLabel(saving ? "Saving changes" : "Save changes")
                    .appTooltip("Save changes (Cmd+S)")
                    .transition(.opacity)
            } else {
                Label("Saved", systemImage: "checkmark")
                    .font(.system(size: 12)).foregroundStyle(Theme.accent)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("explorer.saved")
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 82, minHeight: 30)
        .motion(Motion.control, value: dirty || saving)
        .motion(Motion.control, value: saving)
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
        showNote("Copied \(node.name)", icon: "doc.on.doc")
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
                statusRevision += 1
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
        let rememberedEdit = isInside(node.path, root) ? nil : memory.unsavedEdit(inside: node.path)
        let losesEdits = (dirty && selected.map { contains(node, $0.path) } == true)
            || documents.edits.keys.contains { contains(node, $0) } || rememberedEdit != nil
        var rows: [Dialog.Impact.Row] = [.init(title: node.name,
                                             detail: node.isDirectory ? "The folder and its contents move to the Trash." : "The file moves to the Trash.")]
        if losesEdits {
            rows.append(.init(title: "Unsaved edits",
                              detail: node.isDirectory ? "Unsaved edits in this folder are lost." : "Edits to \(node.name) are lost."))
        }
        rows.append(.init(title: node.isDirectory ? "Folder can be restored" : "File can be restored",
                          detail: "Put it back from the Trash in Finder.", kept: true))
        let owner = projectRoots.filter { isInside(node.path, $0.root) }.max { $0.root.count < $1.root.count }
        dialogs.show(.impact("Move \(node.name) to the Trash?", subject: .init(name: owner?.name ?? rootURL.lastPathComponent), rows: rows,
                             warning: losesEdits ? "Unsaved edits cannot be restored from the Trash." : nil,
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

            memory.removed(node.path)
            documents.removed(node.path)
            expanded = expanded.filter { !contains(node, $0) }
            children = children.filter { !contains(node, $0.key) }
            if let selected, contains(node, selected.path) {
                resetFind()
                self.selected = nil
                preview = nil
                loadingPreview = false
                language = nil
                draft = ""
                original = ""
                loadedAt = nil
            }
            await load(node.url.deletingLastPathComponent().path)
            statusRevision += 1
        }
    }

    // Next to what is selected: inside it when it is a folder, beside it when it is a file.
    private func newItemDestination() -> URL {
        guard let selected else { return rootURL }
        return selected.isDirectory ? selected.url : selected.url.deletingLastPathComponent()
    }

    private func create(folder: Bool, in directory: URL) {
        let rootAtStart = root
        dialogs.show(Dialog(title: folder ? "New folder" : "New file",
                            content: AnyView(ExplorerCreateDialog(folder: folder, directory: directory) { url in
            Task {
                guard root == rootAtStart else { return }
                for path in FileTree.ancestorDirectories(of: url, beneath: rootURL) {
                    expanded.insert(path)
                    if children[path] == nil { await load(path) }
                }
                await load(directory.path)
                guard let node = children[directory.path]?.first(where: { $0.path == url.path }) else { return }
                requestSelect(node)
                if folder { expanded.insert(node.path); await load(node.path) }
                await git.refresh(roots: projectRoots.map(\.root))
            }
        }), actions: [], width: 460, isModal: true))
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
        memory.moved(from: old, to: new)
        documents.moved(from: old, to: new)
        expanded = Set(expanded.map { FileTree.path($0, afterMoving: old, to: new) })
        children = children.filter { !isInside($0.key, old) }
        if var current = selected, isInside(current.path, old) {
            current.url = URL(fileURLWithPath: FileTree.path(current.path, afterMoving: old, to: new))
            current.name = current.url.lastPathComponent
            selected = current
            language = CodeLanguage(path: current.name)
        }
        let oldParent = (old as NSString).deletingLastPathComponent
        let newParent = url.deletingLastPathComponent().path
        if oldParent != newParent, children[oldParent] != nil { await load(oldParent) }
        await load(newParent)
        for path in expanded.sorted(by: { $0.count < $1.count })
        where isInside(path, new) {
            await load(path)
        }
        statusRevision += 1
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
        let destinationRoot = projectRoots.filter { isInside(folder.path, $0.root) }
            .max { $0.root.count < $1.root.count }?.root ?? root
        let local = urls.filter { isInside($0.standardizedFileURL.path, destinationRoot) }
        let outside = urls.filter { !isInside($0.standardizedFileURL.path, destinationRoot) }

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
            statusRevision += 1

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

    // Keep the workspace tree open while swapping the editor and its unsaved draft.
    private func openRoot() async {
        rememberPlace()
        openedRoot = root
        let place = memory.place(for: root) ?? ExplorerMemory.Place()
        documents = place.documents
        if let edit = place.unsaved { documents.edits[edit.path] = edit }
        if children.isEmpty {
            for project in projectRoots {
                expanded.formUnion(memory.place(for: project.root)?.expanded ?? [])
            }
        }
        selected = nil
        previewGeneration += 1
        preview = nil
        loadingPreview = false
        language = nil
        draft = ""
        original = ""
        loadedAt = nil
        resetFind()
        showHidden = place.showHidden
        treeWidth = place.treeWidth
        for project in projectRoots { await load(project.root) }
        for path in expanded.sorted(by: { $0.count < $1.count }) { await load(path) }
        await restore(place)
        await showRequestedFile()
    }

    private func showRequestedFile() async {
        guard let request = reveal.wrappedValue,
              request.path.pathRelative(to: root) != nil else { return }
        reveal.wrappedValue = nil
        collapsedProjects.remove(root)

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
        rememberDraft()
        let unsaved = selected.flatMap { documents.edits[$0.path] }
        for project in projectRoots where project.root != openedRoot {
            var place = memory.place(for: project.root) ?? ExplorerMemory.Place()
            place.expanded = Set(expanded.filter { isInside($0, project.root) })
            memory.remember(place, for: project.root)
        }
        memory.remember(.init(expanded: Set(expanded.filter { isInside($0, openedRoot) }),
                              selected: selected,
                              showHidden: showHidden,
                              treeWidth: treeWidth,
                              unsaved: unsaved,
                              documents: documents),
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
        documents.tabs.removeAll { !fileManager.fileExists(atPath: $0.path) && documents.edits[$0.path] == nil }
        guard !Task.isCancelled, let node = place.selected,
              fileManager.fileExists(atPath: node.path) || documents.edits[node.path] != nil else { return }
        select(node)
    }

    // `unfolding` is set when the folder is being opened by hand, so rows read for the
    // first time fold in, while a refresh changes the list without moving anything.
    private func load(_ path: String, unfolding: Bool = false) async {
        loadingFolders.insert(path)
        let listing = await FileTree.listing(of: URL(fileURLWithPath: path), includeHidden: showHidden)
        loadingFolders.remove(path)
        guard !Task.isCancelled else { return }
        folderErrors[path] = listing.error
        guard listing.error == nil else { return }
        withAnimation(unfolding && children[path] == nil ? treeMotion(opening: true) : nil) {
            children[path] = listing.nodes
        }
        for entry in listing.nodes where entry.isDirectory && !entry.isLink {
            var node = entry
            var chain: [String] = []
            // Follow only single-child folders. Links keep their own row and cannot form a cycle.
            for _ in 0..<32 {
                guard !Task.isCancelled else { return }
                chain.append(node.path)
                let nested = await FileTree.listing(of: node.url, includeHidden: showHidden)
                guard !Task.isCancelled else { return }
                folderErrors[node.path] = nested.error
                guard nested.error == nil else { break }
                children[node.path] = nested.nodes
                guard nested.nodes.count == 1, let child = nested.nodes.first,
                      child.isDirectory, !child.isLink else { break }
                node = child
            }
            if chain.contains(where: expanded.contains) { expanded.insert(node.path) }
        }
    }

    private func reopenFolders() async {
        for path in (projectRoots.map(\.root) + expanded) {
            await load(path)
        }
        statusRevision += 1
    }

    private func toggle(_ node: FileNode) {
        if expanded.contains(node.path) {
            collapseFolder(node.path)
        } else {
            withAnimation(treeMotion(opening: true)) { _ = expanded.insert(node.path) }
            Task { await load(node.path, unfolding: true) }
        }
    }

    private func treeMotion(opening: Bool) -> Animation? {
        reduceMotion ? nil : opening ? Motion.reveal : Motion.leave
    }

    private func collapseFolder(_ path: String) {
        withAnimation(treeMotion(opening: false)) {
            expanded.subtract(rows.first(where: { $0.id == path })?.compactPaths ?? [path])
        }
    }

    private var openFolderCount: Int {
        rows.filter { $0.node.isDirectory && expanded.contains($0.node.path) }.count
    }

    // The deepest open level shuts first and each level above follows a beat later, so
    // the tree folds up rather than snapping shut. Folders left open inside closed ones
    // are shut at the end too, so nothing springs open again later.
    private func collapseAllFolders() {
        guard !reduceMotion else { expanded = []; return }
        let open = rows.filter { $0.node.isDirectory && expanded.contains($0.node.path) }
        let levels = Dictionary(grouping: open, by: \.depth).sorted { $0.key > $1.key }.map(\.value)
        Task {
            for (index, level) in levels.enumerated() {
                if index > 0 { try? await Task.sleep(for: .milliseconds(110)) }
                withAnimation(Motion.leave) { expanded.subtract(level.flatMap(\.compactPaths)) }
            }
            expanded = []
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
            let cursor = projectCursor ?? selected?.path
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
            collapseFolder(path)
        }
    }

    // Each open file keeps its own draft, so moving through the tree never discards edits.
    private func requestSelect(_ node: FileNode, line: Int? = nil, marking query: String? = nil) {
        if let owner = projectRoots.filter({ isInside(node.path, $0.root) }).max(by: { $0.root.count < $1.root.count }),
           owner.root != root {
            reveal.wrappedValue = ExplorerReveal(path: node.path, line: line)
            selectRoot(owner.root)
            return
        }
        if node.path == selected?.path {
            narrowNavigator = node.isDirectory
            if let line {
                markdownMode = .source
                lineToReveal = line
                if let query, !findPresented {
                    revealedMatches = FileTextSearch.hits(of: query, onLine: line, in: draft)
                }
            }
            return
        }
        rememberDraft()
        select(node, line: line, marking: query)
        narrowNavigator = node.isDirectory
    }

    private func rememberDraft() {
        guard let selected, !selected.isDirectory else { return }
        documents.modes[selected.path] = markdownMode
        if dirty, let preview {
            documents.edits[selected.path] = .init(path: selected.path, preview: preview, draft: draft,
                                                   original: original, loadedAt: loadedAt)
        } else {
            documents.edits.removeValue(forKey: selected.path)
        }
    }

    private func revert() {
        let discard = {
            draft = original
            if let selected {
                documents.edits.removeValue(forKey: selected.path)
                saveErrors.removeValue(forKey: selected.path)
            }
            rememberPlace()
        }
        if let selected, selected.supportsMarkdownPreview {
            var dialog = Dialog.confirm("Revert your changes?",
                                        message: "Unsaved edits to \(selected.name) will be replaced with the last saved version.",
                                        action: "Revert changes", cancel: "Keep editing", handler: discard)
            dialog.isModal = true
            dialogs.show(dialog)
        } else {
            confirmDiscard(then: discard)
        }
    }

    private func confirmDiscard(then discard: @escaping () -> Void) {
        dialogs.show(.confirm("Discard changes?",
                              message: "Edits to \(selected?.name ?? "this file") have not been saved.",
                              action: "Discard", cancel: "Keep editing", handler: discard))
    }

    private func save(_ node: FileNode) {
        guard dirty, !saving else { return }
        let saved = draft
        let expectedModification = loadedAt
        saving = true
        Task {
            let modified = await FileTree.modified(of: node.url)
            guard selected?.path == node.path else { saving = false; return }
            guard modified == expectedModification else {
                saving = false
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
        let writtenRoot = openedRoot ?? root
        saving = true
        Task {
            defer { saving = false }
            let failure = await FileTree.write(saved, to: node.url)
            if let failure {
                saveErrors[node.path] = failure
                announceEditorStatus("Could not save \(node.name). Your edits are still here. Retry or export a copy.")
                return
            }
            saveErrors.removeValue(forKey: node.path)
            let modified = await FileTree.modified(of: node.url)
            let fresh = await FileTree.children(of: node.url.deletingLastPathComponent(), includeHidden: true)
                .first(where: { $0.path == node.path })
            if openedRoot == writtenRoot {
                if selected?.path == node.path {
                    original = saved
                    fileWasSaved = draft == saved
                    loadedAt = modified
                    if let fresh { selected = fresh }
                    rememberDraft()
                } else if let edit = documents.edits[node.path] {
                    documents.edits[node.path] = edit.draft == saved ? nil
                        : .init(path: edit.path, preview: edit.preview, draft: edit.draft, original: saved, loadedAt: modified)
                }
                rememberPlace()
                await reopenFolders()
            } else if var place = memory.place(for: writtenRoot), let edit = place.documents.edits[node.path] {
                place.documents.edits[node.path] = edit.draft == saved ? nil
                    : .init(path: edit.path, preview: edit.preview, draft: edit.draft, original: saved, loadedAt: modified)
                place.unsaved = place.selected.flatMap { place.documents.edits[$0.path] }
                memory.remember(place, for: writtenRoot)
            }
        }
    }

    private func select(_ node: FileNode, line: Int? = nil, marking query: String? = nil) {
        previewGeneration += 1
        let generation = previewGeneration
        resetFind()
        selected = node
        markdownMode = line == nil ? documents.modes[node.path] ?? .edit : .source
        fileWasSaved = false
        documents.open(node)
        lineToReveal = line
        preview = nil
        language = nil
        draft = ""
        original = ""
        loadedAt = nil
        guard !node.isDirectory else {
            loadingPreview = false
            return
        }
        if let edit = documents.edits[node.path] {
            preview = edit.preview
            draft = edit.draft
            original = edit.original
            loadedAt = edit.loadedAt
            language = CodeLanguage(path: node.name)
            loadingPreview = false
            if let query, let line { revealedMatches = FileTextSearch.hits(of: query, onLine: line, in: draft) }
            return
        }
        loadingPreview = true
        Task {
            let modified = await FileTree.modified(of: node.url)
            let loaded = await FileTree.preview(of: node.url)
            guard !Task.isCancelled, selected?.path == node.path, previewGeneration == generation else { return }
            loadingPreview = false
            preview = loaded
            loadedAt = modified
            language = CodeLanguage(path: node.name)
            if case .text(let text) = loaded {
                draft = text
                original = text
                if let query, let line {
                    revealedMatches = FileTextSearch.hits(of: query, onLine: line, in: text)
                }
            }
        }
    }
}
