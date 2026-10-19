import CodeStationCore
import TerminalKit
import TerminalTranscript

// The open session's changes: each checkout's branch and status with its changed files,
// and, once a file is picked, that file's diff (unified, or side by side on a wide pane:
// see `DiffLines`). It holds view state only: what the façade last read, which file is
// selected, and how far the list or diff is scrolled.
struct ChangesView {
    let sessionID: String
    let title: String
    private(set) var changes: RemoteChanges?
    private(set) var loading = true
    // Which file is selected, as a checkout and a file within it.
    private var selected: FileRef?
    // The file whose diff is open, when one is.
    private(set) var openFile: FileRef?
    private var listTop = 0
    private var diffTop = 0
    private var lastBodyHeight = 1
    private let theme: TranscriptTheme
    // The files ticked for the next commit, by checkout path and file path. None ticked
    // commits every change in the checkout, as the GUI's list starts with all ticked.
    private(set) var ticked: Set<Tick> = []
    // Said in place of the key help until the next key: what a commit or discard did,
    // or why it could not.
    var notice: String?

    struct Tick: Hashable {
        let checkout: String
        let path: String
    }

    struct FileRef: Equatable {
        let checkout: Int
        let file: Int
    }

    init(sessionID: String, title: String, theme: TranscriptTheme) {
        self.sessionID = sessionID
        self.title = title
        self.theme = theme
    }

    private var refs: [FileRef] {
        guard let changes else { return [] }
        return changes.checkouts.enumerated().flatMap { index, checkout in
            checkout.files.indices.map { FileRef(checkout: index, file: $0) }
        }
    }

    private func file(_ ref: FileRef) -> RemoteChangedFile? {
        guard let changes, changes.checkouts.indices.contains(ref.checkout) else { return nil }
        let files = changes.checkouts[ref.checkout].files
        return files.indices.contains(ref.file) ? files[ref.file] : nil
    }

    // The file the cursor is on, with its checkout.
    var selection: (checkout: RemoteCheckout, file: RemoteChangedFile)? {
        let ref = openFile ?? selected
        guard let ref, let file = file(ref), let changes else { return nil }
        return (changes.checkouts[ref.checkout], file)
    }

    // The checkout a push, pull, fetch or branch switch acts on: the one the cursor is
    // in, or the first.
    var syncCheckout: RemoteCheckout? {
        selection?.checkout ?? changes?.checkouts.first
    }

    // What a commit takes: the checkout the cursor is in (or the first with changes),
    // and its ticked files, or nil paths for all of them.
    var commitTarget: (checkout: RemoteCheckout, paths: [String]?)? {
        guard let changes else { return nil }
        guard let checkout = selection?.checkout ?? changes.checkouts.first(where: { !$0.files.isEmpty }),
              !checkout.files.isEmpty else { return nil }
        let paths = checkout.files.map(\.path).filter { ticked.contains(Tick(checkout: checkout.path, path: $0)) }
        return (checkout, paths.isEmpty ? nil : paths)
    }

    mutating func toggleTick() {
        guard let (checkout, file) = selection else { return }
        let tick = Tick(checkout: checkout.path, path: file.path)
        if ticked.remove(tick) == nil { ticked.insert(tick) }
    }

    mutating func clearTicks(in checkout: String) {
        ticked = ticked.filter { $0.checkout != checkout }
    }

    // MARK: - Loading

    mutating func startLoading() { loading = true }

    // A fresh read keeps the same file selected, and its diff open, when it is still
    // changed; otherwise the selection falls back to the first file.
    mutating func show(_ changes: RemoteChanges?) {
        let selectedPath = selected.flatMap(file)?.path
        let openPath = openFile.flatMap(file)?.path
        self.changes = changes
        loading = false
        let all = refs
        selected = all.first { file($0)?.path == selectedPath } ?? all.first
        let reopened = all.first { file($0)?.path == openPath }
        // A ticked file that is no longer changed is no longer ticked.
        let present = Set(changes?.checkouts.flatMap { checkout in
            checkout.files.map { Tick(checkout: checkout.path, path: $0.path) }
        } ?? [])
        ticked.formIntersection(present)
        if reopened != openFile { diffTop = 0 }
        openFile = openPath == nil ? nil : reopened
    }

    // MARK: - Moving

