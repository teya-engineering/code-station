import Foundation

// How one tool call reads in the UI: a verb, the one argument that matters, and,
// for an edit, the line changes it is making. All of it comes from the call's input,
// which the CLI sends complete and never changes afterwards.
struct ToolPresentation: Sendable {
    struct Line: Identifiable, Equatable, Sendable {
        // A gap stands for the lines between two hunks of the same file, which a diff
        // skips over.
        enum Kind: Equatable, Sendable { case addition, deletion, context, gap }
        let id: Int
        let kind: Kind
        let text: String
        // Which line of the file this is, counted from 1, on the side it belongs to: the
        // file before the edit for a deletion, after it for everything else. Nil when
        // nothing said where the change landed.
        var number: Int?

        var marker: String {
            switch kind {
            case .addition: "+"
            case .deletion: "-"
            case .context, .gap: " "
            }
        }
    }

    // One file's worth of a change, drawn as a diff of its own. An edit changes a single
    // file, while a command can change any number at once.
    struct FileChange: Identifiable, Sendable {
        let id: Int
        // What the diff prints above itself: the file's own name for an edit, which the
        // row it sits under already places, and the path inside the repository for a
        // change git worked out, which may well name a file nothing else mentions.
        let name: String
        var lines: [Line] = []
        var added = 0
        var removed = 0

        // Code reads as code in a diff, the way it does everywhere else in the app.
        var language: CodeLanguage? {
            CodeLanguage(fileExtension: (name as NSString).pathExtension)
        }
    }

    let verb: String
    var argument = ""

    // The one-line form of a call, used wherever a row names what is running:
    // "Bash · swift build", or just the verb when the call has no argument.
    var label: String {
        argument.isEmpty ? verb : "\(verb) · \(argument)"
    }
    var fileName: String?
    var added: Int?
    var removed: Int?
    var changes: [FileChange] = []
    // How many files the call changed. Not always the number of diffs below it: a change
    // too large to keep the patch for has this and nothing else to show for itself.
    var changedFiles = 0
    // Whether the diff is the whole of what the call said. An edit's input is the change
    // itself, so a row showing it has nothing further to open. A command's change was
    // measured off the tree afterwards, and the command that made it is still worth a look.
    var diffIsTheInput = false
    // Whether the collapsed row should say how much came back. True for the calls whose
    // output is the point of making them: a finished row with no note at all reads as a
    // call that did nothing, when it may only be one nobody has expanded.
    var notesResultLineCount = false

    init(tool: ToolUse, projectPath: String) {
        verb = tool.name
        let input = Self.object(from: tool.input)

        if let filePath = input["file_path"] as? String ?? input["notebook_path"] as? String {
            argument = Self.relativize(filePath, to: projectPath)
            fileName = (filePath as NSString).lastPathComponent
        }

        switch tool.name {
        case "Read":
            notesResultLineCount = true
        case "Edit", "Write", "Delete":
            let change = Self.change(tool: tool, input: input)
            added = change.added
            removed = change.removed
            diffIsTheInput = true
            // Codex used to name its edits as a line of prose rather than as arguments,
            // and conversations written then are still read back.
            if fileName == nil { argument = Self.singleLine(tool.input) }
            if !change.lines.isEmpty {
                changes = [FileChange(id: 0, name: fileName ?? argument,
                                      lines: change.lines,
                                      added: change.added, removed: change.removed)]
                changedFiles = 1
            }
        case "Bash":
            // Claude wraps shell input in JSON, while Codex sends the command itself.
            argument = Self.singleLine(input["command"] as? String ?? tool.input)
            notesResultLineCount = true
        case "Grep", "Glob":
            argument = input["pattern"] as? String ?? argument
            notesResultLineCount = true
        case "WebFetch":
            argument = input["url"] as? String ?? ""
            notesResultLineCount = true
        case "WebSearch":
            argument = input["query"] as? String ?? ""
            notesResultLineCount = true
        case "Task", "Agent":
            argument = input["name"] as? String
                ?? input["description"] as? String
                ?? Self.singleLine(input["prompt"] as? String ?? "")
        case "Workflow":
            argument = Self.workflowName(input)
        case "TodoWrite":
            if let todos = input["todos"] as? [Any] {
                argument = "\(todos.count) item" + (todos.count == 1 ? "" : "s")
            }
        default:
            if argument.isEmpty { argument = Self.singleLine(tool.input) }
        }

        // A call that wrote without saying so has its change measured off the working tree
        // instead. The counts stand even when the change was too large to keep the patch
        // for, which is what tells a reader that a call did a great deal.
        if let change = tool.written {
            added = change.added
            removed = change.removed
            changedFiles = change.files
            changes = change.patch.map(Self.files(inPatch:)) ?? []
            notesResultLineCount = false
        }
    }

