import CodeStationCore
import Foundation
import TerminalKit
import TerminalTranscript

// The session's pull requests and commit history, opened with `H` from the Changes tab,
// as the GUI's commit history and the facts card's pull requests:
// - the pull requests the session opened come first; Enter opens one in the browser,
//   through the client's host services;
// - then each checkout's recent commits, newest first; Enter opens a commit's changed
//   files, and Enter on a file its diff against the commit's parent.
// Esc steps back a level, and out to the changes from the list.
@MainActor
final class HistoryScreen {
    private let context: SessionTabContext
    private var history: RemoteHistory?
    private var loading = true
    private var refusal: String?
    private var selected = 0
    private var listTop = 0
    private var opened: OpenCommit?
    private var read: Task<Void, Never>?
    // Said in place of the key help until the next key.
    private var notice: String?

    // A commit picked from the list, its files once they have been read, the file
    // under the cursor and the one whose diff is open.
    private struct OpenCommit {
        let summary: RemoteCommitSummary
        let checkout: String
        var commit: RemoteCommit?
        var refusal: String?
        var file = 0
        var diffOpen = false
        var diffTop = 0
    }

    private enum Row {
        case heading(String)
        case pullRequest(PullRequest)
        case checkout(RemoteCommitLog)
        case commit(RemoteCommitLog, RemoteCommitSummary)
        case note(String)
        case blank

        var selectable: Bool {
            switch self {
            case .pullRequest, .commit: true
            default: false
            }
        }
    }

    init(_ context: SessionTabContext) {
        self.context = context
        load()
    }

    func close() {
        read?.cancel()
    }

    private func load() {
        loading = true
        read?.cancel()
        let id = context.sessionID, commands = context.commands
        read = context.work { [weak self] in
            do throws(StationRefusal) {
                let history = try await commands.readHistory(id)
                guard let self, !Task.isCancelled else { return }
                self.history = history
                self.refusal = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.refusal = error.message
            }
            self?.loading = false
            self?.context.repaint()
        }
    }

    private func open(_ summary: RemoteCommitSummary, in checkout: String) {
        opened = OpenCommit(summary: summary, checkout: checkout)
        read?.cancel()
        let id = context.sessionID, commands = context.commands
        read = context.work { [weak self] in
            do throws(StationRefusal) {
                let commit = try await commands.readCommit(id, checkout: checkout, hash: summary.hash)
                guard let self, !Task.isCancelled, self.opened?.summary == summary else { return }
                self.opened?.commit = commit
            } catch {
                guard let self, !Task.isCancelled, self.opened?.summary == summary else { return }
                self.opened?.refusal = error.message
            }
            self?.context.repaint()
        }
    }

    private var rows: [Row] {
        guard let history else { return [] }
        var rows: [Row] = []
        if !history.pullRequests.isEmpty {
            rows.append(.heading(" Pull requests"))
            rows += history.pullRequests.map(Row.pullRequest)
            rows.append(.blank)
        }
        for (index, log) in history.checkouts.enumerated() {
            if index > 0 { rows.append(.blank) }
            rows.append(.checkout(log))
            if let note = log.note {
                rows.append(.note(note))
            } else if log.commits.isEmpty {
                rows.append(.note("No commits yet."))
            }
            rows += log.commits.map { Row.commit(log, $0) }
        }
        return rows
    }

    private var selectableRows: [Int] {
        rows.indices.filter { rows[$0].selectable }
    }

    // MARK: - Keys

    func handle(_ key: Key, rows height: Int) -> SessionTabOutcome {
        notice = nil
        if opened != nil { return handleInCommit(key, rows: height) }
        let count = selectableRows.count
        let page = max(height - 4, 1)
        switch key {
        case .escape, .left, .char("q", []), .char("h", []): return .back
        case .char("r", []): load()
        case .up, .char("k", []), .char("p", .ctrl): move(to: selected - 1, count: count)
        case .down, .char("j", []), .char("n", .ctrl): move(to: selected + 1, count: count)
        case .pageUp, .char("b", []), .char("u", .ctrl): move(to: selected - page, count: count)
        case .pageDown, .char(" ", []), .char("f", []): move(to: selected + page, count: count)
        case .home, .char("g", []): move(to: 0, count: count)
        case .end, .char("G", []): move(to: count - 1, count: count)
        case .enter([]), .right, .char("l", []), .char("o", []): activate()
        default: return .ignored
        }
        return .handled
    }

    private func move(to index: Int, count: Int) {
        selected = min(max(index, 0), max(count - 1, 0))
    }

    private func activate() {
        let all = rows, selectable = selectableRows
        guard selectable.indices.contains(selected) else { return }
        switch all[selectable[selected]] {
        case .pullRequest(let pullRequest):
            guard let url = URL(string: pullRequest.url) else { return }
            context.openLink(url)
            notice = "Opened #\(pullRequest.number) in the browser."
        case .commit(let log, let summary):
            open(summary, in: log.path)
        default:
            break
        }
    }