    mutating func move(by offset: Int) {
        let all = refs
        guard !all.isEmpty else { return }
        let current = selected.flatMap(all.firstIndex(of:)) ?? 0
        selected = all[min(max(current + offset, 0), all.count - 1)]
    }

    mutating func moveToFirst() { selected = refs.first }
    mutating func moveToLast() { selected = refs.last }

    mutating func openSelected() {
        guard let selected, file(selected) != nil else { return }
        openFile = selected
        diffTop = 0
    }

    mutating func closeDiff() { openFile = nil }

    // The next or previous file's diff, without going back to the list.
    mutating func openNeighbour(by offset: Int) {
        move(by: offset)
        openSelected()
    }

    mutating func scroll(by lines: Int) { diffTop = max(diffTop + lines, 0) }
    mutating func scrollPage(by pages: Int) { scroll(by: pages * max(lastBodyHeight - 1, 1)) }
    mutating func scrollToTop() { diffTop = 0 }
    mutating func scrollToBottom() { diffTop = .max / 2 }

    // MARK: - Drawing

    mutating func frame(size: TerminalSize) -> [String] {
        let width = max(size.cols, 10)
        let bodyHeight = max(size.rows - 3, 1)
        lastBodyHeight = bodyHeight
        if let openFile, let file = file(openFile) {
            return diffFrame(file, checkout: changes!.checkouts[openFile.checkout],
                             width: width, bodyHeight: bodyHeight)
        }
        return listFrame(width: width, bodyHeight: bodyHeight)
    }

    private enum Row {
        case checkout(RemoteCheckout)
        case status(RemoteCheckout)
        case file(FileRef, RemoteChangedFile)
        case empty
        case blank
    }

    private var rows: [Row] {
        guard let changes else { return [] }
        var rows: [Row] = []
        for (index, checkout) in changes.checkouts.enumerated() {
            if index > 0 { rows.append(.blank) }
            rows.append(.checkout(checkout))
            rows.append(.status(checkout))
            if checkout.files.isEmpty && checkout.state == "ready" { rows.append(.empty) }
            for (fileIndex, file) in checkout.files.enumerated() {
                rows.append(.file(FileRef(checkout: index, file: fileIndex), file))
            }
        }
        return rows
    }

    private mutating func listFrame(width: Int, bodyHeight: Int) -> [String] {
        let fileCount = changes?.checkouts.reduce(0) { $0 + $1.files.count } ?? 0
        var heading = " Changes · \(title)"
        if changes != nil { heading += " · \(fileCount) \(fileCount == 1 ? "file" : "files")" }
        let reading = loading ? " reading… " : ""
        let top = Style.bold
            + TerminalColumns.pad(TerminalColumns.fit(heading, to: max(width - TerminalColumns.width(of: reading), 1)),
                                  to: width - TerminalColumns.width(of: reading))
            + Style.reset + Style.dim + reading + Style.reset

        var body: [String]
        let all = rows
        if changes == nil {
            body = [Style.dim + (loading ? "  Reading changes…" : "  This session is gone.") + Style.reset]
        } else {
            if let index = all.firstIndex(where: {
                if case .file(let ref, _) = $0 { ref == selected } else { false }
            }) {
                if index < listTop { listTop = max(index - 2, 0) }
                if index >= listTop + bodyHeight { listTop = index - bodyHeight + 1 }
            }
            listTop = min(listTop, max(all.count - bodyHeight, 0))
            body = all[listTop..<min(all.count, listTop + bodyHeight)].map { draw($0, width: width) }
        }
        body += Array(repeating: "", count: max(bodyHeight - body.count, 0))
        let commit = ticked.isEmpty ? "c commit all" : "c commit ticked"
        let help = Style.dim
            + TerminalColumns.fit(" ↑↓/jk move · enter diff · space tick · \(commit) · D discard · P/U/F push pull fetch · B branch · H history · ? keys · esc back",
                                  to: width)
            + Style.reset
        return [top, ""] + body + [notice.map { noticeLine($0, width: width) } ?? help]
    }

    private func noticeLine(_ text: String, width: Int) -> String {
        Style.yellow + TerminalColumns.fit(" " + text, to: width) + Style.reset
    }

