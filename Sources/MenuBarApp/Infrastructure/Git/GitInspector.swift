import Foundation

// Git inspection for a project folder.
//
// An agent edits the user's real working tree, so this is the main safety net for
// "what did the agent just change?". The inspections have to be accurate and must never
// write: each one only reads, and GIT_OPTIONAL_LOCKS=0 keeps it from touching the index
// lock while the user's own git is running in the same repo.
//
// Git is started through the runner in `Git`, which the types that do change a
// repository share.
enum GitInspector {

    // Rendering more than this many diff lines is slow and nobody reads that far.
    static let diffLineLimit = 2000
    private static let untrackedByteLimit = 4 << 20

    // MARK: - Snapshot

    static func snapshot(at path: String, commandTimeout: TimeInterval? = nil,
                         lane: Git.Lane = .background, comparingToLastCommit: Bool = false,
                         findingRemoteBase: Bool = false, comparingToRemote: Bool = false,
                         remoteRef: String? = nil) async -> GitSnapshot {
        guard let tool = Git.tool() else { return .state(.gitMissing) }
        let url = URL(fileURLWithPath: path)
        return await Git.offMain(lane: lane) {
            snapshot(tool: tool,
                     url: url,
                     commandTimeout: commandTimeout,
                     comparingToLastCommit: comparingToLastCommit,
                     findingRemoteBase: findingRemoteBase,
                     comparingToRemote: comparingToRemote,
                     remoteRef: remoteRef)
        }
    }

