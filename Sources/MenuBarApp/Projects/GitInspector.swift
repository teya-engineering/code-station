import Foundation

// What a file looks like right now compared to the last commit.
enum GitStatusKind: Sendable, Equatable {
    case modified, added, deleted, renamed, untracked, conflicted

    // Single letter for the chip in the file list.
    var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        case .conflicted: "!"
        }
    }

    var label: String {
        switch self {
        case .modified: "modified"
        case .added: "added"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .untracked: "untracked"
        case .conflicted: "conflicted"
        }
    }
}

// One changed file. Line counts are nil when git cannot count them, which happens for
// binary files and for untracked files we could not read.
struct GitChange: Identifiable, Sendable, Equatable {
    var path: String
    var originalPath: String?
    var kind: GitStatusKind
    var isStaged: Bool
    var isUnstaged: Bool
    var added: Int?
    var removed: Int?
    var isBinary: Bool

    var id: String { path }
    var isUntracked: Bool { kind == .untracked }
    var fileName: String { (path as NSString).lastPathComponent }
}

enum GitRepoState: Sendable, Equatable {
    case ready
    case notARepo
    case missingFolder
    case gitMissing
    case failed(String)
}

struct GitSnapshot: Sendable, Equatable {
    var state: GitRepoState
    var root: String = ""
    var branch: String = ""
    // A brand new repo has a branch name but nothing to diff against yet.
    var hasCommits: Bool = true
    // On a detached head there is no branch to be on, so nothing is marked current.
    var onBranch: Bool = false
    // Local branches, most recently committed first, for the branch switcher.
    var branches: [String] = []
    // The remote branch this one tracks, and how the two have drifted apart.
    var upstream: String?
    var ahead: Int = 0
    var behind: Int = 0
    var files: [GitChange] = []

    var totalAdded: Int { files.compactMap(\.added).reduce(0, +) }
    var totalRemoved: Int { files.compactMap(\.removed).reduce(0, +) }

    static func state(_ state: GitRepoState) -> GitSnapshot { GitSnapshot(state: state) }
}

struct DiffLine: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case addition, deletion, hunk, context, meta, section
    }

    var id: Int
    var kind: Kind
    var text: String
}

struct FileDiff: Sendable, Equatable {
    var lines: [DiffLine] = []
    // True when we stopped rendering early so a huge diff cannot stall the UI.
    var truncated: Bool = false
    var totalLines: Int = 0
    var note: String?
}

// Read-only git inspection for a project folder.
//
// Claude Code edits the user's real working tree, so this is the main safety net for
// "what did the agent just change?". It has to be accurate and it must never write:
// every command here only reads, and GIT_OPTIONAL_LOCKS=0 keeps us from touching the
// index lock while the user's own git is running in the same repo.
enum GitInspector {

    // Rendering more than this many diff lines is slow and nobody reads that far.
    static let diffLineLimit = 2000
    // Very long lines (minified files) are the other way a diff can stall layout.
    private static let lineCharacterLimit = 2000
    private static let outputByteLimit = 8 << 20
    private static let untrackedByteLimit = 4 << 20
    // Git commands use blocking process and pipe calls. A serial queue keeps those calls
    // from exhausting the shared dispatch pool when many folders need inspection.
    private static let queue = DispatchQueue(
        label: "com.teya.conductor.git",
        qos: .userInitiated
    )

    // MARK: - Snapshot

    static func snapshot(at path: String) async -> GitSnapshot {
        guard let tool = await tool() else { return .state(.gitMissing) }
        let url = URL(fileURLWithPath: path)
        return await offMain { snapshot(tool: tool, url: url) }
    }

