import Foundation

// What a session has changed, as the station commands façade hands it out: for every
// checkout the session works in, its branch, how it stands against its upstream, and each
// changed file with a unified diff against the last commit. These are new kinds next to
// the phone remote's, written the same way: a fixed type and version on the wire, plain
// Codable values, nothing that points back into the engine.

public struct RemoteChanges: Codable, Equatable, Sendable {
    public let type = "changes"
    public let version = 1
    public let sessionID: String
    // The lead checkout first, as the session lists them.
    public let checkouts: [RemoteCheckout]

    public init(sessionID: String, checkouts: [RemoteCheckout]) {
        self.sessionID = sessionID
        self.checkouts = checkouts
    }

    private enum CodingKeys: String, CodingKey {
        case type, version, sessionID, checkouts
    }

    // The type and version are fixed for this struct, so they are written but not read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        checkouts = try container.decode([RemoteCheckout].self, forKey: .checkouts)
    }
}

// One folder the session works in: a worktree of its own, or the project folder itself.
public struct RemoteCheckout: Codable, Equatable, Sendable {
    public let project: String
    public let path: String
    public let isWorktree: Bool
    public let branch: String
    // "ready" when git answered; otherwise why there is nothing to show: "notARepo",
    // "missingFolder", "gitMissing" or "failed".
    public let state: String
    // One line a person reads: how the branch stands against its upstream, or what went
    // wrong when git could not answer.
    public let status: String
    public let files: [RemoteChangedFile]

    public init(project: String, path: String, isWorktree: Bool, branch: String,
                state: String, status: String, files: [RemoteChangedFile]) {
        self.project = project
        self.path = path
        self.isWorktree = isWorktree
        self.branch = branch
        self.state = state
        self.status = status
        self.files = files
    }
}

public struct RemoteChangedFile: Codable, Equatable, Sendable {
    public let path: String
    public let originalPath: String?
    // The word ("modified", "added", "deleted", "renamed", "untracked", "conflicted") and
    // the one-letter chip for it.
    public let status: String
    public let letter: String
    public let staged: Bool
    public let unstaged: Bool
    // Nil when git cannot count lines, as for a binary file.
    public let added: Int?
    public let removed: Int?
    public let binary: Bool
    public let diff: RemoteDiff

    public init(path: String, originalPath: String?, status: String, letter: String,
                staged: Bool, unstaged: Bool, added: Int?, removed: Int?, binary: Bool,
                diff: RemoteDiff) {
        self.path = path
        self.originalPath = originalPath
        self.status = status
        self.letter = letter
        self.staged = staged
        self.unstaged = unstaged
        self.added = added
        self.removed = removed
        self.binary = binary
        self.diff = diff
    }
}

// A unified diff, one row per line as git wrote it, sign included.
public struct RemoteDiff: Codable, Equatable, Sendable {
    public let type = "diff"
    public let version = 1
    public let lines: [RemoteDiffLine]
    // True when a huge diff was cut short; `totalLines` is how long it really is.
    public let truncated: Bool
    public let totalLines: Int
    // Said instead of lines, or beside them: a binary file, an empty one, an error.
    public let note: String?

    public init(lines: [RemoteDiffLine], truncated: Bool, totalLines: Int, note: String?) {
        self.lines = lines
        self.truncated = truncated
        self.totalLines = totalLines
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case type, version, lines, truncated, totalLines, note
    }

    // The type and version are fixed for this struct, so they are written but not read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lines = try container.decode([RemoteDiffLine].self, forKey: .lines)
        truncated = try container.decode(Bool.self, forKey: .truncated)
        totalLines = try container.decode(Int.self, forKey: .totalLines)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

public struct RemoteDiffLine: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case hunk, context, addition, deletion, meta, section
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

// Builds the changes from the core's own git inspection, the same calls the GUI's
// changes view makes: a snapshot compared with the last commit, then each file's review
// diff.
enum StationChangesReader {
    struct Checkout: Sendable {
        let project: String
        let path: String
        let isWorktree: Bool
    }

    static func read(_ checkout: Checkout) async -> (RemoteCheckout, GitSnapshot) {
        let snapshot = await GitInspector.snapshot(at: checkout.path, lane: .interactive,
                                                   comparingToLastCommit: true)
        var files: [RemoteChangedFile] = []
        if snapshot.state == .ready {
            for change in snapshot.files {
                let diff = await GitInspector.reviewDiff(for: change, root: snapshot.root)
                files.append(RemoteChangedFile(change, diff: RemoteDiff(diff)))
            }
        }
        let remote = RemoteCheckout(project: checkout.project, path: checkout.path,
                                    isWorktree: checkout.isWorktree, branch: snapshot.branch,
                                    state: word(for: snapshot.state),
                                    status: status(of: snapshot), files: files)
        return (remote, snapshot)
    }

    static func word(for state: GitRepoState) -> String {
        switch state {
        case .ready: "ready"
        case .notARepo: "notARepo"
        case .missingFolder: "missingFolder"
        case .gitMissing: "gitMissing"
        case .failed: "failed"
        }
    }

    private static func status(of snapshot: GitSnapshot) -> String {
        switch snapshot.state {
        case .ready: snapshot.syncDescription()
        case .notARepo: "Not a git repository"
        case .missingFolder: "The folder is no longer there"
        case .gitMissing: "Could not find git on PATH"
        case .failed(let message): message
        }
    }
}

extension RemoteChangedFile {
    init(_ change: GitChange, diff: RemoteDiff) {
        self.init(path: change.path, originalPath: change.originalPath,
                  status: change.kind.label, letter: change.kind.letter,
                  staged: change.isStaged, unstaged: change.isUnstaged,
                  added: change.added, removed: change.removed, binary: change.isBinary,
                  diff: diff)
    }
}

extension RemoteDiff {
    // Gap rows are the GUI's handles for opening unchanged lines; a unified diff already
    // says where it skips through its hunk headers, so they are left out. A picture has
    // no text to show and is described instead.
    init(_ diff: FileDiff) {
        let lines = diff.lines.compactMap { line -> RemoteDiffLine? in
            let kind: RemoteDiffLine.Kind? = switch line.kind {
            case .hunk: .hunk
            case .context: .context
            case .addition: .addition
            case .deletion: .deletion
            case .meta: .meta
            case .section: .section
            case .gap: nil
            }
            return kind.map { RemoteDiffLine(kind: $0, text: line.text) }
        }
        let note = diff.note ?? (diff.images != nil ? "Image. Open it in the app to compare." : nil)
        self.init(lines: lines, truncated: diff.truncated, totalLines: diff.totalLines, note: note)
    }
}
