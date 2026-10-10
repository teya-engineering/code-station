import AppKit
import SwiftUI

struct ChangeFileSelection: Equatable {
    private(set) var ids: Set<GitChange.ID> = []
    private(set) var anchorID: GitChange.ID?
    private(set) var activeID: GitChange.ID?

    mutating func select(_ id: GitChange.ID, in orderedIDs: [GitChange.ID],
                         extendingRange: Bool, toggling: Bool) {
        guard let clickedIndex = orderedIDs.firstIndex(of: id) else { return }

        if extendingRange,
           let anchorID,
           let anchorIndex = orderedIDs.firstIndex(of: anchorID) {
            let bounds = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            let range = Set(orderedIDs[bounds])
            ids = toggling ? ids.union(range) : range
            activeID = id
            return
        }

        if toggling {
            if ids.remove(id) == nil {
                ids.insert(id)
                anchorID = id
                activeID = id
            } else {
                let replacement = orderedIDs.first { ids.contains($0) }
                if anchorID == id { anchorID = replacement }
                if activeID == id { activeID = replacement }
            }
            return
        }

        ids = [id]
        anchorID = id
        activeID = id
    }

    mutating func retain(_ validIDs: Set<GitChange.ID>, in orderedIDs: [GitChange.ID]) {
        ids.formIntersection(validIDs)
        if anchorID.map({ !validIDs.contains($0) }) == true { anchorID = nil }
        if activeID.map({ !validIDs.contains($0) }) == true {
            activeID = orderedIDs.first { ids.contains($0) }
        }
        if ids.isEmpty {
            anchorID = nil
            activeID = nil
        } else if anchorID == nil {
            anchorID = activeID
        }
    }

    mutating func clear() {
        ids = []
        anchorID = nil
        activeID = nil
    }

    func contextMenuFiles(for file: GitChange, in files: [GitChange]) -> [GitChange] {
        ids.contains(file.id) ? files.filter { ids.contains($0.id) } : [file]
    }
}

// Where an arrow key lands in a list of rows. With nothing open it starts at the end the
// key points away from, and at either end it stays where it is rather than wrapping.
enum RowStep {
    static func destination(from current: Int?, step: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return step > 0 ? 0 : count - 1 }
        let next = current + step
        return (0..<count).contains(next) ? next : nil
    }
}

struct ChangesNavigatorItem: Hashable {
    let root: String
    let path: String?

    static func next(after current: Self?, step: Int, in items: [Self]) -> Self? {
        guard let index = RowStep.destination(from: current.flatMap { items.firstIndex(of: $0) },
                                              step: step, count: items.count) else { return nil }
        return items[index]
    }
}

@MainActor
@Observable
final class ChangesNavigationMemory {
    var selections: [String: ChangeFileSelection] = [:]
    var collapsed: Set<String> = []
    var treeWidth = ExplorerSplitLayout.defaultTreeWidth
    var showingHistory = false
    var histories: [String: CommitHistorySelection] = [:]
    // Every project's commits, so each project's navigator can list the others' too.
    var commits: [String: [GitCommitSummary]] = [:]
    var collapsedHistories: Set<String> = []
    var historyFilter = ""
}

struct ChangesRepository: Identifiable {
    let root: String
    let name: String
    var id: String { root }

    static func statusLabel(for snapshot: GitSnapshot?) -> String {
        guard let snapshot else { return "Checking" }
        guard snapshot.state == .ready else { return "Unavailable" }
        return snapshot.files.isEmpty ? "Clean" : "\(snapshot.files.count) changed"
    }
}

// The uncommitted changes in a session's folder: the project directory itself, or the
// session's worktree. Sessions edit the real files there, so this screen is how you
// see what the agent did before you keep it. The diffs themselves never touch the tree;
// the header carries the little git a review ends in: switch branch, commit, pull, push.
struct ChangesView: View {
    let root: String
    let initiallySelectedPath: String?
    let repositories: [ChangesRepository]
    let requestedPath: String?
    let navigation: ChangesNavigationMemory?
    let selectRepository: (String, String?) -> Void
    @State private var localCollapsedRepositories: Set<String> = []
    private var collapsedRepositories: Set<String> {
        get { navigation?.collapsed ?? localCollapsedRepositories }
        nonmutating set {
            if let navigation { navigation.collapsed = newValue }
            else { localCollapsedRepositories = newValue }
        }
    }
    @State private var localCollapsedHistories: Set<String> = []
    // The history folds its projects apart from the changes, so closing a project's
    // commits leaves its changed files open and the other way round.
    private var collapsedHistories: Set<String> {
        get { navigation?.collapsedHistories ?? localCollapsedHistories }
        nonmutating set {
            if let navigation { navigation.collapsedHistories = newValue }
            else { localCollapsedHistories = newValue }
        }
    }
    @State private var localHistoryFilter = ""
    private var historyFilter: String {
        get { navigation?.historyFilter ?? localHistoryFilter }
        nonmutating set {
            if let navigation { navigation.historyFilter = newValue }
            else { localHistoryFilter = newValue }
        }
    }
    @State private var localTreeWidth = ExplorerSplitLayout.defaultTreeWidth
    private var treeWidth: CGFloat {
        get { navigation?.treeWidth ?? localTreeWidth }
        nonmutating set {
            if let navigation { navigation.treeWidth = newValue }
            else { localTreeWidth = newValue }
        }
    }
    // The navigator keeps its own cursor instead of focusing each row, since a plain
    // button only takes keyboard focus when Full Keyboard Access is on.
    @State private var navigatorCursor: ChangesNavigatorItem?
    @FocusState private var navigatorFocused: Bool
    // A click already highlights the row it picks, so the cursor outline only shows
    // while the keyboard is driving the navigator.
    @State private var navigatorCursorVisible = false

    private enum Mode: Hashable { case changes, history }

    @Environment(DialogPresenter.self) private var dialogs
    @Environment(GitStatsCache.self) private var gitStats
    @Environment(AppSettings.self) private var appSettings

    @State private var copied: GitInspector.CopyVersion?
    @State private var copiedPath: String?
    @State private var checkedAt: Date?
    @State private var refreshFailed = false
    @State private var feedback = ""
    @State private var latestCommit: GitCommitSummary?
    @State private var openLatestCommit = false
    @State private var snapshot: GitSnapshot?
    @State private var loading = false
    @State private var working: String?
    @State private var localMode: Mode = .changes
    private var mode: Mode {
        get { navigation.map { $0.showingHistory ? .history : .changes } ?? localMode }
        nonmutating set {
            if let navigation { navigation.showingHistory = newValue == .history }
            else { localMode = newValue }
        }
    }
    @State private var committing = false
    @State private var commitMessage = ""
    @FocusState private var commitFocused: Bool
    @FocusState private var pushFocused: Bool
    // Files the next commit leaves out. Tracking the exclusions rather than the picks
    // means a file that appears between refreshes starts selected, like everything else.
    @State private var excluded: Set<GitChange.ID> = []
    @State private var amend = false
    @State private var messageBeforeAmend = ""
    @State private var fileSelection = ChangeFileSelection()
    @State private var commits: [GitCommitSummary]?
    @State private var historyNote: String?
    @State private var loadingHistory = false
    @State private var historySelection = CommitHistorySelection()
    @State private var diff: FileDiff?
    @State private var diffText: NSAttributedString?
    @State private var loadingDiff = false
    @State private var diffScroll = DiffTextView.Scroll.top
    // Gap rows git is reading the hidden lines for right now.
    @State private var expanding: Set<String> = []
    @State private var appliedInitialSelection = false