    private func handleInCommit(_ key: Key, rows height: Int) -> SessionTabOutcome {
        guard var open = opened else { return .ignored }
        let count = open.commit?.files.count ?? 0
        let page = max(height - 4, 1)
        if open.diffOpen {
            switch key {
            case .escape, .left, .char("q", []), .char("h", []): open.diffOpen = false
            case .up, .char("k", []), .char("p", .ctrl): open.diffTop = max(open.diffTop - 1, 0)
            case .down, .char("j", []), .char("n", .ctrl): open.diffTop += 1
            case .pageUp, .char("b", []), .char("u", .ctrl): open.diffTop = max(open.diffTop - page, 0)
            case .pageDown, .char(" ", []), .char("f", []): open.diffTop += page
            case .home, .char("g", []): open.diffTop = 0
            case .end, .char("G", []): open.diffTop = .max / 2
            case .char("n", []), .char("p", []):
                let step = key == .char("n", []) ? 1 : -1
                open.file = min(max(open.file + step, 0), max(count - 1, 0))
                open.diffTop = 0
            default: return .ignored
            }
        } else {
            switch key {
            case .escape, .left, .char("q", []), .char("h", []):
                opened = nil
                return .handled
            case .up, .char("k", []), .char("p", .ctrl): open.file = max(open.file - 1, 0)
            case .down, .char("j", []), .char("n", .ctrl): open.file = min(open.file + 1, max(count - 1, 0))
            case .home, .char("g", []): open.file = 0
            case .end, .char("G", []): open.file = max(count - 1, 0)
            case .enter([]), .right, .char("l", []):
                if count > 0 {
                    open.diffOpen = true
                    open.diffTop = 0
                }
            default: return .ignored
            }
        }
        opened = open
        return .handled
    }

    // MARK: - Drawing

    func frame(size: TerminalSize) -> [String] {
        let width = max(size.cols, 10)
        let bodyHeight = max(size.rows - 3, 1)
        if let opened {
            if opened.diffOpen, let commit = opened.commit, commit.files.indices.contains(opened.file) {
                return diffFrame(opened, commit.files[opened.file], width: width, bodyHeight: bodyHeight)
            }
            return commitFrame(opened, width: width, bodyHeight: bodyHeight)
        }
        return listFrame(width: width, bodyHeight: bodyHeight)
    }

    private func heading(_ text: String, trailing: String, width: Int) -> String {
        let room = max(width - TerminalColumns.width(of: trailing), 1)
        return Style.bold + TerminalColumns.pad(TerminalColumns.fit(text, to: room), to: room) + Style.reset
            + Style.dim + trailing + Style.reset
    }

    private func help(_ text: String, width: Int) -> String {
        if let notice { return Style.yellow + TerminalColumns.fit(" " + notice, to: width) + Style.reset }
        return Style.dim + TerminalColumns.fit(text, to: width) + Style.reset
    }

    private func listFrame(width: Int, bodyHeight: Int) -> [String] {
        let top = heading(" History · \(context.title)", trailing: loading ? " reading… " : "", width: width)
        var body: [String]
        if let refusal, history == nil {
            body = [Style.yellow + TerminalColumns.fit("  " + refusal, to: width) + Style.reset]
        } else if history == nil {
            body = [Style.dim + "  Reading the history…" + Style.reset]
        } else {
            let all = rows
            let selectable = selectableRows
            let current = selectable.indices.contains(selected) ? selectable[selected] : nil
            if let current {
                if current < listTop { listTop = max(current - 2, 0) }
                if current >= listTop + bodyHeight { listTop = current - bodyHeight + 1 }
            }
            listTop = min(listTop, max(all.count - bodyHeight, 0))
            body = all.indices[listTop..<min(all.count, listTop + bodyHeight)].map {
                draw(all[$0], selected: $0 == current, width: width)
            }
        }
        body += Array(repeating: "", count: max(bodyHeight - body.count, 0))
        return [top, ""] + body
            + [help(" ↑↓/jk move · enter open (a pull request in the browser) · r read again · ? keys · esc changes",
                    width: width)]
    }

    private func draw(_ row: Row, selected: Bool, width: Int) -> String {
        let marker = selected ? " ▸ " : "   "
        switch row {
        case .blank:
            return ""
        case .heading(let text):
            return Style.bold + TerminalColumns.fit(text, to: width) + Style.reset
        case .note(let text):
            return Style.dim + TerminalColumns.fit("    " + text, to: width) + Style.reset
        case .checkout(let log):
            let name = TerminalColumns.fit(" \(log.project) ", to: width)
            let place = log.isWorktree ? "worktree" : "project folder"
            let rest = TerminalColumns.fit("\(place) · \(log.path)", to: max(width - TerminalColumns.width(of: name), 0))
            return Style.bold + name + Style.reset + Style.dim + rest + Style.reset
        case .pullRequest(let pullRequest):
            let text = TerminalColumns.fit("\(marker)#\(pullRequest.number)  \(pullRequest.url)", to: width)
            if selected { return Style.reverse + TerminalColumns.pad(text, to: width) + Style.reset }
            return Style.cyan + text + Style.reset
        case .commit(_, let commit):
            let meta = "  \(commit.author) · \(commit.relativeDate)"
            let hash = commit.shortHash + "  "
            let room = max(width - TerminalColumns.width(of: marker + hash) - TerminalColumns.width(of: meta), 4)
            let subject = TerminalColumns.pad(TerminalColumns.fit(commit.subject, to: room), to: room)
            if selected { return Style.reverse + marker + hash + subject + meta + Style.reset }
            return marker + Style.yellow + hash + Style.reset + subject + Style.dim + meta + Style.reset
        }
    }

