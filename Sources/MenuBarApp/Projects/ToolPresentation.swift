import Foundation

// How one tool call reads in the UI: a verb, the one argument that matters, and,
// for an edit, the line changes it is making. All of it comes from the call's input,
// which the CLI sends complete and never changes afterwards.
struct ToolPresentation {
    struct Line: Identifiable, Equatable {
        enum Kind: Equatable { case addition, deletion, context }
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
            argument = Self.singleLine(input["command"] as? String ?? "")
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
        var oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        var newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")

        var prefix: [String] = []
        while let first = oldLines.first, first == newLines.first {
            prefix.append(first)
            oldLines.removeFirst()
            newLines.removeFirst()
        }
        var suffix: [String] = []
        while let last = oldLines.last, !newLines.isEmpty, last == newLines.last {
            suffix.insert(last, at: 0)
            oldLines.removeLast()
            newLines.removeLast()
        }

        var lines: [Line] = []
        func append(_ kind: Line.Kind, _ text: String) {
            lines.append(Line(id: lines.count, kind: kind, text: text))
        }
        for text in prefix.suffix(2) { append(.context, text) }
        for text in oldLines { append(.deletion, text) }
        for text in newLines { append(.addition, text) }
        for text in suffix.prefix(2) { append(.context, text) }
        return (lines, newLines.count, oldLines.count)
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
        let root = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        if path.hasPrefix(root) { return String(path.dropFirst(root.count)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.replacingOccurrences(of: home, with: "~")
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// The transcript and the sidebar both redraw on every streamed token, so parsing a
// call's input JSON on each draw would be wasted work. Inputs are immutable once the
// call exists, which makes its id a safe cache key.
@MainActor
enum ToolPresentationCache {
    private static var cache: [String: ToolPresentation] = [:]

    static func presentation(for tool: ToolUse, projectPath: String) -> ToolPresentation {
        if let cached = cache[tool.id] { return cached }
        let fresh = ToolPresentation(tool: tool, projectPath: projectPath)
        cache[tool.id] = fresh
        return fresh
    }

    // Dropped when the conversation they were built from leaves memory. An entry for an
    // edit holds the lines it changed, so keeping them for every call the app has ever
    // drawn would undo the point of letting the conversation go.
    static func forget(_ toolIDs: some Sequence<String>) {
        for id in toolIDs { cache.removeValue(forKey: id) }
    }
}