    private static func snapshot(tool: Git.Tool, url: URL, commandTimeout: TimeInterval?,
                                 comparingToLastCommit: Bool, findingRemoteBase: Bool,
                                 comparingToRemote: Bool, remoteRef: String?) -> GitSnapshot {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists && isDirectory.boolValue else { return .state(.missingFolder) }

        let top = Git.run(tool, ["rev-parse", "--show-toplevel"], in: url,
                          timeout: commandTimeout)
        guard top.ok else {
            // git says "not a git repository" for a plain folder, which is not an error.
            let message = top.errorText.lowercased()
            if message.contains("not a git repository") { return .state(.notARepo) }
            return .state(.failed(top.failureMessage))
        }

        var snapshot = GitSnapshot(state: .ready)
        snapshot.root = top.trimmedText
        let root = URL(fileURLWithPath: snapshot.root)

        let head = Git.run(tool, ["rev-parse", "--abbrev-ref", "HEAD"], in: url,
                           timeout: commandTimeout)
        if head.ok {
            let name = head.trimmedText
            if name == "HEAD" {
                let sha = Git.run(tool, ["rev-parse", "--short", "HEAD"], in: url,
                                  timeout: commandTimeout)
                snapshot.branch = "detached at " + sha.trimmedText
            } else {
                snapshot.branch = name
                snapshot.onBranch = true
            }
        } else {
            // No commits yet, so HEAD points at a branch that does not exist.
            snapshot.hasCommits = false
            let symbolic = Git.run(tool, ["symbolic-ref", "--short", "HEAD"], in: url,
                                   timeout: commandTimeout)
            snapshot.branch = symbolic.ok ? symbolic.trimmedText : "HEAD"
        }

        if snapshot.hasCommits {
            // Unix time and the subject on one line, split on a tab the subject cannot
            // contain because git strips it out of the first line.
            let last = Git.run(tool, ["log", "-1", "--format=%ct\t%s"], in: url,
                               timeout: commandTimeout)
            let parts = last.trimmedText.split(separator: "\t", maxSplits: 1)
            if last.ok, parts.count == 2, let seconds = TimeInterval(parts[0]) {
                snapshot.lastCommitDate = Date(timeIntervalSince1970: seconds)
                snapshot.lastCommitSubject = String(parts[1])
            }
        }

        let upstream = Git.run(tool, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
                               in: url, timeout: commandTimeout)
        if upstream.ok {
            snapshot.upstream = upstream.trimmedText
            let drift = Git.run(tool, ["rev-list", "--left-right", "--count", "HEAD...@{u}"],
                                in: url, timeout: commandTimeout)
            if let drift = drift.aheadBehind {
                snapshot.trackingKnown = true
                snapshot.ahead = drift.ahead
                snapshot.behind = drift.behind
            }
        }

        // -uall lists untracked files one by one instead of collapsing whole directories,
        // which is what we need for per-file counts.
        let status = Git.run(tool, ["status", "--porcelain=v1", "-z", "-uall"], in: url,
                             timeout: commandTimeout)
        guard status.ok else { return .state(.failed(status.failureMessage)) }

        var files = parseStatus(status.text)

        let lastCommit = snapshot.hasCommits ? "HEAD" : Git.emptyTree
        let numstat = ["--numstat", "-z"] + Git.plainDiff + ["-M"]
        let countArguments = comparingToLastCommit
            ? [["diff", lastCommit] + numstat]
            : [["diff"] + numstat, ["diff", "--cached"] + numstat]
        let counts = lineCounts(countArguments, tool: tool, url: url, timeout: commandTimeout)
        for i in files.indices {
            if let count = counts[files[i].path] {
                files[i].apply(count)
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

        if (findingRemoteBase || comparingToRemote) && snapshot.hasCommits {
            snapshot.remoteBase = remoteBase(tool: tool, url: url, timeout: commandTimeout, preferring: remoteRef)
        }
        if comparingToRemote, let base = snapshot.remoteBase {
            let committed = Git.run(tool, ["diff", base.commit, "--name-status", "-z", "--no-ext-diff", "-M"],
                                    in: url, timeout: commandTimeout)
            guard committed.ok else { return .state(.failed(committed.failureMessage)) }
            let entries = parseNameStatus(committed.text)
            var merged = merging(files, with: entries)
            let baseCounts = lineCounts([["diff", base.commit] + numstat],
                                        tool: tool, url: url, timeout: commandTimeout)
            let changed = Set(entries.map(\.path))
            for i in merged.indices where changed.contains(merged[i].path) {
                if let count = baseCounts[merged[i].path] { merged[i].apply(count) }
            }
            merged.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            snapshot.uncommittedFiles = files
            snapshot.files = merged
            snapshot.pathsChangedFromBase = changed
            snapshot.comparedToRemote = true
        }
        return snapshot
    }

    typealias LineCount = (added: Int?, removed: Int?, binary: Bool)

    private static func lineCounts(_ argumentSets: [[String]], tool: Git.Tool, url: URL,
                                   timeout: TimeInterval?) -> [String: LineCount] {
        var counts: [String: LineCount] = [:]
        for arguments in argumentSets {
            let output = Git.run(tool, arguments, in: url, timeout: timeout)
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
        return counts
    }

    // What origin calls its default branch, without the remote's name, read from the
    // origin/HEAD ref a clone leaves behind. A remote added by hand has none.
    static func originDefaultBranch(_ tool: Git.Tool, in url: URL, timeout: TimeInterval? = nil) -> String? {
        let named = Git.run(tool, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
                            in: url, timeout: timeout)
        guard named.ok, named.trimmedText.hasPrefix("origin/") else { return nil }
        let branch = String(named.trimmedText.dropFirst("origin/".count))
        return branch.isEmpty ? nil : branch
    }

    // The usual names are tried after origin/HEAD, which may be missing or still point at
    // a branch the remote has since renamed and pruned.
    private static func remoteBase(tool: Git.Tool, url: URL, timeout: TimeInterval?, preferring preferred: String?) -> GitCompareBase? {
        var candidates = ["origin/main", "origin/master"]
        if let named = originDefaultBranch(tool, in: url, timeout: timeout) {
            candidates.removeAll { $0 == "origin/" + named }
            candidates.insert("origin/" + named, at: 0)
        }
        // Only a remote branch is taken, so a name typed elsewhere can never become an option
        // to git.
        if let preferred, !preferred.hasPrefix("-"), preferred.contains("/") {
            candidates.insert("refs/remotes/" + preferred, at: 0)
        }
        for ref in candidates {
            let base = Git.run(tool, ["merge-base", "HEAD", ref], in: url, timeout: timeout)
            if base.ok && !base.trimmedText.isEmpty {
                let name = ref.hasPrefix("refs/remotes/") ? String(ref.dropFirst("refs/remotes/".count)) : ref
                return GitCompareBase(ref: name, commit: base.trimmedText)
            }
        }
        return nil
    }

    // Every branch the remotes had at the last fetch, for picking the one to compare with,
    // and which of them `branch` was made from.
    static func remoteBranches(at path: String, branch: String? = nil) async -> GitRemoteBranches {
        guard let tool = Git.tool() else { return GitRemoteBranches() }
        let url = URL(fileURLWithPath: path)
        return await Git.offMain(lane: .interactive) {
            let refs = Git.run(tool, ["for-each-ref", "--format=%(refname)", "refs/remotes"], in: url)
            let urls = Git.run(tool, ["config", "--get-regexp", "^remote\\..*\\.url$"], in: url)
            var branches = GitRemoteBranches(refs: refs.ok ? parseRemoteRefs(refs.text) : [],
                                             urls: urls.ok ? parseRemoteURLs(urls.text) : [:], branch: branch)
            if let branch, !branch.isEmpty {
                let log = Git.run(tool, ["reflog", "show", "--format=%gs", "refs/heads/" + branch, "--"], in: url)
                // A log cut short has lost its oldest entry, which is the one that says.
                if log.ok, !log.truncated { branches.startedFrom = parseStartedFrom(log.text, refs: branches.refs) }
            }
            return branches
        }
    }

    // A branch's oldest reflog entry says what it was made from, as "branch: Created from
    // origin/main". Only a remote branch the list holds counts; a local branch or a commit
    // is not something to compare with.
    static func parseStartedFrom(_ reflog: String, refs: [String]) -> String? {
        let prefix = "branch: Created from "
        guard let oldest = reflog.split(separator: "\n").last(where: { !$0.isEmpty }),
              oldest.hasPrefix(prefix) else { return nil }
        var from = String(oldest.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if from.hasPrefix("refs/remotes/") { from.removeFirst("refs/remotes/".count) }
        return refs.contains(from) ? from : nil
    }

    // `for-each-ref` lines are full ref names. A remote's HEAD only points at one of its
    // branches, so it is left out.
    static func parseRemoteRefs(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let ref = line.trimmingCharacters(in: .whitespaces)
            guard ref.hasPrefix("refs/remotes/") else { return nil }
            let name = String(ref.dropFirst("refs/remotes/".count))
            guard name.contains("/"), !name.hasSuffix("/HEAD") else { return nil }
            return name
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // `config --get-regexp` lines are "remote.<name>.url <url>".
    static func parseRemoteURLs(_ text: String) -> [String: String] {
        var urls: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].hasPrefix("remote."), parts[0].hasSuffix(".url") else { continue }
            let name = String(parts[0].dropFirst("remote.".count).dropLast(".url".count))
            if urls[name] == nil { urls[name] = parts[1] }
        }
        return urls
    }

    // The working tree's files joined with the ones that differ from the base. A file
    // the working tree also changed keeps its staging state; its kind is what it is next
    // to the base, so a file the branch added reads as added. A local rename that the
    // base diff sees as a separate delete and add stays one renamed row, since the old
    // path's deletion is part of the local work.
    static func merging(_ local: [GitChange],
                        with committed: [(path: String, originalPath: String?, kind: GitStatusKind)]) -> [GitChange] {
        var files = local
        var index = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1.path, $0) })
        let renamedAway = Set(local.compactMap(\.originalPath))
        for entry in committed {
            if let at = index[entry.path] {
                guard files[at].kind != .conflicted && !files[at].isUntracked else { continue }
                if entry.originalPath == nil && files[at].originalPath != nil { continue }
                files[at].kind = entry.kind
                files[at].originalPath = entry.originalPath
            } else if renamedAway.contains(entry.path) {
                continue
            } else {
                index[entry.path] = files.count
                files.append(GitChange(path: entry.path,
                                       originalPath: entry.originalPath,
                                       kind: entry.kind,
                                       isStaged: false,
                                       isUnstaged: false,
                                       added: nil,
                                       removed: nil,
                                       isBinary: false))
            }
        }
        return files
    }