    private var files: [GitChange] { snapshot?.files ?? [] }
    private var selected: GitChange? { files.first { $0.id == fileSelection.activeID } }
    private var selectedFiles: [GitChange] { files.filter { !excluded.contains($0.id) } }
    private var repoRoot: String { snapshot?.root ?? root }
    private var busy: Bool { loading || working != nil }
    private var repositoryName: String { repositories.first { $0.root == root }?.name ?? root }

    // Amending rewrites the last commit, which is only safe while nothing else has it:
    // an unpublished branch, or one that is ahead of its upstream.
    private var canAmend: Bool {
        guard let snapshot, snapshot.hasCommits else { return false }
        return snapshot.upstream == nil || snapshot.ahead > 0
    }

    init(root: String, initiallySelectedPath: String? = nil,
         repositories: [ChangesRepository] = [], requestedPath: String? = nil,
         navigation: ChangesNavigationMemory? = nil,
         selectRepository: @escaping (String, String?) -> Void = { _, _ in }) {
        self.navigation = navigation
        _historySelection = State(initialValue: navigation?.histories[root] ?? CommitHistorySelection())
        _fileSelection = State(initialValue: navigation?.selections[root] ?? ChangeFileSelection())
        _appliedInitialSelection = State(initialValue: navigation?.selections[root] != nil
            && initiallySelectedPath == nil && requestedPath == nil)
        self.root = root
        self.initiallySelectedPath = initiallySelectedPath
        self.repositories = repositories.isEmpty
            ? [ChangesRepository(root: root, name: (root as NSString).lastPathComponent)] : repositories
        self.requestedPath = requestedPath
        self.selectRepository = selectRepository
    }

