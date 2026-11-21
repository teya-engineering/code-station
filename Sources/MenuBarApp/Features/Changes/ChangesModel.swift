import AppKit
import Observation

@MainActor
@Observable
final class ChangesModel {
    var checkedAt: Date?
    var refreshFailed = false
    var latestCommit: GitCommitSummary?
    var snapshot: GitSnapshot?
    // Compare the files to where the branch left the remote's default branch, so work
    // already committed shows next to what is not.
    var comparesToRemote = false
    // The remote branch to compare with. Nil takes the remote's default branch.
    var remoteRef: String?
    // The remotes' branches as last fetched, for the menu that picks one.
    var remoteBranches: GitRemoteBranches?
    var loading = false
    var working: String?
    var commits: [GitCommitSummary]?
    var historyNote: String?
    var loadingHistory = false
    var diff: FileDiff?
    // The changed file the diff on screen belongs to. It can trail the selection while
    // the next file is read, so the pane keeps showing one whole file until then.
    var diffFileID: String?
    var diffText: NSAttributedString?
    // The words picked out in each changed line of the diff, keyed by line id. Always
    // matches the diff's lines, or is empty.
    var diffMarks: [Int: [NSRange]] = [:]
    // The thread lines the text on screen was built with, so it is only built again
    // when they change.
    @ObservationIgnored private(set) var renderedThreads: Set<Int> = []
    var loadingDiff = false
    var expanding: Set<String> = []
    @ObservationIgnored private var renderGeneration = 0
    @ObservationIgnored private var loadGeneration = 0

    @ObservationIgnored private let readSnapshot: (_ root: String, _ comparingToRemote: Bool,
                                                   _ remoteRef: String?) async -> GitSnapshot

    init(readSnapshot: @escaping (_ root: String, _ comparingToRemote: Bool,
                                  _ remoteRef: String?) async -> GitSnapshot = {
        await GitInspector.snapshot(at: $0, lane: .interactive, comparingToLastCommit: true,
                                    findingRemoteBase: true, comparingToRemote: $1, remoteRef: $2)
    }) {
        self.readSnapshot = readSnapshot
    }

    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var historyGeneration = 0

    var busy: Bool { loading || working != nil }

    func perform(_ progress: String, _ action: () async -> String?) async -> String? {
        guard !busy else { return nil }
        working = progress
        defer { working = nil }
        return await action()
    }

    func reload(root: String, fetchOrigin: Bool, gitStats: GitStatsCache,
                onError: (String) -> Void) async -> Bool {
        refreshGeneration += 1
        let generation = refreshGeneration
        loading = true
        defer { if generation == refreshGeneration { loading = false } }
        if fetchOrigin { refreshFailed = false }
        if fetchOrigin, snapshot?.state == .ready,
           let error = await GitActions.fetchOrigin(at: snapshot?.root ?? root) {
            guard !Task.isCancelled, generation == refreshGeneration else { return false }
            refreshFailed = true
            onError(error)
        }
        let fresh = await readSnapshot(root, comparesToRemote, remoteRef)
        guard !Task.isCancelled, generation == refreshGeneration else { return false }
        snapshot = fresh
        checkedAt = Date()
        // A remote that went away takes the choice with it, so it does not come back on
        // its own when the remote returns.
        if fresh.state == .ready && fresh.remoteBase == nil { comparesToRemote = false }
        // The cache feeds the uncommitted totals shown elsewhere, which committed work
        // must not inflate.
        gitStats.store(fresh.againstLastCommit, at: root)
        latestCommit = nil
        if fresh.files.isEmpty && fresh.hasCommits {
            let latest = await GitInspector.recentCommits(at: fresh.root, limit: 1).commits.first
            guard !Task.isCancelled, generation == refreshGeneration else { return false }
            latestCommit = latest
        }
        return true
    }

    func loadHistory(at root: String) async -> Bool {
        historyGeneration += 1
        let generation = historyGeneration
        loadingHistory = true
        defer { if generation == historyGeneration { loadingHistory = false } }
        let history = await GitInspector.recentCommits(at: root)
        guard !Task.isCancelled, generation == historyGeneration else { return false }
        commits = history.commits
        historyNote = history.note
        return true
    }

