import CodeStationCore
import Foundation
import TerminalKit
import TerminalTranscript

// One open session's transcript. It holds view state only: the reader's copy of the
// session, kept up to date from the façade's events, where the window sits, which tool
// calls are open, and the prompt being written. The renderer draws the lines; this adds
// the pointer at the selected tool call, the queue, the composer and the key
// help around them.
struct TranscriptView {
    let sessionID: String
    private(set) var transcript: RemoteTranscript
    private var viewport = TranscriptViewport()
    private let theme: TranscriptTheme
    // The prompt being written, and whether keys go to it rather than to the transcript.
    var composer = ComposerView()
    var composing = false
    // Shown in place of the key help until the next key: why a command was refused.
    var notice: String?
    // A question the next key answers, such as whether to compact, shown in place of the
    // key help until it is answered.
    var asking: String?
    // The key help of a screen that shows this transcript inside its own (the Design
    // tab), in place of the chat's, while nothing more pressing has the line.
    var keysHelp: String?
    // What the agent is waiting on the person for, while it waits. It shows where the
    // composer sits, until the composer is given focus.
    var prompt: PermissionPrompt?
    // Set when the person asked for the turn to stop, until the session stops being busy.
    private(set) var stopRequested = false
    // The tool calls the reader has opened, and the one Tab has pointed at.
    private var expanded: Set<String> = []
    private var selectedTool: String?
    private var lastWindow: [StyledLine] = []
    // Text being looked for in the transcript, while find is open.
    private(set) var find: Find?
    // A row to bring into view on the next frame: a tool call, or a match of the find.
    private var pendingJump: Jump?
    // The slash commands the session can be sent, as the station last listed them, the
    // one the menu points at, and the word typed when the menu was waved away, so it
    // stays away until the word changes (as in the GUI).
    var commands: [RemoteSlashCommand] = []
    private(set) var commandSelection = 0
    private var dismissedQuery: String?

    // Find in the transcript, as the GUI's find bar: what is typed, whether keys type
    // into it, and the match on screen. A search starts at the newest match.
    struct Find {
        var field = ComposerView()
        var editing = true
        var matches: [TranscriptViewport.Position] = []
        var current: TranscriptViewport.Position?

        var query: String { field.string.trimmingCharacters(in: .whitespacesAndNewlines) }

        var currentIndex: Int? { current.flatMap(matches.firstIndex(of:)) }
    }

    private enum Jump {
        case tool(String)
        case newestMatch
        case match(step: Int)
    }

    init(_ opened: OpenedSession, theme: TranscriptTheme) {
        sessionID = opened.snapshot.sessionID
        transcript = RemoteTranscript(opened.snapshot)
        self.theme = theme
        prompt = transcript.permission.map(PermissionPrompt.init)
    }

    var isBusy: Bool { transcript.header.isBusy }

    // False when the event did not fit, and the session should be resynced.
    mutating func apply(_ event: StationSessionEvent) -> Bool {
        let fits = transcript.apply(event)
        if !transcript.header.isBusy { stopRequested = false }
        // A new request starts a fresh prompt; one still waiting keeps what was picked.
        if transcript.permission?.id != prompt?.permission.id {
            prompt = transcript.permission.map(PermissionPrompt.init)
            // It takes the composer's place at once, unless a prompt is half written.
            if prompt != nil && composer.text.isEmpty { composing = false }
        }
        return fits
    }

    mutating func noteStopRequested() {
        if isBusy { stopRequested = true }
    }

    // MARK: - The command menu

    // The word after the slash while the whole prompt is one command being typed.
    var slashQuery: String? { composing ? SlashQuery.typed(in: composer.string) : nil }

    // What the menu lists: the commands the typed word points at, nearest first.
    var slashMatches: [RemoteSlashCommand] {
        guard let query = slashQuery, query != dismissedQuery else { return [] }
        return commands.matching(query)
    }

    // Keeps the pointer on the list as the typed word changes it.
    mutating func noteSlashEdit() {
        commandSelection = 0
        if slashQuery != dismissedQuery { dismissedQuery = nil }
    }

    mutating func moveSlashSelection(by step: Int) {
        let count = slashMatches.count
        guard count > 0 else { return }
        commandSelection = ((min(commandSelection, count - 1) + step) % count + count) % count
    }