    // In a session the Workspace band sits over the navigator and the actions band over
    // the content, so the two rules meet as one line and the navigator row is the only
    // thing that names the project. A single project has no Workspace band, so its
    // header spans the pane as before.
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                // A narrow history has no room for two columns, so the navigator and the
                // commit page take turns.
                let narrowHistory = mode == .history && geometry.size.width < 850
                let navigatorVisible = showsNavigator(width: geometry.size.width) && !narrowHistory
                let width = navigation == nil ? 280
                    : ExplorerSplitLayout.treeWidth(treeWidth, availableWidth: geometry.size.width)
                let headerWidth = navigatorVisible
                    ? geometry.size.width - width - ExplorerSplitLayout.dividerWidth : geometry.size.width
                VStack(spacing: 0) {
                    if navigation == nil {
                        header(compact: geometry.size.width < 700, namesProject: !navigatorVisible)
                        if committing && mode == .changes { commitBar }
                    }
                    HStack(spacing: 0) {
                        if navigatorVisible {
                            VStack(spacing: 0) {
                                if navigation != nil { workspaceBand }
                                workspaceNavigator
                            }.frame(width: width).clipped()
                            Rectangle().fill(Theme.hairline).frame(width: ExplorerSplitLayout.dividerWidth)
                        }
                        VStack(spacing: 0) {
                            if navigation != nil {
                                header(compact: headerWidth < 600, namesProject: false)
                                if committing && mode == .changes { commitBar }
                            }
                            content(narrowHistory: narrowHistory)
                        }.frame(maxWidth: .infinity).clipped()
                    }
                    .overlay(alignment: .leading) {
                        if navigatorVisible && navigation != nil {
                            WorkspaceSplitHandle(width: Binding(get: { treeWidth }, set: { treeWidth = $0 }), displayedWidth: width,
                                                 availableWidth: geometry.size.width)
                                .offset(x: width + (ExplorerSplitLayout.dividerWidth - ExplorerSplitLayout.handleWidth) / 2)
                        }
                    }
                }
            }
            if let checkedAt {
                HStack {
                    Text(feedback.isEmpty ? (mode == .changes ? "Last commit → Working tree" : "Commit history") : feedback)
                    Spacer()
                    if let working { Text(working) }
                    Text(checkedAt, style: .relative)
                    refreshButton
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            }
        }
        .background(Theme.background)
        .onAppear { navigation?.histories[root] = historySelection }
        .onChange(of: fileSelection) { _, selection in navigation?.selections[root] = selection }
        // The screen opens on the last snapshot taken of this tree while a fresh one
        // is fetched, so the file list is there at first glance instead of after git.
        .task(id: root) {
            if snapshot == nil { snapshot = gitStats.snapshot(at: root) }
            await reload()
            await refreshOtherProjects()
        }
        .onChange(of: requestedPath) { _, path in
            guard let file = files.first(where: { $0.id == path }) else { return }
            mode = .changes
            select(file)
        }
        .onChange(of: mode) { _, _ in switchedMode() }
        .onChange(of: syncStatus) { _, status in announce(status) }
        // The open diff is one attributed string built when the file was picked, so its
        // font is baked in and a new reading size only reaches it by building it again.
        .onChange(of: appSettings.textSize) { _, _ in reopenDiff() }
        // Amending reuses the last message as the starting point; the typed one comes
        // back if the box is unticked.
        .onChange(of: amend) { _, on in
            if on {
                messageBeforeAmend = commitMessage
                if let subject = snapshot?.lastCommitSubject { commitMessage = subject }
            } else {
                commitMessage = messageBeforeAmend
            }
        }
    }

    private var syncStatus: String {
        snapshot?.syncDescription(remoteUnavailable: refreshFailed) ?? "Checking branch status"
    }

    private var cleanContent: some View {
        VStack(spacing: 16) {
            PaneMessage(icon: "checkmark.seal", title: "No uncommitted changes",
                        detail: "\(repositoryName) has no pending changes.\n" + syncStatus) {
                ActionButton(title: "View commit history") { mode = .history }
            }
            .frame(maxHeight: 260)
            if let subject = snapshot?.lastCommitSubject {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Latest commit").font(.system(size: 12, weight: .semibold))
                    Button { openLatestCommit = true; mode = .history } label: {
                        HStack {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            Text(subject).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if let latestCommit {
                        Text("\(latestCommit.shortHash) · \(latestCommit.author) · \(latestCommit.relativeDate)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if let date = snapshot?.lastCommitDate {
                        Text(date, style: .relative).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text(snapshot?.upstream.map { "Tracking " + $0 } ?? "No upstream branch")
                        .font(.mono(11)).foregroundStyle(.secondary)
                }
                .padding(20).background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
                .frame(maxWidth: 660)
            }
            Spacer()
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func versionHeader(_ title: String, version: GitInspector.CopyVersion, file: GitChange) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            copyButton(version, file: file, label: "Copy")
        }.frame(maxWidth: .infinity)
    }

    private func copyButton(_ version: GitInspector.CopyVersion, file: GitChange, label: String) -> some View {
        Button {
            copy(version, file: file)
        } label: {
            Label(copied == version && copiedPath == file.id ? "Copied" : label, systemImage: "doc.on.doc")
                .font(.system(size: 12)).padding(8)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityLabel(version == .patch ? "Copy unified diff" : version == .before ? "Copy last commit version" : "Copy working tree version")
    }

    private func copy(_ version: GitInspector.CopyVersion, file: GitChange) {
        Task {
            let result = await GitInspector.copyText(for: file, root: repoRoot, version: version)
            switch result {
            case .success(let text):
                guard Pasteboard.copy(text) else {
                    dialogs.show(.notice("Could not copy", message: "The clipboard is unavailable. Try Copy again."))
                    return
                }
                copied = version
                copiedPath = file.id
                announce("Copied " + file.fileName)
                try? await Task.sleep(for: .seconds(2))
                copied = nil
            case .failure(let error):
                dialogs.show(.notice("Could not copy", message: error.message + " Try refreshing or open the file in an editor."))
            }
        }
    }

    // MARK: - Header

    // A session's navigator is always there, and so is the history's, since the commits
    // live in it. A single project's changes only show the navigator where it fits.
    private func showsNavigator(width: CGFloat) -> Bool {
        navigation != nil || mode == .history || width >= 650 || committing
    }

    private var workspaceBand: some View {
        HStack {
            Text("Workspace").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(counted(repositories.count, "project"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    // The header names the project only while the navigator is hidden, so the name is
    // never shown twice.
    private func header(compact: Bool, namesProject: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            if namesProject { projectLabel }
            HStack(spacing: 4) {
                ChoicePill(title: "Changes \(files.count)", selected: mode == .changes) { mode = .changes }
                ChoicePill(title: "History", selected: mode == .history) { mode = .history }
            }
            Spacer(minLength: 0)
            if let snapshot, snapshot.state == .ready {
                if !compact {
                    Text(snapshot.branch).font(.mono(11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 140, alignment: .trailing)
                        .accessibilityHint(syncStatus)
                }
                Image(systemName: "ellipsis").padding(8).contentShape(Rectangle())
                    .appMenu { repositoryMenu(snapshot) }
                    .accessibilityLabel("Repository actions for \(repositories.first { $0.root == root }?.name ?? root)")
                    .disabled(busy)
                pushButton(snapshot, compact: compact)
                if !files.isEmpty && mode == .changes {
                    ActionButton(title: compact ? "Commit" : "Commit…", height: 30, size: 12) {
                        if committing { committing = false } else { beginCommit() }
                    }.disabled(busy)
                }
            }
        }
        .padding(.horizontal, compact ? 12 : 20)
        .headerBand()
    }

    // A menu when there is a choice to make, a plain name when there is not.
    @ViewBuilder private var projectLabel: some View {
        let label = HStack(spacing: 7) {
            ProjectDot(tint: Theme.projectTint(for: repositoryName), size: 8)
            Text(repositoryName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if repositories.count > 1 { Image(systemName: "chevron.down").font(.system(size: 10)) }
        }
        if repositories.count > 1 {
            label.padding(7).surface(Theme.field, cornerRadius: 7).contentShape(Rectangle())
                .appMenu {
                    repositories.map { repository in
                        .item(repository.name, checked: repository.root == root) { selectRepository(repository.root, nil) }
                    }
                }.accessibilityLabel("Select project, \(repositoryName)")
        } else {
            label.appTooltip(repositoryName)
        }
    }

    private func pushButton(_ snapshot: GitSnapshot, compact: Bool) -> some View {
        let action = snapshot.remoteActions.first {
            switch $0 {
            case .push, .publish: true
            case .pull: false
            }
        }
        let title: String
        switch action {
        case .push(let count): title = compact ? "Push \(count)" : "Push \(counted(count, "commit"))"
        case .publish: title = "Publish branch"
        default:
            if !snapshot.hasCommits { title = "No commits" }
            else if snapshot.upstream != nil && !snapshot.trackingKnown { title = "Status unknown" }
            else { title = "Up to date" }
        }
        return ActionButton(title: working ?? title, tone: action == nil ? .outlined : .green,
                            height: 30, size: 12, icon: action == nil ? "checkmark" : "arrow.up") {
            pushFocused = true
            confirmPush(snapshot)
        }
        .focused($pushFocused)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(pushFocused ? Theme.accent : .clear, lineWidth: 2))
        .accessibilityLabel(working ?? title)
        .accessibilityHint("\(repositoryName). \(syncStatus)")
        .disabled(busy || action == nil)
        .layoutPriority(1)
    }

    private func repositoryMenu(_ snapshot: GitSnapshot) -> [MenuEntry] {
        var entries = snapshot.remoteActions.compactMap { action -> MenuEntry? in
            guard case .pull(let count) = action else { return nil }
            return .item("Pull \(counted(count, "commit"))", icon: "arrow.down") { pull() }
        }
        if !entries.isEmpty { entries.append(.separator) }
        entries.append(contentsOf: branchMenu(snapshot))
        return entries
    }

    private func repositoryStatus(_ repository: ChangesRepository) -> String {
        if repository.root == root, loading { return "Checking" }
        let status = repository.root == root ? snapshot : gitStats.snapshot(at: repository.root)
        return ChangesRepository.statusLabel(for: status)
    }

    private var navigatorItems: [ChangesNavigatorItem] {
        if mode == .history {
            return repositories.flatMap { repository in
                [ChangesNavigatorItem(root: repository.root, path: nil)]
                    + (collapsedHistories.contains(repository.root) ? [] : shownCommits(repository.root).map {
                        ChangesNavigatorItem(root: repository.root, path: $0.hash)
                    })
            }
        }
        return repositories.flatMap { repository in
            let changes = repository.root == root ? files : gitStats.snapshot(at: repository.root)?.files ?? []
            return [ChangesNavigatorItem(root: repository.root, path: nil)]
                + (collapsedRepositories.contains(repository.root) ? [] : changes.map {
                    ChangesNavigatorItem(root: repository.root, path: $0.id)
                })
        }
    }

    private func moveNavigator(_ direction: MoveCommandDirection) {
        navigatorCursorVisible = true
        if let item = navigatorCursor, item.path == nil, direction == .left || direction == .right {
            if mode == .history {
                if direction == .left { collapsedHistories.insert(item.root) } else { collapsedHistories.remove(item.root) }
            } else {
                if direction == .left { collapsedRepositories.insert(item.root) } else { collapsedRepositories.remove(item.root) }
            }
            return
        }
        guard direction == .up || direction == .down,
              let next = ChangesNavigatorItem.next(after: navigatorCursor,
                  step: direction == .up ? -1 : 1, in: navigatorItems) else { return }
        navigatorCursor = next
        if mode == .history {
            if next.root == root, let commit = commits?.first(where: { $0.hash == next.path }) {
                historySelection.select(commit)
                announce(commit.subject)
            }
        } else if next.root == root, let file = files.first(where: { $0.id == next.path }) {
            mode = .changes
            select(file)
        }
    }

    private var workspaceNavigator: some View {
        VStack(spacing: 0) {
            if mode == .history { historyFilterField }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(repositories) { repository in
                            if mode == .history { historyProject(repository) } else { changesProject(repository) }
                        }
                    }.padding(10)
                    .smoothlyResizes(when: mode == .history ? collapsedHistories : collapsedRepositories)
                }
                .accessibilityLabel(mode == .history ? "Workspace projects and commits"
                                                     : "Workspace repositories and changed files")
                .focusable()
                .focused($navigatorFocused)
                .onChange(of: navigatorFocused) { _, focused in
                    if focused && navigatorCursor == nil {
                        navigatorCursor = ChangesNavigatorItem(root: root, path: nil)
                    }
                }
                .focusEffectDisabled()
                .onMoveCommand(perform: moveNavigator)
                .onKeyPress(.return) {
                    if mode == .history, let item = navigatorCursor {
                        if let commit = projectCommits(item.root)?.first(where: { $0.hash == item.path }) {
                            openCommit(commit, in: item.root)
                        } else if item.path == nil {
                            openProjectHistory(item.root)
                        }
                        return .handled
                    }
                    guard let item = navigatorCursor, item.root != root || item.path == nil else { return .ignored }
                    selectRepository(item.root, item.path)
                    return .handled
                }
                .onChange(of: navigatorCursor) { _, item in
                    if let item { proxy.scrollTo(item) }
                }
                .onChange(of: fileSelection.activeID) { _, path in
                    guard let path else { return }
                    let item = ChangesNavigatorItem(root: root, path: path)
                    navigatorCursor = item
                    proxy.scrollTo(item)
                }
                .onChange(of: historySelection.commit?.id) { _, hash in
                    guard mode == .history, let hash else { return }
                    let item = ChangesNavigatorItem(root: root, path: hash)
                    navigatorCursor = item
                    proxy.scrollTo(item)
                }
            }
        }
        .background(Theme.card)
    }

    @ViewBuilder private func changesProject(_ repository: ChangesRepository) -> some View {
        let changes = repository.root == root ? files : gitStats.snapshot(at: repository.root)?.files ?? []
        let item = ChangesNavigatorItem(root: repository.root, path: nil)
        WorkspaceProjectRow(name: repository.name,
                            detail: repositoryStatus(repository),
                            selected: repository.root == root,
                            showsCursor: showsCursor(item),
                            hasChildren: !changes.isEmpty,
                            collapsed: collapsedRepositories.contains(repository.root)) {
            if !collapsedRepositories.insert(repository.root).inserted {
                collapsedRepositories.remove(repository.root)
            }
        } select: {
            navigatorCursor = item
            navigatorCursorVisible = false
            navigatorFocused = true
            selectRepository(repository.root, nil)
        }
        .id(item)
        // Each file is a row of the lazy stack itself, not part of one block per project,
        // so only the rows on screen are built.
        if !collapsedRepositories.contains(repository.root) {
            ForEach(changes) { file in
                Group {
                    if repository.root == root {
                        row(file)
                    } else {
                        otherProjectRow(file, in: repository.root)
                    }
                }
                .padding(.leading, 9)
                .overlay(alignment: .leading) {
                    // Runs into the gaps between rows so the rule down the side is unbroken.
                    Rectangle().fill(Theme.border).frame(width: 1).padding(.vertical, -1.5)
                }
                .padding(.leading, 21)
                .id(ChangesNavigatorItem(root: repository.root, path: file.id))
                .transition(.fold)
            }
        }
    }

    private func otherProjectRow(_ file: GitChange, in repositoryRoot: String) -> some View {
        let item = ChangesNavigatorItem(root: repositoryRoot, path: file.id)
        return Button {
            navigatorCursor = item
            navigatorCursorVisible = false
            navigatorFocused = true
            selectRepository(repositoryRoot, file.id)
        } label: {
            HStack {
                StatusChip(kind: file.kind)
                fileName(file)
                counts(file)
            }.padding(10)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(showsCursor(item) ? Theme.accent : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: - History navigator

    private var historyFilterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter commits by title or hash",
                      text: Binding(get: { historyFilter }, set: { historyFilter = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .accessibilityLabel("Filter commits by title or hash")
                .onMoveCommand { direction in
                    if direction == .up || direction == .down { moveNavigator(direction) }
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 2)
    }

    private func projectCommits(_ repositoryRoot: String) -> [GitCommitSummary]? {
        repositoryRoot == root ? commits : navigation?.commits[repositoryRoot]
    }

    private func shownCommits(_ repositoryRoot: String) -> [GitCommitSummary] {
        (projectCommits(repositoryRoot) ?? []).filter { $0.matches(historyFilter) }
    }

    private func historyDetail(_ repositoryRoot: String) -> String {
        if repositoryRoot == root, historyNote != nil { return "Unavailable" }
        guard let all = projectCommits(repositoryRoot) else { return "Loading" }
        if historyFilter.trimmingCharacters(in: .whitespaces).isEmpty { return counted(all.count, "commit") }
        return "\(shownCommits(repositoryRoot).count) of \(all.count)"
    }

    // Commits sit under their project the way files sit under it in the Explorer, so the
    // navigator is the one place that names the project and the one control that picks it.
    @ViewBuilder private func historyProject(_ repository: ChangesRepository) -> some View {
        let all = projectCommits(repository.root) ?? []
        let shown = shownCommits(repository.root)
        let item = ChangesNavigatorItem(root: repository.root, path: nil)
        let isCollapsed = collapsedHistories.contains(repository.root)
        WorkspaceProjectRow(name: repository.name,
                            detail: historyDetail(repository.root),
                            selected: repository.root == root,
                            showsCursor: showsCursor(item),
                            hasChildren: !all.isEmpty,
                            collapsed: isCollapsed) {
            if !collapsedHistories.insert(repository.root).inserted {
                collapsedHistories.remove(repository.root)
            }
        } select: {
            navigatorCursor = item
            navigatorCursorVisible = false
            navigatorFocused = true
            openProjectHistory(repository.root)
        }
        .id(item)
        if !all.isEmpty && !isCollapsed {
            VStack(alignment: .leading, spacing: 1) {
                if shown.isEmpty {
                    Text("No matching commits")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.leading, 36).padding(.vertical, 6)
                }
                ForEach(CommitDay.groups(shown)) { group in
                    Text(group.title)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .padding(.leading, 36).padding(.top, 8).padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.commits) { commit in
                        commitRow(commit, in: repository.root)
                    }
                }
            }
            .transition(.fold)
        }
    }

    private func commitRow(_ commit: GitCommitSummary, in repositoryRoot: String) -> some View {
        let item = ChangesNavigatorItem(root: repositoryRoot, path: commit.hash)
        let isSelected = repositoryRoot == root && historySelection.commit?.id == commit.id
        return Button {
            navigatorCursor = item
            navigatorCursorVisible = false
            navigatorFocused = true
            openCommit(commit, in: repositoryRoot)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? Theme.accent : Color.secondary.opacity(0.45))
                    .frame(width: 6, height: 6)
                Text(commit.subject)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(commit.date.map(RelativeTime.short) ?? commit.relativeDate)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.leading, 22).padding(.trailing, 8)
            .frame(height: 28)
            .background(isSelected ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Theme.accent.opacity(0.3) : .clear))
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3).padding(.vertical, 6)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6).stroke(showsCursor(item) ? Theme.accent : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 6)
        .id(item)
        .appTooltip(commit.subject)
        .accessibilityLabel("\(commit.subject), \(commit.relativeDate)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func openCommit(_ commit: GitCommitSummary, in repositoryRoot: String) {
        if repositoryRoot == root {
            historySelection.select(commit)
        } else {
            let selection = navigation?.histories[repositoryRoot] ?? CommitHistorySelection()
            selection.select(commit)
            navigation?.histories[repositoryRoot] = selection
            selectRepository(repositoryRoot, nil)
        }
        announce(commit.subject)
    }

    // Picking a project opens it on its newest commit, so the page is never left empty.
    private func openProjectHistory(_ repositoryRoot: String) {
        collapsedHistories.remove(repositoryRoot)
        if let newest = projectCommits(repositoryRoot)?.first {
            openCommit(newest, in: repositoryRoot)
        } else if repositoryRoot != root {
            selectRepository(repositoryRoot, nil)
        }
    }

    private func showsCursor(_ item: ChangesNavigatorItem) -> Bool {
        navigatorFocused && navigatorCursorVisible && navigatorCursor == item
    }

    private func fileName(_ file: GitChange) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(file.fileName).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text((file.path as NSString).deletingLastPathComponent)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            if let original = file.originalPath {
                Text("was \(original)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .appTooltip(file.path)
    }

    private var refreshButton: some View {
        Button {
            Task {
                await reload(fetchOrigin: true)
                feedback = snapshot?.state != .ready ? "Could not read Git status. Try Refresh again."
                    : refreshFailed ? "Remote refresh failed. Try Refresh again." : "Git status refreshed."
                announce(feedback)
            }
        } label: {
            Group {
                if loading || loadingHistory {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(.secondary)
            .padding(9)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .appTooltip("Refresh Git status")
        .accessibilityLabel("Refresh Git status")
    }

    private func branchMenu(_ snapshot: GitSnapshot) -> [MenuEntry] {
        guard !busy else { return [] }
        var entries: [MenuEntry] = [
            .item("Create new branch", icon: "plus") {
                showCreateBranchDialog(from: snapshot.branch)
            },
            .separator
        ]
        let local = snapshot.branches.map { branch in
            let current = snapshot.onBranch && branch == snapshot.branch
            return MenuItem(label: branch, checked: current, handler: {
                guard !current else { return }
                perform("Switching to \(branch)…", failure: "Could not switch branch") {
                    await GitActions.switchBranch(branch, at: repoRoot)
                }
            })
        }
        let remote = snapshot.remoteBranches.map { branch in
            // A remote branch that already has a local one of the same name opens that,
            // rather than making a second copy.
            let hasLocal = snapshot.branches.contains(branch.name)
            return MenuItem(label: branch.ref, handler: {
                perform("Switching to \(branch.name)…", failure: "Could not switch branch") {
                    if hasLocal {
                        return await GitActions.switchBranch(branch.name, at: repoRoot)
                    }
                    return await GitActions.checkoutRemoteBranch(branch, at: repoRoot)
                }
            })
        }
        if remote.isEmpty && local.count <= 6 {
            // A handful of branches read faster as plain rows than behind a field to type in.
            entries.append(contentsOf: local.map { MenuEntry.item($0) })
        } else {
            let groups = [
                MenuItemGroup(title: "Local", items: local),
                MenuItemGroup(title: "Remote", items: remote, startsExpanded: false)
            ]
            entries.append(.searchable(groups: groups.filter { !$0.items.isEmpty },
                                       prompt: "Filter branches by name",
                                       noResults: "No branch matches this filter."))
        }
        return entries
    }

    private func showCreateBranchDialog(from branch: String) {
        let draft = BranchDraft()
        dialogs.show(Dialog(
            title: "Create new branch",
            message: "Create it from \(branch) and switch to it.",
            content: AnyView(BranchNameEditor(draft: draft)),
            actions: [
                .init(label: "Create branch", kind: .primary, handler: {
                    createBranch(draft.name.trimmed)
                }, isEnabled: { !draft.name.isBlank }),
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    private func createBranch(_ branch: String) {
        perform("Creating \(branch)…", failure: "Could not create branch") {
            await GitActions.createBranch(branch, at: repoRoot)
        }
    }
    // MARK: - Commit

    private var commitBar: some View {
        let blocked = busy || commitMessage.isBlank || selectedFiles.isEmpty
        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("Commit message", text: $commitMessage)
                    .appTextField()
                    .focused($commitFocused)
                    .onSubmit { commit() }

                ActionButton(title: amend ? "Amend" : "Commit", height: 30, size: 12) { commit() }
                    .disabled(blocked)

                InlineLink(title: "Cancel", tint: Color.secondary) {
                    committing = false
                    if amend { amend = false }
                }
            }

            HStack(spacing: 16) {
                Toggle(isOn: Binding(
                    get: { excluded.isEmpty },
                    set: { on in excluded = on ? [] : Set(files.map(\.id)) }
                )) {
                    Text(excluded.isEmpty
                         ? "All \(counted(files.count, "file")) selected"
                         : "\(selectedFiles.count) of \(files.count) files selected")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.appCheckbox)

                if canAmend {
                    Toggle(isOn: $amend) {
                        Text("Amend last commit")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.appCheckbox)
                    .appTooltip("Fold these changes into the last commit instead of making a new one")
                }

                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .onAppear { commitFocused = true }
    }

    private func commit() {
        let message = commitMessage.trimmed
        let chosen = selectedFiles
        guard !message.isEmpty, !busy, !chosen.isEmpty else { return }
        let everything = excluded.isEmpty
        let fold = amend
        Task {
            working = fold ? "Amending…" : "Committing…"
            let error = everything
                ? await GitActions.commitAll(message: message, amend: fold, at: repoRoot)
                : await GitActions.commitSelected(message: message, files: chosen,
                                                  amend: fold, at: repoRoot)
            working = nil
            if let error {
                dialogs.show(.notice(fold ? "Could not amend" : "Could not commit", message: error))
            } else {
                // The message only clears once it is safely in a commit, so a failed
                // attempt can be fixed and retried without retyping it.
                messageBeforeAmend = ""
                amend = false
                commitMessage = ""
                excluded = []
                committing = false
            }
            await reload()
        }
    }

    // MARK: - Content

    @ViewBuilder private func content(narrowHistory: Bool) -> some View {
        switch snapshot?.state {
        case .ready:
            if mode == .history {
                historyContent(narrow: narrowHistory)
            } else if files.isEmpty {
                cleanContent
            } else {
                HStack(spacing: 0) {
                    if let file = selected {
                        diffPane(truncationHint: "Open the file to see the rest.",
                                 reveal: { reveal(file) }) {
                            fileName(file)
                            counts(file)
                            if fileSelection.ids.count > 1 {
                                Text("\(fileSelection.ids.count) files selected")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        PaneMessage(icon: "doc.text", title: "Select a file",
                                    detail: "Choose a changed file in the workspace navigator.")
                    }
                }
            }
        case .notARepo:
            PaneMessage(icon: "folder", title: "Not a git repository",
                        detail: "This folder is not tracked by git, so there is nothing to compare against.")
        case .missingFolder:
            PaneMessage(icon: "questionmark.folder", title: "Folder not found",
                        detail: root.abbreviatedPath)
        case .gitMissing:
            PaneMessage(icon: "exclamationmark.triangle", title: "git not found",
                        detail: "Install the command line developer tools or add git to your PATH.")
        case .failed(let reason):
            PaneMessage(icon: "exclamationmark.triangle", title: "Could not read this repository",
                        detail: reason, mono: true)
        case nil:
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ file: GitChange) -> some View {
        let isSelected = fileSelection.ids.contains(file.id)
        return Button {
            navigatorCursor = ChangesNavigatorItem(root: root, path: file.id)
            navigatorCursorVisible = false
            navigatorFocused = true
            mode = .changes
            select(file)
        } label: {
            HStack(spacing: 10) {
                // The pick only matters to a commit, so the box appears with the
                // commit bar and the list stays plain the rest of the time.
                if committing {
                    Toggle(isOn: Binding(
                        get: { !excluded.contains(file.id) },
                        set: { on in
                            if on { excluded.remove(file.id) } else { excluded.insert(file.id) }
                        }
                    )) { EmptyView() }
                    .toggleStyle(.appCheckbox)
                    .appTooltip("Include in the commit")
                }

                StatusChip(kind: file.kind)

                fileName(file)

                if file.isStaged && file.isUnstaged {
                    Text("partly staged").font(.system(size: 10)).foregroundStyle(.secondary)
                }

                counts(file)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .surface(isSelected ? Theme.accent.opacity(0.06) : .clear, cornerRadius: 8,
                     border: isSelected ? Theme.accent.opacity(0.25) : .clear)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(showsCursor(ChangesNavigatorItem(root: root, path: file.id)) ? Theme.accent : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 8)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .appContextMenu {
            let targets = fileSelection.contextMenuFiles(for: file, in: files)
            let multiple = targets.count > 1
            return [.item(multiple ? "Commit \(targets.count) Files…" : "Commit This File…") {
                beginCommit(with: targets)
             },
             .separator,
             .item("Reveal in Finder") { reveal(file) },
             .item("Copy Path") { Pasteboard.copy(fileURL(file).path) },
             .separator,
             .item(multiple ? "Discard Changes in \(targets.count) Files…" : "Discard Changes",
                   kind: .destructive) { confirmDiscard(targets) }]
        }
    }

    private func beginCommit(with chosen: [GitChange]? = nil) {
        if let chosen {
            excluded = Set(files.map(\.id)).subtracting(chosen.map(\.id))
        }
        committing = true
        commitFocused = true
    }

    @ViewBuilder private func counts(_ file: GitChange) -> some View {
        if file.isBinary {
            Text("binary").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                Text(file.added.map { "+\($0)" } ?? "")
                    .foregroundStyle(Theme.addition)
                Text(file.removed.map { "-\($0)" } ?? "")
                    .foregroundStyle(Theme.deletion)
            }
            .font(.mono(11, .medium))
        }
    }

    // MARK: - Diff

    // History and file reviews share the same diff surface.
    private func diffPane<Title: View>(truncationHint: String, reveal: (() -> Void)? = nil,
                                       @ViewBuilder title: () -> Title) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                title()
                Spacer()
                if loadingDiff { ProgressView().controlSize(.small) }
                if mode == .changes, let file = selected {
                    Image(systemName: "ellipsis").padding(8).contentShape(Rectangle())
                        .appMenu {
                            var entries: [MenuEntry] = []
                            if !file.isBinary && diff?.images == nil {
                                entries = ["Unified diff", "Side by side"].map { layout in
                                    .item(layout, checked: appSettings.changesDiffLayout == layout) {
                                        appSettings.changesDiffLayout = layout
                                    }
                                }
                                entries += [.separator, .item("Copy diff") { copy(.patch, file: file) }]
                            }
                            if let reveal { entries.append(.item("Reveal in Finder", action: reveal)) }
                            return entries
                        }
                        .accessibilityLabel("Diff options")
                } else if let reveal {
                    InlineLink(title: "Reveal in Finder", action: reveal)
                }
                Button {
                    closeDiff()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .hoverLift(amount: Motion.smallLift)
                .accessibilityLabel("Close diff")
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            if mode == .changes, let file = selected, !file.isBinary, diff?.images == nil {
                if appSettings.changesDiffLayout == "Side by side" {
                    HStack {
                        versionHeader("Last commit", version: .before, file: file)
                        versionHeader("Working tree", version: .after, file: file)
                    }.padding(.horizontal, 20).padding(.vertical, 8)
                }
            }
            diffBody(truncationHint: truncationHint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card)
    }

    // The rendered diff below a pane header, so a file and a commit truncate and report
    // notes the same way.
    @ViewBuilder private func diffBody(truncationHint: String) -> some View {
        if let images = diff?.images {
            ImageDiffView(images: images)
        } else if let note = diff?.note {
            Text(note)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if mode == .changes, diff?.lines.isEmpty == true, !loadingDiff {
            PaneMessage(icon: "doc", title: "No content changes",
                        detail: "This file may have metadata changes or changes confined to the index.")
        } else if mode == .changes, appSettings.changesDiffLayout == "Side by side", let diff {
            SideBySideDiff(lines: diff.lines, expand: expand)
        } else if let diffText {
            DiffTextView(text: diffText, scroll: diffScroll) { gap, direction in
                expand(gap, direction)
            }
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        if let diff, diff.truncated {
            Text("Showing the first \(diff.lines.count - diff.revealed) lines of \(diff.totalLines). \(truncationHint)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.field)
        }
    }

    // MARK: - History

    @ViewBuilder private func historyContent(narrow: Bool) -> some View {
        if narrow && !historySelection.showingDetail {
            workspaceNavigator
        } else if let historyNote {
            PaneMessage(icon: "exclamationmark.triangle", title: "Could not read the history",
                        detail: historyNote, mono: true)
        } else if let commits {
            if commits.isEmpty {
                PaneMessage(icon: "clock", title: "No commits yet",
                            detail: "This branch has no history to show.")
            } else {
                CommitHistoryView(root: repoRoot, selection: historySelection,
                                  back: narrow ? { historySelection.showingDetail = false } : nil)
            }
        } else {
            ProgressView("Loading history…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    // The count on the button is only as fresh as the last fetch, so the press never
    // decides for itself that there is nothing to pull: GitActions.pull reads origin first
    // and works out what to do from that.
    private func pull() {
        guard !busy else { return }
        Task {
            working = "Pulling…"
            let outcome = await GitActions.pull(at: repoRoot)
            working = nil
            report(outcome)
            await reload()
        }
    }

    private func report(_ outcome: GitPullOutcome) {
        switch outcome {
        case .upToDate:
            dialogs.show(.notice("Already up to date",
                                 message: "There were no new commits to pull from origin."))
        case .updated(let commits):
            dialogs.show(pullResultDialog(commits: commits, hasStashConflict: false))
        case .updatedWithStashConflict(let commits):
            dialogs.show(pullResultDialog(commits: commits, hasStashConflict: true))
        case .failed(let error):
            dialogs.show(.notice("Could not pull", message: error))
        }
    }

    private func pullResultDialog(commits: [GitRemoteCommit], hasStashConflict: Bool) -> Dialog {
        let pulled = "Pulled \(counted(commits.count, "commit"))"
        return Dialog(
            title: hasStashConflict ? "\(pulled), with conflicts" : pulled,
            message: hasStashConflict
                ? "Origin's commits are in, but your uncommitted changes could not go back on "
                    + "top of them cleanly. The files hold both versions between conflict markers, "
                    + "and the originals remain in the stash."
                : "These commits were pulled from origin.",
            content: AnyView(remoteCommitList(commits,
                                              emptyMessage: "There were no commits to show.")),
            actions: [.init(label: "OK", kind: .cancel)],
            width: 520)
    }

    // Discarding is the one action here that destroys work rather than moving it around,
    // and nothing on this screen can undo it, so it always asks first and says in plain
    // words what the files will be left as.
    private func confirmDiscard(_ files: [GitChange]) {
        guard !busy, let file = files.first else { return }
        let root = repoRoot
        let untrackedCount = files.count(where: \.isUntracked)
        let allUntracked = untrackedCount == files.count
        let multiple = files.count > 1
        let message: String
        if !multiple {
            message = file.isUntracked
                ? "\(file.path) is not in git yet, so there is no committed version to go back "
                    + "to. It will be moved to the Trash."
                : "\(file.path) goes back to the way the last commit has it. The changes in it "
                    + "are lost."
        } else if allUntracked {
            message = "These files are not in git yet. They will be moved to the Trash."
        } else {
            message = "Tracked files go back to the way the last commit has them. "
                + "Their uncommitted changes are lost."
                + (untrackedCount > 0 ? " Untracked files will be moved to the Trash." : "")
        }
        dialogs.show(Dialog(
            title: multiple ? "Discard changes in \(files.count) files?"
                : (allUntracked ? "Delete this file?" : "Discard changes?"),
            message: message,
            content: multiple ? AnyView(
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(files) { file in
                            Text(file.path)
                                .font(.mono(11))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 160)
            ) : nil,
            actions: [
                .init(label: allUntracked ? "Move to Trash" : "Discard", kind: .destructive) {
                    perform("Discarding…", failure: "Could not discard changes") {
                        await GitActions.discard(files, at: root)
                    }
                },
                .init(label: "Cancel", kind: .cancel)
            ],
            width: 420))
    }

    private func confirmPush(_ snapshot: GitSnapshot) {
        guard !busy else { return }
        working = "Checking commits…"
        let root = snapshot.root
        let upstream = snapshot.upstream
        let hasUpstream = upstream != nil
        Task {
            let preview = await GitActions.commitsToPush(hasUpstream: hasUpstream, at: root)
            working = nil
            switch preview {
            case .commits(let commits):
                dialogs.show(pushDialog(commits: commits, upstream: upstream,
                                        hasUpstream: hasUpstream, root: root))
            case .behindUpstream(let behind, let commits):
                dialogs.show(behindDialog(behind: behind, commits: commits, upstream: upstream,
                                          hasUpstream: hasUpstream, root: root))
            case .failed(let error):
                dialogs.show(.notice("Could not check commits to push", message: error))
            }
        }
    }

    private func pushDialog(commits: [GitRemoteCommit], upstream: String?,
                            hasUpstream: Bool, root: String) -> Dialog {
        let count = commits.count
        let title = count == 0
            ? (hasUpstream ? "Push branch?" : "Publish branch?")
            : "Push \(counted(count, "commit"))?"
        let message = upstream.map {
            count == 0
                ? "No commits are ahead of \($0)."
                : "These commits will be pushed to \($0)."
        } ?? "This branch will be published to origin and start tracking it."
        return Dialog(
            title: title,
            message: message,
            content: AnyView(remoteCommitList(
                commits, emptyMessage: "There are no new commits to send.")),
            actions: [
                .init(label: count == 0 ? (hasUpstream ? "Push" : "Publish branch") : "Push commits",
                      kind: .primary) {
                    perform("Pushing…", failure: "Could not push") {
                        await GitActions.push(hasUpstream: hasUpstream, at: root)
                    }
                },
                .init(label: "Cancel", kind: .cancel) { pushFocused = true }
            ],
            onCancel: { pushFocused = true }, width: 520, isModal: true)
    }

    // Origin refuses a push from a branch that trails it, so the screen says so instead of
    // sending one to be rejected, and offers the pull that makes it possible in one press.
    private func behindDialog(behind: Int, commits: [GitRemoteCommit], upstream: String?,
                              hasUpstream: Bool, root: String) -> Dialog {
        let target = upstream ?? "origin"
        let mine = commits.count == 1 ? "your commit" : "your \(commits.count) commits"
        return Dialog(
            title: "Pull before pushing",
            message: "\(target) has \(counted(behind, "commit")) this branch does "
                + "not, so origin would refuse the push. Pulling first puts \(mine) on top.",
            content: AnyView(remoteCommitList(
                commits, emptyMessage: "There are no new commits to send.")),
            actions: [
                .init(label: "Pull, then push", kind: .primary) {
                    pullThenPush(hasUpstream: hasUpstream, root: root)
                },
                .init(label: "Cancel", kind: .cancel) { pushFocused = true }
            ],
            onCancel: { pushFocused = true }, width: 520, isModal: true)
    }

    // Only a pull that fails stops the push: a stash that came back badly leaves conflict
    // markers in uncommitted files, which is worth saying but has no bearing on what the
    // push sends. Either way that news waits until after, so one dialog cannot bury another.
    private func pullThenPush(hasUpstream: Bool, root: String) {
        guard !busy else { return }
        Task {
            working = "Pulling…"
            let outcome = await GitActions.pull(at: root)
            if case .failed(let error) = outcome {
                working = nil
                dialogs.show(.notice("Could not pull", message: error))
                await reload()
                return
            }
            working = "Pushing…"
            let error = await GitActions.push(hasUpstream: hasUpstream, at: root)
            working = nil
            if let error {
                dialogs.show(.notice("Could not push", message: error))
            } else {
                report(outcome)
            }
            await reload()
        }
    }

    @ViewBuilder private func remoteCommitList(_ commits: [GitRemoteCommit],
                                               emptyMessage: String) -> some View {
        if commits.isEmpty {
            Text(emptyMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("COMMITS")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(commits) { commit in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(commit.shortID)
                                    .font(.mono(11, .medium))
                                    .foregroundStyle(.secondary)
                                Text(commit.subject)
                                    .font(.system(size: 12))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
        }
    }

    // Every git action ends in a reload, success or not: a failed pull can still have
    // moved the tree, and the header has to show whatever is true now.
    private func perform(_ progress: String, failure: String,
                         _ action: @escaping () async -> String?) {
        guard !busy else { return }
        Task {
            working = progress
            let error = await action()
            working = nil
            if let error { dialogs.show(.notice(failure, message: error)) }
            await reload()
        }
    }

    private func reload(fetchOrigin: Bool = false) async {
        loading = true
        if fetchOrigin { refreshFailed = false }
        if fetchOrigin, snapshot?.state == .ready,
           let error = await GitActions.fetchOrigin(at: repoRoot) {
            guard !Task.isCancelled else { return }
            refreshFailed = true
            dialogs.show(.notice("Could not refresh origin", message: error))
        }
        let fresh = await GitInspector.snapshot(at: root, lane: .interactive, comparingToLastCommit: true)
        guard !Task.isCancelled else { return }
        snapshot = fresh
        checkedAt = Date()
        // The session header shows the same tree, so a commit or pull made here
        // updates its numbers too rather than waiting for the next run to end.
        gitStats.store(fresh, at: root)
        loading = false
        if fresh.files.isEmpty && fresh.hasCommits {
            latestCommit = await GitInspector.recentCommits(at: fresh.root, limit: 1).commits.first
        }
        excluded.formIntersection(Set(fresh.files.map(\.id)))
        // A push can land between refreshes, and amending a pushed commit is exactly
        // what the checkbox exists to prevent.
        if amend && !canAmend { amend = false }

        if mode == .history {
            await loadHistory()
            return
        }

        // Keep the open file open across a refresh, but only if it still has changes.
        let orderedIDs = fresh.files.map(\.id)
        fileSelection.retain(Set(orderedIDs), in: orderedIDs)
        if !appliedInitialSelection {
            appliedInitialSelection = true
            if let initial = (requestedPath ?? initiallySelectedPath).flatMap({ path in fresh.files.first { $0.id == path } }) ?? fresh.files.first {
                fileSelection.select(initial.id, in: orderedIDs,
                                     extendingRange: false, toggling: false)
            }
        }
        if let selectedID = fileSelection.activeID,
           let file = fresh.files.first(where: { $0.id == selectedID }) {
            await loadDiff(file, root: fresh.root)
        } else {
            closeDiff()
        }
    }

    private func switchedMode() {
        clearDiffContent()
        if mode == .history {
            Task {
                await loadHistory()
                if openLatestCommit, let commit = commits?.first { historySelection.select(commit) }
                openLatestCommit = false
                await refreshOtherProjects()
            }
        } else if let selected {
            Task { await loadDiff(selected, root: repoRoot) }
        }
    }

    // The other projects in the navigator are drawn from what was last read of them.
    // Reading them again on the background lane, after this project, keeps them current
    // without holding up the one on screen.
    private func refreshOtherProjects() async {
        for repository in repositories where repository.root != root {
            if mode == .history {
                let history = await GitInspector.recentCommits(at: repository.root)
                guard !Task.isCancelled else { return }
                navigation?.commits[repository.root] = history.commits
            } else {
                let fresh = await GitInspector.snapshot(at: repository.root, comparingToLastCommit: true)
                guard !Task.isCancelled else { return }
                gitStats.store(fresh, at: repository.root)
            }
        }
    }

    // Every visit reads the log again: a commit, pull or amend made in the other mode
    // rewrites exactly what this list shows.
    private func loadHistory() async {
        loadingHistory = true
        let history = await GitInspector.recentCommits(at: repoRoot)
        guard !Task.isCancelled else { return }
        commits = history.commits
        historyNote = history.note
        navigation?.commits[root] = history.commits
        loadingHistory = false

        if let current = historySelection.commit,
           history.commits.contains(where: { $0.id == current.id }) { return }
        if let first = history.commits.first { historySelection.select(first) }
        else { historySelection.commit = nil }
    }

    private func select(_ file: GitChange) {
        let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        let previousActiveID = fileSelection.activeID
        fileSelection.select(file.id,
                             in: files.map(\.id),
                             extendingRange: flags.contains(.shift),
                             toggling: flags.contains(.command))
        guard fileSelection.activeID != previousActiveID else { return }
        clearDiffContent()
        guard let selectedID = fileSelection.activeID,
              let selected = files.first(where: { $0.id == selectedID }) else { return }
        let root = snapshot?.root ?? root
        Task { await loadDiff(selected, root: root) }
    }

    // Built again from the lines already in hand rather than by asking git a second time:
    // nothing about the change has moved, only the size it is drawn at.
    private func reopenDiff() {
        diffScroll = .top
        Task { await renderDiff() }
    }

    // A commit diff spans many files and takes its languages from its own section
    // headings, so only a single file's diff has a language to name here.
    private func renderDiff() async {
        guard let diff, !diff.lines.isEmpty else { return }
        let lines = diff.lines
        let text = await DiffText.build(
            lines,
            language: (mode == .changes ? selected : nil).flatMap {
                CodeLanguage(fileExtension: ($0.path as NSString).pathExtension)
            },
            scale: appSettings.textSize.scale, numbered: mode == .changes)
        // Another file, or more of this one, can have opened while the text was built.
        guard self.diff?.lines == lines else { return }
        diffText = text
    }

    // A grey gap row stands for the unchanged lines the diff skipped. Pressing one of its
    // controls reads that end of the gap back and drops the lines in beside the row, so a
    // change can be read with the code around it without leaving the pane.
    private func expand(_ key: String, _ direction: DiffExpandDirection) {
        // Pressing again before the first read lands would show the same lines twice.
        guard !expanding.contains(key),
              let gap = diff?.lines.first(where: { $0.gap?.key == key })?.gap else { return }
        expanding.insert(key)
        Task {
            let expansion = await GitInspector.expand(gap, direction, root: repoRoot)
            expanding.remove(key)
            // The diff can have been reloaded or closed while git was reading the file.
            guard var opened = diff,
                  let at = opened.lines.firstIndex(where: { $0.gap?.key == key }) else { return }
            if let left = expansion.gap {
                // The row holds whatever is still hidden, so it keeps sitting between the
                // lines opened from one end and the ones opened from the other.
                opened.lines[at].gap = left
                opened.lines.insert(contentsOf: expansion.lines, at: direction == .up ? at + 1 : at)
                opened.revealed += expansion.lines.count
            } else {
                opened.lines.replaceSubrange(at...at, with: expansion.lines)
                opened.revealed += expansion.lines.count - 1
            }
            for i in opened.lines.indices { opened.lines[i].id = i }
            diff = opened
            // Only reading down puts lines above the row that was pressed.
            diffScroll = direction == .down ? .follow : .hold
            await renderDiff()
        }
    }

    private func closeDiff() {
        if mode == .changes { fileSelection.clear() }
        clearDiffContent()
    }

    private func clearDiffContent() {
        diff = nil
        diffText = nil
        loadingDiff = false
        diffScroll = .top
    }

    private func loadDiff(_ file: GitChange, root: String) async {
        loadingDiff = true
        let loaded = await GitInspector.reviewDiff(for: file, root: root)
        guard !Task.isCancelled, mode == .changes, fileSelection.activeID == file.id else { return }
        let text = loaded.lines.isEmpty ? nil : await DiffText.build(
            loaded.lines,
            language: CodeLanguage(fileExtension: (file.path as NSString).pathExtension),
            scale: appSettings.textSize.scale, numbered: true)
        guard !Task.isCancelled, mode == .changes, fileSelection.activeID == file.id else { return }
        diffScroll = .top
        diff = loaded
        diffText = text
        loadingDiff = false
    }

    private func fileURL(_ file: GitChange) -> URL {
        URL(fileURLWithPath: snapshot?.root ?? root).appendingPathComponent(file.path)
    }

    private func reveal(_ file: GitChange) {
        let url = fileURL(file)
        // A deleted file cannot be selected, so fall back to opening its folder.
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }
}

// A changed picture side by side with its last committed version. A file with only one
// side, new or deleted, gets that side on its own.
private struct ImageDiffView: View {
    let before: Data?
    let after: Data?

    init(images: DiffImages) {
        before = images.before
        after = images.after
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let before {
                side(before, title: before == after ? "UNCHANGED" : "BEFORE")
            }
            if let after, after != before {
                side(after, title: before == nil ? "NEW" : "AFTER")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func side(_ data: Data, title: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.mono(11, .medium))
                .foregroundStyle(.secondary)
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("\(Int(image.size.width)) × \(Int(image.size.height)) · \(data.count.formatted(.byteCount(style: .file)))")
                    .font(.mono(11))
                    .foregroundStyle(.secondary)
            } else {
                PaneMessage(icon: "photo", title: "Cannot draw this image",
                            detail: data.count.formatted(.byteCount(style: .file)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
@Observable
private final class BranchDraft {
    var name = ""
}

private struct BranchNameEditor: View {
    @Bindable var draft: BranchDraft
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Branch name", text: $draft.name)
            .appTextField()
            .focused($focused)
            .task { focused = true }
    }
}

private struct StatusChip: View {
    let kind: GitStatusKind

    private var color: Color {
        switch kind {
        case .modified: Theme.secret
        case .added, .untracked: Theme.dotOn
        case .deleted, .conflicted: Theme.deletion
        case .renamed: Theme.accent
        }
    }

    var body: some View {
        Text(kind.letter)
            .font(.mono(11, .bold))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.16)))
            .appTooltip(kind.label)
    }
}
