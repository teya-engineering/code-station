import Foundation

// How one tool call reads in the UI: a verb, the one argument that matters, and,
// for an edit, the line changes it is making. All of it comes from the call's input,
// which the CLI sends complete and never changes afterwards.
struct ToolPresentation: Sendable {
    struct Line: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable { case addition, deletion, context }
        let id: Int
        let kind: Kind
        let text: String

        var marker: String {
            switch kind {
            case .addition: "+"
            case .deletion: "-"
            case .context: " "
            }
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
    var diff: [Line] = []
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
        case "Edit":
            let change = Self.diff(old: input["old_string"] as? String ?? "",
                                   new: input["new_string"] as? String ?? "")
            diff = change.lines
            added = change.added
            removed = change.removed
        case "Write":
            let change = Self.diff(old: "", new: input["content"] as? String ?? "")
            diff = change.lines
            added = change.added
            removed = change.removed
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
    }

    // MARK: - Diffing an edit

    // A cheap line diff: lines shared at the start and end of both strings are context,
    // everything between is a straight remove-then-add. Edit inputs are written as the
    // changed lines plus a little surrounding context, so this reads like a real diff
    // without needing a diff algorithm.
    private static func diff(old: String, new: String) -> (lines: [Line], added: Int, removed: Int) {
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
        func append(_ kind: Line.Kind, _ text: String) {
            lines.append(Line(id: lines.count, kind: kind, text: text))
        }
        for text in oldLines[..<prefixCount].suffix(2) { append(.context, text) }
        for text in oldChange { append(.deletion, text) }
        for text in newChange { append(.addition, text) }
        for text in oldLines[(oldLines.count - suffixCount)...].prefix(2) { append(.context, text) }
        return (lines, newChange.count, oldChange.count)
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
enum ToolPresentationCache {
    private static let storage = Storage()

    static func presentation(for tool: ToolUse, projectPath: String) -> ToolPresentation {
        storage.presentation(for: tool, projectPath: projectPath)
    }

    // Dropped when the conversation they were built from leaves memory. An entry for an
    // edit holds the lines it changed, so keeping them for every call the app has ever
    // drawn would undo the point of letting the conversation go.
    static func forget(_ toolIDs: some Sequence<String>) {
        storage.forget(toolIDs)
    }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: ToolPresentation] = [:]

        func presentation(for tool: ToolUse, projectPath: String) -> ToolPresentation {
            if let cached = withLock({ values[tool.id] }) { return cached }
            let fresh = ToolPresentation(tool: tool, projectPath: projectPath)
            return withLock {
                if let cached = values[tool.id] { return cached }
                values[tool.id] = fresh
                return fresh
            }
        }

        func forget(_ toolIDs: some Sequence<String>) {
            withLock {
                for id in toolIDs { values.removeValue(forKey: id) }
            }
        }

        private func withLock<T>(_ operation: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return operation()
        }
    }
}