    // How many files hold work git does not have yet. A folder that is gone or is not a
    // repository answers zero. Nil when git could not say, such as when it failed to start
    // or tripped over a checkout half way through: a caller must not read that as clean,
    // since a clean answer hides the mark that warns a delete would lose work. The count
    // is shared by the project screen and the sidebar monitor so one inspection can
    // support both the exact location line and the smaller safety mark.
    static func uncommittedFileCount(at path: String) async -> Int? {
        guard let tool = Git.tool() else { return 0 }
        let url = URL(fileURLWithPath: path)
        return await Git.offMain {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard exists && isDirectory.boolValue else { return 0 }
            let status = Git.run(tool, ["status", "--porcelain=v1", "-z", "-uall"], in: url)
            if status.ok { return parseStatus(status.text).count }
            return status.errorText.lowercased().contains("not a git repository") ? 0 : nil
        }
    }

    // Commits on HEAD that are on no remote branch. A repository with no remote at all
    // answers zero: nothing there was ever meant to be pushed, so every local commit
    // would count and the answer would say nothing. Nil when git could not say, which a
    // caller about to delete the checkout must not read as "nothing to lose".
    static func unpushedCommitCount(at path: String,
                                    commandTimeout: TimeInterval? = nil) async -> Int? {
        guard let tool = Git.tool() else { return nil }
        let url = URL(fileURLWithPath: path)
        return await Git.offMain {
            let remotes = Git.run(tool, ["remote"], in: url, timeout: commandTimeout)
            guard remotes.ok else { return nil }
            guard !remotes.trimmedText.isEmpty else { return 0 }
            let count = Git.run(tool, ["rev-list", "--count", "HEAD", "--not", "--remotes"],
                                in: url, timeout: commandTimeout)
            return count.ok ? Int(count.trimmedText) : nil
        }
    }

