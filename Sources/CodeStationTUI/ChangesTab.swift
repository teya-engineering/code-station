import CodeStationCore
import TerminalKit
import TerminalTranscript

// The open session's changes as a tab: the files each checkout changed, and a file's
// diff once one is picked. It follows the station's changes subscription, so what the
// agent edits shows up by itself; `r` reads them again at once.
//
// From here, as in the GUI's changes view:
// - space ticks files for the next commit; with none ticked a commit takes everything
//   in the checkout the cursor is in;
// - `c` asks for a message and commits;
// - `D` discards the file under the cursor, after a confirmation that says what goes
//   and what stays;
// - `P`, `U` and `F` push, pull and fetch the checkout the cursor is in, and `B` opens
//   its branch picker (see `SyncActions`);
// - `H` opens the commit history and the session's pull requests (`HistoryScreen`).
@MainActor
final class ChangesTab: SessionTabScreen {
    private var view: ChangesView
    private let context: SessionTabContext
    private var read: Task<Void, Never>?
    private var following: Task<Void, Never>?
    private var prompt: CommitPrompt?
    private var discard: (view: ImpactConfirmation, checkout: String, path: String)?
    private var sync: SyncActions!
    private var history: HistoryScreen?

    // The commit message being written, and what the commit will take.
    private struct CommitPrompt {
        let checkout: RemoteCheckout
        let paths: [String]?
        var field = ComposerView()
        // Why the station refused the last try; the message stays for another.
        var refusal: String?

        var count: Int { paths?.count ?? checkout.files.count }

        var title: String {
            let files = count == 1 ? "file" : "files"
            return paths == nil ? "Commit all \(count) \(files) in \(checkout.project)"
                : "Commit \(count) \(files) in \(checkout.project)"
        }
    }

    init(_ context: SessionTabContext) {
        self.context = context
        view = ChangesView(sessionID: context.sessionID, title: context.title, theme: context.theme)
        sync = SyncActions(commands: context.commands, theme: context.theme, work: context.work,
                           repaint: context.repaint)
        follow()
    }

    var place: KeyBindings.Place {
        if history != nil { return .history }
        if prompt != nil { return .composer }
        if discard != nil { return .confirmation }
        if sync.isOpen { return .branches }
        return view.openFile == nil ? .changes : .diff
    }

    // The message prompt and the confirmation take every key, number keys included.
    var takesTyping: Bool { prompt != nil || discard != nil || sync.isOpen }

    func frame(size: TerminalSize) -> (lines: [String], cursor: Screen.Cursor?) {
        if let history { return (history.frame(size: size), nil) }
        if let prompt { return promptFrame(prompt, size: size) }
        if let discard { return (discard.view.frame(size: size, theme: context.theme), nil) }
        if sync.isOpen { return sync.frame(size: size) }
        return (sync.overlay(view.frame(size: size), width: size.cols), nil)
    }

    func close() {
        read?.cancel()
        following?.cancel()
        history?.close()
    }

    // The live changes: the first copy straight away, then each one git answers
    // differently. Not counted as work from a key, since it never ends by itself.
    private func follow() {
        view.startLoading()
        let stream = context.commands.changesUpdates(context.sessionID)
        following = Task { [weak self] in
            for await changes in stream {
                guard let self else { return }
                self.view.show(changes)
                self.context.repaint()
            }
            // The session went away on the host.
            guard let self, !Task.isCancelled else { return }
            self.view.show(nil)
            self.context.repaint()
        }
    }

    private func reload() {
        view.startLoading()
        read?.cancel()
        let id = context.sessionID, commands = context.commands
        read = context.work { [weak self] in
            let changes = try? await commands.readChanges(id)
            guard let self, !Task.isCancelled else { return }
            self.view.show(changes)
            self.context.repaint()
        }
    }

    func handle(_ key: Key, rows: Int) -> SessionTabOutcome {
        if let history {
            guard history.handle(key, rows: rows) == .back else { return .handled }
            history.close()
            self.history = nil
            return .handled
        }
        if prompt != nil { return handleInPrompt(key) }
        if discard != nil { return handleInDiscard(key) }
        if sync.isOpen { return sync.handle(key) ? .handled : .ignored }
        view.notice = nil
        let target = view.syncCheckout.map {
            SyncActions.Target(scope: context.sessionID, checkout: $0.path, name: $0.project)
        }
        if sync.start(key, at: target) { return .handled }
        let inDiff = view.openFile != nil
        let page = max(rows - 4, 1)
        switch key {
        case .char("r", []): reload()
        case .char("c", []): askForMessage()
        case .char("H", []), .char("H", .shift): history = HistoryScreen(context)
        case .char("D", []), .char("D", .shift): askToDiscard()
        case .char(" ", []) where !inDiff: view.toggleTick()
        case .escape, .left, .char("q", []), .char("h", []):
            guard inDiff else { return .back }
            view.closeDiff()
        case .enter([]), .right, .char("l", []):
            if !inDiff { view.openSelected() }
        case .char("n", []) where inDiff: view.openNeighbour(by: 1)
        case .char("p", []) where inDiff: view.openNeighbour(by: -1)
        case .up, .char("k", []), .char("p", .ctrl):
            if inDiff { view.scroll(by: -1) } else { view.move(by: -1) }
        case .down, .char("j", []), .char("n", .ctrl):
            if inDiff { view.scroll(by: 1) } else { view.move(by: 1) }
        case .pageUp, .char("b", []), .char("u", .ctrl):
            if inDiff { view.scrollPage(by: -1) } else { view.move(by: -page) }
        case .pageDown, .char(" ", []), .char("f", []):
            if inDiff { view.scrollPage(by: 1) } else { view.move(by: page) }
        case .home, .char("g", []):
            if inDiff { view.scrollToTop() } else { view.moveToFirst() }
        case .end, .char("G", []):
            if inDiff { view.scrollToBottom() } else { view.moveToLast() }
        default: return .ignored
        }
        return .handled
    }