    private func draw(_ row: Row, width: Int) -> String {
        switch row {
        case .blank:
            return ""
        case .checkout(let checkout):
            let name = TerminalColumns.fit(" \(checkout.project) ", to: width)
            let branch = checkout.branch.isEmpty ? "" : "⎇ \(checkout.branch)"
            let place = checkout.isWorktree ? "  worktree" : "  project folder"
            let rest = TerminalColumns.fit(branch + place, to: max(width - TerminalColumns.width(of: name), 0))
            return Style.bold + name + Style.reset + Style.cyan + rest + Style.reset
        case .status(let checkout):
            let colour = checkout.state == "ready" ? Style.dim : Style.yellow
            return colour + TerminalColumns.fit("   \(checkout.status) · \(checkout.path)", to: width) + Style.reset
        case .empty:
            return Style.dim + TerminalColumns.fit("    No changes.", to: width) + Style.reset
        case .file(let ref, let file):
            let isSelected = ref == selected
            let counts = countText(file)
            let tick = ticked.contains(Tick(checkout: changes?.checkouts[ref.checkout].path ?? "", path: file.path))
            let marker = (isSelected ? " ▸" : "  ") + (tick ? "✓ " : "  ")
            let letter = file.letter + " "
            let pathWidth = max(width - TerminalColumns.width(of: marker + letter) - TerminalColumns.width(of: counts) - 1, 4)
            var path = file.path
            if let original = file.originalPath { path = "\(original) → \(path)" }
            let pathText = TerminalColumns.pad(TerminalColumns.fit(path, to: pathWidth), to: pathWidth) + " "
            let coloured = colouredCounts(file)
            if isSelected {
                return Style.reverse + marker + letter + pathText + Style.reset + coloured
            }
            return marker + Self.letterColour(file.status) + letter + Style.reset + pathText + coloured
        }
    }

    private func countText(_ file: RemoteChangedFile) -> String {
        if file.binary { return "binary" }
        return "+\(file.added ?? 0) -\(file.removed ?? 0)"
    }

    private func colouredCounts(_ file: RemoteChangedFile) -> String {
        if file.binary { return Style.dim + "binary" + Style.reset }
        return theme.encode(StyledLine([Span("+\(file.added ?? 0)", .added), Span(" "),
                                        Span("-\(file.removed ?? 0)", .removed)]))
    }

    private static func letterColour(_ status: String) -> String {
        switch status {
        case "added", "untracked": Style.green
        case "deleted", "conflicted": Style.red
        default: Style.yellow
        }
    }

    private mutating func diffFrame(_ file: RemoteChangedFile, checkout: RemoteCheckout,
                                    width: Int, bodyHeight: Int) -> [String] {
        let position = refs.firstIndex(of: openFile!).map { " \($0 + 1)/\(refs.count) " } ?? ""
        let heading = " \(file.path) · \(file.status) · \(countText(file)) · ⎇ \(checkout.branch)"
        let top = Style.bold
            + TerminalColumns.pad(TerminalColumns.fit(heading, to: max(width - TerminalColumns.width(of: position), 1)),
                                  to: width - TerminalColumns.width(of: position))
            + Style.reset + Style.dim + position + Style.reset

        var lines = DiffLines.draw(file.diff.lines, width: width, theme: theme)
        if let note = file.diff.note {
            lines.append(Style.dim + TerminalColumns.fit(" \(note)", to: width) + Style.reset)
        }
        if file.diff.truncated {
            let hidden = file.diff.totalLines - file.diff.lines.count
            lines.append(Style.dim + TerminalColumns.fit(" … \(hidden) more lines not shown", to: width) + Style.reset)
        }
        diffTop = min(diffTop, max(lines.count - bodyHeight, 0))
        var body = Array(lines[diffTop..<min(lines.count, diffTop + bodyHeight)])
        body += Array(repeating: "", count: max(bodyHeight - body.count, 0))

        let more = diffTop + bodyHeight < lines.count ? " ▼ more below " : ""
        let help = " ↑↓/jk scroll · PgUp/PgDn page · n/p file · c commit · D discard · ? keys · esc files"
        let helpLine = Style.dim
            + TerminalColumns.pad(TerminalColumns.fit(help, to: max(width - TerminalColumns.width(of: more), 1)),
                                  to: width - TerminalColumns.width(of: more))
            + Style.reset + Style.reverse + more + Style.reset
        return [top, ""] + body + [notice.map { noticeLine($0, width: width) } ?? helpLine]
    }
}
