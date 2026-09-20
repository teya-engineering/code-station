import Foundation

// The slash commands a session can be sent, gathered for one agent in one folder.
//
// The three CLIs agree on the shape of a command - a markdown file whose words become
// the prompt - and on nothing else. They keep them in different folders, call them
// different things, and only Claude Code recognises one when it arrives in a headless
// prompt. Codex and Copilot read the line as ordinary text and go looking for a file
// named after it, so for those two the app puts the words in the prompt itself.
struct AgentCommand: Identifiable, Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        // The app answers it, whichever agent the session runs on.
        case app
        // The CLI answers it.
        case builtIn
        // A file in the person's own folder, offered in every project.
        case user
        // A file in the checkout, offered only to sessions working there.
        case project
    }

    let name: String
    let summary: String
    let scope: Scope
    // The file the words come from, for the commands that have one.
    var file: URL?

    var id: String { name }
    var typed: String { "/\(name)" }
}

enum AgentCommands {
    // Everything a session on this agent can be offered, nearest first: what the app
    // answers, then what the project keeps, then what the person keeps, and last what the
    // CLI ships. A name found twice is the nearer copy's, so a file someone wrote takes
    // the name over the CLI's own command of that name. The app's two are the exception,
    // since those are answered here before a prompt is ever sent.
    static func all(for agent: AgentKind, workingDirectories: [String],
                    home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    environment: [String: String] = ProcessInfo.processInfo.environment)
        -> [AgentCommand] {
        var found = appCommands(for: agent)
        var taken = Set(found.map(\.name))
        for folder in folders(for: agent, home: home, workingDirectories: workingDirectories,
                              environment: environment) {
            for command in onDisk(in: folder.url, scope: folder.scope)
            where taken.insert(command.name).inserted {
                found.append(command)
            }
        }
        for command in builtIns(for: agent) where taken.insert(command.name).inserted {
            found.append(command)
        }
        return found
    }

    // What the app intercepts rather than passing on. Compaction is Claude Code's alone:
    // the other two make room as they go and the app says so when asked.
    static func appCommands(for agent: AgentKind) -> [AgentCommand] {
        var commands = [AgentCommand(name: "clear",
                                     summary: "Start a fresh conversation in the same folder",
                                     scope: .app)]
        if agent == .claudeCode {
            commands.append(AgentCommand(name: "compact",
                                         summary: "Summarise the conversation so far and carry on from it",
                                         scope: .app))
        }
        return commands
    }

    // Only the commands the CLI answers in a headless prompt. Most of what a CLI offers
    // belongs to its own terminal window - picking a model, reading usage - and arrives
    // here as a line of text the agent has to guess at, so none of those are offered.
    static func builtIns(for agent: AgentKind) -> [AgentCommand] {
        switch agent {
        case .claudeCode:
            [AgentCommand(name: "init", summary: "Write a CLAUDE.md for this codebase", scope: .builtIn),
             AgentCommand(name: "review", summary: "Review a pull request", scope: .builtIn),
             AgentCommand(name: "security-review", summary: "Review the current changes for security problems",
                          scope: .builtIn)]
        case .codex, .copilot:
            []
        }
    }

    struct Folder: Equatable, Sendable {
        let url: URL
        let scope: AgentCommand.Scope
    }

