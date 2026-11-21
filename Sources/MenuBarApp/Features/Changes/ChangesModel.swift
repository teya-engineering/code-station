import AppKit
import Observation

// What a load takes from the screen it runs for. The closures are read when a diff is
// drawn, so a load that began before the reading size or a comment changed still draws
// with what is true by then.
struct ChangesScreen {
    let gitStats: GitStatsCache
    // The other projects listed in the navigator.
    var otherRoots: [String] = []
    // The file to open the first time the project's files are read.
    var firstPath: String?
    var textScale: () -> CGFloat = { 1 }
    var comments: (GitChange?, [DiffLine]) -> DiffComments? = { _, _ in nil }
    var fetchFailed: (String) -> Void = { _ in }
}

@MainActor
@Observable
final class ChangesModel {
    let root: String
    @ObservationIgnored private let navigation: ChangesNavigationMemory

    var checkedAt: Date?
    var refreshFailed = false
    var latestCommit: GitCommitSummary?
    var snapshot: GitSnapshot?
    // Compare the files to where the branch left the remote's default branch, so work
    // already committed shows next to what is not.
    var comparesToRemote = false
    var loading = false
    var working: String?
    var commits: [GitCommitSummary]?
    var historyNote: String?
    var loadingHistory = false
    // Set by a press on the latest commit, so the history opens on it once the log is read.
    @ObservationIgnored var openLatestCommit = false
    // True once the project's first file has been picked, or it kept the one picked before.
    @ObservationIgnored var pickedInitialFile = false
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
    // Where the pane is left when the diff's text is next put in it.
    var diffScroll = DiffTextView.Scroll.top
    var loadingDiff = false
    // Gap rows git is reading the hidden lines for right now.
    var expanding: Set<String> = []
    // The text being built again for the diff on screen. A newer build, a newly shown
    // file and a cleared pane each cancel it, so its text never lands over theirs.
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var historyGeneration = 0

    @ObservationIgnored private let readSnapshot: (_ root: String, _ comparingToRemote: Bool) async -> GitSnapshot

    init(root: String, navigation: ChangesNavigationMemory,
         readSnapshot: @escaping (_ root: String, _ comparingToRemote: Bool) async -> GitSnapshot = {
        await GitInspector.snapshot(at: $0, lane: .interactive, comparingToLastCommit: true,
                                   findingRemoteBase: true, comparingToRemote: $1)
    }) {
        self.root = root
        self.navigation = navigation
        self.readSnapshot = readSnapshot
    }

    var busy: Bool { loading || working != nil }

    var commitDraft: ChangesCommitDraft { navigation.commitDraft(for: root) }
    var historySelection: CommitHistorySelection { navigation.history(for: root) }
    var fileSelection: ChangeFileSelection {
        get { navigation.selections[root] ?? ChangeFileSelection() }
        set { navigation.selections[root] = newValue }
    }

    func perform(_ progress: String, _ action: () async -> String?) async -> String? {
        guard !busy else { return nil }
        working = progress
        defer { working = nil }
        return await action()
    }

    // Reads the project again, then brings what hangs on its files in line with it: the
    // files picked for the commit, the open file and its diff, or the log while the
    // history is showing.
    func reload(fetchOrigin: Bool = false, for screen: ChangesScreen) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let fresh: GitSnapshot
        // The header is only busy while the project itself is read, not while the diff
        // or the log is read after it.
        do {
            loading = true
            defer { if generation == refreshGeneration { loading = false } }
            if fetchOrigin { refreshFailed = false }
            if fetchOrigin, snapshot?.state == .ready,
               let error = await GitActions.fetchOrigin(at: snapshot?.root ?? root) {
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                refreshFailed = true
                screen.fetchFailed(error)
            }
            fresh = await readSnapshot(root, comparesToRemote)
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            snapshot = fresh
            checkedAt = Date()
            // A remote that went away takes the choice with it, so it does not come back on
            // its own when the remote returns.
            if fresh.state == .ready && fresh.remoteBase == nil { comparesToRemote = false }
            // The cache feeds the uncommitted totals shown elsewhere, which committed work
            // must not inflate.
            screen.gitStats.store(fresh.againstLastCommit, at: root)
            latestCommit = nil
            if fresh.files.isEmpty && fresh.hasCommits {
                let latest = await GitInspector.recentCommits(at: fresh.root, limit: 1).commits.first
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                latestCommit = latest
            }
        }

        commitDraft.excluded.formIntersection(Set(fresh.files.map(\.id)))
        // A push can land between refreshes, and amending a pushed commit is exactly
        // what the checkbox exists to prevent.
        if commitDraft.amend && !fresh.canAmend {
            commitDraft.setAmend(false, lastMessage: fresh.lastCommitSubject)
        }

        if navigation.showingHistory {
            await loadHistory(at: fresh.root)
            return
        }

