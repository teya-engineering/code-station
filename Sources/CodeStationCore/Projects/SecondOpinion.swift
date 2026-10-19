import Foundation

// Another agent reads a session's changes and leaves review comments on them. It runs on
// its own, read-only, outside the session's conversation: what it finds lands in the
// review as comments the person can keep, edit or delete before any of it reaches the
// agent that wrote the code.
public enum SecondOpinion {
    public struct Failure: Error, Equatable {
        public let message: String
    }

    // One file's changes as the reviewer is shown them. The label is how the prompt names
    // the file, which in a workspace has to say which project it is in.
    public struct Patch: Equatable, Sendable {
        public var root: String
        public var path: String
        public var label: String
        public var text: String
        public var deleted = false
    }

    // What the reviewer is asked to send back for each problem it finds.
    public struct Finding: Decodable, Equatable {
        public var file: String
        public var line: Int
        public var comment: String
        public var severity: String? = nil
    }

    // What a reviewer is asked to look for. The person picks any mix of them.
    public enum Focus: String, CaseIterable, Sendable, Codable {
        case bugs, edgeCases, security, missingTests, projectInstructions

        public static let standard: [Focus] = [.bugs, .edgeCases, .security]

        public var title: String {
            switch self {
            case .bugs: "Bugs"
            case .edgeCases: "Edge cases"
            case .security: "Security"
            case .missingTests: "Missing tests"
            case .projectInstructions: "Project instructions"
            }
        }

        public var ask: String {
            switch self {
            case .bugs: "bugs and broken behaviour"
            case .edgeCases: "edge cases the change does not handle"
            case .security: "security issues"
            case .missingTests: "behaviour the change adds or alters with no test covering it"
            case .projectInstructions: "places that go against the project's AGENTS.md or CLAUDE.md instructions"
            }
        }
    }

    // One seat in the lineup: an agent on a model, thinking at an effort. Nil model or
    // effort means whatever that agent is set to use. The same agent can sit twice on
    // different models, so the seat as a whole is what tells two runs apart.
    public struct Reviewer: Hashable, Codable, Sendable {
        public var agent: AgentKind
        public var model: String?
        public var effort: String?

        public init(agent: AgentKind, model: String? = nil, effort: String? = nil) {
            self.agent = agent
            self.model = model
            self.effort = effort
        }

        public static let maxSeats = 4

        // "Sol high": what a finding adds after the agent's name. Nil when the seat runs
        // on whatever its agent is set to use.
        public var seatLabel: String? {
            let full = label()
            return full == agent.title ? nil : String(full.dropFirst(agent.title.count + " on ".count))
        }

        // "Codex on Sol high", the way a finding names who raised it.
        public func label(modelTitle: (String) -> String = { ModelChoice.title(of: $0) }) -> String {
            let words = [model.map(modelTitle), effort.map { EffortChoice.summary(of: $0, agent: agent).lowercased() }]
                .compactMap { $0 }
            return words.isEmpty ? agent.title : agent.title + " on " + words.joined(separator: " ")
        }
    }

    // How far a reviewer stands from the agent that did the work. A reviewer from another
    // maker shares the fewest blind spots; the author's own model, even on a fresh start,
    // tends to agree with itself. Unknown is a reviewer whose model is picked for it.
    public enum Independence: Equatable, Sendable {
        case differentMaker, otherModel, sameModel, unknown

        // Lit steps on the three-step meter. Unknown lights none and is drawn dashed.
        public var steps: Int {
            switch self {
            case .differentMaker: 3
            case .otherModel: 2
            case .sameModel: 1
            case .unknown: 0
            }
        }

        public var line: String {
            switch self {
            case .differentMaker: "Different maker. Best at catching what the author missed."
            case .otherModel: "Same maker, different model."
            case .sameModel: "Same model as the author, fresh start. Tends to agree with itself."
            case .unknown: "Copilot picks the model, so how independent it is can change."
            }
        }
    }

    public static func independence(of reviewer: Reviewer, from author: Reviewer) -> Independence {
        guard let theirs = maker(of: reviewer), let ours = maker(of: author) else { return .unknown }
        guard theirs == ours else { return .differentMaker }
        switch (reviewer.model.map(modelKey), author.model.map(modelKey)) {
        case (nil, nil): return reviewer.agent == author.agent ? .sameModel : .otherModel
        case (let a?, let b?): return a == b ? .sameModel : .otherModel
        default: return .otherModel
        }
    }