    // The name goes in whole with a space after it, so its words can be typed straight
    // on, and the menu closes.
    mutating func takeSlashSelection() {
        let matches = slashMatches
        guard !matches.isEmpty else { return }
        composer.replace(with: matches[min(commandSelection, matches.count - 1)].typed + " ")
        commandSelection = 0
    }

    mutating func dismissSlashMenu() { dismissedQuery = slashQuery }

    // MARK: - Scrolling

    mutating func scroll(by lines: Int) { viewport.scroll(by: lines) }
    mutating func scrollPage(by pages: Int) { viewport.scrollPage(by: pages) }
    mutating func scrollToTop() { viewport.scrollToTop() }
    mutating func scrollToBottom() { viewport.scrollToBottom() }

    // MARK: - Tool calls

    // The tool calls on screen, top to bottom.
    private var visibleTools: [String] {
        var seen: Set<String> = []
        return lastWindow.compactMap { $0.source?.toolID }.filter { seen.insert($0).inserted }
    }

    // Points at the next (or previous) tool call on screen, going round at the ends.
    mutating func selectTool(by step: Int) {
        let tools = visibleTools
        guard !tools.isEmpty else { return }
        if let selectedTool, let index = tools.firstIndex(of: selectedTool) {
            self.selectedTool = tools[(index + step % tools.count + tools.count) % tools.count]
        } else {
            selectedTool = step > 0 ? tools.first : tools.last
        }
    }

    // Opens or closes the tool call pointed at. With none on screen pointed at, it takes
    // the last one on screen, which is usually the one just made.
    mutating func toggleSelectedTool() {
        let tools = visibleTools
        if selectedTool.map(tools.contains) != true { selectedTool = tools.last }
        guard let selectedTool else { return }
        if expanded.remove(selectedTool) == nil { expanded.insert(selectedTool) }
    }

    // Closes every open call, or opens them all when none is open.
    mutating func toggleAllTools() {
        if !expanded.isEmpty {
            expanded = []
            return
        }
        for message in transcript.messages {
            for block in message.blocks {
                for tool in block.tools ?? [] { expanded.insert(tool.id) }
            }
        }
    }

    // MARK: - Copying

    // What `y` and `c` copied last, so pressing the same key again takes the one above.
    // Any other key forgets it (see `forgetCopy`).
    private var lastCopied: CopyTarget?

    private enum CopyTarget: Equatable {
        case message(String)
        case code(LineSource)
    }

    mutating func forgetCopy() { lastCopied = nil }

    // The message on screen nearest the bottom, or the one above the last copied: its
    // text and what to tell the reader. Nil text when there is nothing on screen.
    mutating func copyMessage() -> (text: String?, notice: String) {
        var seen: Set<String> = []
        let onScreen = lastWindow.reversed().compactMap { $0.source?.messageID }
            .filter { seen.insert($0).inserted }.map(CopyTarget.message)
        guard case .message(let id)? = nextCopy(among: onScreen),
              let message = transcript.messages.first(where: { $0.id == id }) else {
            return (nil, "Nothing on screen to copy.")
        }
        let text = TranscriptCopy.text(of: message)
        let what = message.role == "user" ? "the prompt" : message.role == "assistant" ? "the reply" : "the note"
        return (text, "Copied \(what) · \(Self.count(lines: text)) · y again for the one above")
    }

    // The fenced code block on screen nearest the bottom, or the one above the last copied.
    mutating func copyCode() -> (text: String?, notice: String) {
        var seen: Set<LineSource> = []
        let onScreen = lastWindow.reversed().compactMap { line -> CopyTarget? in
            guard let source = line.source, source.code != nil, source.toolID == nil,
                  seen.insert(source).inserted else { return nil }
            return .code(source)
        }
        guard case .code(let source)? = nextCopy(among: onScreen),
              let message = transcript.messages.first(where: { $0.id == source.messageID }),
              let code = TranscriptCopy.code(in: message, at: source) else {
            return (nil, "No code block on screen.")
        }
        return (code, "Copied the code block · \(Self.count(lines: code)) · c again for the one above")
    }

