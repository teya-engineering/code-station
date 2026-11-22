import AppKit
import SwiftUI

// Says that a pane with a find of its own, a file or the chat, has taken the key the
// sidebar's filter is on. It travels up to the window so the sidebar can stop naming that
// key as the way into its own filter while the pane answers for it.
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

// Every file in a session's folder, as a tree with the file itself beside it. Changes only
// covers what git has something to say about; this is the whole working tree, which is
// what you want when the agent names a file you have never opened.
//
// A text file opens straight into an editor: there is no read mode to leave first, and
// nothing is written until Save. The tree itself can create, copy, paste, rename, drag to
// move and move items to the Trash.
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
    @State var projectCursor: String?
    // A click already highlights the row it picks, so the cursor ring only shows while
    // the keyboard is driving the tree.
    @State var treeCursorVisible = false

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

    var projectRoots: [ChangesRepository] {
        repositories.isEmpty ? [ChangesRepository(root: root, name: rootURL.lastPathComponent)] : repositories
    }

    // The deepest project holding the path, since one project can sit inside another.
    func project(owning path: String) -> ChangesRepository? {
        projectRoots.filter { path.isInside($0.root) }.max { $0.root.count < $1.root.count }
    }

    @Environment(DialogPresenter.self) var dialogs
    @Environment(ExplorerMemory.self) var memory
    @Environment(MenuPresenter.self) private var menus
    @State var markdownOnly = false
    @State var markdownCanEdit = true

    @State var tree = ExplorerTree()
    @State var editor = ExplorerEditor()
    @State private var ownShowHidden = true
    @State var pastingFiles = false
    @State private var treeWidth = ExplorerSplitLayout.defaultTreeWidth
    @State var git = ExplorerGitStatus()
    @State var focusEditor = false
    @State var narrowNavigator = false
    @State var detailsPresented = false
    @Namespace var tabUnderline
    // A click whose work happens outside the window, such as opening Finder, moves
    // nothing in it, so a short note is all the window shows of it.
    @State private var note = TransientNote(duration: .seconds(1.9))
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.keyBindings) var keyBindings
    @Environment(\.showExternalNote) var showExternalNote
    @Environment(\.openShell) var openShell
    @FocusState var treeFocused: Bool
    // The row being renamed, by path. The name is edited in place, the way Finder does it.
    @State var renaming: String?
    @State var renameDraft = ""
    @State var renameSelection: TextSelection?
    @State var renameCancelled = false
    @FocusState var renameFocused: Bool
    // What a drag is over, and the folder a drop there would land in. A file row hands the
    // drop to the folder it sits in, so that folder is what lights up.
    @State var dropHover: DropHover?

    struct DropHover: Equatable {
        let key: String
        let folder: String
    }

    // Both of the strokes a person tries for find. Cmd+F searches whatever is being read
    // on a Mac, and with a file open that is the file rather than the sidebar's filter.
    // They are caught with monitors because a SwiftUI shortcut is only offered the stroke
    // after the window's own shortcuts have had it, and the sidebar's filter takes Cmd+F.
    @State private var findMonitor = WindowKeyMonitor(.control, "f")
    @State private var commandFindMonitor = WindowKeyMonitor(AppCommand.findInFile.info.keys)
    @FocusState private var findFocused: Bool
    // Cmd+H hides the app on a Mac, so find in files takes Ctrl+H, next to Ctrl+F.
    @State private var findInFilesMonitor = WindowKeyMonitor(AppCommand.findInFiles.info.keys)
    @State private var escapeMonitor = WindowKeyMonitor([], "\u{1b}")
    // Closes the file in front, the way Cmd+W closes a tab in an editor. With no file
    // open the stroke goes on to close the window as usual.
    @State private var closeTabMonitor = WindowKeyMonitor(.command, "w")
    // The Find dialog while it is open, and what it held when it was last closed, so the
    // next opening starts from the same mode and query.
    @State private var finder: ExplorerFindModel?
    @State private var finderDialog: UUID?
    @State private var finderMode = ExplorerSearchMode.names
    @State private var finderQuery = ""

    var rootURL: URL { URL(fileURLWithPath: root) }

    private var showHiddenBinding: Binding<Bool> { sharedShowHidden ?? $ownShowHidden }

    var showHidden: Bool {
        get { showHiddenBinding.wrappedValue }
        nonmutating set {
            showHiddenBinding.wrappedValue = newValue
            tree.showHidden = newValue
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let sideBySide = geometry.size.width >= ExplorerSplitLayout.minimumSplitWidth
            let showsTree = !focusEditor && (sideBySide || editor.selected == nil || narrowNavigator)
            let width = sideBySide
                ? ExplorerSplitLayout.treeWidth(treeWidth, availableWidth: geometry.size.width, keepsDetailMinimum: true)
                : min(ExplorerSplitLayout.defaultTreeWidth, geometry.size.width)

            HStack(spacing: 0) {
                if showsTree && sideBySide {
                    treePane.frame(width: width).clipped()
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
                        treePane.frame(width: width).background(Theme.background)
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
        .headerNote(note, top: 50, trailing: Space.lg)
        .background(ExplorerSearchShortcut { showFinder(.names) })
        .background(ExplorerFileShortcuts(
            enabled: treeFocused && projectCursor == nil && dialogs.current == nil && !pastingFiles,
            onCopy: copySelected,
            onPaste: { pasteFiles(at: editor.selected) },
            onTrash: trashSelected,
            onRename: renameSelected))
        .background(WindowAnchor(monitor: findMonitor))
        .background(WindowAnchor(monitor: commandFindMonitor).keyMonitor(commandFindMonitor, follows: .findInFile))
        .background(WindowAnchor(monitor: findInFilesMonitor).keyMonitor(findInFilesMonitor, follows: .findInFiles))
        .background(WindowAnchor(monitor: escapeMonitor))
        .background(WindowAnchor(monitor: closeTabMonitor))
        .onAppear {
            closeTabMonitor.start {
                guard dialogs.current == nil, renaming == nil else { return false }
                guard
                      let open = editor.documents.tabs.first(where: { $0.path == editor.selected?.path }) ?? editor.documents.tabs.last
                else { return false }
                closeTab(open)
                return true
            }
            escapeMonitor.start {
                guard dialogs.current == nil, renaming == nil else { return false }
                if detailsPresented { detailsPresented = false; return true }
                if editor.find.presented { closeFind(); return true }
                if focusEditor || narrowNavigator { focusEditor = false; narrowNavigator = false; return true }
                return false
            }
        }
        .preference(key: PaneFindShortcutKey.self,
                    value: canFind && keyBindings.takes(.filterSidebar, from: .findInFile))
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
        .onChange(of: editor.find.query) {
            editor.find.selection = 0
            editor.refreshFind()
        }
        // A file swap or a closed tab puts the bar away without a click on it, and the
        // caret must not stay behind in a field that has gone.
        .onChange(of: editor.find.presented) { _, presented in
            if !presented { findFocused = false }
        }
        .onChange(of: editor.draft) { editor.draftChanged() }
        .onChange(of: editor.markdownMode) { _, mode in
            if let selected = editor.selected { editor.documents.modes[selected.path] = mode }
            if mode != .source { editor.find = ExplorerFileFind() }
        }
        .onChange(of: showHidden) { _, shown in
            tree.showHidden = shown
            Task { await reopenFolders() }
        }
        .onChange(of: openFolderCount, initial: true) { _, count in openFolders?.wrappedValue = count }
        .task(id: projectRoots.map(\.root) + [String(tree.statusRevision)]) {
            await git.refresh(roots: projectRoots.map(\.root))
        }
        .onChange(of: command?.wrappedValue) { _, requested in
            guard let requested else { return }
            command?.wrappedValue = nil
            perform(requested)
        }
        .task(id: root) { await openRoot() }
        .onChange(of: reveal.wrappedValue) {
            if editor.root == root { Task { await showRequestedFile() } }
        }
    }

    // The dimmed layer behind a panel that covers the pane.
    var scrim: AnyTransition {
        .asymmetric(insertion: .opacity.animation(Motion.reveal), removal: .opacity.animation(Motion.leave))
    }

    // A small mark landing on a row or a tab, such as the dot for unsaved edits.
    var markLands: AnyTransition {
        reduceMotion
            ? .opacity.animation(Motion.reveal)
            : .scale(scale: 0.5).combined(with: .opacity).animation(Motion.pop)
    }

    func showNote(_ text: String, icon: String = "arrow.up.forward.app") {
        note.show(text, icon: icon)
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
                refreshed(projectRoots.reduce(0) { $0 + (tree.children[$1.root]?.count ?? 0) })
            }
        }
    }

    // Next to what is selected: inside it when it is a folder, beside it when it is a file.
    private func newItemDestination() -> URL {
        guard let selected = editor.selected else { return rootURL }
        return selected.isDirectory ? selected.url : selected.url.deletingLastPathComponent()
    }

    // MARK: - Find

    var findBar: some View {
        FindBar(placeholder: "Find in file",
                query: $editor.find.query,
                summary: FindSummary.text(query: editor.find.query,
                                          matchCount: editor.find.result.matches.count,
                                          hasMore: editor.find.result.hasMore,
                                          selection: editor.find.selection),
                hasMatches: !editor.find.result.matches.isEmpty,
                focused: $findFocused,
                move: { editor.find.move(by: $0) },
                close: closeFind)
    }

    // A file worth searching is open and nothing is in front of it. While this is false
    // both strokes are left alone, so Cmd+F still opens the sidebar's filter.
    var canFind: Bool {
        editor.isEditable && dialogs.current == nil
    }

    private var findMonitors: [WindowKeyMonitor] { [findMonitor, commandFindMonitor] }

    func showFind() {
        guard canFind else { return }
        editor.markdownMode = .source
        withAnimation(reduceMotion ? nil : Motion.reveal) { editor.find.presented = true }
        editor.refreshFind()
        $findFocused.request()
    }

    private func closeFind() {
        withAnimation(reduceMotion ? nil : Motion.leave) { editor.find.presented = false }
        findFocused = false
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

    func revealAndSelect(_ node: FileNode, line: Int? = nil, marking query: String? = nil) {
        Task {
            await tree.openFolders(leadingTo: node.url, beneath: rootURL)
            requestSelect(node, line: line, marking: query)
            narrowNavigator = false
            treeFocused = true
        }
    }

    // MARK: - Opening a folder

    // Keep the workspace tree open while swapping the editor and its unsaved draft.
    private func openRoot() async {
        rememberPlace()
        let place = memory.place(for: root) ?? ExplorerMemory.Place()
        var documents = place.documents
        if let edit = place.unsaved { documents.edits[edit.path] = edit }
        editor.open(root, documents: documents)
        if tree.children.isEmpty {
            for project in projectRoots {
                tree.expanded.formUnion(memory.place(for: project.root)?.expanded ?? [])
            }
        }
        showHidden = place.showHidden
        treeWidth = place.treeWidth
        for project in projectRoots { await tree.load(project.root) }
        for path in tree.expanded.sorted(by: { $0.count < $1.count }) { await tree.load(path) }
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
        await tree.openFolders(leadingTo: url, beneath: rootURL)
        guard !Task.isCancelled,
              let node = tree.children[ancestors.last ?? root]?.first(where: { $0.path == url.path })
        else { return }
        requestSelect(node, line: request.line)
        treeFocused = true
    }

    func rememberPlace() {
        guard let openedRoot = editor.root else { return }
        editor.rememberDraft()
        let unsaved = editor.selected.flatMap { editor.documents.edits[$0.path] }
        for project in projectRoots where project.root != openedRoot {
            var place = memory.place(for: project.root) ?? ExplorerMemory.Place()
            place.expanded = Set(tree.expanded.filter { $0.isInside(project.root) })
            memory.remember(place, for: project.root)
        }
        memory.remember(.init(expanded: Set(tree.expanded.filter { $0.isInside(openedRoot) }),
                              selected: editor.selected,
                              showHidden: showHidden,
                              treeWidth: treeWidth,
                              unsaved: unsaved,
                              documents: editor.documents),
                        for: openedRoot)
    }

    // Folders and files may have gone while the pane was away, so only what is still on
    // disk is opened again. Parents are read before their children.
    private func restore(_ place: ExplorerMemory.Place) async {
        let fileManager = FileManager.default
        for path in place.expanded.sorted(by: { $0.count < $1.count })
        where fileManager.fileExists(atPath: path) {
            guard !Task.isCancelled else { return }
            tree.expanded.insert(path)
            await tree.load(path)
        }
        editor.documents.tabs.removeAll { !fileManager.fileExists(atPath: $0.path) && editor.documents.edits[$0.path] == nil }
        guard !Task.isCancelled, let node = place.selected,
              fileManager.fileExists(atPath: node.path) || editor.documents.edits[node.path] != nil else { return }
        editor.select(node)
    }

    func reopenFolders() async {
        await tree.reopenFolders(roots: projectRoots.map(\.root))
    }

    func requestSelect(_ node: FileNode, line: Int? = nil, marking query: String? = nil) {
        if let owner = project(owning: node.path), owner.root != root {
            reveal.wrappedValue = ExplorerReveal(path: node.path, line: line)
            selectRoot(owner.root)
            return
        }
        editor.show(node, line: line, marking: query)
        narrowNavigator = node.isDirectory
    }
}
