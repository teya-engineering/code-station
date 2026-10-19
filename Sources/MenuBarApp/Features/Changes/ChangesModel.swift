import AppKit
import Observation
import CodeStationCore

@MainActor
@Observable
final class ChangesModel {
    var checkedAt: Date?
    var refreshFailed = false
    var latestCommit: GitCommitSummary?
    var snapshot: GitSnapshot?
    var loading = false
    var working: String?
    var commits: [GitCommitSummary]?
    var historyNote: String?
    var loadingHistory = false
    var diff: FileDiff?
    var diffText: NSAttributedString?
    var loadingDiff = false
    var expanding: Set<String> = []
    @ObservationIgnored private var renderGeneration = 0
    @ObservationIgnored private var loadGeneration = 0

    @ObservationIgnored private let readSnapshot: (String) async -> GitSnapshot

    init(readSnapshot: @escaping (String) async -> GitSnapshot = {
        await GitInspector.snapshot(at: $0, lane: .interactive, comparingToLastCommit: true)
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
        let fresh = await readSnapshot(root)
        guard !Task.isCancelled, generation == refreshGeneration else { return false }
        snapshot = fresh
        checkedAt = Date()
        gitStats.store(fresh, at: root)
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
        let loaded = await GitInspector.reviewDiff(for: file, root: root)
        guard !Task.isCancelled, generation == loadGeneration, isCurrent() else { return nil }
        return loaded
    }

    func renderDiff(language: CodeLanguage?, scale: CGFloat, numbered: Bool,
                    comments: DiffComments?) async {
        guard let diff, !diff.lines.isEmpty else { return }
        let lines = diff.lines
        renderGeneration += 1
        let generation = renderGeneration
        let text = await DiffText.build(lines, language: language, scale: scale,
                                        numbered: numbered, comments: comments)
        guard !Task.isCancelled, self.diff?.lines == lines,
              generation == renderGeneration else { return }
        diffText = text
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
        if let left = expansion.gap {
            opened.lines[at].gap = left
            opened.lines.insert(contentsOf: expansion.lines, at: direction == .up ? at + 1 : at)
            opened.revealed += expansion.lines.count
        } else {
            opened.lines.replaceSubrange(at...at, with: expansion.lines)
            opened.revealed += expansion.lines.count - 1
        }
        for i in opened.lines.indices { opened.lines[i].id = i }
        diff = opened
        return true
    }

    func clearDiff() {
        loadGeneration += 1
        renderGeneration += 1
        diff = nil
        diffText = nil
        loadingDiff = false
        expanding = []
    }
}