    // MARK: - Commit

    private func askForMessage() {
        guard let target = view.commitTarget else {
            view.notice = "There is nothing to commit."
            return
        }
        prompt = CommitPrompt(checkout: target.checkout, paths: target.paths)
    }

    private func handleInPrompt(_ key: Key) -> SessionTabOutcome {
        guard var open = prompt else { return .ignored }
        switch key {
        case .escape:
            prompt = nil
            return .handled
        // One line: a commit message from here is its subject.
        case .enter([]):
            commit(open)
            return .handled
        case .enter, .char("j", .ctrl):
            return .handled
        case .paste(let text):
            _ = open.field.handle(.paste(text.split(whereSeparator: \.isNewline).joined(separator: " ")))
        default:
            guard open.field.handle(key) != .ignored else { return .handled }
        }
        open.refusal = nil
        prompt = open
        return .handled
    }

    private func commit(_ open: CommitPrompt) {
        let id = context.sessionID, commands = context.commands
        let message = open.field.string
        _ = context.work { [weak self] in
            do throws(StationRefusal) {
                try await commands.commitChanges(id, checkout: open.checkout.path, message: message,
                                                 paths: open.paths)
                guard let self else { return }
                self.prompt = nil
                self.view.clearTicks(in: open.checkout.path)
                self.view.notice = "Committed \(open.count) \(open.count == 1 ? "file" : "files")."
            } catch {
                guard let self else { return }
                self.prompt?.refusal = error.message
            }
            self?.context.repaint()
        }
    }

    private func promptFrame(_ prompt: CommitPrompt, size: TerminalSize) -> (lines: [String], cursor: Screen.Cursor?) {
        let width = max(size.cols, 10)
        var lines = [Style.bold + TerminalColumns.fit(" " + prompt.title, to: width) + Style.reset, ""]
        let files = prompt.paths ?? prompt.checkout.files.map(\.path)
        let room = max(size.rows - 9, 1)
        for path in files.prefix(room) {
            lines.append(Style.dim + TerminalColumns.fit("   " + path, to: width) + Style.reset)
        }
        if files.count > room {
            lines.append(Style.dim + TerminalColumns.fit("   and \(files.count - room) more", to: width) + Style.reset)
        }
        lines.append("")
        lines.append(Style.dim + " Message" + Style.reset)
        let (field, at) = prompt.field.layout(width: width - 1)
        let top = lines.count
        lines += field.map { " " + $0 }
        if let refusal = prompt.refusal {
            lines.append(Style.yellow + TerminalColumns.fit(" " + refusal, to: width) + Style.reset)
        }
        let rows = max(size.rows, lines.count + 1)
        lines += Array(repeating: "", count: rows - lines.count - 1)
        lines.append(Style.dim + TerminalColumns.fit(" enter commit · esc cancel", to: width) + Style.reset)
        return (lines, Screen.Cursor(row: top + at.row, col: at.col + 1))
    }

    // MARK: - Discard

    // Mirrors the GUI's confirmation: the file goes back to the last commit, or to the
    // Trash when git has never seen it, and every other change stays.
    private func askToDiscard() {
        guard let (checkout, file) = view.selection else {
            view.notice = "There is nothing to discard."
            return
        }
        let untracked = file.status == "untracked"
        let others = checkout.files.count - 1
        var rows = [ImpactConfirmation.Row(file.path, untracked ? "Moved to the Trash"
                                           : "Goes back to the way the last commit has it")]
        if others > 0 {
            rows.append(.init("Other changes", "\(others) other changed \(others == 1 ? "file stays" : "files stay") as \(others == 1 ? "it is" : "they are")",
                              kept: true))
        }
        let confirmation = ImpactConfirmation(
            untracked ? "Delete this file?" : "Discard changes?",
            message: untracked
                ? "\(file.path) is not in git yet, so there is no committed version to go back to."
                : "\(file.path) goes back to the way the last commit has it.",
            subject: .init(name: checkout.project),
            rows: rows,
            warning: untracked ? nil : "The changes in it are lost, and cannot be restored.",
            action: untracked ? "Move to Trash" : "Discard")
        discard = (confirmation, checkout.path, file.path)
    }

    private func handleInDiscard(_ key: Key) -> SessionTabOutcome {
        guard var open = discard else { return .ignored }
        switch open.view.handle(key) {
        case .handled: discard = open
        case .ignored: break
        case .cancel: discard = nil
        case .confirm:
            discard = nil
            let id = context.sessionID, commands = context.commands
            _ = context.work { [weak self] in
                do throws(StationRefusal) {
                    try await commands.discardChanges(id, checkout: open.checkout, paths: [open.path])
                    self?.view.notice = "Discarded the changes in \(open.path)."
                } catch {
                    self?.view.notice = error.message
                }
                self?.context.repaint()
            }
        }
        return .handled
    }
}
