import Foundation

// A session's commit history and pull requests, as the station commands façade hands
// them out: the recent commits of every checkout the session works in, the pull requests
// the session opened, and one commit's changed files, each with its diff against the
// commit's first parent. The same reads the GUI's commit history makes.

public struct RemoteHistory: Codable, Equatable, Sendable {
    public let type = "history"
    public let version = 1
    public let sessionID: String
    // The lead checkout first, as the session lists them.
    public let checkouts: [RemoteCommitLog]
    // In the order the session opened them.
    public let pullRequests: [PullRequest]

    public init(sessionID: String, checkouts: [RemoteCommitLog], pullRequests: [PullRequest]) {
        self.sessionID = sessionID
        self.checkouts = checkouts
        self.pullRequests = pullRequests
    }

    private enum CodingKeys: String, CodingKey {
        case type, version, sessionID, checkouts, pullRequests
    }

    // The type and version are fixed for this struct, so they are written but not read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        checkouts = try container.decode([RemoteCommitLog].self, forKey: .checkouts)
        pullRequests = try container.decodeIfPresent([PullRequest].self, forKey: .pullRequests) ?? []
    }
}

// One checkout's recent commits, newest first, up to `GitInspector.historyLimit`.
public struct RemoteCommitLog: Codable, Equatable, Sendable {
    public let project: String
    public let path: String
    public let isWorktree: Bool
    public let commits: [RemoteCommitSummary]
    // Why there are no commits to show when git could not answer. A repository with no
    // commits yet has none and no note.
    public let note: String?

    public init(project: String, path: String, isWorktree: Bool, commits: [RemoteCommitSummary], note: String?) {
        self.project = project
        self.path = path
        self.isWorktree = isWorktree
        self.commits = commits
        self.note = note
    }
}

public struct RemoteCommitSummary: Codable, Equatable, Sendable {
    public let hash: String
    public let shortHash: String
    public let author: String
    // As git says it: "3 hours ago".
    public let relativeDate: String
    public let subject: String

    public init(hash: String, shortHash: String, author: String, relativeDate: String, subject: String) {
        self.hash = hash
        self.shortHash = shortHash
        self.author = author
        self.relativeDate = relativeDate
        self.subject = subject
    }
}

// One commit opened: its parents and the files it changed against the first of them (or
// the empty tree for a first commit), each with its unified diff.
public struct RemoteCommit: Codable, Equatable, Sendable {
    public let type = "commit"
    public let version = 1
    public let hash: String
    public let parents: [String]
    public let files: [RemoteChangedFile]
    // Said when git could not list every file.
    public let note: String?

    public init(hash: String, parents: [String], files: [RemoteChangedFile], note: String?) {
        self.hash = hash
        self.parents = parents
        self.files = files
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case type, version, hash, parents, files, note
    }

    // The type and version are fixed for this struct, so they are written but not read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hash = try container.decode(String.self, forKey: .hash)
        parents = try container.decode([String].self, forKey: .parents)
        files = try container.decode([RemoteChangedFile].self, forKey: .files)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

extension StationCommands {
    // A commit with more files than this is listed in full, but only the first ones come
    // with their diffs, so one huge commit cannot flood a client.
    static let commitDiffLimit = 100

    // The recent commits of every checkout the session works in, lead first, and the
    // pull requests it opened.
    public func readHistory(_ sessionID: String) async throws(StationRefusal) -> RemoteHistory {
        guard let id = UUID(uuidString: sessionID), let session = store.session(id) else { throw .noSession }
        var logs: [RemoteCommitLog] = []
        for checkout in changesCheckouts(of: session) {
            let (commits, note) = await GitInspector.recentCommits(at: checkout.path)
            logs.append(RemoteCommitLog(project: checkout.project, path: checkout.path,
                                        isWorktree: checkout.isWorktree,
                                        commits: commits.map(RemoteCommitSummary.init), note: note))
        }
        // The session may have been removed while git answered.
        let pullRequests = store.session(id)?.pullRequests ?? session.pullRequests
        return RemoteHistory(sessionID: id.uuidString, checkouts: logs, pullRequests: pullRequests)
    }

    // One commit of one of the session's checkouts, by its hash.
    public func readCommit(_ sessionID: String, checkout: String,
                           hash: String) async throws(StationRefusal) -> RemoteCommit {
        guard let id = UUID(uuidString: sessionID), let session = store.session(id) else { throw .noSession }
        guard changesCheckouts(of: session).contains(where: { $0.path == checkout }) else {
            throw StationRefusal("This session does not work in \(checkout).")
        }
        guard await Self.isCommit(hash, in: checkout) else { throw StationRefusal("\(hash) is not a commit.") }
        let listed = await GitInspector.commitFiles(hash, root: checkout)
        let parent = listed.parents.first
        var files: [RemoteChangedFile] = []
        for (index, change) in listed.files.enumerated() {
            let diff = index < Self.commitDiffLimit
                ? await GitInspector.commitFileDiff(hash, parent: parent, file: change, root: checkout)
                : FileDiff(note: "Not shown: this commit changes more than \(Self.commitDiffLimit) files.")
            files.append(RemoteChangedFile(change, diff: RemoteDiff(diff)))
        }
        return RemoteCommit(hash: hash, parents: listed.parents, files: files, note: listed.note)
    }

    // Only a hash is taken, never anything git could read as an option or a range.
    private static func isCommit(_ hash: String, in checkout: String) async -> Bool {
        guard (4...64).contains(hash.count), hash.allSatisfy(\.isHexDigit),
              let tool = GitInspector.tool() else { return false }
        return await GitInspector.offMain(lane: .interactive) {
            GitInspector.run(tool, ["rev-parse", "--verify", "--quiet", "\(hash)^{commit}"],
                             in: URL(fileURLWithPath: checkout)).status == 0
        }
    }
}

extension RemoteCommitSummary {
    init(_ commit: GitCommitSummary) {
        self.init(hash: commit.hash, shortHash: commit.shortHash, author: commit.author,
                  relativeDate: commit.relativeDate, subject: commit.subject)
    }
}
