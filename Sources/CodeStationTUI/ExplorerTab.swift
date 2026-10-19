import CodeStationCore
import Foundation
import TerminalKit
import TerminalTranscript

// The open session's checkout as a tab, as the GUI's Explorer: a tree read a folder at a
// time, file name search (`/`), find in files (`F`), a file handed to `$EDITOR` (Enter or
// `e`), and creating (`n`, `N`), renaming (`R`) and trashing (`D`) files. Everything is
// read from and done by the station; the editor runs on this terminal, in the checkout.
@MainActor
final class ExplorerTab: SessionTabScreen {
    private let context: SessionTabContext

    // The session's working directory on the host, once the root has been read.
    private var root: String?
    // Each folder read so far, by its path relative to the root ("" for the root).
    private var folders: [String: [RemoteFileEntry]] = [:]
    private var expanded: Set<String> = []
    private var selectedPath: String?
    private var top = 0
    private var loading = true
    // Said on the help line until the next key, such as why a rename was refused.
    private var notice: String?

    private enum Mode {
        case tree
        // File name search, as it is typed.
        case names
        // Find in files, run on Enter.
        case find
        // A name being typed for a new file or folder, or for a rename.
        case naming(Naming)
    }

    private enum Naming {
        case newFile(in: String)
        case newFolder(in: String)
        case rename(RemoteFileEntry)
    }

    private var mode = Mode.tree
    private var field = ComposerView()
    private var nameResults: [RemoteFileEntry] = []
    private var findResult: RemoteFindInFiles?
    private var searching = false
    private var resultIndex = 0
    private var resultTop = 0
    private var confirmation: (view: ImpactConfirmation, path: String)?
    private var tasks: [Task<Void, Never>] = []
    private var search: Task<Void, Never>?

    init(_ context: SessionTabContext) {
        self.context = context
        reload()
    }

    var place: KeyBindings.Place {
        if confirmation != nil { return .confirmation }
        if case .tree = mode { return .explorer }
        return .explorerTyping
    }

    var takesTyping: Bool {
        if confirmation != nil { return true }
        if case .tree = mode { return false }
        return true
    }

    func close() {
        tasks.forEach { $0.cancel() }
        search?.cancel()
    }

    // MARK: - Reading

    private func run(_ body: @escaping @MainActor (ExplorerTab) async -> Void) {
        tasks.removeAll { $0.isCancelled }
        tasks.append(context.work { [weak self] in
            guard let self else { return }
            await body(self)
            guard !Task.isCancelled else { return }
            self.context.repaint()
        })
    }

    // Reads the root and every open folder again, keeping the selection where it can.
    private func reload() {
        loading = true
        let open = [""] + expanded.sorted()
        run { tab in
            for path in open {
                await tab.read(path)
            }
            tab.loading = false
            tab.fixSelection()
        }
    }

    // Reads one folder. A folder that has gone is dropped from the open ones.
    private func read(_ path: String) async {
        do throws(StationRefusal) {
            let folder = try await context.commands.readFolder(context.sessionID, path: path)
            root = folder.root
            folders[path] = folder.entries
        } catch {
            folders[path] = nil
            expanded.remove(path)
            if path.isEmpty { notice = error.message }
        }
    }

    // MARK: - The tree's rows

    private struct Row {
        let entry: RemoteFileEntry
        let depth: Int
    }

    private var rows: [Row] {
        var rows: [Row] = []
        func add(_ path: String, depth: Int) {
            for entry in folders[path] ?? [] {
                rows.append(Row(entry: entry, depth: depth))
                if entry.isDirectory, expanded.contains(entry.path) { add(entry.path, depth: depth + 1) }
            }
        }
        add("", depth: 0)
        return rows
    }

    private func fixSelection() {
        let rows = rows
        if let selectedPath, rows.contains(where: { $0.entry.path == selectedPath }) { return }
        // A path that went keeps the selection near where it was: its folder, else the top.
        var parent = selectedPath.map { ($0 as NSString).deletingLastPathComponent }
        while let folder = parent, !folder.isEmpty {
            if rows.contains(where: { $0.entry.path == folder }) {
                selectedPath = folder
                return
            }
            parent = (folder as NSString).deletingLastPathComponent
        }
        selectedPath = rows.first?.entry.path
    }

    private var selected: RemoteFileEntry? {
        rows.first { $0.entry.path == selectedPath }?.entry
    }

    // The folder a new file goes in: the picked folder, or the picked file's folder.
    private var targetFolder: String {
        guard let selected else { return "" }
        return selected.isDirectory ? selected.path : (selected.path as NSString).deletingLastPathComponent
    }