    // A folder git could not read counts as dirty, so nothing is treated as safely
    // committed on a guess.
    static func isDirty(at path: String) async -> Bool {
        await uncommittedFileCount(at: path).map { $0 > 0 } ?? true
    }

    // The full hash of the commit checked out at a path. Nil outside a repository and in
    // one with no commits yet.
    static func head(at path: String) async -> String? {
        guard let tool = Git.tool() else { return nil }
        return await Git.offMain(lane: .interactive) {
            let output = Git.run(tool, ["rev-parse", "--verify", "--quiet", "HEAD"],
                                 in: URL(fileURLWithPath: path))
            let hash = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return output.ok && !hash.isEmpty ? hash : nil
        }
    }

    struct TurnCommits {
        let root: String
        let start: String
        let head: GitCommitSummary
    }

    // The commits a turn made, when it committed all of its work. Nil when any folder
    // still holds uncommitted work, since that work is what needs reviewing, and nil when
    // no folder moved to a new commit. With several folders the first one that moved wins.
    static func turnCommits(roots: [String], startHeads: [String: String]) async -> TurnCommits? {
        var found: TurnCommits?
        for root in roots {
            if await isDirty(at: root) { return nil }
            guard found == nil, let start = startHeads[root],
                  let head = await head(at: root), head != start,
                  let summary = await recentCommits(at: root, limit: 1).commits.first
            else { continue }
            found = TurnCommits(root: root, start: start, head: summary)
        }
        return found
    }

    // MARK: - History

    // Listing subjects is cheap even on a big repository; the expensive part of history
    // is a commit's diff, which only loads once one is opened.
    static let historyLimit = 100

