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
}

struct ChangesRepository: Identifiable {
    let root: String
    let name: String
    var id: String { root }

    static func statusLabel(for snapshot: GitSnapshot?) -> String {
        guard let snapshot else { return "Checking" }
        guard snapshot.state == .ready else { return "Unavailable" }
        return snapshot.files.isEmpty ? "Clean" : "\(snapshot.files.count)"
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
    @State private var navigatorVisible = true
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
    @State private var mode: Mode = .changes
    @State private var committing = false
    @State private var commitMessage = ""
    @FocusState private var commitFocused: Bool
    @FocusState private var listFocused: Bool
    // Files the next commit leaves out. Tracking the exclusions rather than the picks
    // means a file that appears between refreshes starts selected, like everything else.
    @State private var excluded: Set<GitChange.ID> = []
    @State private var amend = false
    @State private var messageBeforeAmend = ""
    @State private var fileSelection = ChangeFileSelection()
    @State private var commits: [GitCommitSummary]?
    @State private var historyNote: String?
    @State private var loadingHistory = false
    @State private var selectedCommit: GitCommitSummary?
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

    var body: some View {
        VStack(spacing: 0) {
            if navigation == nil {
                header()
                if committing && mode == .changes { commitBar }
            }
            GeometryReader { geometry in
                let width = navigation == nil ? 280
                    : ExplorerSplitLayout.treeWidth(treeWidth, availableWidth: geometry.size.width)
                HStack(spacing: 0) {
                    if navigatorVisible && (navigation != nil || geometry.size.width >= 650 || committing) {
                        VStack(spacing: 0) {
                            if navigation != nil {
                                HStack {
                                    Text("Workspace").font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text(counted(repositories.count, "project"))
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 20)
                                .headerBand(height: Theme.headerHeight)
                            }
                            workspaceNavigator
                        }.frame(width: width).clipped()
                        Rectangle().fill(Theme.hairline).frame(width: ExplorerSplitLayout.dividerWidth)
                    }
                    VStack(spacing: 0) {
                        if navigation != nil {
                            header(compact: geometry.size.width - (navigatorVisible ? width : 0) < 500)
                            if committing && mode == .changes { commitBar }
                        }
                        content
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
        .onChange(of: fileSelection) { _, selection in navigation?.selections[root] = selection }
        // The screen opens on the last snapshot taken of this tree while a fresh one
        // is fetched, so the file list is there at first glance instead of after git.
        .task(id: root) {
            if snapshot == nil { snapshot = gitStats.snapshot(at: root) }
            await reload()
        }
        .onChange(of: requestedPath) { _, path in
            guard let file = files.first(where: { $0.id == path }) else { return }
            mode = .changes
            select(file)
        }
        .onChange(of: mode) { _, _ in switchedMode() }
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

    private func header(compact: Bool = false) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            Image(systemName: "sidebar.left")
                .padding(7).contentShape(Rectangle())
                .appMenu { navigatorMenu }
                .accessibilityLabel("Workspace navigator")
            if navigation != nil {
                HStack(spacing: 7) {
                    ProjectDot(tint: Theme.projectTint(for: repositoryName), size: 8)
                    Text(repositoryName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }.appTooltip(repositoryName)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(repositories.count > 1 ? "Workspace changes" : "Project changes")
                        .font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 7) {
                        ProjectDot(tint: Theme.projectTint(for: repositoryName), size: 8)
                        Text(repositoryName)
                            .font(.system(size: 11)).foregroundStyle(Theme.accent).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            if let snapshot, snapshot.state == .ready {
                if !compact {
                    Text(snapshot.branch).font(.mono(11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 140)
                        .accessibilityHint(syncStatus)
                }
                InlineLink(title: mode == .history ? "Back to changes" : "History") {
                    mode = mode == .history ? .changes : .history
                }
                Image(systemName: "ellipsis").padding(8).contentShape(Rectangle())
                    .appMenu { repositoryMenu(snapshot) }
                    .accessibilityLabel("Repository actions for \(repositories.first { $0.root == root }?.name ?? root)")
                    .disabled(busy)
                if !files.isEmpty && mode == .changes {
                    ActionButton(title: compact ? "Commit" : "Commit…", height: 30, size: 12) {
                        if committing { committing = false } else { beginCommit() }
                    }.disabled(busy)
                }
            }
        }
        .padding(.horizontal, compact ? 12 : 20)
        .padding(.vertical, navigation == nil ? 12 : 0)
        .frame(height: navigation == nil ? nil : Theme.headerHeight)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func repositoryMenu(_ snapshot: GitSnapshot) -> [MenuEntry] {
        var entries = snapshot.remoteActions.map { action -> MenuEntry in
            switch action {
            case .pull(let count):
                return .item("Pull \(counted(count, "commit"))", icon: "arrow.down") { pull() }
            case .push(let count):
                return .item("Push \(counted(count, "commit"))", icon: "arrow.up") { confirmPush(snapshot) }
            case .publish:
                return .item("Publish branch", icon: "arrow.up") { confirmPush(snapshot) }
            }
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

    private var navigatorMenu: [MenuEntry] {
        [.item(navigatorVisible ? "Hide navigator" : "Show navigator") { navigatorVisible.toggle() }, .separator]
        + repositories.flatMap { repository -> [MenuEntry] in
            let changes = repository.root == root ? files : gitStats.snapshot(at: repository.root)?.files ?? []
            return [.item(repository.name, checked: repository.root == root) {
                selectRepository(repository.root, nil)
            }] + changes.map { file in
                .item(file.fileName, subtitle: file.path) {
                    if repository.root == root { mode = .changes; select(file) }
                    else { selectRepository(repository.root, file.id) }
                }
            }
        }
    }

    private var navigatorItems: [ChangesNavigatorItem] {
        repositories.flatMap { repository in
            let changes = repository.root == root ? files : gitStats.snapshot(at: repository.root)?.files ?? []
            return [ChangesNavigatorItem(root: repository.root, path: nil)]
                + (collapsedRepositories.contains(repository.root) ? [] : changes.map {
                    ChangesNavigatorItem(root: repository.root, path: $0.id)
                })
        }
    }

    private func moveNavigator(_ direction: MoveCommandDirection) {
        if let item = navigatorCursor, item.path == nil {
            if direction == .left { collapsedRepositories.insert(item.root); return }
            if direction == .right { collapsedRepositories.remove(item.root); return }
        }
        guard direction == .up || direction == .down,
              let next = ChangesNavigatorItem.next(after: navigatorCursor,
                  step: direction == .up ? -1 : 1, in: navigatorItems) else { return }
        navigatorCursor = next
        if next.root == root, let file = files.first(where: { $0.id == next.path }) {
            mode = .changes
            select(file)
        }
    }

    private var workspaceNavigator: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(repositories) { repository in
                        let changes = repository.root == root ? files : gitStats.snapshot(at: repository.root)?.files ?? []
                        HStack(spacing: 6) {
                            if !changes.isEmpty {
                                Button {
                                    if !collapsedRepositories.insert(repository.root).inserted {
                                        collapsedRepositories.remove(repository.root)
                                    }
                                } label: {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10))
                                        .rotationEffect(.degrees(collapsedRepositories.contains(repository.root) ? 0 : 90))
                                        .frame(width: 20, height: 30).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .motion(Motion.control, value: collapsedRepositories.contains(repository.root))
                                    .accessibilityLabel("\(collapsedRepositories.contains(repository.root) ? "Expand" : "Collapse") \(repository.name)")
                                    .accessibilityValue(collapsedRepositories.contains(repository.root) ? "Collapsed" : "Expanded")
                            } else {
                                Color.clear.frame(width: 20, height: 30).accessibilityHidden(true)
                            }
                            Button {
                                navigatorCursor = ChangesNavigatorItem(root: repository.root, path: nil)
                                navigatorFocused = true
                                selectRepository(repository.root, nil)
                            } label: {
                                HStack(spacing: 7) {
                                    ProjectDot(tint: Theme.projectTint(for: repository.name), size: 8)
                                    Text(repository.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(repositoryStatus(repository))
                                        .font(.system(size: 10))
                                        .fixedSize()
                                }.foregroundStyle(repository.root == root ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                                .padding(.vertical, 10).padding(.trailing, 8)
                                .surface(.clear, cornerRadius: 8,
                                         border: showsCursor(ChangesNavigatorItem(root: repository.root, path: nil)) ? Theme.accent : .clear)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .id(ChangesNavigatorItem(root: repository.root, path: nil))
                                .accessibilityAddTraits(repository.root == root ? .isSelected : [])
                                .appTooltip(repository.name)
                        }
                        .background(repository.root == root ? Theme.accent.opacity(0.1) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .overlay(alignment: .leading) {
                            if repository.root == root {
                                RoundedRectangle(cornerRadius: 2).fill(Theme.accent)
                                    .frame(width: 3).padding(.vertical, 10)
                            }
                        }
                        if !changes.isEmpty && !collapsedRepositories.contains(repository.root) {
                            VStack(spacing: 3) {
                                ForEach(changes) { file in
                                    if repository.root == root {
                                        row(file)
                                            .id(ChangesNavigatorItem(root: root, path: file.id))
                                    } else {
                                        let item = ChangesNavigatorItem(root: repository.root, path: file.id)
                                        Button {
                                            navigatorCursor = item
                                            navigatorFocused = true
                                            selectRepository(repository.root, file.id)
                                        } label: {
                                            HStack {
                                                StatusChip(kind: file.kind)
                                                fileName(file)
                                                counts(file)
                                            }.padding(10)
                                            .surface(.clear, cornerRadius: 8, border: showsCursor(item) ? Theme.accent : .clear)
                                            .contentShape(Rectangle())
                                        }.buttonStyle(.plain)
                                            .id(item)
                                    }
                                }
                            }
                            .padding(.leading, 9)
                            .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
                            .padding(.leading, 21)
                            .transition(.fold)
                        }
                    }
                }.padding(10)
                .smoothlyResizes(when: collapsedRepositories)
            }
            .background(Theme.card)
            .accessibilityLabel("Workspace repositories and changed files")
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
        }
    }

    private func showsCursor(_ item: ChangesNavigatorItem) -> Bool {
        navigatorFocused && navigatorCursor == item
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

    @ViewBuilder private var content: some View {
        switch snapshot?.state {
        case .ready:
            if mode == .history {
                historyContent
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

    // File and history lists share selection and keyboard behavior.
    private func list<Item: Identifiable, Row: View>(
        _ items: [Item], isOpen: Bool, activeID: Item.ID?,
        @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { item in
                        row(item).id(item.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: activeID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(maxHeight: isOpen ? 260 : .infinity)
        .contentShape(Rectangle())
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onMoveCommand(perform: moveSelection)
        .task { listFocused = true }
    }

    private func row(_ file: GitChange) -> some View {
        let isSelected = fileSelection.ids.contains(file.id)
        return Button {
            navigatorCursor = ChangesNavigatorItem(root: root, path: file.id)
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
        navigatorVisible = true
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

    @ViewBuilder private var historyContent: some View {
        if let historyNote {
            PaneMessage(icon: "exclamationmark.triangle", title: "Could not read the history",
                        detail: historyNote, mono: true)
        } else if let commits {
            if commits.isEmpty {
                PaneMessage(icon: "clock", title: "No commits yet",
                            detail: "This branch has no history to show.")
            } else {
                list(commits, isOpen: selectedCommit != nil,
                     activeID: selectedCommit?.id, row: commitRow)
                if let commit = selectedCommit {
                    Divider().overlay(Theme.hairline)
                    diffPane(truncationHint: "Run git show in a terminal to see the rest.") {
                        Text(commit.subject).font(.serif(15, .semibold)).lineLimit(1)
                        Text(commit.shortHash)
                            .font(.mono(11, .medium))
                            .foregroundStyle(.secondary)
                        Text("\(commit.author), \(commit.relativeDate)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func commitRow(_ commit: GitCommitSummary) -> some View {
        let isSelected = commit.id == selectedCommit?.id
        return Button {
            listFocused = true
            select(commit)
        } label: {
            HStack(spacing: 10) {
                Text(commit.shortHash)
                    .font(.mono(11, .medium))
                    .foregroundStyle(.secondary)
                Text(commit.subject)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(commit.author)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(commit.relativeDate)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .surface(isSelected ? Theme.card : .clear, cornerRadius: 8,
                     border: isSelected ? Theme.border : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 8)
        .appContextMenu {
            [.item("Copy Hash") { Pasteboard.copy(commit.hash) }]
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
        let root = snapshot.root
        let upstream = snapshot.upstream
        let hasUpstream = upstream != nil
        Task {
            working = "Checking commits…"
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
                .init(label: "Cancel", kind: .cancel)
            ],
            width: 520)
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
                .init(label: "Cancel", kind: .cancel)
            ],
            width: 520)
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
        selectedCommit = nil
        if mode == .history {
            Task {
                await loadHistory()
                if openLatestCommit, let commit = commits?.first { select(commit) }
                openLatestCommit = false
            }
        } else if let selected {
            Task { await loadDiff(selected, root: repoRoot) }
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
        loadingHistory = false

        // Keep the open commit open across a refresh, but only while it is still in
        // the list; an amend or rebase can have rewritten it away.
        if let current = selectedCommit {
            if history.commits.contains(where: { $0.id == current.id }) {
                await loadCommitDiff(current)
            } else {
                closeDiff()
            }
        }
    }

    // The arrow keys walk the list the way a click would, so a review can go through the
    // files one at a time without reaching for the mouse. While nothing is open, the first
    // press opens the end of the list the key points away from.
    private func moveSelection(_ direction: MoveCommandDirection) {
        guard dialogs.current == nil else { return }
        let step: Int
        switch direction {
        case .up: step = -1
        case .down: step = 1
        default: return
        }

        if mode == .history {
            guard let commits,
                  let next = RowStep.destination(from: commits.firstIndex { $0.id == selectedCommit?.id },
                                                 step: step, count: commits.count)
            else { return }
            select(commits[next])
        } else {
            guard let next = RowStep.destination(from: files.firstIndex { $0.id == fileSelection.activeID },
                                                 step: step, count: files.count)
            else { return }
            select(files[next])
        }
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

    private func select(_ commit: GitCommitSummary) {
        guard selectedCommit?.id != commit.id else {
            closeDiff()
            return
        }
        closeDiff()
        selectedCommit = commit
        Task { await loadCommitDiff(commit) }
    }

    private func loadCommitDiff(_ commit: GitCommitSummary) async {
        loadingDiff = true
        let loaded = await GitInspector.commitDiff(commit.hash, root: repoRoot)
        guard !Task.isCancelled, mode == .history, selectedCommit?.id == commit.id else { return }
        diffScroll = .top
        diff = loaded
        diffText = loaded.lines.isEmpty
            ? nil
            : DiffText.attributed(loaded.lines, scale: appSettings.textSize.scale, numbered: mode == .changes)
        loadingDiff = false
    }

    // Built again from the lines already in hand rather than by asking git a second time:
    // nothing about the change has moved, only the size it is drawn at.
    private func reopenDiff() {
        diffScroll = .top
        renderDiff()
    }

    // A commit diff spans many files and takes its languages from its own section
    // headings, so only a single file's diff has a language to name here.
    private func renderDiff() {
        guard let diff, !diff.lines.isEmpty else { return }
        diffText = DiffText.attributed(
            diff.lines,
            language: (mode == .changes ? selected : nil).flatMap {
                CodeLanguage(fileExtension: ($0.path as NSString).pathExtension)
            },
            scale: appSettings.textSize.scale, numbered: mode == .changes)
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
            renderDiff()
        }
    }

    private func closeDiff() {
        if mode == .changes { fileSelection.clear() }
        selectedCommit = nil
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
        diffScroll = .top
        diff = loaded
        diffText = loaded.lines.isEmpty ? nil : DiffText.attributed(
            loaded.lines,
            language: CodeLanguage(fileExtension: (file.path as NSString).pathExtension),
            scale: appSettings.textSize.scale, numbered: mode == .changes)
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