    // MARK: - Keys

    func handle(_ key: Key, rows height: Int) -> SessionTabOutcome {
        notice = nil
        if confirmation != nil { return handleInConfirmation(key) }
        switch mode {
        case .tree: return handleInTree(key, height: height)
        case .names: return handleInNames(key)
        case .find: return handleInFind(key)
        case .naming(let naming): return handleInNaming(key, naming)
        }
    }

    private func handleInTree(_ key: Key, height: Int) -> SessionTabOutcome {
        let page = max(height - 4, 1)
        switch key {
        case .escape, .char("q", []): return .back
        case .up, .char("k", []), .char("p", .ctrl): navigate(.up)
        case .down, .char("j", []), .char("n", .ctrl): navigate(.down)
        case .right, .char("l", []): navigate(.right)
        case .left, .char("h", []): navigate(.left)
        case .pageUp, .char("b", []), .char("u", .ctrl): step(by: -page)
        case .pageDown, .char(" ", []), .char("f", []): step(by: page)
        case .home, .char("g", []): selectedPath = rows.first?.entry.path
        case .end, .char("G", []), .char("G", .shift): selectedPath = rows.last?.entry.path
        case .enter([]):
            guard let selected else { break }
            if selected.isDirectory {
                navigate(expanded.contains(selected.path) ? .left : .right)
            } else {
                openInEditor(selected.path)
            }
        case .char("e", []):
            if let selected, !selected.isDirectory { openInEditor(selected.path) }
        case .char("r", []): reload()
        case .char("/", []):
            mode = .names
            field.clear()
            nameResults = []
            resultIndex = 0
            resultTop = 0
        case .char("F", []), .char("F", .shift), .char("f", .ctrl):
            mode = .find
            field.clear()
            findResult = nil
            resultIndex = 0
            resultTop = 0
        case .char("n", []):
            mode = .naming(.newFile(in: targetFolder))
            field.clear()
        case .char("N", []), .char("N", .shift):
            mode = .naming(.newFolder(in: targetFolder))
            field.clear()
        case .char("R", []), .char("R", .shift):
            guard let selected else { break }
            mode = .naming(.rename(selected))
            field.replace(with: selected.name)
        case .char("D", []), .char("D", .shift), .delete:
            guard let selected else { break }
            confirmTrash(selected)
        default: return .ignored
        }
        return .handled
    }