    // Where each CLI keeps the commands people write. A workspace session works in
    // several checkouts at once, so each of them is asked.
    static func folders(for agent: AgentKind, home: URL, workingDirectories: [String],
                        environment: [String: String] = ProcessInfo.processInfo.environment)
        -> [Folder] {
        let roots = workingDirectories.map { URL(fileURLWithPath: $0) }
        switch agent {
        case .claudeCode:
            let base = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".claude")
            return roots.map { Folder(url: $0.appendingPathComponent(".claude/commands"), scope: .project) }
                + [Folder(url: base.appendingPathComponent("commands"), scope: .user)]
        case .codex:
            let base = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".codex")
            return [Folder(url: base.appendingPathComponent("prompts"), scope: .user)]
        case .copilot:
            return roots.map { Folder(url: $0.appendingPathComponent(".github/prompts"), scope: .project) }
                + [Folder(url: home.appendingPathComponent(".copilot/prompts"), scope: .user)]
        }
    }

    // The markdown files in one folder. Subfolders name what they hold, the way all three
    // CLIs read them, so `review/api.md` is `/review:api`.
    static func onDisk(in folder: URL, scope: AgentCommand.Scope) -> [AgentCommand] {
        let files = FileManager.default
        guard let walker = files.enumerator(at: folder,
                                            includingPropertiesForKeys: [.isRegularFileKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        // Both sides resolved, since a folder under /var is handed back as /private/var
        // and the two spellings would not line up.
        let base = folder.resolvingSymlinksInPath().pathComponents
        var found: [AgentCommand] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "md" {
            guard let name = commandName(of: url, under: base) else { continue }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            found.append(AgentCommand(name: name, summary: summary(of: text, named: name),
                                      scope: scope, file: url))
        }
        return found.sorted { $0.name < $1.name }
    }

    private static func commandName(of url: URL, under base: [String]) -> String? {
        let whole = url.resolvingSymlinksInPath().pathComponents
        guard whole.count > base.count, Array(whole.prefix(base.count)) == base else { return nil }
        let parts = Array(whole.dropFirst(base.count))
        guard var last = parts.last else { return nil }
        last = (last as NSString).deletingPathExtension
        // VS Code's naming for the same thing, which Copilot also reads.
        if last.lowercased().hasSuffix(".prompt") { last = String(last.dropLast(7)) }
        let name = (parts.dropLast() + [last]).joined(separator: ":")
        return name.isBlank ? nil : name
    }

    // MARK: - Reading a command file

    // The line under the name in the menu. A file that says what it is in its front
    // matter is taken at its word; otherwise the first line of the prompt stands in,
    // which is usually the sentence that explains it anyway.
    static func summary(of text: String, named name: String) -> String {
        if let described = frontMatterValue("description", in: text) { return described }
        let first = body(of: text)
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: CharacterSet(charactersIn: "# *>-").union(.whitespaces)) ?? ""
        guard !first.isBlank else { return name }
        return first.count > 120 ? String(first.prefix(120)) + "…" : first
    }

    // The prompt itself, with the front matter block taken off the top. Everything in
    // that block is for the CLI that reads it, so none of it belongs in a prompt.
    static func body(of text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmedLine == "---",
              let close = lines.dropFirst().firstIndex(where: { $0.trimmedLine == "---" })
        else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        lines.removeSubrange(0...close)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func frontMatterValue(_ key: String, in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmedLine == "---" else { return nil }
        for line in lines.dropFirst() {
            let line = line.trimmedLine
            if line == "---" { return nil }
            guard line.lowercased().hasPrefix(key + ":") else { continue }
            let value = line.dropFirst(key.count + 1)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return value.isBlank ? nil : value
        }
        return nil
    }

    // MARK: - Standing in for a CLI that does not expand its own commands

    // The prompt to send for a typed command, or nil when the line is not one the app
    // knows a file for and should travel as it was typed.
    static func expansion(of text: String, in commands: [AgentCommand]) -> String? {
        let line = text.trimmed
        guard line.hasPrefix("/") else { return nil }
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1,
                                           omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.first?.lowercased(), !name.isEmpty,
              let command = commands.first(where: { $0.name.lowercased() == name }),
              let file = command.file,
              let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let arguments = parts.count > 1 ? parts[1].trimmed : ""
        return filled(body(of: contents), with: arguments)
    }

    // The placeholders every CLI supports in a command file: all of what was typed after
    // the name, or one word of it at a time. A file that asks for neither still gets the
    // words, since they were typed for a reason.
    static func filled(_ body: String, with arguments: String) -> String {
        let words = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        var filled = body
        var asked = body.contains("$ARGUMENTS")
        filled = filled.replacingOccurrences(of: "$ARGUMENTS", with: arguments)
        for index in 1...9 {
            let placeholder = "$\(index)"
            guard filled.contains(placeholder) else { continue }
            asked = true
            filled = filled.replacingOccurrences(of: placeholder,
                                                 with: index <= words.count ? words[index - 1] : "")
        }
        guard !asked, !arguments.isBlank else { return filled.trimmed }
        return "\(filled.trimmed)\n\n\(arguments)"
    }
}

private extension Substring {
    var trimmedLine: String { trimmingCharacters(in: .whitespaces) }
}

// The word being typed after a slash, and the commands it points at.
enum SlashQuery {
    // A command is only ever the whole of an unfinished prompt: the CLIs read one off the
    // front of a prompt and nowhere else, and a slash in the middle of a sentence is a
    // path or a date far more often than it is a command.
    static func typed(in text: String) -> String? {
        guard text.hasPrefix("/"), text.count <= 64,
              !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return String(text.dropFirst())
    }

    // What matches, nearest first: the name itself, then a name starting with it, then a
    // name holding it anywhere. A name is often two words joined by a colon, so the part
    // after the colon counts as a start of its own.
    static func matches(_ query: String, in commands: [AgentCommand]) -> [AgentCommand] {
        let query = query.lowercased()
        guard !query.isEmpty else { return commands }
        return commands.compactMap { command -> (AgentCommand, Int)? in
            let name = command.name.lowercased()
            let tail = name.split(separator: ":").last.map(String.init) ?? name
            if name == query { return (command, 0) }
            if name.hasPrefix(query) { return (command, 1) }
            if tail.hasPrefix(query) { return (command, 2) }
            if name.contains(query) { return (command, 3) }
            return nil
        }
        .enumerated()
        .sorted { left, right in
            left.element.1 != right.element.1
                ? left.element.1 < right.element.1
                : left.offset < right.offset
        }
        .map(\.element.0)
    }
}