    // Bottom first; again, the one above the last copied, going round at the top.
    private mutating func nextCopy(among targets: [CopyTarget]) -> CopyTarget? {
        guard !targets.isEmpty else { return nil }
        let next = lastCopied.flatMap { targets.firstIndex(of: $0) }
            .map { targets[($0 + 1) % targets.count] } ?? targets[0]
        lastCopied = next
        return next
    }

    private static func count(lines text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return lines == 1 ? "1 line" : "\(lines) lines"
    }

    // MARK: - Finding

    var isFindEditing: Bool { find?.editing == true }

    // Opens find, or goes back to typing in the find already open.
    mutating func startFind() {
        composing = false
        if find == nil { find = Find() }
        find?.editing = true
    }

    // The key edits what is looked for, and the search starts again from the newest
    // match. False when the key is not one that edits.
    mutating func editFind(with key: Key) -> Bool {
        guard var open = find else { return false }
        switch key {
        case .enter, .char("j", .ctrl): return false
        default:
            guard open.field.handle(key) != .ignored else { return false }
        }
        find = open
        pendingJump = .newestMatch
        return true
    }

    mutating func stopEditingFind() { find?.editing = false }

    mutating func closeFind() { find = nil }

    // The next match (newer) or the one before (older), going round at the ends.
    mutating func stepFind(by step: Int) {
        guard find != nil else { return }
        pendingJump = .match(step: step)
    }

    // MARK: - Jumping to an agent

    // Brings the tool call into view and points at it, as the agents indicator does.
    mutating func reveal(tool id: String) {
        selectedTool = id
        pendingJump = .tool(id)
    }

    // Works out where the next window should be for a jump asked for since the last one,
    // and where find's matches are now.
    private mutating func resolveJumps(width: Int) {
        let jump = pendingJump
        pendingJump = nil
        if case .tool(let id) = jump,
           let position = viewport.positions(in: transcript.messages, width: width, expanded: expanded,
                                             where: { $0.source?.toolID == id }).first {
            viewport.reveal(position)
        }
        guard var open = find else { return }
        let query = open.query.lowercased()
        open.matches = query.isEmpty ? [] : viewport.positions(in: transcript.messages, width: width,
                                                               expanded: expanded,
                                                               where: { $0.text.lowercased().contains(query) })
        switch jump {
        case .newestMatch: open.current = open.matches.last
        case .match(let step):
            if let index = open.currentIndex ?? (open.matches.isEmpty ? nil : open.matches.count - 1) {
                let count = open.matches.count
                open.current = open.matches[((index + step) % count + count) % count]
            } else {
                open.current = open.matches.last
            }
        case .tool, nil:
            if open.currentIndex == nil { open.current = nil }
        }
        if let current = open.current, jump != nil, !isTool(jump) { viewport.reveal(current) }
        find = open
    }

    private func isTool(_ jump: Jump?) -> Bool {
        if case .tool = jump { return true }
        return false
    }

    // MARK: - Drawing

    // The top bar over this transcript: the session's identity, state and facts.
    var topBar: TopBarView {
        TopBarView(header: transcript.header, stateOverride: stopRequested ? "STOPPING" : nil, theme: theme)
    }