    private func step(by offset: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.entry.path == selectedPath } ?? 0
        selectedPath = rows[min(max(index + offset, 0), rows.count - 1)].entry.path
    }

    // The GUI tree's arrow rules (`FileTreeNavigation`): right opens a folder or steps
    // into it, left folds it or steps out to its parent.
    private func navigate(_ direction: FileTreeNavigation.Direction) {
        let navigation = rows.map {
            FileTreeNavigation.Row(path: $0.entry.path, isDirectory: $0.entry.isDirectory, depth: $0.depth)
        }
        switch FileTreeNavigation.action(for: direction, selectedPath: selectedPath, rows: navigation,
                                         expanded: expanded) {
        case .select(let path)?: selectedPath = path
        case .collapse(let path)?: expanded.remove(path)
        case .expand(let path)?: expand(path)
        case nil: break
        }
    }

    private func expand(_ path: String) {
        expanded.insert(path)
        guard folders[path] == nil else { return }
        run { tab in await tab.read(path) }
    }

    // Opens every folder above `path` and picks it.
    private func reveal(_ path: String) async {
        var folder = ""
        for part in (path as NSString).deletingLastPathComponent.split(separator: "/") {
            folder = folder.isEmpty ? String(part) : folder + "/" + part
            expanded.insert(folder)
            if folders[folder] == nil { await read(folder) }
        }
        let parent = (path as NSString).deletingLastPathComponent
        await read(parent)
        selectedPath = path
    }

    // MARK: - The editor

    // `$VISUAL`, else `$EDITOR`, else vi, on the file, in the checkout. An editor known
    // to take `+line` is opened at the line given.
    private func openInEditor(_ path: String, line: Int? = nil) {
        guard let root else { return }
        let configured = context.environment["VISUAL"].flatMap { $0.isBlank ? nil : $0 }
            ?? context.environment["EDITOR"].flatMap { $0.isBlank ? nil : $0 } ?? "vi"
        let editor = configured.split(separator: " ").map(String.init)
        let name = ((editor.first ?? "vi") as NSString).lastPathComponent
        var arguments = editor
        if let line, Self.editorsTakingLine.contains(name) { arguments.append("+\(line)") }
        arguments.append(root + "/" + path)
        let handoff = Handoff(arguments: arguments, directory: root)
        run { tab in
            guard let status = await tab.context.handoff(handoff) else {
                tab.notice = "No editor can be started from here."
                return
            }
            if status < 0 { tab.notice = "\(name) could not be started." }
            // The editor may have made or removed files.
            for folder in [""] + tab.expanded.sorted() { await tab.read(folder) }
            tab.fixSelection()
        }
    }

    private static let editorsTakingLine: Set<String> = [
        "vi", "vim", "nvim", "nano", "emacs", "emacsclient", "micro", "kak", "mg", "joe", "ne",
    ]

    // MARK: - File name search

    private func handleInNames(_ key: Key) -> SessionTabOutcome {
        switch key {
        case .escape:
            search?.cancel()
            mode = .tree
        case .up, .char("p", .ctrl): moveResult(by: -1, count: nameResults.count)
        case .down, .char("n", .ctrl): moveResult(by: 1, count: nameResults.count)
        case .enter([]):
            guard nameResults.indices.contains(resultIndex) else { break }
            let entry = nameResults[resultIndex]
            mode = .tree
            run { tab in await tab.reveal(entry.path) }
            if !entry.isDirectory { openInEditor(entry.path) }
        default:
            guard edit(key) else { return .handled }
            searchNames()
        }
        return .handled
    }

    private func searchNames() {
        search?.cancel()
        let query = field.string, id = context.sessionID, commands = context.commands
        guard !query.isBlank else {
            nameResults = []
            return
        }
        searching = true
        search = context.work { [weak self] in
            let found = try? await commands.searchFileNames(id, query: query)
            guard let self, !Task.isCancelled, case .names = self.mode, self.field.string == query else { return }
            self.searching = false
            self.nameResults = found ?? []
            self.resultIndex = 0
            self.resultTop = 0
            self.context.repaint()
        }
    }

    // MARK: - Find in files

    // One row of the results: a file's path, or one of its lines.
    private enum FoundRow {
        case file(String)
        case line(path: String, RemoteFindInFiles.Line)
    }

    private var foundRows: [FoundRow] {
        (findResult?.files ?? []).flatMap { file in
            [FoundRow.file(file.path)] + file.lines.map { FoundRow.line(path: file.path, $0) }
        }
    }

    // The lines alone, which are what the selection moves through.
    private var foundLines: [(path: String, line: RemoteFindInFiles.Line)] {
        (findResult?.files ?? []).flatMap { file in file.lines.map { (file.path, $0) } }
    }

    private func handleInFind(_ key: Key) -> SessionTabOutcome {
        switch key {
        case .escape:
            search?.cancel()
            mode = .tree
        case .up, .char("p", .ctrl): moveResult(by: -1, count: foundLines.count)
        case .down, .char("n", .ctrl): moveResult(by: 1, count: foundLines.count)
        case .enter([]):
            if findResult?.query != field.string {
                find()
            } else if foundLines.indices.contains(resultIndex) {
                let found = foundLines[resultIndex]
                openInEditor(found.path, line: found.line.number)
            }
        default:
            _ = edit(key)
        }
        return .handled
    }

    private func find() {
        search?.cancel()
        let query = field.string, id = context.sessionID, commands = context.commands
        guard !query.isBlank else { return }
        searching = true
        search = context.work { [weak self] in
            let result: RemoteFindInFiles?
            let refusal: String?
            do throws(StationRefusal) {
                result = try await commands.findInFiles(id, query: query)
                refusal = nil
            } catch {
                result = nil
                refusal = error.message
            }
            guard let self, !Task.isCancelled, case .find = self.mode else { return }
            self.searching = false
            self.findResult = result
            self.notice = refusal
            self.resultIndex = 0
            self.resultTop = 0
            self.context.repaint()
        }
    }

    private func moveResult(by offset: Int, count: Int) {
        guard count > 0 else { return }
        resultIndex = min(max(resultIndex + offset, 0), count - 1)
    }

    // A key typed into the one-line field. False when it changed nothing.
    private func edit(_ key: Key) -> Bool {
        switch key {
        case .enter, .char("j", .ctrl), .up, .down: return false
        case .paste(let text):
            return field.handle(.paste(text.split(whereSeparator: \.isNewline).joined())) != .ignored
        default:
            return field.handle(key) != .ignored
        }
    }

    // MARK: - Naming

    private func handleInNaming(_ key: Key, _ naming: Naming) -> SessionTabOutcome {
        switch key {
        case .escape: mode = .tree
        case .enter([]): submit(naming, name: field.string)
        default: _ = edit(key)
        }
        return .handled
    }

    private func submit(_ naming: Naming, name: String) {
        let id = context.sessionID, commands = context.commands
        run { tab in
            do throws(StationRefusal) {
                let entry: RemoteFileEntry
                switch naming {
                case .newFile(let folder):
                    entry = try await commands.createFile(id, in: folder, name: name, isFolder: false)
                case .newFolder(let folder):
                    entry = try await commands.createFile(id, in: folder, name: name, isFolder: true)
                case .rename(let old):
                    entry = try await commands.renameFile(id, path: old.path, to: name)
                    if old.isDirectory, tab.expanded.remove(old.path) != nil { tab.expanded.insert(entry.path) }
                }
                tab.mode = .tree
                await tab.reveal(entry.path)
            } catch {
                // The name stays, to be put right.
                tab.notice = error.message
            }
        }
    }

    // MARK: - Trash

    private func confirmTrash(_ entry: RemoteFileEntry) {
        let view = ImpactConfirmation(
            "Move \(entry.name) to the Trash?",
            rows: [.init(entry.isDirectory ? "Folder can be restored" : "File can be restored",
                         "Put it back from the Trash in Finder.", kept: true)],
            action: "Move to Trash")
        confirmation = (view, entry.path)
    }

    private func handleInConfirmation(_ key: Key) -> SessionTabOutcome {
        guard var open = confirmation else { return .ignored }
        let outcome = open.view.handle(key)
        confirmation = open
        switch outcome {
        case .handled, .ignored: break
        case .cancel: confirmation = nil
        case .confirm:
            confirmation = nil
            let id = context.sessionID, commands = context.commands, path = open.path
            run { tab in
                do throws(StationRefusal) {
                    try await commands.trashFile(id, path: path)
                } catch {
                    tab.notice = error.message
                }
                await tab.read((path as NSString).deletingLastPathComponent)
                tab.expanded = tab.expanded.filter { $0 != path && !$0.hasPrefix(path + "/") }
                tab.fixSelection()
            }
        }
        return .handled
    }

    // MARK: - Drawing

    func frame(size: TerminalSize) -> (lines: [String], cursor: Screen.Cursor?) {
        let width = max(size.cols, 10)
        let height = max(size.rows, 2)
        if let confirmation {
            return (confirmation.view.frame(size: TerminalSize(cols: width, rows: height), theme: context.theme), nil)
        }
        var heading = " Explorer · \(context.title)"
        if let root { heading += " · " + root.abbreviatedPath }
        let reading = loading || searching ? " reading… " : ""
        var lines = [SidebarView.paint([(heading, Style.bold), (reading, Style.dim)], width: width)]
        var cursor: Screen.Cursor?

        switch mode {
        case .tree, .naming:
            lines += treeLines(width: width, height: height - 2)
        case .names:
            cursor = fieldLine("Find a file: ", into: &lines, width: width)
            lines += nameLines(width: width, height: height - 3)
        case .find:
            cursor = fieldLine("Find in files: ", into: &lines, width: width)
            lines += findLines(width: width, height: height - 3)
        }
        lines = Array(lines.prefix(height - 1))
        lines += Array(repeating: "", count: max(height - 1 - lines.count, 0))

        if case .naming(let naming) = mode {
            let label = switch naming {
            case .newFile: " New file: "
            case .newFolder: " New folder: "
            case .rename: " Rename: "
            }
            let text = field.string
            if let notice {
                lines[height - 2] = SidebarView.paint([(" " + notice, Style.code(.attention, theme: context.theme))],
                                                      width: width)
            }
            lines.append(SidebarView.paint([(label, Style.bold), (text, "")], width: width))
            cursor = Screen.Cursor(row: height - 1, col: min(TerminalColumns.width(of: label + text), width - 1))
        } else if let notice {
            lines.append(SidebarView.paint([(" " + notice, Style.code(.attention, theme: context.theme))], width: width))
        } else {
            lines.append(SidebarView.paint([(" " + help, Style.dim)], width: width))
        }
        return (lines, cursor)
    }

    private var help: String {
        switch mode {
        case .tree: "enter open · / find a file · F find in files · n new · N folder · R rename · D trash · esc chat"
        case .names: "type a name · ↑↓ pick · enter open in the editor · esc tree"
        case .find: "enter search, then open the line in the editor · ↑↓ pick · esc tree"
        case .naming: "enter save · esc cancel"
        }
    }

    private func fieldLine(_ label: String, into lines: inout [String], width: Int) -> Screen.Cursor {
        let text = field.string
        lines.append(SidebarView.paint([(" " + label, Style.bold), (text, "")], width: width))
        return Screen.Cursor(row: lines.count - 1, col: min(TerminalColumns.width(of: " " + label + text), width - 1))
    }

    private func treeLines(width: Int, height: Int) -> [String] {
        let rows = rows
        guard !rows.isEmpty else {
            return loading ? [] : [SidebarView.paint([(" This folder is empty.", Style.dim)], width: width)]
        }
        let index = rows.firstIndex { $0.entry.path == selectedPath } ?? 0
        top = Self.scrolled(top, toShow: index, height: max(height, 1), count: rows.count)
        return rows[top..<min(top + max(height, 1), rows.count)].map { row in
            let entry = row.entry
            let indent = String(repeating: "  ", count: row.depth)
            let picked = entry.path == selectedPath
            if entry.isDirectory {
                let glyph = expanded.contains(entry.path) ? "▾ " : "▸ "
                return SidebarView.paint([("  " + indent + glyph, ""), (entry.name + "/", Style.bold),
                                          (entry.linkDestination.map { " → " + $0 } ?? "", Style.dim)],
                                         width: width, reversed: picked)
            }
            return SidebarView.paint([("  " + indent + "  ", ""), (entry.name, ""),
                                      (entry.linkDestination.map { " → " + $0 } ?? "", Style.dim)],
                                     width: width, reversed: picked)
        }
    }

    private func nameLines(width: Int, height: Int) -> [String] {
        guard !nameResults.isEmpty else {
            let empty = field.string.isBlank || searching ? "" : " No file is called that."
            return ["", SidebarView.paint([(empty, Style.dim)], width: width)]
        }
        resultTop = Self.scrolled(resultTop, toShow: resultIndex, height: max(height, 1), count: nameResults.count)
        return nameResults.indices[resultTop..<min(resultTop + max(height, 1), nameResults.count)].map { index in
            let entry = nameResults[index]
            return SidebarView.paint([("   " + entry.path + (entry.isDirectory ? "/" : ""), "")],
                                     width: width, reversed: index == resultIndex)
        }
    }

    private func findLines(width: Int, height: Int) -> [String] {
        guard let findResult else { return [] }
        var summary: String
        if findResult.files.isEmpty {
            summary = " No matches"
        } else {
            let lines = findResult.lineCount, files = findResult.files.count
            summary = " \(lines)\(findResult.more ? "+" : "") \(lines == 1 ? "match" : "matches") in "
                + "\(files) \(files == 1 ? "file" : "files")"
        }
        if findResult.limited { summary += " · some large files were not searched" }
        var out = [SidebarView.paint([(summary, Style.dim)], width: width)]
        let rows = foundRows
        // The selected line's place among all rows, to keep it in view.
        var lineCounter = -1
        var selectedRow = 0
        for (index, row) in rows.enumerated() {
            if case .line = row {
                lineCounter += 1
                if lineCounter == resultIndex { selectedRow = index }
            }
        }
        let shown = max(height - 1, 1)
        resultTop = Self.scrolled(resultTop, toShow: selectedRow, height: shown, count: rows.count)
        let match = Style.code(.attention, theme: context.theme)
        for index in rows.indices[resultTop..<min(resultTop + shown, rows.count)] {
            switch rows[index] {
            case .file(let path):
                out.append(SidebarView.paint([("  " + path, Style.bold)], width: width))
            case .line(_, let line):
                let number = String(line.number)
                let gutter = String(repeating: " ", count: max(4 - number.count, 0)) + number + "  "
                out.append(SidebarView.paint([(" " + gutter, Style.dim)] + Self.marked(line, style: match),
                                             width: width, reversed: index == selectedRow))
            }
        }
        return out
    }

    // A found line in runs, its hits in the match colour.
    private static func marked(_ line: RemoteFindInFiles.Line, style: String) -> [(text: String, style: String)] {
        let text = line.text as NSString
        var runs: [(text: String, style: String)] = []
        var at = 0
        for hit in line.hits where hit.location >= at && hit.location + hit.length <= text.length {
            if hit.location > at { runs.append((text.substring(with: NSRange(location: at, length: hit.location - at)), "")) }
            runs.append((text.substring(with: NSRange(location: hit.location, length: hit.length)), style + Style.bold))
            at = hit.location + hit.length
        }
        if at < text.length { runs.append((text.substring(from: at), "")) }
        return runs
    }

    // The first row to show so that `index` is on screen, moving as little as it can.
    private static func scrolled(_ top: Int, toShow index: Int, height: Int, count: Int) -> Int {
        var top = min(top, max(count - height, 0))
        if index < top { top = index }
        if index >= top + height { top = index - height + 1 }
        return max(top, 0)
    }
}
