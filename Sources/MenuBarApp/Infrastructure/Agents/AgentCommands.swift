import Foundation
import Yams

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
        // Part of a plugin the CLI loads, named after the plugin.
        case plugin
    }

    let name: String
    let summary: String
    let scope: Scope
    // The file the words come from, for the commands that have one.
    var file: URL?

    var id: String { name }
    var typed: String { "/\(name)" }

    // Whether the agent still acts on it when it is named later in a prompt, which is the
    // case for a skill or a command file the agent picks up while it reads. The app's own
    // commands are caught only at the front, and the CLI's built-ins only run as the
    // first word.
    func worksMidPrompt(for agent: AgentKind) -> Bool {
        guard agent.readsCommandsMidPrompt else { return false }
        return switch scope {
        case .user, .project, .plugin: true
        case .app, .builtIn: false
        }
    }
}

enum AgentCommands {
    // Everything a session on this agent can be offered, in the order the agent settles a
    // name it finds twice: what the app answers, then the folders the CLI reads, and last
    // what the CLI ships. A name found twice is the first copy's, so a file someone wrote
    // takes the name over the CLI's own command of that name. The app's own are the
    // exception, since those are answered here before a prompt is ever sent.
    static func all(for agent: AgentKind, workingDirectories: [String],
                    home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    environment: [String: String] = ProcessInfo.processInfo.environment)
        -> [AgentCommand] {
        var found = appCommands(for: agent)
        var taken = Set(found.map(\.name))
        for folder in folders(for: agent, home: home, workingDirectories: workingDirectories,
                              environment: environment) {
            let commands = switch folder.holds {
            case .commands: onDisk(in: folder.url, scope: folder.scope, namespace: folder.namespace)
            case .skills: skills(in: folder.url, scope: folder.scope, namespace: folder.namespace)
            }
            for command in commands where taken.insert(command.name).inserted {
                found.append(command)
            }
        }
        for command in builtIns(for: agent) where taken.insert(command.name).inserted {
            found.append(command)
        }
        return found
    }