    // The lines of the frame, and where the cursor goes while the composer has focus.
    mutating func frame(size: TerminalSize) -> (lines: [String], cursor: Screen.Cursor?) {
        let width = max(size.cols, 10)
        let header = transcript.header

        let queue = upkeepLines(width: width) + queueLines(width: width) + composerExtras(width: width)
        let composerRoom = max(min(8, size.rows / 3), 1)
        let composerLines: [String]
        let composerCursor: (row: Int, col: Int)?
        if let prompt, !composing {
            (composerLines, composerCursor) = prompt.frame(width: width, room: max(size.rows / 2, 3))
        } else {
            (composerLines, composerCursor) = composerBlock(width: width, room: composerRoom)
        }
        let bodyHeight = max(size.rows - 2 - queue.count - composerLines.count, 1)

        // A blank column on each side keeps the text off the terminal's edge.
        resolveJumps(width: max(width - 2, 1))
        let window = viewport.window(of: transcript.messages, width: max(width - 2, 1), height: bodyHeight,
                                     expanded: expanded)
        lastWindow = window
        // The selected call is pointed at in the left margin, on its first line on screen,
        // and find's match on screen is marked there too.
        let pointer = theme.encode(StyledLine([Span("▸", .userMarker)]))
        let marked = theme.encode(StyledLine([Span("»", .attention)]))
        let pointed = selectedTool.flatMap { id in window.firstIndex { $0.source?.toolID == id } }
        let matched = find?.current.flatMap { viewport.windowPositions.firstIndex(of: $0) }
        var body = window.enumerated().map { index, line in
            (index == matched ? marked : index == pointed ? pointer : " ") + theme.encode(line)
        }
        if transcript.messages.isEmpty {
            body = [Style.dim + "  Nothing here yet." + Style.reset]
        }
        body += Array(repeating: "", count: max(bodyHeight - body.count, 0))

        let rule = Style.dim + String(repeating: "─", count: width) + Style.reset
        let more = viewport.isFollowing ? "" : " ▼ more below "
        let helpLine = Style.dim
            + TerminalColumns.pad(TerminalColumns.fit(help(header), to: max(width - TerminalColumns.width(of: more), 1)),
                                  to: width - TerminalColumns.width(of: more))
            + Style.reset + Style.reverse + more + Style.reset

        let lines = body + queue + [rule] + composerLines + [helpLine]
        if let find, find.editing {
            let typed = TerminalColumns.width(of: " find: " + find.field.string)
            return (lines, Screen.Cursor(row: lines.count - 1, col: min(typed, width - 1)))
        }
        let cursor = composerCursor.map {
            Screen.Cursor(row: body.count + queue.count + 1 + $0.row, col: $0.col)
        }
        return (lines, cursor)
    }

    private func help(_ header: RemoteHeader) -> String {
        if let asking { return " " + asking }
        if let notice { return " " + notice }
        if let find { return findHelp(find) }
        if let prompt, !composing { return prompt.help }
        if composing, !slashMatches.isEmpty {
            return " ↑↓ choose · tab/enter take the command · esc hide · keep typing to narrow"
        }
        if composing {
            let escape = isBusy && !stopRequested ? "esc stop turn" : "esc done"
            let tab = prompt == nil ? "tab transcript" : "tab answer the agent"
            return " enter send · alt+enter/ctrl-j newline · ↑ earlier · \(tab) · \(escape)"
        }
        if let keysHelp { return keysHelp }
        if let failure = header.failure {
            return " " + failure + (header.upkeep?.canContinue == true ? " · m continue or dismiss" : " · m dismiss")
        }
        let escape = isBusy && !stopRequested ? "esc stop turn · ← back" : "esc back"
        return " enter write · jk scroll · tab/o tools · O all · d changes · y/c copy · ? keys · \(escape)"
    }