    private static func snapshot(tool: GitTool, url: URL) -> GitSnapshot {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists && isDirectory.boolValue else { return .state(.missingFolder) }

        let top = run(tool, ["rev-parse", "--show-toplevel"], in: url)
        guard top.ok else {
            // git says "not a git repository" for a plain folder, which is not an error.
            let message = top.errorText.lowercased()
            if message.contains("not a git repository") { return .state(.notARepo) }
            return .state(.failed(top.failureMessage))
        }

        var snapshot = GitSnapshot(state: .ready)
        snapshot.root = top.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = URL(fileURLWithPath: snapshot.root)

        let head = run(tool, ["rev-parse", "--abbrev-ref", "HEAD"], in: url)
        if head.ok {
            let name = head.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "HEAD" {
                let sha = run(tool, ["rev-parse", "--short", "HEAD"], in: url)
                snapshot.branch = "detached at " + sha.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                snapshot.branch = name
                snapshot.onBranch = true
            }
        } else {
            // No commits yet, so HEAD points at a branch that does not exist.
            snapshot.hasCommits = false
            let symbolic = run(tool, ["symbolic-ref", "--short", "HEAD"], in: url)
            snapshot.branch = symbolic.ok
                ? symbolic.text.trimmingCharacters(in: .whitespacesAndNewlines)
                : "HEAD"
        }

        let refs = run(tool, ["for-each-ref", "refs/heads",
                              "--format=%(refname:short)", "--sort=-committerdate"], in: url)
        if refs.ok {
            snapshot.branches = refs.text.split(separator: "\n").map(String.init)
        }

        let upstream = run(tool, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: url)
        if upstream.ok {
            snapshot.upstream = upstream.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // left counts commits only in the upstream, right the ones only here.
            let drift = run(tool, ["rev-list", "--left-right", "--count", "@{u}...HEAD"], in: url)
            let counts = drift.text.split(separator: "\t").compactMap {
                Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if drift.ok, counts.count == 2 {
                snapshot.behind = counts[0]
                snapshot.ahead = counts[1]
            }
        }

        // -uall lists untracked files one by one instead of collapsing whole directories,
        // which is what we need for per-file counts.
        let status = run(tool, ["status", "--porcelain=v1", "-z", "-uall"], in: url)
        guard status.ok else { return .state(.failed(status.failureMessage)) }

        var files = parseStatus(status.text)

        var counts: [String: (added: Int?, removed: Int?, binary: Bool)] = [:]
        for arguments in [["diff", "--numstat", "-z", "--no-ext-diff", "--no-textconv", "-M"],
                          ["diff", "--cached", "--numstat", "-z", "--no-ext-diff", "--no-textconv", "-M"]] {
            let output = run(tool, arguments, in: url)
            guard output.ok else { continue }
            for entry in parseNumstat(output.text) {
                let current = counts[entry.path] ?? (0, 0, false)
                counts[entry.path] = (
                    sum(current.added, entry.added),
                    sum(current.removed, entry.removed),
                    current.binary || entry.added == nil
                )
            }
        }

        for i in files.indices {
            if let count = counts[files[i].path] {
                files[i].added = count.binary ? nil : count.added
                files[i].removed = count.binary ? nil : count.removed
                files[i].isBinary = count.binary
            } else if files[i].isUntracked {
                // Untracked files are not in any diff, so count their lines ourselves.
                let measured = measureUntracked(at: root.appendingPathComponent(files[i].path))
                files[i].added = measured.lines
                files[i].removed = measured.lines == nil ? nil : 0
                files[i].isBinary = measured.isBinary
            }
        }

        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        snapshot.files = files
        return snapshot
    }

    // Whether the folder holds anything git does not have yet, and nothing else about it.
    // The sidebar asks this for every folder it draws, so it takes the cheapest status
    // git can give: untracked directories stay collapsed, since one entry is enough to
    // answer yes. A folder that is not a repository answers no.
    static func isDirty(at path: String) async -> Bool {
        guard let tool = await tool() else { return false }
        let url = URL(fileURLWithPath: path)
        return await offMain {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard exists && isDirectory.boolValue else { return false }
            let status = run(tool, ["status", "--porcelain=v1", "-z"], in: url)
            return status.ok && !status.text.isEmpty
        }
    }

    // MARK: - Per-file diff

    static func diff(for change: GitChange, root: String, limit: Int = diffLineLimit) async -> FileDiff {
        guard let tool = await tool() else {
            return FileDiff(note: "Could not find git on PATH.")
        }
        return await offMain { diff(tool: tool, change: change, root: root, limit: limit) }
    }

    private static func diff(tool: GitTool, change: GitChange, root: String, limit: Int) -> FileDiff {
        let rootURL = URL(fileURLWithPath: root)
        guard FileManager.default.fileExists(atPath: root) else {
            return FileDiff(note: "The project folder is no longer there.")
        }

        if change.isUntracked {
            return untrackedDiff(at: rootURL.appendingPathComponent(change.path), limit: limit)
        }

        // A rename only reads as a rename when both sides are in the pathspec; with just
        // the new path git reports it as a brand new file.
        var pathspec = [change.path]
        if let original = change.originalPath { pathspec.insert(original, at: 0) }

        var diff = FileDiff()
        var sources: [(title: String, arguments: [String])] = []
        if change.isStaged {
            sources.append(("STAGED", ["diff", "--cached"]))
        }
        if change.isUnstaged || sources.isEmpty {
            sources.append(("NOT STAGED", ["diff"]))
        }

        for source in sources {
            // --no-ext-diff and --no-textconv keep a repo's own diff drivers from running:
            // we only ever want git's own output here.
            let arguments = ["--no-pager"] + source.arguments
                + ["--no-color", "--no-ext-diff", "--no-textconv", "-M", "--"] + pathspec
            let output = run(tool, arguments, in: rootURL)
            guard output.ok else {
                diff.note = output.failureMessage
                return diff
            }
            let parsed = parse(output.text, startingAt: diff.lines.count, limit: limit - diff.lines.count)
            if parsed.binary {
                diff.note = "Binary file. Line by line changes are not shown."
                return diff
            }
            guard !parsed.lines.isEmpty else { continue }
            if sources.count > 1 {
                diff.lines.append(DiffLine(id: diff.lines.count, kind: .section, text: source.title))
                diff.totalLines += 1
            }
            diff.lines.append(contentsOf: parsed.lines)
            diff.totalLines += parsed.total
            if parsed.truncated || output.truncated { diff.truncated = true }
        }

        if diff.lines.isEmpty && diff.note == nil {
            diff.note = change.kind == .renamed
                ? "Renamed with no content changes."
                : "No content changes."
        }
        // Section headers are inserted between parsed blocks, so ids only settle at the end.
        for i in diff.lines.indices { diff.lines[i].id = i }
        return diff
    }

    private static func untrackedDiff(at url: URL, limit: Int) -> FileDiff {
        guard let data = readLimited(url) else {
            return FileDiff(note: "Could not read this file.")
        }
        if data.looksBinary {
            return FileDiff(note: "Binary file. Line by line changes are not shown.")
        }
        let text = String(decoding: data, as: UTF8.self)
        var all = text.components(separatedBy: "\n")
        if all.last == "" { all.removeLast() }
        var lines: [DiffLine] = []
        for raw in all.prefix(limit) {
            lines.append(DiffLine(id: lines.count, kind: .addition, text: "+" + clean(raw)))
        }
        return FileDiff(
            lines: lines,
            truncated: all.count > limit,
            totalLines: all.count,
            note: all.isEmpty ? "Empty file." : nil)
    }

    // MARK: - Parsing

    // Porcelain v1 records are "XY path", NUL separated. A rename adds a second record
    // holding the old path.
    private static func parseStatus(_ text: String) -> [GitChange] {
        let records = text.components(separatedBy: "\0")
        var files: [GitChange] = []
        var i = 0
        while i < records.count {
            let entry = Array(records[i])
            i += 1
            guard entry.count > 3 else { continue }
            let index = entry[0]
            let worktree = entry[1]
            let path = String(entry[3...])

            var original: String?
            if index == "R" || index == "C" || worktree == "R" || worktree == "C" {
                guard i < records.count else { break }
                original = records[i]
                i += 1
            }

            let untracked = index == "?" && worktree == "?"
            let conflicted = index == "U" || worktree == "U"
                || (index == "A" && worktree == "A") || (index == "D" && worktree == "D")

            let kind: GitStatusKind
            if untracked {
                kind = .untracked
            } else if conflicted {
                kind = .conflicted
            } else {
                kind = self.kind(from: index == " " ? worktree : index)
            }

            files.append(GitChange(
                path: path,
                originalPath: original,
                kind: kind,
                isStaged: !untracked && index != " ",
                isUnstaged: untracked || worktree != " ",
                added: nil,
                removed: nil,
                isBinary: false))
        }
        return files
    }

    private static func kind(from letter: Character) -> GitStatusKind {
        switch letter {
        case "A", "C": .added
        case "D": .deleted
        case "R": .renamed
        default: .modified
        }
    }

    // numstat -z records are "added\tremoved\tpath". A rename leaves the path empty and
    // puts the old and new paths in the two records that follow.
    private static func parseNumstat(_ text: String) -> [(path: String, added: Int?, removed: Int?)] {
        let records = text.components(separatedBy: "\0")
        var entries: [(String, Int?, Int?)] = []
        var i = 0
        while i < records.count {
            let parts = records[i].components(separatedBy: "\t")
            i += 1
            guard parts.count >= 3 else { continue }
            // git writes "-" for both counts when the file is binary.
            let added = Int(parts[0])
            let removed = Int(parts[1])
            var path = parts[2]
            if path.isEmpty {
                guard i + 1 < records.count else { break }
                i += 1
                path = records[i]
                i += 1
            }
            guard !path.isEmpty else { continue }
            entries.append((path, added, removed))
        }
        return entries
    }

    // Header lines before the first hunk are noise we already show elsewhere, so they are
    // dropped. Once inside a hunk every line is classified by its first character only:
    // a removed line whose own text starts with "--" would otherwise look like a header.
    private static func parse(
        _ text: String, startingAt offset: Int, limit: Int
    ) -> (lines: [DiffLine], truncated: Bool, total: Int, binary: Bool) {
        var lines: [DiffLine] = []
        var total = 0
        var inHunk = false
        var binary = false

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if !inHunk {
                if line.hasPrefix("@@") {
                    inHunk = true
                } else if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") {
                    binary = true
                    break
                } else if line.hasPrefix("rename from") || line.hasPrefix("rename to")
                            || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode") {
                    total += 1
                    if lines.count < limit {
                        lines.append(DiffLine(id: offset + lines.count, kind: .meta, text: line))
                    }
                    continue
                } else {
                    continue
                }
            } else if line.hasPrefix("diff --git") {
                // Start of another file in the same output: back to header lines.
                inHunk = false
                continue
            }