    private func commitFrame(_ open: OpenCommit, width: Int, bodyHeight: Int) -> [String] {
        let files = open.commit?.files ?? []
        let count = open.commit == nil ? "" : " · \(files.count) \(files.count == 1 ? "file" : "files")"
        let top = heading(" \(open.summary.shortHash) \(open.summary.subject)\(count)",
                          trailing: open.commit == nil && open.refusal == nil ? " reading… " : "", width: width)
        var body = [Style.dim + TerminalColumns.fit("   \(open.summary.author) · \(open.summary.relativeDate)"
                                                     + " · \(open.commit.map(parentText) ?? "")", to: width) + Style.reset,
                    ""]
        if let refusal = open.refusal {
            body.append(Style.yellow + TerminalColumns.fit("  " + refusal, to: width) + Style.reset)
        } else if let commit = open.commit {
            if let note = commit.note {
                body.append(Style.yellow + TerminalColumns.fit("  " + note, to: width) + Style.reset)
            }
            if files.isEmpty { body.append(Style.dim + "    No file changes." + Style.reset) }
            let room = max(bodyHeight - body.count, 1)
            let first = min(max(open.file - room + 1, 0), max(files.count - room, 0))
            for index in files.indices.dropFirst(first).prefix(room) {
                body.append(drawFile(files[index], selected: index == open.file, width: width))
            }
        }
        body = Array(body.prefix(bodyHeight))
        body += Array(repeating: "", count: max(bodyHeight - body.count, 0))
        return [top, ""] + body + [help(" ↑↓/jk move · enter diff · ? keys · esc history", width: width)]
    }

    private func parentText(_ commit: RemoteCommit) -> String {
        guard let parent = commit.parents.first else { return "first commit" }
        let compared = "compared with \(parent.prefix(8))"
        return commit.parents.count > 1 ? compared + " (first of \(commit.parents.count) parents)" : compared
    }

    private func drawFile(_ file: RemoteChangedFile, selected: Bool, width: Int) -> String {
        let marker = selected ? " ▸ " : "   "
        let counts = file.binary ? "binary" : "+\(file.added ?? 0) -\(file.removed ?? 0)"
        let letter = file.letter + " "
        let path = file.originalPath.map { "\($0) → \(file.path)" } ?? file.path
        let room = max(width - TerminalColumns.width(of: marker + letter) - TerminalColumns.width(of: counts) - 1, 4)
        let pathText = TerminalColumns.pad(TerminalColumns.fit(path, to: room), to: room) + " "
        let coloured = file.binary ? Style.dim + counts + Style.reset
            : context.theme.encode(StyledLine([Span("+\(file.added ?? 0)", .added), Span(" "),
                                               Span("-\(file.removed ?? 0)", .removed)]))
        if selected { return Style.reverse + marker + letter + pathText + Style.reset + coloured }
        return marker + letter + pathText + coloured
    }

    private func diffFrame(_ open: OpenCommit, _ file: RemoteChangedFile, width: Int, bodyHeight: Int) -> [String] {
        let count = open.commit?.files.count ?? 0
        let top = heading(" \(file.path) · \(file.status) · \(open.summary.shortHash) \(open.summary.subject)",
                          trailing: " \(open.file + 1)/\(count) ", width: width)
        var lines = DiffLines.draw(file.diff.lines, width: width, theme: context.theme)
        if let note = file.diff.note {
            lines.append(Style.dim + TerminalColumns.fit(" \(note)", to: width) + Style.reset)
        }
        if file.diff.truncated {
            let hidden = file.diff.totalLines - file.diff.lines.count
            lines.append(Style.dim + TerminalColumns.fit(" … \(hidden) more lines not shown", to: width) + Style.reset)
        }
        let diffTop = min(open.diffTop, max(lines.count - bodyHeight, 0))
        if diffTop != open.diffTop { opened?.diffTop = diffTop }
        var body = Array(lines[diffTop..<min(lines.count, diffTop + bodyHeight)])
        body += Array(repeating: "", count: max(bodyHeight - body.count, 0))
        return [top, ""] + body
            + [help(" ↑↓/jk scroll · PgUp/PgDn page · n/p file · ? keys · esc files", width: width)]
    }
}