    // " find: apple   2 of 5 · enter done · ↑↓ older, newer · esc close" while typing;
    // the same with n and N once the keys are back with the transcript.
    private func findHelp(_ find: Find) -> String {
        let count = find.query.isEmpty ? "" : find.matches.isEmpty ? "No matches"
            : "\((find.currentIndex ?? 0) + 1) of \(find.matches.count)"
        let keys = find.editing ? "enter done · ↑↓ older, newer · esc close" : "N older · n newer · / edit · esc close"
        return " find: \(find.field.string)   " + [count, keys].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // What the session offers over the composer, as the GUI shows it there: the last
    // recap, and the prompt the agent expects next while the session is free.
    private func upkeepLines(width: Int) -> [String] {
        guard let upkeep = transcript.header.upkeep else { return [] }
        var lines: [String] = []
        if let recap = upkeep.recap {
            lines += TranscriptRenderer.wrap("RECAP · " + recap, width: max(width - 2, 1)).prefix(3)
                .map { Style.cyan + " " + $0 + Style.reset }
        } else if upkeep.isRecapping {
            lines.append(Style.dim + TerminalColumns.fit(" RECAP · being written…", to: width) + Style.reset)
        }
        if let suggestion = upkeep.suggestion, prompt == nil {
            let keys = composer.text.isEmpty ? "s send" : "s add to the prompt"
            lines.append(Style.cyan + TerminalColumns.fit(" ✦ Suggested: \(suggestion)", to: max(width - keys.count - 5, 1))
                         + Style.reset + Style.dim + "  · " + keys + Style.reset)
        }
        return lines
    }

    // What goes out with the next prompt, over the composer as the GUI's chips are: the
    // files attached and the custom instructions. Then, while a command is being typed,
    // the commands it points at.
    private func composerExtras(width: Int) -> [String] {
        var lines: [String] = []
        if !composer.attachments.isEmpty {
            let chips = " " + composer.attachments.map { "⎘ " + (($0 as NSString).lastPathComponent) }
                .joined(separator: "  ")
            // The key that takes one off, where there is room for it.
            let keys = "  · backspace on an empty prompt takes off the last"
            let room = TerminalColumns.width(of: chips) + TerminalColumns.width(of: keys) <= width
            lines.append(Style.cyan + TerminalColumns.fit(chips, to: width) + Style.reset
                         + (composing && room ? Style.dim + keys + Style.reset : ""))
        }
        let instructions = composer.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            let first = instructions.split(whereSeparator: \.isNewline).first.map(String.init) ?? instructions
            lines.append(Style.cyan + TerminalColumns.fit(" ✎ Instructions: " + first, to: width) + Style.reset)
        }
        let matches = slashMatches
        if !matches.isEmpty {
            let selected = min(commandSelection, matches.count - 1)
            let first = min(max(selected - 4, 0), max(matches.count - 5, 0))
            let shown = matches.enumerated().dropFirst(first).prefix(5)
            let column = min(shown.map { TerminalColumns.width(of: $0.element.typed) }.max() ?? 0, 22) + 1
            for (index, command) in shown {
                let picked = index == selected
                let name = TerminalColumns.pad(TerminalColumns.fit(command.typed, to: column), to: column)
                let scope = switch command.scope {
                case .app: "app"
                case .builtIn: "built-in"
                case .user: "yours"
                case .project: "project"
                }
                let text = (picked ? " ▸ " : "   ") + name + " " + command.summary
                let tail = "  " + scope
                let line = TerminalColumns.fit(text, to: max(width - TerminalColumns.width(of: tail), 1))
                let padded = TerminalColumns.pad(line, to: max(width - TerminalColumns.width(of: tail), 1))
                lines.append((picked ? Style.reverse : "") + padded + Style.reset + Style.dim + tail + Style.reset)
            }
            if matches.count > 5 {
                lines.append(Style.dim + "   \(matches.count) commands" + Style.reset)
            }
        }
        return lines
    }

    // Prompts waiting behind the running turn, or held after a stopped or failed one,
    // as the GUI shows them above its composer.
    private func queueLines(width: Int) -> [String] {
        let queued = transcript.queued
        guard !queued.isEmpty else { return [] }
        let heading = isBusy ? " QUEUED · \(queued.count) · RUNS WHEN THIS TURN ENDS"
                             : " QUEUED · \(queued.count) · RUNS BEFORE THE NEXT PROMPT"
        var lines = [Style.cyan + TerminalColumns.fit(heading, to: width) + Style.reset]
        for prompt in queued.prefix(3) {
            let first = prompt.text.split(separator: "\n").first.map(String.init) ?? ""
            lines.append(Style.dim + TerminalColumns.fit("   ⋯ " + first, to: width) + Style.reset)
        }
        if queued.count > 3 {
            lines.append(Style.dim + "   +\(queued.count - 3) more" + Style.reset)
        }
        return lines
    }

    // The composer's lines, at most `room` of them around the cursor, and the cursor's
    // place among them while it has focus.
    private func composerBlock(width: Int, room: Int) -> ([String], (row: Int, col: Int)?) {
        if !composing && composer.text.isEmpty {
            return ([Style.dim + " › write a prompt: enter" + Style.reset], nil)
        }
        let (all, at) = composer.layout(width: max(width - 1, 3))
        let first = min(max(at.row - room + 1, 0), max(all.count - room, 0))
        let shown = all[first..<min(first + room, all.count)].map {
            (composing ? "" : Style.dim) + " " + $0 + (composing ? "" : Style.reset)
        }
        return (Array(shown), composing ? (at.row - first, at.col + 1) : nil)
    }
}