        // Keep the open file open across a refresh, but only if it still has changes.
        let orderedIDs = fresh.files.map(\.id)
        fileSelection.retain(Set(orderedIDs), in: orderedIDs)
        if !pickedInitialFile {
            pickedInitialFile = true
            if let initial = screen.firstPath.flatMap({ path in fresh.files.first { $0.id == path } }) ?? fresh.files.first {
                fileSelection.select(initial.id, in: orderedIDs,
                                     extendingRange: false, toggling: false)
            }
        }
        if let selectedID = fileSelection.activeID,
           let file = fresh.files.first(where: { $0.id == selectedID }) {
            await loadDiff(file, at: fresh.root, recheckList: false, for: screen)
        } else {
            closeDiff()
        }
    }

    // The other projects in the navigator are drawn from what was last read of them.
    // Reading them again on the background lane, after this project, keeps them current
    // without holding up the one on screen.
    func refreshOthers(for screen: ChangesScreen) async {
        for other in screen.otherRoots {
            if navigation.showingHistory {
                let history = await GitInspector.recentCommits(at: other)
                guard !Task.isCancelled else { return }
                navigation.commits[other] = history.commits
            } else {
                let fresh = await GitInspector.snapshot(at: other, comparingToLastCommit: true)
                guard !Task.isCancelled else { return }
                screen.gitStats.store(fresh, at: other)
            }
        }
    }

    // The diff on screen belongs to the mode left behind, so it goes at once. Then the
    // mode now showing reads what it draws: the log, or the diff of the file left open.
    func switchedMode(reopening file: GitChange?, at gitRoot: String, for screen: ChangesScreen) {
        clearDiff()
        if navigation.showingHistory {
            Task {
                await loadHistory(at: gitRoot)
                if openLatestCommit, let commit = commits?.first { historySelection.select(commit) }
                openLatestCommit = false
                await refreshOthers(for: screen)
            }
        } else if let file {
            Task { await loadDiff(file, at: gitRoot, for: screen) }
        }
    }

    // Every visit reads the log again: a commit, pull or amend made in the other mode
    // rewrites exactly what this list shows.
    func loadHistory(at gitRoot: String) async {
        historyGeneration += 1
        let generation = historyGeneration
        loadingHistory = true
        let history = await GitInspector.recentCommits(at: gitRoot)
        if generation == historyGeneration { loadingHistory = false }
        guard !Task.isCancelled, generation == historyGeneration else { return }
        commits = history.commits
        historyNote = history.note
        navigation.commits[root] = history.commits

        if let current = historySelection.commit,
           history.commits.contains(where: { $0.id == current.id }) { return }
        if let first = history.commits.first { historySelection.select(first) }
        else { historySelection.commit = nil }
    }

    func loadDiff(_ file: GitChange, at gitRoot: String, recheckList: Bool = true,
                  for screen: ChangesScreen) async {
        loadGeneration += 1
        let generation = loadGeneration
        loadingDiff = true
        let loaded = await GitInspector.reviewDiff(for: file, root: gitRoot, base: snapshot?.diffBase(for: file))
        if generation == loadGeneration { loadingDiff = false }
        guard !Task.isCancelled, generation == loadGeneration,
              !navigation.showingHistory, fileSelection.activeID == file.id else { return }
        // The list can be older than the tree, for example when a session commits just
        // as a file is opened. An empty diff for a row that counts changed lines means
        // the list is out of date, so read it again rather than show an empty file.
        // The reload opens the diff without this check, so it cannot loop.
        let countedLines = (file.added ?? 0) + (file.removed ?? 0) > 0
        if recheckList, countedLines, loaded.lines.isEmpty, loaded.note == nil, loaded.images == nil {
            await reload(for: screen)
            return
        }
        diffScroll = !recheckList && diffFileID == file.id ? .hold : .top
        await showDiff(loaded, of: file.id, language: CodeLanguage(path: file.path), scale: screen.textScale(),
                       comments: screen.comments(file, loaded.lines))
    }

    func renderDiff(language: CodeLanguage?, scale: CGFloat, numbered: Bool,
                    comments: DiffComments?) {
        guard let diff, !diff.lines.isEmpty else { return }
        let lines = diff.lines
        renderTask?.cancel()
        renderTask = Task {
            let built = await DiffText.build(lines, language: language, scale: scale,
                                             numbered: numbered, comments: comments)
            guard !Task.isCancelled, self.diff?.lines == lines else { return }
            diffText = built.text
            diffMarks = built.marks
            renderedThreads = comments?.threads ?? []
        }
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
        renderTask?.cancel()
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

    func closeDiff() {
        if !navigation.showingHistory { fileSelection.clear() }
        clearDiff()
    }

    func clearDiff() {
        loadGeneration += 1
        renderTask?.cancel()
        diff = nil
        diffFileID = nil
        diffText = nil
        diffMarks = [:]
        renderedThreads = []
        loadingDiff = false
        expanding = []
        diffScroll = .top
    }
}

// The models of the projects a Changes screen has shown. Not observed: a model is made
// the first time its project is drawn, and making one changes nothing on screen.
@MainActor
final class ChangesModels {
    private let navigation: ChangesNavigationMemory
    private var models: [String: ChangesModel] = [:]

    init(navigation: ChangesNavigationMemory) {
        self.navigation = navigation
    }

    func model(for root: String) -> ChangesModel {
        if let model = models[root] { return model }
        let model = ChangesModel(root: root, navigation: navigation)
        models[root] = model
        return model
    }
}