    static func recentCommits(at path: String, limit: Int = historyLimit)
        async -> (commits: [GitCommitSummary], note: String?) {
        guard let tool = Git.tool() else { return ([], Git.notFoundMessage) }
        let url = URL(fileURLWithPath: path)
        return await Git.offMain {
            // Tabs separate the fields because git strips them from the subject line,
            // so the record splits cleanly whatever the subject says.
            let output = Git.run(tool, ["log", "--no-color", "-n", "\(limit)",
                                    "--format=%H%x09%h%x09%an%x09%cr%x09%ct%x09%s"], in: url)
            guard output.ok else {
                // A repository with no commits yet has an empty history, not a broken one.
                if output.errorText.lowercased().contains("does not have any commits") {
                    return ([], nil)
                }
                return ([], output.failureMessage)
            }
            let commits: [GitCommitSummary] = output.text.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: "\t", maxSplits: 5,
                                        omittingEmptySubsequences: false)
                guard fields.count == 6 else { return nil }
                return GitCommitSummary(hash: String(fields[0]), shortHash: String(fields[1]),
                                        author: String(fields[2]), relativeDate: String(fields[3]),
                                        subject: String(fields[5]),
                                        date: TimeInterval(fields[4]).map(Date.init(timeIntervalSince1970:)))
            }
            return (commits, nil)
        }
    }

    struct CommitFiles: Sendable {
        var parents: [String] = []
        var files: [GitChange] = []
        var note: String?
        // Both sides of each file's change, so viewed marks apply only to this diff.
        var versions: [String: ViewedChange] = [:]
    }

    static func commitFiles(_ hash: String, parent: String? = nil, root: String) async -> CommitFiles {
        guard let tool = Git.tool() else { return CommitFiles(note: Git.notFoundMessage) }
        return await Git.offMain(lane: .interactive) {
            let url = URL(fileURLWithPath: root)
            let ancestry = Git.run(tool, ["rev-list", "--parents", "-n", "1", hash], in: url)
            guard ancestry.ok else { return CommitFiles(note: ancestry.failureMessage) }
            let parents = ancestry.text.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
            let base = parent ?? parents.first
            let command = base.map { ["diff", $0, hash] } ?? ["show", "--format=", hash]
            let options = Git.plainDiff + ["-M"]
            let names = Git.run(tool, command + options + ["--name-status", "-z"], in: url)
            let stats = Git.run(tool, command + options + ["--numstat", "-z"], in: url)
            let raw = Git.run(tool, command + options + ["--raw", "--no-abbrev", "-z"], in: url)
            guard names.ok, stats.ok, !names.truncated, !stats.truncated else {
                return CommitFiles(parents: parents, note: "Could not read all changed files. " + (names.ok ? stats.failureMessage : names.failureMessage))
            }
            let counts = Dictionary(uniqueKeysWithValues: parseNumstat(stats.text).map { ($0.path, ($0.added, $0.removed)) })
            let records = names.text.components(separatedBy: "\0")
            var files: [GitChange] = []
            var i = 0
            while i + 1 < records.count {
                let status = records[i]; i += 1
                let first = records[i]; i += 1
                var path = first
                var original: String?
                if status.hasPrefix("R") || status.hasPrefix("C") {
                    guard i < records.count else { break }
                    original = first; path = records[i]; i += 1
                }
                let count = counts[path]
                let kind: GitStatusKind = original != nil ? .renamed
                    : status == "A" ? .added : status == "D" ? .deleted : .modified
                files.append(GitChange(path: path, originalPath: original, kind: kind,
                                       isStaged: false, isUnstaged: false,
                                       added: count?.0, removed: count?.1,
                                       isBinary: count != nil && count?.0 == nil))
            }
            return CommitFiles(parents: parents, files: files,
                               versions: raw.ok && !raw.truncated ? parseRawVersions(raw.text) : [:])
        }
    }

    // Both sides of each change, from `--raw -z` output: a ":modes ids
    // status" record, then the path, or the old path and the new one for a rename or copy.
    static func parseRawVersions(_ text: String) -> [String: ViewedChange] {
        let records = text.components(separatedBy: "\0")
        var versions: [String: ViewedChange] = [:]
        var i = 0
        while i < records.count {
            let record = records[i]; i += 1
            guard record.hasPrefix(":") else { continue }
            let fields = record.split(separator: " ")
            guard fields.count >= 5, i < records.count else { break }
            let status = fields[4]
            var path = records[i]; i += 1
            var originalPath: String?
            if status.hasPrefix("R") || status.hasPrefix("C") {
                originalPath = path
                guard i < records.count else { break }
                path = records[i]; i += 1
            }
            versions[path] = ViewedChange(
                before: .init(mode: String(fields[0].dropFirst()), blob: String(fields[2])),
                after: .init(mode: String(fields[1]), blob: String(fields[3])), originalPath: originalPath)
        }
        return versions
    }

    static func commitFileDiff(_ hash: String, parent: String?, file: GitChange,
                               root: String, limit: Int = diffLineLimit) async -> FileDiff {
        if file.isBinary { return FileDiff(note: "Preview unavailable for binary file: \(file.path)") }
        guard let tool = Git.tool() else { return FileDiff(note: Git.notFoundMessage) }
        return await Git.offMain(lane: .interactive) {
            let command = parent.map { ["diff", $0, hash] } ?? ["show", "--format=", hash]
            let paths = [file.originalPath, file.path].compactMap { $0 }
            let output = Git.run(tool, ["--literal-pathspecs"] + command
                                 + ["--no-color"] + Git.plainDiff + ["-M", "--"] + paths,
                                 in: URL(fileURLWithPath: root))
            guard output.ok else { return FileDiff(note: output.failureMessage) }
            let parsed = parse(output.text, startingAt: 0, limit: limit,
                               revision: .commit(hash), path: file.path)
            return FileDiff(lines: parsed.lines, truncated: parsed.truncated || output.truncated,
                            totalLines: parsed.total, revealed: parsed.extra,
                            note: parsed.lines.isEmpty ? "No content changes in this file." : nil)
        }
    }

    // MARK: - Per-file diff

    // With a base, the file is compared to that commit in one piece. Without one, staged
    // and unstaged work are shown apart against the last commit.
    static func diff(for change: GitChange, root: String, limit: Int = diffLineLimit,
                     base: String? = nil) async -> FileDiff {
        guard let tool = Git.tool() else {
            return FileDiff(note: Git.notFoundMessage)
        }
        // Always the fast lane: a per-file diff only ever loads because someone just
        // clicked the file and is looking at an empty pane until it arrives.
        return await Git.offMain(lane: .interactive) {
            diff(tool: tool, change: change, root: root, limit: limit, base: base)
        }
    }

    private static func diff(tool: Git.Tool, change: GitChange, root: String, limit: Int,
                             base: String?) -> FileDiff {
        let rootURL = URL(fileURLWithPath: root)
        guard FileManager.default.fileExists(atPath: root) else {
            return FileDiff(note: "The project folder is no longer there.")
        }

        if FileTree.imageKinds.contains((change.path as NSString).pathExtension.lowercased()) {
            return imageDiff(tool: tool, change: change, root: rootURL, base: base)
        }

        if change.isUntracked {
            return untrackedDiff(at: rootURL.appendingPathComponent(change.path), limit: limit)
        }

        // A rename only reads as a rename when both sides are in the pathspec; with just
        // the new path git reports it as a brand new file.
        var pathspec = [change.path]
        if let original = change.originalPath { pathspec.insert(original, at: 0) }

        var diff = FileDiff()
        var sources: [(title: String, revision: DiffRevision, arguments: [String])] = []
        if let base {
            sources.append(("", .workingTree, ["diff", base]))
        } else {
            if change.isStaged {
                sources.append(("STAGED", .index, ["diff", "--cached"]))
            }
            if change.isUnstaged || sources.isEmpty {
                sources.append(("NOT STAGED", .workingTree, ["diff"]))
            }
        }

        for source in sources {
            let arguments = ["--no-pager", "--literal-pathspecs"] + source.arguments
                + ["--no-color"] + Git.plainDiff + ["-M", "--"] + pathspec
            let output = Git.run(tool, arguments, in: rootURL)
            guard output.ok else {
                diff.note = output.failureMessage
                return diff
            }
            let parsed = parse(output.text, startingAt: diff.lines.count,
                               limit: limit - diff.lines.count,
                               revision: source.revision, path: change.path)
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
            diff.revealed += parsed.extra
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

    // A picture is compared by eye, so the pane gets the bytes of each side rather than
    // a text diff: the last committed version from git and the current one from disk.
    private static func imageDiff(tool: Git.Tool, change: GitChange, root: URL, base: String?) -> FileDiff {
        var images = DiffImages()
        if change.kind != .untracked && change.kind != .added {
            images.before = committedBytes(tool: tool, path: change.originalPath ?? change.path,
                                           at: base ?? "HEAD", in: root)
        }
        if change.kind != .deleted {
            images.after = readLimited(root.appendingPathComponent(change.path))
        }
        guard images.before != nil || images.after != nil else {
            return FileDiff(note: "Binary file. Line by line changes are not shown.")
        }
        return FileDiff(images: images)
    }

    // The shared runner keeps output as text, which would mangle a picture, so the raw
    // chunks are gathered as they arrive. The "./" makes git read the path from the
    // folder it runs in rather than from the top of the repository.
    private static func committedBytes(tool: Git.Tool, path: String, at commit: String, in root: URL) -> Data? {
        let collected = ByteCollector()
        let output = Git.run(tool, ["--no-pager", "show", commit + ":./" + path], in: root,
                             captureByteLimit: untrackedByteLimit) { collected.append($0) }
        guard output.ok, !output.truncated else { return nil }
        return collected.data
    }

    private final class ByteCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        var data: Data { lock.withLock { storage } }
        func append(_ chunk: Data) { lock.withLock { storage.append(chunk) } }
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

    // MARK: - Opening up a gap

    // A gap this short is opened in one go; a longer one comes back a step at a time, so
    // one press on a row near the top of a big file reveals a screenful and not the
    // thousand lines before the change.
    static let gapExpandStep = 20
    static let gapExpandWhole = 40

    // The lines a gap stands for, read back from the version the diff was made against.
    // Only the end that was pressed comes back, and the gap left over says what is still
    // hidden between the two sides.
    static func expand(_ gap: DiffGap, _ direction: DiffExpandDirection,
                       root: String) async -> DiffExpansion {
        guard let tool = Git.tool() else { return DiffExpansion(gap: gap) }
        return await Git.offMain(lane: .interactive) {
            let rootURL = URL(fileURLWithPath: root)
            guard let text = contents(of: gap.path, at: gap.revision, tool: tool, root: rootURL)
            else { return DiffExpansion() }

            var all = text.components(separatedBy: "\n")
            if all.last == "" { all.removeLast() }
            // A gap running to the end of the file learns its size here; a measured one
            // is still held against the file, which can have moved on since the diff.
            let hidden = min(gap.count ?? .max, max(0, all.count - gap.start + 1))
            guard hidden > 0 else { return DiffExpansion() }
            let take = direction == .all || hidden <= gapExpandWhole ? hidden : gapExpandStep
            let first = direction == .up ? gap.start - 1 + hidden - take : gap.start - 1

            // Unchanged lines carry a leading space in a diff, which is what lines the
            // code up with the signed rows around it.
            let lines = all[first..<(first + take)].map {
                DiffLine(id: 0, kind: .context, text: clean(" " + $0))
            }
            var left = gap
            left.count = hidden - take
            // Reading down takes the top of the gap, so what is left starts lower.
            if direction != .up { left.start = gap.start + take }
            return DiffExpansion(lines: lines, gap: left.count == 0 ? nil : left)
        }
    }

    private static func contents(of path: String, at revision: DiffRevision,
                                 tool: Git.Tool, root: URL) -> String? {
        switch revision {
        case .workingTree:
            guard let data = readLimited(root.appendingPathComponent(path)),
                  !data.looksBinary else { return nil }
            return String(decoding: data, as: UTF8.self)
        case .index:
            return show(":./" + path, tool: tool, root: root)
        case .commit(let hash):
            return show(hash + ":./" + path, tool: tool, root: root)
        }
    }

    // The text a blob holds, for keeping beside a file read in a commit. Nil for one too
    // big to keep or that is not text.
    static func blobText(_ id: String, root: String) async -> String? {
        guard id.count == 40, id.allSatisfy(\.isHexDigit), let tool = Git.tool() else { return nil }
        return await Git.offMain(lane: .interactive) {
            let output = Git.run(tool, ["cat-file", "blob", id], in: URL(fileURLWithPath: root))
            guard output.ok, !output.truncated, output.text.utf8.count <= ViewedFileStore.textLimit,
                  !output.text.contains("\0") else { return nil }
            return output.text
        }
    }

    private static func show(_ object: String, tool: Git.Tool, root: URL) -> String? {
        let output = Git.run(tool, ["--no-pager", "show", object], in: root)
        guard output.ok, !output.truncated else { return nil }
        return output.text
    }

    // MARK: - Review and copy

    static func readReviewDiff(for change: GitChange, root: String, base: String? = nil) async -> FileDiff {
        if change.isBinary || FileTree.imageKinds.contains((change.path as NSString).pathExtension.lowercased()) {
            return await diff(for: change, root: root, base: base)
        }
        guard let tool = Git.tool() else { return FileDiff(note: Git.unavailableMessage) }
        return await Git.offMain(lane: .interactive) {
            let output = Git.run(tool, patchArguments(for: change, tool: tool, root: root, base: base),
                                 in: URL(fileURLWithPath: root))
            guard output.ok || (change.isUntracked && output.status == 1) else { return FileDiff(note: output.failureMessage) }
            let parsed = parse(output.text, startingAt: 0, limit: diffLineLimit,
                               revision: .workingTree, path: change.path)
            return FileDiff(lines: parsed.lines, truncated: parsed.truncated || output.truncated,
                            totalLines: parsed.total, revealed: parsed.extra,
                            note: parsed.binary ? "Binary file. Line by line changes are not shown." : nil)
        }
    }

    private static func patchArguments(for change: GitChange, tool: Git.Tool, root: String,
                                       base: String?) -> [String] {
        if change.isUntracked {
            return ["diff", "--no-index", "--no-color", "--no-ext-diff", "--", "/dev/null", change.path]
        }
        var paths = [change.path]
        if let original = change.originalPath { paths.insert(original, at: 0) }
        return ["diff", "--no-color"] + Git.plainDiff
            + ["-M", base ?? lastCommit(tool: tool, root: root), "--"] + paths
    }

    private static func lastCommit(tool: Git.Tool, root: String) -> String {
        Git.run(tool, ["rev-parse", "--verify", "HEAD"], in: URL(fileURLWithPath: root)).ok ? "HEAD" : Git.emptyTree
    }

    enum CopyVersion: Sendable { case patch, before, after }

    static func copyText(for change: GitChange, root: String, version: CopyVersion,
                         base: String? = nil) async -> Result<String, CopyError> {
        guard let tool = Git.tool() else { return .failure(CopyError(message: Git.unavailableMessage)) }
        return await Git.offMain(lane: .interactive) {
            let url = URL(fileURLWithPath: root)
            if version == .after || (version == .before && (change.isUntracked || change.kind == .added)) {
                if version == .before || change.kind == .deleted { return .success("") }
                do {
                    let file = url.appendingPathComponent(change.path)
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= Git.outputByteLimit else {
                        return .failure(CopyError(message: "This file is too large to copy in full. Open it in an editor to copy it."))
                    }
                    return .success(try String(contentsOf: file, encoding: .utf8))
                } catch { return .failure(CopyError(message: error.localizedDescription)) }
            }
            let arguments = version == .before
                ? ["show", (base ?? "HEAD") + ":" + (change.originalPath ?? change.path)]
                : patchArguments(for: change, tool: tool, root: root, base: base)
            let result = Git.run(tool, arguments, in: url)
            guard (result.ok || (change.isUntracked && result.status == 1)), !result.truncated else {
                return .failure(CopyError(message: result.truncated ? "This file is too large to copy in full. Open it in an editor to copy it." : result.failureMessage))
            }
            return .success(result.text)
        }
    }

    struct CopyError: Error, Sendable { let message: String }

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
}