    // MARK: - Diffing an edit

    typealias Change = (lines: [Line], added: Int, removed: Int)

    // The two shapes an edit arrives in. Codex hands over a unified diff it has already
    // worked out; Claude Code hands over the strings it swapped, which have to be
    // compared here.
    private static func change(tool: ToolUse, input: [String: Any]) -> Change {
        if let unified = input["diff"] as? String, !unified.isEmpty {
            return Self.unified(unified)
        }
        if tool.name == "Write" {
            return Self.diff(old: "", new: input["content"] as? String ?? "", startLine: 1)
        }
        return Self.diff(old: input["old_string"] as? String ?? "",
                         new: input["new_string"] as? String ?? "",
                         startLine: tool.editStartLine)
    }

    // A cheap line diff: lines shared at the start and end of both strings are context,
    // everything between is a straight remove-then-add. Edit inputs are written as the
    // changed lines plus a little surrounding context, so this reads like a real diff
    // without needing a diff algorithm.
    //
    // startLine is where in the file the two strings begin. Both sides are identical up
    // to that point, so one number numbers the whole diff.
    private static func diff(old: String, new: String, startLine: Int?) -> Change {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")

        var prefixCount = 0
        let sharedCount = min(oldLines.count, newLines.count)
        while prefixCount < sharedCount,
              oldLines[prefixCount] == newLines[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < sharedCount - prefixCount,
              oldLines[oldLines.count - suffixCount - 1]
                == newLines[newLines.count - suffixCount - 1] {
            suffixCount += 1
        }

        let oldChange = oldLines[prefixCount..<(oldLines.count - suffixCount)]
        let newChange = newLines[prefixCount..<(newLines.count - suffixCount)]

        var lines: [Line] = []
        func append(_ kind: Line.Kind, _ text: String, _ number: Int?) {
            lines.append(Line(id: lines.count, kind: kind, text: text, number: number))
        }

        // Only as much of the shared prefix as is shown gets numbered, so the count runs
        // from the first context line actually on screen up to the change itself.
        let shownPrefix = oldLines[..<prefixCount].suffix(2)
        var oldNumber = startLine.map { $0 + prefixCount - shownPrefix.count }
        var newNumber = oldNumber
        func step(_ number: inout Int?) -> Int? {
            defer { number = number.map { $0 + 1 } }
            return number
        }
        for text in shownPrefix {
            append(.context, text, step(&newNumber))
            _ = step(&oldNumber)
        }
        for text in oldChange { append(.deletion, text, step(&oldNumber)) }
        for text in newChange { append(.addition, text, step(&newNumber)) }
        for text in oldLines[(oldLines.count - suffixCount)...].prefix(2) {
            append(.context, text, step(&newNumber))
        }
        return (lines, newChange.count, oldChange.count)
    }

    // A unified diff read back into rows. Only the hunk headers and the marked lines
    // matter: the file headers name a file the row already names, and the numbering the
    // headers carry is the whole reason to prefer this over comparing strings.
    private static func unified(_ text: String) -> Change {
        var lines: [Line] = []
        var added = 0
        var removed = 0
        var oldNumber = 0
        var newNumber = 0
        var inHunk = false

        // A diff usually ends in a newline, which would otherwise read back as one more
        // blank line of file.
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        for row in body.split(separator: "\n", omittingEmptySubsequences: false) {
            guard lines.count < GitInspector.diffLineLimit else { break }
            func append(_ kind: Line.Kind, _ body: Substring, _ number: Int?) {
                lines.append(Line(id: lines.count, kind: kind, text: String(body), number: number))
            }

            if row.hasPrefix("@@") {
                guard let header = HunkHeader(row) else { continue }
                // Everything between two hunks is untouched file the diff skipped.
                if inHunk { append(.gap, "", nil) }
                oldNumber = header.oldStart
                newNumber = header.newStart
                inHunk = true
                continue
            }
            guard inHunk else { continue }

            if row.hasPrefix("+") {
                append(.addition, row.dropFirst(), newNumber)
                newNumber += 1
                added += 1
            } else if row.hasPrefix("-") {
                append(.deletion, row.dropFirst(), oldNumber)
                oldNumber += 1
                removed += 1
            } else if row.hasPrefix("\\") {
                // "\ No newline at end of file" describes the line above it.
                continue
            } else {
                append(.context, row.dropFirst(), newNumber)
                oldNumber += 1
                newNumber += 1
            }
        }
        return (lines, added, removed)
    }

    // A patch git wrote, cut back into the files it covers. One command can touch several,
    // and each of them is a diff in its own right with its own numbering, so they are read
    // apart rather than run together.
    //
    // A "diff --git" line can only ever start a file: every line inside a hunk carries a
    // marker in front of it, even a line whose own content is a patch.
    private static func files(inPatch text: String) -> [FileChange] {
        var files: [FileChange] = []
        var name: String?
        var body: [Substring] = []
        // Once the hunks start, a line beginning "+++" or "---" is a line of the file with
        // its marker in front of it, not the header naming the file.
        var namesRead = false

        func close() {
            guard let name, !body.isEmpty else { return }
            let change = unified(body.joined(separator: "\n"))
            guard !change.lines.isEmpty else { return }
            files.append(FileChange(id: files.count, name: name, lines: change.lines,
                                    added: change.added, removed: change.removed))
        }

        for row in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if row.hasPrefix("diff --git ") {
                close()
                name = nil
                body = []
                namesRead = false
                continue
            }
            if row.hasPrefix("@@") { namesRead = true }
            // The path is taken off the header rather than the "diff --git" line, since
            // that line runs both paths together and gives no way to tell where one ends.
            // A deleted file has no new side, so it keeps the name it had.
            if !namesRead, row.hasPrefix("+++ ") || row.hasPrefix("--- ") {
                let path = row.dropFirst(4)
                if path != "/dev/null" { name = String(path.dropFirst(2)) }
                continue
            }
            body.append(row)
        }
        close()
        return files
    }