    func loadDiff(_ file: GitChange, at root: String,
                  isCurrent: () -> Bool) async -> FileDiff? {
        loadGeneration += 1
        let generation = loadGeneration
        loadingDiff = true
        defer { if generation == loadGeneration { loadingDiff = false } }
        let loaded = await GitInspector.reviewDiff(for: file, root: root, base: snapshot?.diffBase(for: file))
        guard !Task.isCancelled, generation == loadGeneration, isCurrent() else { return nil }
        return loaded
    }

    func renderDiff(language: CodeLanguage?, scale: CGFloat, numbered: Bool,
                    comments: DiffComments?) async {
        guard let diff, !diff.lines.isEmpty else { return }
        let lines = diff.lines
        renderGeneration += 1
        let generation = renderGeneration
        let built = await DiffText.build(lines, language: language, scale: scale,
                                         numbered: numbered, comments: comments)
        guard !Task.isCancelled, self.diff?.lines == lines,
              generation == renderGeneration else { return }
        diffText = built.text
        diffMarks = built.marks
        renderedThreads = comments?.threads ?? []
    }

    // A newly read file replaces the one on screen only once its text is built, all in
    // one go. Clearing the pane first would flash it empty while git and the build run.
    // Only a newer load stops it: the file still on screen may be drawn again meanwhile.
    func showDiff(_ loaded: FileDiff, of fileID: String, language: CodeLanguage?, scale: CGFloat,
                  comments: DiffComments?) async {
        let generation = loadGeneration
        let built = loaded.lines.isEmpty ? nil
            : await DiffText.build(loaded.lines, language: language, scale: scale,
                                   numbered: true, comments: comments)
        guard !Task.isCancelled, generation == loadGeneration else { return }
        renderGeneration += 1
        diff = loaded
        diffFileID = fileID
        diffText = built?.text
        diffMarks = built?.marks ?? [:]
        renderedThreads = comments?.threads ?? []
    }

    func expand(_ key: String, _ direction: DiffExpandDirection, at root: String) async -> Bool {
        guard !expanding.contains(key),
              let gap = diff?.lines.first(where: { $0.gap?.key == key })?.gap else { return false }
        let generation = loadGeneration
        expanding.insert(key)
        defer { if generation == loadGeneration { expanding.remove(key) } }
        let expansion = await GitInspector.expand(gap, direction, root: root)
        guard !Task.isCancelled, generation == loadGeneration, var opened = diff,
              let at = opened.lines.firstIndex(where: { $0.gap?.key == key }) else { return false }
        let movedFrom: Int
        let shift: Int
        if let left = expansion.gap {
            opened.lines[at].gap = left
            movedFrom = direction == .up ? at + 1 : at
            shift = expansion.lines.count
            opened.lines.insert(contentsOf: expansion.lines, at: movedFrom)
            opened.revealed += expansion.lines.count
        } else {
            movedFrom = at + 1
            shift = expansion.lines.count - 1
            opened.lines.replaceSubrange(at...at, with: expansion.lines)
            opened.revealed += expansion.lines.count - 1
        }
        for i in opened.lines.indices { opened.lines[i].id = i }
        diff = opened
        // The lines after the gap move along, and their marks move with them, so no line
        // shows another line's marks while the text is built again.
        diffMarks = Dictionary(uniqueKeysWithValues: diffMarks.map { id, ranges in
            (id >= movedFrom ? id + shift : id, ranges)
        })
        return true
    }

    func clearDiff() {
        loadGeneration += 1
        renderGeneration += 1
        diff = nil
        diffFileID = nil
        diffText = nil
        diffMarks = [:]
        renderedThreads = []
        loadingDiff = false
        expanding = []
    }
}

// The models of the projects a Changes screen has shown. Not observed: a model is made
// the first time its project is drawn, and making one changes nothing on screen.
@MainActor
final class ChangesModels {
    private var models: [String: ChangesModel] = [:]

    // `comparingToRemote` is where a new model starts. A model already made keeps the
    // comparison it has.
    func model(for root: String, comparingToRemote: Bool = false) -> ChangesModel {
        if let model = models[root] { return model }
        let model = ChangesModel()
        model.comparesToRemote = comparingToRemote
        models[root] = model
        return model
    }
}