    // Who trained the model a seat runs on. Copilot serves several makers' models, and
    // on its default or Auto it chooses one itself, so there is no saying.
    public static func maker(of reviewer: Reviewer) -> String? {
        switch reviewer.agent {
        case .claudeCode: return "anthropic"
        case .codex: return "openai"
        case .copilot:
            guard let model = reviewer.model?.lowercased(), model != "auto" else { return nil }
            if model.hasPrefix("claude") { return "anthropic" }
            if model.hasPrefix("gpt") || model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") {
                return "openai"
            }
            if model.hasPrefix("gemini") { return "google" }
            return nil
        }
    }

    // A model's name without the parts that differ between CLIs for the same model:
    // Claude Code's "opus" and Copilot's "claude-opus-5" are one model family.
    public static func modelKey(_ id: String) -> String {
        var name = id.lowercased()
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        if name.hasPrefix("claude-") { name = String(name.dropFirst("claude-".count)) }
        if let family = ["opus", "sonnet", "haiku", "fable"].first(where: { name.hasPrefix($0) }) { return family }
        return name
    }

    // A rough wait for one seat, by how hard it is asked to think. None of the CLIs say
    // beforehand, so this only sets expectations. Seats run side by side, so a lineup
    // takes as long as its slowest seat.
    public static func minutes(for effort: String?) -> Int {
        switch effort {
        case "none", "minimal", "low": 2
        case "medium": 3
        case "high", nil: 4
        case "xhigh": 6
        default: 8
        }
    }

    // A prompt is passed on the command line, and a huge diff would not fit there or in a
    // reviewer's attention. Files past this budget are named without their patch.
    public static let patchBudget = 120_000
    public static let maxFindings = 8

    // MARK: - Gathering the changes

    public static func patches(for repositories: [(root: String, name: String)]) async -> [Patch] {
        let spansProjects = repositories.count > 1
        var patches: [Patch] = []
        for repository in repositories {
            let snapshot = await GitInspector.snapshot(at: repository.root, lane: .interactive,
                                                       comparingToLastCommit: true)
            guard snapshot.state == .ready else { continue }
            for file in snapshot.files where !file.isBinary {
                guard case .success(let text) = await GitInspector.copyText(
                    for: file, root: snapshot.root, version: .patch), !text.isBlank else { continue }
                patches.append(Patch(root: snapshot.root, path: file.path,
                                     label: spansProjects ? repository.name + "/" + file.path : file.path,
                                     text: text, deleted: file.kind == .deleted))
            }
        }
        return patches
    }

    // The changes a request asks for: everything uncommitted, or only what changed after
    // the last review was sent, read from the tree recorded in each project then.
    public static func patches(for request: SecondOpinionRequest) async -> [Patch] {
        let repositories = request.repositories.map { (root: $0.root, name: $0.name) }
        guard case .sinceReview(let trees) = request.scope else {
            return await patches(for: repositories)
        }
        let spansProjects = repositories.count > 1
        var patches: [Patch] = []
        for repository in repositories {
            guard let tree = trees[repository.root],
                  let changed = await TreeSnapshots.shared.patch(since: tree, at: repository.root) else { continue }
            patches += split(changed.text, root: changed.root).map { patch in
                var patch = patch
                if spansProjects { patch.label = repository.name + "/" + patch.path }
                return patch
            }
        }
        return patches
    }

    // One patch per file out of a patch that covers many.
    public static func split(_ text: String, root: String) -> [Patch] {
        var patches: [Patch] = []
        var current: [String] = []
        func finish() {
            guard !current.isEmpty else { return }
            let lines = current
            current = []
            let added = lines.first { $0.hasPrefix("+++ ") }.map { String($0.dropFirst(4)) }
            let removed = lines.first { $0.hasPrefix("--- ") }.map { String($0.dropFirst(4)) }
            let deleted = added == "/dev/null"
            guard let named = deleted ? removed : added, named != "/dev/null" else { return }
            let path = named.hasPrefix("a/") || named.hasPrefix("b/") ? String(named.dropFirst(2)) : named
            patches.append(Patch(root: root, path: path, label: path,
                                 text: lines.joined(separator: "\n"), deleted: deleted))
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") { finish() }
            current.append(line)
        }
        finish()
        return patches
    }

    // MARK: - Asking

    public static func prompt(for patches: [Patch], repositories: [(root: String, name: String)] = [],
                       focus: [Focus] = Focus.standard, sinceReview: Bool = false) -> String {
        var budget = patchBudget
        var shown: [String] = []
        var left: [String] = []
        for patch in patches {
            let file = "File: \(patch.label)\nPath: \((patch.root as NSString).appendingPathComponent(patch.path))"
            if patch.text.utf8.count <= budget {
                budget -= patch.text.utf8.count
                shown.append(file + "\n" + patch.text)
            } else {
                left.append(file)
            }
        }
        let asks = (focus.isEmpty ? Focus.standard : Focus.allCases.filter(focus.contains)).map(\.ask)
        var text = """
        You are reviewing changes another coding agent made in this repository. Do not change any files or run commands that change anything. You may read files for context.

        Look for real problems of these kinds: \(asks.joined(separator: "; ")). Skip style preferences, naming opinions and praise. Report at most \(maxFindings) findings, the most important first. If nothing is worth raising, return an empty array.

        Reply with only a JSON array and no other text. Each item is:
        {"file": "<the path after File: below>", "line": <line number in the new version of the file>, "severity": "must" | "should" | "look", "comment": "<one or two sentences addressed to the author>"}
        Use "must" for something that will break or is unsafe, "should" for a real problem worth fixing before this is merged, and "look" for something worth a second look.
        For a problem on a removed line, use the nearest line in the new version.
        """
        if sinceReview {
            text += "\n\nThese are only the changes made after the author's last review was sent, so they are mostly fixes for that review. Check that the fixes are right and did not break anything else."
        }
        if !repositories.isEmpty {
            text += "\n\nProject roots (the first is the working directory):\n"
                + repositories.map { "- \($0.name): \($0.root)" }.joined(separator: "\n")
            text += "\nRead the AGENTS.md or CLAUDE.md instructions in each project you review."
        }
        text += "\n\nThe changes:"
        text += "\n\n" + shown.joined(separator: "\n\n")
        if !left.isEmpty {
            text += "\n\nThese files also changed but are too large to include. Read them if you need to:\n"
                + left.joined(separator: "\n\n")
        }
        return text
    }

    // Each CLI in its strictest read-only setting, so a reviewer that reaches for an edit
    // is stopped by the agent rather than by the prompt. None of them gets the MCP servers
    // the person has set up either: any one of those can write, and none is needed to read
    // a diff.
    // The model and effort go in with the same flags a session launch uses.
    public static func arguments(for reviewer: Reviewer, prompt: String,
                          addDirectories: [String] = [],
                          codexServers: [DisabledMCPServer] = [],
                          copilotServers: [String] = []) -> [String] {
        let model = reviewer.model.map { ["--model", $0] } ?? []
        switch reviewer.agent {
        case .claudeCode:
            // Streamed like the others, so its lane can say what it is reading.
            return ["-p", prompt, "--output-format", "stream-json", "--verbose",
             "--permission-mode", "default",
             "--allowedTools", "Read,Grep,Glob",
             "--disallowedTools", "Edit,Write,MultiEdit,NotebookEdit,Bash",
             "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
                + model + (reviewer.effort.map { ["--effort", $0] } ?? [])
                + (addDirectories.isEmpty ? [] : ["--add-dir"] + addDirectories)
        case .codex:
            var arguments = ["exec", "--json", "--skip-git-repo-check",
                             "--sandbox", "read-only",
                             "-c", #"approval_policy="never""#]
            if let override = AgentLaunchConfiguration.disabledMCPServersOverride(codexServers) {
                arguments += ["-c", override]
            }
            if let effort = reviewer.effort { arguments += ["-c", "model_reasoning_effort=\"\(effort)\""] }
            // Read-only already permits reads outside the working directory. --add-dir
            // configures writable roots, which a review does not need.
            // "--" ends the options, so a list option such as --image cannot take the prompt
            // as one more value and leave Codex waiting for one on stdin.
            return arguments + model + ["--", prompt]
        case .copilot:
            // Copilot remembers what was allowed in a folder from one run to the next, and
            // a denial outranks every allowance, so writes and the shell are denied outright.
            return ["-p", prompt, "--output-format", "json",
             "--no-ask-user", "--disable-builtin-mcps", "--log-level", "none",
             "--deny-tool=shell", "--deny-tool=write"]
                + copilotServers.flatMap { ["--disable-mcp-server", $0, "--deny-tool=\($0)"] }
                + model + (reviewer.effort.map { ["--effort", $0] } ?? [])
                + addDirectories.flatMap { ["--add-dir", $0] }
        }
    }

    public static func arguments(for agent: AgentKind, prompt: String,
                          addDirectories: [String] = [],
                          codexServers: [DisabledMCPServer] = [],
                          copilotServers: [String] = []) -> [String] {
        arguments(for: Reviewer(agent: agent), prompt: prompt, addDirectories: addDirectories,
                  codexServers: codexServers, copilotServers: copilotServers)
    }

    // The servers in Copilot's own MCP configuration, which it loads on every run and has
    // no switch to leave out as a whole.
    public static func copilotServers(in url: URL = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent(".copilot/mcp-config.json")) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any] else { return [] }
        return servers.keys.sorted()
    }

    public static func review(_ patches: [Patch], reviewer: Reviewer, executable: String,
                       searchPath: String, repositories: [(root: String, name: String)],
                       focus: [Focus] = Focus.standard, sinceReview: Bool = false,
                       activity: @escaping @Sendable (String) -> Void = { _ in }) async -> Result<[ReviewComment], Failure> {
        let agent = reviewer.agent
        guard let directory = repositories.first?.root else {
            return .failure(Failure(message: "There is no project to review."))
        }
        let prompt = prompt(for: patches, repositories: repositories, focus: focus, sinceReview: sinceReview)
        let output = await run(agent: agent, executable: executable, searchPath: searchPath, directory: directory,
                               timeout: .seconds(420), writing: "Writing findings", activity: activity) { codexServers, copilotServers in
            arguments(for: reviewer, prompt: prompt, addDirectories: repositories.dropFirst().map(\.root),
                      codexServers: codexServers, copilotServers: copilotServers)
        }
        switch output {
        case .failure(let failure):
            return .failure(failure)
        case .success(let raw):
            let answer = answer(from: raw, agent: agent)
            guard let findings = findings(in: answer) else {
                SessionLog.note("\(agent.command) second opinion was unreadable: " + String(answer.prefix(400)))
                return .failure(Failure(message: "Its answer was not a list of findings."))
            }
            return .success(comments(from: findings, patches: patches, agent: agent, model: reviewer.seatLabel))
        }
    }

    // Runs an agent's CLI read-only and hands back everything it printed. Codex's own MCP
    // servers are listed first so the arguments can turn each one off by name.
    public static func run(agent: AgentKind, executable: String, searchPath: String, directory: String,
                    timeout: Duration, writing: String,
                    activity: @escaping @Sendable (String) -> Void,
                    arguments: (_ codexServers: [DisabledMCPServer], _ copilotServers: [String]) -> [String]) async -> Result<String, Failure> {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        let output: CommandRunner.Output
        do {
            var codexServers: [DisabledMCPServer] = []
            if agent == .codex {
                let listed: CommandRunner.Output
                do {
                    listed = try await CommandRunner.run(
                        executable: executable, arguments: ["mcp", "list", "--json"],
                        currentDirectory: URL(fileURLWithPath: directory), environment: environment,
                        timeout: .seconds(30))
                } catch {
                    return .failure(Failure(message: "Could not list Codex's MCP servers. " + error.localizedDescription))
                }
                guard listed.succeeded, !listed.outputTruncated,
                      let servers = CodexMCPListing.enabledServers(in: Data(listed.output.utf8)),
                      servers.allSatisfy({ !$0.name.isEmpty }) else {
                    return .failure(Failure(message: "Could not list Codex's MCP servers to disable them."))
                }
                codexServers = servers
            }
            let reader = ActivityReader(agent: agent, writing: writing, report: activity)
            output = try await CommandRunner.run(
                executable: executable,
                arguments: arguments(codexServers, agent == .copilot ? copilotServers() : []),
                currentDirectory: URL(fileURLWithPath: directory),
                environment: environment,
                outputChunkHandler: { reader.take($0) },
                timeout: timeout,
                outputByteLimit: 8_388_608)
        } catch let error as CommandRunner.RunError {
            let minutes = Int(timeout.components.seconds / 60)
            return .failure(Failure(message: error == .timedOut
                ? "It took longer than \(counted(minutes, "minute"))." : error.localizedDescription))
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
        guard output.succeeded else {
            SessionLog.note("\(agent.command) read-only run failed status=\(output.status) "
                            + String(output.errorOutput.suffix(400)))
            let reason = output.errorOutput.split(whereSeparator: \.isNewline).map(String.init).last { !$0.isBlank }
                .map { " " + String($0.prefix(200)) } ?? ""
            return .failure(Failure(message: "The \(agent.command) command stopped with status \(output.status)." + reason))
        }
        return .success(output.output)
    }

    // MARK: - What the reviewer is doing

    // A line for the reviewer's lane, from a call it made: the file it opened, what it
    // searched for, the command it ran.
    public static func activity(for tool: ToolUse) -> String {
        let fields = (try? JSONSerialization.jsonObject(with: Data(tool.input.utf8))) as? [String: Any] ?? [:]
        func value(_ keys: String...) -> String? {
            for key in keys {
                if let text = fields[key] as? String, !text.isBlank { return text }
                if let parts = fields[key] as? [String], !parts.isEmpty { return parts.joined(separator: " ") }
            }
            return nil
        }
        let name = tool.name.lowercased()
        if ["read", "view", "read_file", "readfile"].contains(name),
           let path = value("file_path", "path", "filePath") {
            return "Reading " + (path as NSString).lastPathComponent
        }
        if ["grep", "glob", "search", "rg"].contains(name), let pattern = value("pattern", "query", "glob") {
            return "Searching for " + pattern
        }
        if ["bash", "shell", "command", "exec", "command_execution"].contains(name),
           let command = value("command", "cmd") {
            return "Running " + command.split(separator: " ").prefix(3).joined(separator: " ")
        }
        return "Using " + tool.name
    }

    // Reads the reviewer's output as it streams and reports each call it makes. It only
    // ever sees chunks, so it keeps the part of a line that has not ended yet.
    private final class ActivityReader: @unchecked Sendable {
        private let agent: AgentKind
        private let writing: String
        private let report: @Sendable (String) -> Void
        private let copilot = CopilotStream()
        private let lock = NSLock()
        private var partial = Data()

        public init(agent: AgentKind, writing: String, report: @escaping @Sendable (String) -> Void) {
            self.agent = agent
            self.writing = writing
            self.report = report
        }

        public func take(_ chunk: Data) {
            lock.lock()
            partial.append(chunk)
            var lines: [String] = []
            while let end = partial.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(String(decoding: partial[partial.startIndex..<end], as: UTF8.self))
                partial.removeSubrange(partial.startIndex...end)
            }
            lock.unlock()
            for line in lines where !line.isBlank {
                let events: [StreamEvent] = switch agent {
                case .claudeCode: StreamEvent.parse(line)
                case .codex: StreamEvent.parseCodex(line)
                case .copilot: copilot.parse(line)
                }
                for event in events {
                    switch event {
                    case .toolUse(let tool): report(SecondOpinion.activity(for: tool))
                    case .text: report(writing)
                    default: break
                    }
                }
            }
        }
    }

    // MARK: - Reading the answer

    // The words the reviewer ended on. Claude ends its stream with one result object; the
    // others stream events, and the findings are in what they said last.
    public static func answer(from output: String, agent: AgentKind) -> String {
        switch agent {
        case .claudeCode:
            for line in output.split(separator: "\n").reversed() {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = object["result"] as? String else { continue }
                return result
            }
            return output
        case .codex, .copilot:
            let copilot = CopilotStream()
            var parts: [String] = []
            for line in output.split(separator: "\n") {
                let events = agent == .codex ? StreamEvent.parseCodex(String(line)) : copilot.parse(String(line))
                for case .text(let text) in events { parts.append(text) }
            }
            return parts.joined(separator: "\n")
        }
    }

    // The last JSON array of findings in the text. Models wrap their answer in a fence or
    // a sentence however firmly they are told not to, so the array is found rather than
    // expected to be the whole reply. Nil when there is none, which is not the same as an
    // empty array: that is a reviewer saying it found nothing.
    public static func findings(in text: String) -> [Finding]? {
        var found: [Finding]?
        for candidate in jsonArrays(in: text) {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let decoded = try? JSONDecoder().decode([Finding].self, from: data) {
                found = decoded
            }
        }
        return found.map { Array($0.prefix(maxFindings)) }
    }

    public static func jsonArrays(in text: String) -> [String] { jsonRuns(in: text, open: "[", close: "]") }

    // Every top-level run between the open and close marks, with marks inside strings ignored.
    public static func jsonRuns(in text: String, open: Character, close: Character) -> [String] {
        let characters = Array(text)
        var arrays: [String] = []
        var depth = 0
        var start: Int?
        var inString = false
        var escaped = false
        for (index, character) in characters.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"" where depth > 0:
                inString = true
            case open:
                if depth == 0 { start = index }
                depth += 1
            case close where depth > 0:
                depth -= 1
                if depth == 0, let begin = start {
                    arrays.append(String(characters[begin...index]))
                    start = nil
                }
            default:
                break
            }
        }
        return arrays
    }

    // MARK: - Turning findings into comments

    public static func comments(from findings: [Finding], patches: [Patch], agent: AgentKind,
                         model: String? = nil) -> [ReviewComment] {
        findings.compactMap { finding in
            let body = finding.comment.trimmed
            guard !body.isEmpty, finding.line > 0,
                  let patch = patches.first(where: { $0.label == finding.file })
                    ?? patches.first(where: { $0.path == finding.file || finding.file.hasSuffix("/" + $0.path) })
            else { return nil }
            let side: ReviewSide = patch.deleted ? .old : .new
            let lines = side == .new ? newLines(in: patch.text) : oldLines(in: patch.text)
            let excerpt = lines[finding.line] ?? fileLine(finding.line, of: patch) ?? ""
            var comment = ReviewComment(root: patch.root, path: patch.path,
                                        anchor: DiffAnchor(side: side, line: finding.line),
                                        excerpt: excerpt, body: body, author: .agent(agent),
                                        status: .pending,
                                        severity: finding.severity.flatMap { ReviewComment.Severity(rawValue: $0.lowercased()) })
            comment.reviewerModel = model
            return comment
        }
    }

    // The lines a patch shows of the new version, by their number there.
    public static func newLines(in patch: String) -> [Int: String] { lines(in: patch, side: .new) }
    public static func oldLines(in patch: String) -> [Int: String] { lines(in: patch, side: .old) }

    private static func lines(in patch: String, side: ReviewSide) -> [Int: String] {
        var result: [Int: String] = [:]
        var old = 0
        var new = 0
        var inHunk = false
        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("@@") {
                let parts = line.split(separator: " ")
                guard parts.count >= 3 else { continue }
                old = Int(parts[1].dropFirst().split(separator: ",")[0]) ?? 0
                new = Int(parts[2].dropFirst().split(separator: ",")[0]) ?? 0
                inHunk = true
                continue
            }
            guard inHunk else { continue }
            if line.hasPrefix("+") {
                if side == .new { result[new] = String(line.dropFirst()) }
                new += 1
            } else if line.hasPrefix("-") {
                if side == .old { result[old] = String(line.dropFirst()) }
                old += 1
            } else if line.hasPrefix(" ") {
                result[side == .new ? new : old] = String(line.dropFirst())
                old += 1
                new += 1
            }
        }
        return result
    }

    // A reviewer can point at a line the diff does not show. The file on disk has it.
    private static func fileLine(_ number: Int, of patch: Patch) -> String? {
        guard !patch.deleted,
              let text = try? String(contentsOfFile: (patch.root as NSString).appendingPathComponent(patch.path),
                                     encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        return number <= lines.count ? lines[number - 1] : nil
    }
}