    // What the app intercepts rather than passing on. Compaction and planning are Claude
    // Code's alone: the other two make room as they go and the app says so when asked, and
    // only Claude Code has a plan mode a headless run can start in.
    static func appCommands(for agent: AgentKind) -> [AgentCommand] {
        var commands = [AgentCommand(name: "clear",
                                     summary: "Start a fresh conversation in the same folder",
                                     scope: .app),
                    AgentCommand(name: "btw",
                                 summary: "Ask a quick side question without adding it to the conversation",
                                 scope: .app)]
        if agent == .claudeCode {
            commands.append(AgentCommand(name: "compact",
                                         summary: "Summarise the conversation so far and carry on from it",
                                         scope: .app))
            commands.append(AgentCommand(name: "plan",
                                         summary: "Plan the work first and change nothing until the plan is approved",
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
        enum Holds: Equatable, Sendable {
            // Markdown files, each one a command.
            case commands
            // A folder per skill, each holding a SKILL.md.
            case skills
        }

        let url: URL
        let scope: AgentCommand.Scope
        let holds: Holds
        // Put in front of every name found here, as a plugin's name is.
        var namespace: String? = nil
    }

    // Where each CLI keeps the commands people write. A workspace session works in
    // several checkouts at once, so each of them is asked.
    static func folders(for agent: AgentKind, home: URL, workingDirectories: [String],
                        environment: [String: String] = ProcessInfo.processInfo.environment)
        -> [Folder] {
        let roots = workingDirectories.map { URL(fileURLWithPath: $0) }
        switch agent {
        case .claudeCode:
            let base = agent.configDirectory(environment: environment, home: home)
            // Claude settles a skill's name the other way round from a command's: your own
            // skill over the project's, and a skill over any command of the same name.
            return [Folder(url: base.appendingPathComponent("skills"), scope: .user, holds: .skills)]
                + roots.map { Folder(url: $0.appendingPathComponent(".claude/skills"), scope: .project,
                                     holds: .skills) }
                + roots.map { Folder(url: $0.appendingPathComponent(".claude/commands"), scope: .project,
                                     holds: .commands) }
                + [Folder(url: base.appendingPathComponent("commands"), scope: .user, holds: .commands)]
                + pluginFolders(base: base, lead: roots.first)
        case .codex:
            let base = agent.configDirectory(environment: environment, home: home)
            return [Folder(url: base.appendingPathComponent("prompts"), scope: .user, holds: .commands)]
        case .copilot:
            return roots.map { Folder(url: $0.appendingPathComponent(".github/prompts"), scope: .project,
                                      holds: .commands) }
                + [Folder(url: home.appendingPathComponent(".copilot/prompts"), scope: .user, holds: .commands)]
        }
    }

    // The plugins Claude loads in the lead checkout, which is the folder it runs in. A
    // plugin counts when it is switched on in the person's settings or the checkout's,
    // the nearer setting winning, and is installed either for everyone or for this
    // project. A worktree belongs to the project of the checkout it came from, and that
    // checkout's path is the one a project install records.
    static func pluginFolders(base: URL, lead: URL?) -> [Folder] {
        var enabled: [String: Bool] = [:]
        for file in claudeSettingsFiles(base: base, lead: lead) {
            for (key, value) in jsonObject(at: file)?["enabledPlugins"] as? [String: Any] ?? [:] {
                if let on = value as? Bool { enabled[key] = on }
            }
        }

        let installed = jsonObject(at: base.appendingPathComponent("plugins/installed_plugins.json"))?["plugins"]
            as? [String: Any] ?? [:]
        let project = lead.map { [$0, mainCheckout(of: $0)].map { $0.resolvingSymlinksInPath().path } } ?? []
        var folders: [Folder] = []
        for key in enabled.filter(\.value).keys.sorted() {
            let installs = installed[key] as? [[String: Any]] ?? []
            let forProject = installs.first { install in
                ["project", "local"].contains(install["scope"] as? String)
                    && (install["projectPath"] as? String).map {
                        project.contains(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path)
                    } == true
            }
            guard let install = forProject ?? installs.first(where: { $0["scope"] as? String == "user" }),
                  let path = install["installPath"] as? String else { continue }
            let root = URL(fileURLWithPath: path)
            let name = jsonObject(at: root.appendingPathComponent(".claude-plugin/plugin.json"))?["name"] as? String
                ?? String(key.prefix { $0 != "@" })
            folders += [Folder(url: root.appendingPathComponent("skills"), scope: .plugin, holds: .skills,
                               namespace: name),
                        Folder(url: root.appendingPathComponent("commands"), scope: .plugin, holds: .commands,
                               namespace: name)]
        }
        return folders
    }

    // The settings files Claude reads in the folder it runs in, farthest first, so a
    // later file overrides an earlier one.
    static func claudeSettingsFiles(base: URL, lead: URL?) -> [URL] {
        var files = [base.appendingPathComponent("settings.json")]
        if let lead {
            files += [lead.appendingPathComponent(".claude/settings.json"),
                      lead.appendingPathComponent(".claude/settings.local.json")]
        }
        return files
    }

    private static func jsonObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // A linked worktree's .git is a file that points into the main checkout's .git
    // folder, and the commondir file there leads back to it. A submodule's pointer has
    // no commondir, so it stays its own checkout.
    static func mainCheckout(of checkout: URL) -> URL {
        guard let pointer = try? String(contentsOf: checkout.appendingPathComponent(".git"), encoding: .utf8),
              pointer.hasPrefix("gitdir:") else { return checkout }
        let target = String(pointer.dropFirst("gitdir:".count)).trimmed
        let gitDirectory = target.hasPrefix("/") ? URL(fileURLWithPath: target)
                                                 : checkout.appendingPathComponent(target)
        guard let common = (try? String(contentsOf: gitDirectory.appendingPathComponent("commondir"),
                                        encoding: .utf8))?.trimmed
        else { return checkout }
        let shared = (common.hasPrefix("/") ? URL(fileURLWithPath: common)
                                            : gitDirectory.appendingPathComponent(common)).standardizedFileURL
        return shared.lastPathComponent == ".git" ? shared.deletingLastPathComponent() : checkout
    }

    // The markdown files in one folder. Subfolders name what they hold, the way all three
    // CLIs read them, so `review/api.md` is `/review:api`.
    static func onDisk(in folder: URL, scope: AgentCommand.Scope,
                       namespace: String? = nil) -> [AgentCommand] {
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
            guard let plain = commandName(of: url, under: base) else { continue }
            let name = namespace.map { "\($0):\(plain)" } ?? plain
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            found.append(AgentCommand(name: name, summary: summary(of: text, named: name),
                                      scope: scope, file: url))
        }
        return found.sorted { $0.name < $1.name }
    }

    // One folder per skill, holding a SKILL.md. The folder is often a link to a skill kept
    // in another checkout, so it is read where the link points rather than checked
    // against the folder it sits in, the way a command file is. Claude names a skill after
    // its folder, even when the front matter gives it some other name.
    static func skills(in folder: URL, scope: AgentCommand.Scope,
                       namespace: String? = nil) -> [AgentCommand] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var found: [AgentCommand] = []
        for entry in entries {
            let file = entry.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  // Claude keeps these for itself and leaves them out of its own menu.
                  frontMatterValue("user-invocable", in: text)?.lowercased() != "false"
            else { continue }
            let name = namespace.map { "\($0):\(entry.lastPathComponent)" } ?? entry.lastPathComponent
            found.append(AgentCommand(name: name, summary: summary(of: text, named: name),
                                      scope: scope, file: file))
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
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let close = frontMatterEnd(lines)
        else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        lines.removeSubrange(0...close)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func frontMatterEnd(_ lines: [Substring]) -> Int? {
        guard lines.first?.trimmedLine == "---" else { return nil }
        return lines.dropFirst().firstIndex { $0.trimmedLine == "---" }
    }

    // Only top-level keys count, so a `description` kept under `metadata` does not
    // describe the file. The menu shows one line, so a value folded or written over
    // several lines is joined with spaces.
    private static func frontMatterValue(_ key: String, in text: String) -> String? {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let close = frontMatterEnd(lines) else { return nil }
        let block = lines[1..<close]
        let value: String?
        // The basic resolver keeps every value as text, so `false` and `No` are read the
        // same way whatever the YAML version would make of them.
        if let mapping = (try? Yams.compose(yaml: block.joined(separator: "\n"), .basic))?.mapping {
            value = mapping.first { $0.key.string?.lowercased() == key }?.value.scalar?.string
        } else {
            value = looseValue(key, in: block)
        }
        let line = value?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line?.isBlank == false ? line : nil
    }

    // People write front matter by hand, and a colon inside a plain value, as in
    // `description: Use when: the build fails`, is not valid YAML. The CLIs still read
    // such a file, so it falls back to taking each top-level line as written.
    private static func looseValue(_ key: String, in block: ArraySlice<Substring>) -> String? {
        for line in block where line.indentation == 0 {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmedLine.lowercased() == key else { continue }
            let value = line[line.index(after: colon)...].trimmedLine
            if let quote = value.first, "\"'".contains(quote), value.count > 1, value.last == quote {
                return String(value.dropFirst().dropLast())
            }
            return value
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
    var indentation: Int { prefix { $0 == " " || $0 == "\t" }.count }
}

// A word in a prompt that starts with a slash and may name a command. Ranges count UTF-16
// units, the way the text field counts them.
struct SlashWord: Equatable, Sendable {
    // From the slash to the next space.
    let range: NSRange
    // From the slash to the end of the name. The whole word for a leading command; later
    // on, punctuation after the name is left out of it.
    let nameRange: NSRange
    // The name as written, without the slash.
    let name: String
    // What has been typed of the name up to the caret, for the word the caret is in. The
    // whole name for any other word.
    var query: String
    // Whether it is the first thing in the prompt, where everything is offered.
    let atStart: Bool
}

// The names a prompt can call on, split by where in the prompt each one works.
struct SlashCommandNames: Equatable, Sendable {
    // The first word of a prompt can be any command.
    var leading: Set<String> = []
    // Further in, only what the agent still acts on there.
    var inline: Set<String> = []

    init(leading: Set<String> = [], inline: Set<String> = []) {
        self.leading = leading
        self.inline = inline
    }

    init(_ commands: [AgentCommand], agent: AgentKind) {
        leading = Set(commands.map { $0.name.lowercased() })
        inline = Set(commands.filter { $0.worksMidPrompt(for: agent) }.map { $0.name.lowercased() })
    }

    func offered(atStart: Bool) -> Set<String> { atStart ? leading : inline }
}

// What the menu offers for the word at the caret: the commands that work where it sits,
// and the matches that only work at the start of a prompt, which are shown but cannot be
// picked.
struct SlashOffer: Equatable {
    var usable: [AgentCommand] = []
    var startOnly: [AgentCommand] = []

    var isEmpty: Bool { usable.isEmpty && startOnly.isEmpty }
}

// The slash words in a prompt, and the commands they point at.
//
// A slash counts at the start of the prompt or after a space, a tab or a new line. A word
// holding a second slash is a path, and a slash inside a word, as in `src/routes`, `11/20`
// or `and/or`, never counts. A leading command runs to the first space, since that is
// how the CLI reads one. Later on the agent reads the prompt as prose, so the name is
// the run of letters, digits and `_-:.` after the slash, without a full stop or colon at
// its end. Code, in a fenced block or in backticks, is sent as written and never runs, so
// a slash word in it does not count.
enum SlashQuery {
    private static let slash = UInt16(UInt8(ascii: "/"))
    private static let backtick = UInt16(UInt8(ascii: "`"))

    // Every slash word in the text, in order. A paragraph that comes later in a prompt,
    // such as one under a code block, does not open it, so nothing in it is at the start.
    static func words(in text: String, opensPrompt: Bool = true) -> [SlashWord] {
        let units = Array(text.utf16)
        let code = codeRanges(in: text, units: units)
        var words: [SlashWord] = []
        var index = 0
        var blank = true
        while index < units.count {
            guard !isSpace(units[index]) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < units.count, !isSpace(units[end]) { end += 1 }
            let body = units[(index + 1)..<end]
            let start = index
            if units[index] == slash, !body.contains(slash),
               !code.contains(where: { NSLocationInRange(start, $0) }) {
                let atStart = opensPrompt && blank
                var nameEnd = end
                if !atStart {
                    nameEnd = body.firstIndex { !isNameUnit($0) } ?? end
                    while nameEnd > index + 1, isTrailingPunctuation(units[nameEnd - 1]) { nameEnd -= 1 }
                }
                let name = String(decoding: units[(index + 1)..<nameEnd], as: UTF16.self)
                words.append(SlashWord(range: NSRange(location: index, length: end - index),
                                       nameRange: NSRange(location: index, length: nameEnd - index),
                                       name: name, query: name, atStart: atStart))
            }
            blank = false
            index = end
        }
        return words
    }

    // The slash word the caret is in, with what has been typed of it so far. Nil with a
    // selection, since the caret is then nowhere, and past the length of any name.
    static func word(in text: String, caret: Int?) -> SlashWord? {
        guard let caret,
              var word = words(in: text).first(where: {
                  caret > $0.range.location && caret <= NSMaxRange($0.range)
              }) else { return nil }
        let typed = NSRange(location: word.range.location + 1, length: caret - word.range.location - 1)
        word.query = (text as NSString).substring(with: typed)
        return word.query.count <= 64 ? word : nil
    }

    // The commands to colour. The word being typed, with the caret at its end, is coloured
    // while a command offered there still starts with it. Any other word has to be a whole
    // name offered where it sits, so a typo or a command that only works first stays
    // plain, and the colour always means the command will run.
    static func highlightedRanges(in text: String, caret: Int?, names: SlashCommandNames,
                                  opensPrompt: Bool = true) -> [NSRange] {
        words(in: text, opensPrompt: opensPrompt).compactMap { word in
            let offered = names.offered(atStart: word.atStart)
            let name = word.name.lowercased()
            let typing = caret == NSMaxRange(word.range) && word.nameRange == word.range
            let known = typing ? offered.contains { $0.hasPrefix(name) } : offered.contains(name)
            return known ? word.nameRange : nil
        }
    }

    // At the start of a prompt everything that matches is offered. Further in, a match the
    // agent only acts on as the first word is shown apart, so it is clear why it is there
    // and that it will not run. A slash on its own further in is usually just a slash, as
    // in `A / B`, so nothing is offered until a letter follows it.
    static func offer(for word: SlashWord, in commands: [AgentCommand], agent: AgentKind) -> SlashOffer {
        guard word.atStart || !word.query.isEmpty else { return SlashOffer() }
        let found = matches(word.query, in: commands)
        guard !word.atStart else { return SlashOffer(usable: found) }
        return SlashOffer(usable: found.filter { $0.worksMidPrompt(for: agent) },
                          startOnly: found.filter { !$0.worksMidPrompt(for: agent) })
    }

    // The prompt with a command put in place of the word at the caret, and where the caret
    // goes. The word is replaced from its slash to the end of its name, or to the caret if
    // that is further on. A space follows unless a space or punctuation is already there,
    // so anything the command takes can be typed straight on. The caret lands past that
    // space, but not past a line break or a comma the person typed.
    static func completing(_ word: SlashWord, with command: AgentCommand, caret: Int,
                           in text: String) -> (text: String, caret: Int) {
        let text = text as NSString
        let start = word.range.location
        let end = min(max(NSMaxRange(word.nameRange), caret), text.length)
        let next = (text.substring(from: end) as String).first
        let settled = next.map { $0.isWhitespace || ",.;:!?)".contains($0) } ?? false
        let typed = command.typed
        let completed = text.replacingCharacters(in: NSRange(location: start, length: end - start),
                                                 with: settled ? typed : typed + " ")
        let steps = !settled || next.map { $0.isWhitespace && !$0.isNewline } == true ? 1 : 0
        return (completed, start + (typed as NSString).length + steps)
    }

    // What Markdown shows as code, the way the transcript reads it: every line from a fence
    // to the fence that closes it, or to the end if none does, and each span opened by a
    // run of backticks and closed by a run just as long.
    private static func codeRanges(in text: String, units: [UInt16]) -> [NSRange] {
        guard units.contains(backtick) || text.contains("~~~") else { return [] }
        var ranges: [NSRange] = []
        var prose: [NSRange] = []
        var fence: Fence?
        var fenceStart = 0
        var proseStart = 0
        var offset = 0
        for line in text.components(separatedBy: "\n") {
            let length = line.utf16.count
            let lineFence = Fence(line)
            if let opened = fence {
                if let lineFence, opened.isClosed(by: lineFence) {
                    ranges.append(NSRange(location: fenceStart, length: offset + length - fenceStart))
                    fence = nil
                    proseStart = offset + length
                }
            } else if let lineFence, lineFence.opens {
                prose.append(NSRange(location: proseStart, length: offset - proseStart))
                fence = lineFence
                fenceStart = offset
            }
            offset += length + 1
        }
        if fence != nil {
            ranges.append(NSRange(location: fenceStart, length: units.count - fenceStart))
        } else {
            prose.append(NSRange(location: proseStart, length: max(units.count - proseStart, 0)))
        }

        for part in prose {
            var index = part.location
            let end = NSMaxRange(part)
            while index < end {
                guard units[index] == backtick else {
                    index += 1
                    continue
                }
                let run = backtickRun(at: index, in: units, before: end)
                var search = index + run
                var closed = false
                while search < end {
                    guard units[search] == backtick else {
                        search += 1
                        continue
                    }
                    let closing = backtickRun(at: search, in: units, before: end)
                    if closing == run {
                        ranges.append(NSRange(location: index, length: search + closing - index))
                        index = search + closing
                        closed = true
                        break
                    }
                    search += closing
                }
                if !closed { index += run }
            }
        }
        return ranges
    }

    private static func backtickRun(at index: Int, in units: [UInt16], before end: Int) -> Int {
        var length = 0
        while index + length < end, units[index + length] == backtick { length += 1 }
        return length
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit)?.properties.isWhitespace ?? false
    }

    private static func isNameUnit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit), scalar.isASCII else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || "_-:.".unicodeScalars.contains(scalar)
    }

    private static func isTrailingPunctuation(_ unit: UInt16) -> Bool {
        unit == UInt16(UInt8(ascii: ".")) || unit == UInt16(UInt8(ascii: ":"))
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
