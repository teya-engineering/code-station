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
    // False for a file that only differs from the base through commits already made,
    // which leaves nothing to stage, commit or discard.
    var hasLocalChanges: Bool { isStaged || isUnstaged }
    var fileName: String { (path as NSString).lastPathComponent }

    mutating func apply(_ count: GitInspector.LineCount) {
        added = count.binary ? nil : count.added
        removed = count.binary ? nil : count.removed
        isBinary = count.binary
    }
}

// Where this branch left the remote's default branch, which is what a pull request
// compares against.
struct GitCompareBase: Sendable, Equatable {
    var ref: String
    var commit: String
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
    // The remote branch this one tracks, and how the two have drifted apart.
    var upstream: String?
    var trackingKnown = false
    var ahead: Int = 0
    var behind: Int = 0
    // The subject of the newest commit and when it landed, which is what says whether the
    // folder has been worked in recently or only read.
    var lastCommitSubject: String?
    var lastCommitDate: Date?
    var files: [GitChange] = []
    // Commits on HEAD that no remote has. Only filled in by cleanup, which needs it to
    // know whether deleting a checkout throws away the only copy of some commits.
    var unpushedCommits = 0
    // Only read for the Changes screen. When files are compared to it, they also hold
    // what the branch has committed since it left the remote's default branch.
    var remoteBase: GitCompareBase?
    var comparedToRemote = false
    // Compared to the remote, the rows in `files` describe each file next to the base,
    // which is not what a commit or a discard acts on. These are the same files as git
    // status sees them, counted against the last commit.
    var uncommittedFiles: [GitChange] = []
    // The paths that differ from the base. A file changed only since the last commit,
    // in a way that brings it back to the base, is not among them.
    var pathsChangedFromBase: Set<String> = []

    // The files a commit or a discard can act on.
    var localFiles: [GitChange] { comparedToRemote ? uncommittedFiles : files }

    // What a file's diff compares against, or nil for the last commit. A file that only
    // differs from the last commit shows that, since next to the base it has no change.
    func diffBase(for file: GitChange) -> String? {
        guard comparedToRemote, pathsChangedFromBase.contains(file.path) else { return nil }
        return remoteBase?.commit
    }

    // Amending rewrites the last commit, which is only safe while nothing else has it:
    // an unpublished branch, or one that is ahead of its upstream.
    var canAmend: Bool { hasCommits && (upstream == nil || ahead > 0) }

    // The same snapshot as it looks against the last commit, for anything that counts
    // uncommitted work.
    var againstLastCommit: GitSnapshot {
        guard comparedToRemote else { return self }
        var snapshot = self
        snapshot.files = uncommittedFiles
        snapshot.uncommittedFiles = []
        snapshot.pathsChangedFromBase = []
        snapshot.comparedToRemote = false
        return snapshot
    }

    var totalAdded: Int { files.compactMap(\.added).reduce(0, +) }
    var totalRemoved: Int { files.compactMap(\.removed).reduce(0, +) }

    func syncDescription(remoteUnavailable: Bool = false) -> String {
        if remoteUnavailable { return "Remote status unavailable" }
        guard let upstream else { return "No upstream branch" }
        guard trackingKnown else { return "Remote status unknown" }
        if ahead > 0 || behind > 0 { return "\(ahead) ahead · \(behind) behind \(upstream)" }
        return "Up to date with \(upstream) (last fetched)"
    }

    // What the remote needs from this branch, in the order the header offers it: a pull
    // comes first so a push after it is not refused.
    var remoteActions: [GitRemoteAction] {
        var actions: [GitRemoteAction] = []
        if upstream != nil && behind > 0 { actions.append(.pull(behind)) }
        if hasCommits {
            if upstream == nil {
                actions.append(.publish)
            } else if ahead > 0 {
                actions.append(.push(ahead))
            }
        }
        return actions
    }

    static func state(_ state: GitRepoState) -> GitSnapshot { GitSnapshot(state: state) }
}

enum GitRemoteAction: Sendable, Equatable, Hashable {
    case pull(Int)
    case push(Int)
    case publish
}

// Which version of a file a diff put on its new side, so the lines it left out can be
// read back from the same place the diff came from.
enum DiffRevision: Sendable, Equatable, Hashable {
    case workingTree
    case index
    case commit(String)
}

// Which end of a gap a press opens. The arrow points the way the reader is travelling:
// down carries on from the code above the gap, up reads back from the code below it.
enum DiffExpandDirection: String, Sendable, Equatable, Hashable {
    case up, down, all
}

// A run of unchanged lines a diff left out, and the row that stands in for it. Line
// numbers count the new side of the file, which is the side we can read back.
struct DiffGap: Sendable, Equatable, Hashable {
    var revision: DiffRevision
    var path: String
    // Handed out while parsing and never touched again. A gap opens from either end, so
    // neither of its line numbers stays put long enough to name the row it belongs to.
    var id: Int
    var start: Int
    // Nil for the gap after the last hunk: a diff never says how long the file is, so
    // the size of that one only settles once the lines are read back.
    var count: Int?

    // Names one row for as long as the diff is open. A file diff parses the staged and
    // the unstaged side apart from each other, so the version is part of the name too.
    var key: String {
        let version = switch revision {
        case .workingTree: "tree"
        case .index: "index"
        case .commit(let hash): hash
        }
        return "\(version)|\(path)|\(id)"
    }
}

struct DiffLine: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case addition, deletion, hunk, context, meta, section, gap
    }

    var id: Int
    var kind: Kind
    var text: String
    // Only on a gap row: the lines that row stands for, which is what it carries its
    // controls for.
    var gap: DiffGap?
}

// What one press on a gap row brings back: the lines to drop in beside it, and whatever
// is still hidden after that.
struct DiffExpansion: Sendable, Equatable {
    var lines: [DiffLine] = []
    var gap: DiffGap?
}

// Both sides of a changed picture. A side is nil when that version does not exist: a
// new image has no before, a deleted one has no after.
struct DiffImages: Sendable, Equatable {
    var before: Data?
    var after: Data?
}

struct FileDiff: Sendable, Equatable {
    var lines: [DiffLine] = []
    // True when we stopped rendering early so a huge diff cannot stall the UI.
    var truncated: Bool = false
    var totalLines: Int = 0
    // Rows that are not diff output: the gap rows, and the unchanged lines a reader
    // opened from one. They do not count towards what a cut-short diff says it holds back.
    var revealed: Int = 0
    var note: String?
    // Set instead of lines when the file is a picture, which has nothing to show as text.
    var images: DiffImages?
}

// One commit in the recent history list.
struct GitCommitSummary: Identifiable, Sendable, Equatable {
    var hash: String
    var shortHash: String
    var author: String
    var relativeDate: String
    var subject: String
    var date: Date? = nil

    var id: String { hash }

    // A query names a commit by words from its subject or by the start of its hash.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || subject.localizedCaseInsensitiveContains(query)
            || hash.lowercased().hasPrefix(query.lowercased())
    }
}