            let kind: DiffLine.Kind
            switch line.first {
            case "@": kind = .hunk
            case "+": kind = .addition
            case "-": kind = .deletion
            case "\\": kind = .meta
            default: kind = .context
            }
            total += 1
            if lines.count < limit {
                lines.append(DiffLine(id: offset + lines.count, kind: kind, text: clean(line)))
            }
        }

        // A trailing newline always produces one empty final line.
        if let last = lines.last, last.text.isEmpty, last.kind == .context {
            lines.removeLast()
            total -= 1
        }
        return (lines, total > lines.count, total, binary)
    }

    private static func clean(_ line: String) -> String {
        var text = line.replacingOccurrences(of: "\t", with: "    ")
        text = text.replacingOccurrences(of: "\r", with: "")
        if text.count > lineCharacterLimit {
            text = String(text.prefix(lineCharacterLimit)) + " …"
        }
        return text
    }

    // MARK: - Untracked files

    private static func measureUntracked(at url: URL) -> (lines: Int?, isBinary: Bool) {
        guard let data = readLimited(url) else { return (nil, false) }
        guard !data.looksBinary else { return (nil, true) }
        guard !data.isEmpty else { return (0, false) }
        let newline = UInt8(ascii: "\n")
        var count = data.reduce(0) { $1 == newline ? $0 + 1 : $0 }
        if data.last != newline { count += 1 }
        return (count, false)
    }

    private static func readLimited(_ url: URL) -> Data? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let type = attributes?[.type] as? FileAttributeType, type != .typeRegular { return nil }
        if let size = attributes?[.size] as? NSNumber, size.intValue > untrackedByteLimit { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func sum(_ a: Int?, _ b: Int?) -> Int? {
        guard let a, let b else { return nil }
        return a + b
    }

    // MARK: - Running git

    // The runner below is shared with every other part of the app that starts git, so
    // they all behave the same way: same lookup, same environment, same pipe handling.
    struct GitTool: Sendable {
        var path: String
        var searchPath: String
    }

    // ProcessManager owns executable lookup, and a Finder launched app has almost no PATH,
    // so reuse it rather than assuming /usr/bin/git exists.
    @MainActor static func tool() -> GitTool? {
        guard let path = ProcessManager.resolve("git") else { return nil }
        return GitTool(path: path, searchPath: ProcessManager.searchPath)
    }

    struct CommandOutput: Sendable {
        var text = ""
        var errorText = ""
        var status: Int32 = -1
        var truncated = false

        var ok: Bool { status == 0 }
        var failureMessage: String {
            let trimmed = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "git exited with code \(status)." : trimmed
        }
    }

    // `directory` is nil for callers that steer git with `-C` instead: the folder they
    // target may no longer exist, and a missing working directory would keep the
    // process from launching at all.
    static func run(_ tool: GitTool, _ arguments: [String], in directory: URL? = nil,
                    timeout: TimeInterval? = nil,
                    captureByteLimit: Int = GitInspector.outputByteLimit) -> CommandOutput {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = tool.searchPath
        // No tty here, so make sure git can never sit waiting for a password or an editor.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_PAGER"] = "cat"

        var result = CommandOutput()
        do {
            let output = try CommandRunner.runBlocking(
                executable: tool.path,
                arguments: arguments,
                currentDirectory: directory,
                environment: environment,
                timeout: timeout.map { .seconds($0) },
                outputByteLimit: captureByteLimit
            )
            result.text = output.output
            result.errorText = output.errorOutput
            result.status = output.status
            result.truncated = output.outputTruncated || output.errorOutputTruncated
        } catch {
            result.errorText = error.localizedDescription
        }
        return result
    }

    // Git is slow enough on a big repo to be felt, so it runs on one serial background
    // queue rather than the main thread or an unbounded number of shared workers.
    static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }
}