    // The line each side of a hunk starts on, out of "@@ -12,7 +12,9 @@".
    private struct HunkHeader {
        let oldStart: Int
        let newStart: Int

        init?(_ row: Substring) {
            let counts = row.split(separator: " ").compactMap { field -> Int? in
                guard field.hasPrefix("-") || field.hasPrefix("+") else { return nil }
                return Int(field.dropFirst().prefix { $0.isNumber })
            }
            guard counts.count >= 2 else { return nil }
            oldStart = counts[0]
            newStart = counts[1]
        }
    }

    // MARK: - Helpers

    private static func object(from input: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any] ?? [:]
    }

    // What a workflow goes by: the saved name it was launched under, the script file it
    // was resumed from, or the name in the script's own meta block. Without one the row
    // would carry a whole workflow script as its argument.
    private static func workflowName(_ input: [String: Any]) -> String {
        if let name = input["name"] as? String, !name.isEmpty { return name }
        if let path = input["scriptPath"] as? String, !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        let head = (input["script"] as? String ?? "").prefix(400)
        guard let range = head.range(of: "name:\\s*['\"][^'\"]+", options: .regularExpression)
        else { return "workflow" }
        let name = head[range].drop { $0 != "'" && $0 != "\"" }.dropFirst()
        return name.isEmpty ? "workflow" : String(name)
    }

    private static func relativize(_ path: String, to projectPath: String) -> String {
        path.pathRelative(to: projectPath) ?? path.abbreviatedPath
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// The transcript and the sidebar both redraw on every streamed token, while summaries
// are derived on the persistence queue. Inputs are immutable once the call exists, so
// one locked cache avoids parsing the same JSON and diff on either path.
//
// Entries outlive the conversation they were built from. A call's id is unique and its
// input never changes, so a kept entry can never be the wrong answer, and reopening a
// session is common enough that rebuilding every diff again is the expensive half of
// drawing one. What bounds the cache is its own size rather than what is on screen.
//
// The one part of a call that does change is where an edit landed, which is only known
// once the call reports in. An entry built before that is kept apart from the entry
// built after, so a diff drawn while the edit ran does not keep its missing gutter.
enum ToolPresentationCache {
    // An edit's entry carries the lines it changed, so lines are what the cache is
    // measured in. Enough for several long conversations at once, and far short of what
    // holding every call the app has ever drawn would cost.
    static let lineBudget = 200_000

    private static let storage = Storage()

    static func presentation(for tool: ToolUse, projectPath: String) -> ToolPresentation {
        storage.presentation(for: tool, projectPath: projectPath)
    }

    // For calls that will never be drawn again: a deleted session, or turns a checkpoint
    // has wound back. Everything else is left to the budget.
    static func forget(_ toolIDs: some Sequence<String>) {
        storage.forget(toolIDs)
    }

    private final class Storage: @unchecked Sendable {
        private struct Entry {
            let presentation: ToolPresentation
            let startLine: Int?
            // What git saw the call write, which lands later still. Held as its size
            // rather than itself, since a patch only ever appears once and comparing whole
            // patches on every cache hit would cost more than building one.
            let writtenSize: Int?
            let lines: Int
            var lastUsed: Int
        }

        private let lock = NSLock()
        private var values: [String: Entry] = [:]
        private var lines = 0
        private var clock = 0

        func presentation(for tool: ToolUse, projectPath: String) -> ToolPresentation {
            if let cached = withLock({ used(tool) }) { return cached }
            let fresh = ToolPresentation(tool: tool, projectPath: projectPath)
            return withLock {
                if let cached = used(tool) { return cached }
                drop(tool.id)
                clock += 1
                let entry = Entry(presentation: fresh,
                                  startLine: tool.editStartLine,
                                  writtenSize: Self.writtenSize(tool),
                                  lines: 1 + fresh.changes.reduce(0) { $0 + $1.lines.count },
                                  lastUsed: clock)
                values[tool.id] = entry
                lines += entry.lines
                trim()
                return fresh
            }
        }

        func forget(_ toolIDs: some Sequence<String>) {
            withLock {
                for id in toolIDs { drop(id) }
            }
        }

        // A call whose change was measured but was too large to keep is still a call the
        // app knows something new about, so "nothing written" and "written, no patch" have
        // to read differently here.
        private static func writtenSize(_ tool: ToolUse) -> Int? {
            tool.written.map { $0.patch?.count ?? 0 }
        }

        // Called holding the lock.
        private func used(_ tool: ToolUse) -> ToolPresentation? {
            guard let entry = values[tool.id], entry.startLine == tool.editStartLine,
                  entry.writtenSize == Self.writtenSize(tool)
            else { return nil }
            clock += 1
            values[tool.id]?.lastUsed = clock
            return entry.presentation
        }

        private func drop(_ id: String) {
            guard let entry = values.removeValue(forKey: id) else { return }
            lines -= entry.lines
        }

        // Over budget, the calls nobody has looked at for longest go first. A whole
        // conversation is usually drawn in one go, so this drops the sessions that have
        // been closed longest rather than picking rows out of the one on screen.
        private func trim() {
            guard lines > ToolPresentationCache.lineBudget else { return }
            for id in values.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }).map(\.key) {
                drop(id)
                if lines <= ToolPresentationCache.lineBudget { return }
            }
        }

        private func withLock<T>(_ operation: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return operation()
        }
    }
}
