import AppKit
import SwiftUI
import CodeStationCore

// The uncommitted changes in a session's folder: the project directory itself, or the
// session's worktree. Sessions edit the real files there, so this screen is how you
// see what the agent did before you keep it. The diffs themselves never touch the tree;
// the header carries the little git a review ends in: switch branch, commit, pull, push.
struct ChangesView: View {
    let root: String
    let initiallySelectedPath: String?
    let repositories: [ChangesRepository]
    let requestedPath: String?
    @State private var model = ChangesModel()
    @State private var navigation: ChangesNavigationMemory
    private let isWorkspace: Bool
    let selectRepository: (String, String?) -> Void
    let review: ReviewTarget?

    private var collapsedRepositories: Set<String> {
        get { navigation.collapsed }
        nonmutating set { navigation.collapsed = newValue }
    }
    private var collapsedHistories: Set<String> {
        get { navigation.collapsedHistories }
        nonmutating set { navigation.collapsedHistories = newValue }
    }
    private var historyFilter: String {
        get { navigation.historyFilter }
        nonmutating set { navigation.historyFilter = newValue }
    }
    private var treeWidth: CGFloat {
        get { navigation.treeWidth }
        nonmutating set { navigation.treeWidth = newValue }
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

    @State private var commentDraft: CommentDraft?
    @State private var toast: ReviewToast?
    // The second opinion dialog showing progress or findings, so a reviewer finishing
    // while it is open does not also raise a toast behind it.
    @State private var secondOpinionDialog: UUID?
    @State private var pickerLineup: [SecondOpinion.Reviewer] = []
    @State private var pickerScope = SecondOpinionScopeChoice.all
    // An unplaced comment waiting for a line number to be clicked to move onto.
    @State private var reattaching: UUID?
    // Bumped to scroll the diff to the focused comment again, even when it has not moved.
    @State private var revealSerial = 0
    @State private var reviewKeys = WindowKeyHandler()
    @AppStorage("changes.reviewCoachSeen") private var coachSeen = false
    private var showingReview: Bool {
        get { navigation.showingReview }
        nonmutating set { navigation.showingReview = newValue }
    }
    private var showingQuestions: Bool {
        get { navigation.showingQuestions }
        nonmutating set { navigation.showingQuestions = newValue }
    }
    @State private var wholeQuestion = ""
    private var focusedComment: UUID? {
        get { navigation.focusedComment }
        nonmutating set { navigation.focusedComment = newValue }
    }

    @State private var copied: GitInspector.CopyVersion?
    @State private var copiedPath: String?
    private var checkedAt: Date? { model.checkedAt }
    private var refreshFailed: Bool { model.refreshFailed }
    @State private var feedback = ""
    private var latestCommit: GitCommitSummary? { model.latestCommit }
    @State private var openLatestCommit = false
    private var snapshot: GitSnapshot? { model.snapshot }
    private var loading: Bool { model.loading }
    private var working: String? {
        get { model.working }
        nonmutating set { model.working = newValue }
    }
    private var mode: Mode {
        get { navigation.showingHistory ? .history : .changes }
        nonmutating set { navigation.showingHistory = newValue == .history }
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
    private var fileSelection: ChangeFileSelection {
        get { navigation.selections[root] ?? ChangeFileSelection() }
        nonmutating set { navigation.selections[root] = newValue }
    }
    private var commits: [GitCommitSummary]? { model.commits }
    private var historyNote: String? { model.historyNote }
    private var loadingHistory: Bool { model.loadingHistory }
    private var historySelection: CommitHistorySelection { navigation.history(for: root) }
    private var diff: FileDiff? {
        get { model.diff }
        nonmutating set { model.diff = newValue }
    }
    private var diffText: NSAttributedString? {
        get { model.diffText }
        nonmutating set { model.diffText = newValue }
    }
    private var loadingDiff: Bool { model.loadingDiff }
    @State private var diffScroll = DiffTextView.Scroll.top
    // Gap rows git is reading the hidden lines for right now.
    private var expanding: Set<String> { model.expanding }
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
         review: ReviewTarget? = nil,
         selectRepository: @escaping (String, String?) -> Void = { _, _ in }) {
        let memory = navigation ?? ChangesNavigationMemory()
        _ = memory.history(for: root)
        _navigation = State(initialValue: memory)
        isWorkspace = navigation != nil
        _appliedInitialSelection = State(initialValue: navigation?.selections[root] != nil
            && initiallySelectedPath == nil && requestedPath == nil)
        self.root = root
        self.initiallySelectedPath = initiallySelectedPath
        self.repositories = repositories.isEmpty
            ? [ChangesRepository(root: root, name: (root as NSString).lastPathComponent)] : repositories
        self.requestedPath = requestedPath
        self.selectRepository = selectRepository
        self.review = review
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
                let width = !isWorkspace ? 280
                    : ExplorerSplitLayout.treeWidth(treeWidth, availableWidth: geometry.size.width)
                let headerWidth = navigatorVisible
                    ? geometry.size.width - width - ExplorerSplitLayout.dividerWidth : geometry.size.width
                VStack(spacing: 0) {
                    if !isWorkspace {
                        header(compact: geometry.size.width < 700, namesProject: !navigatorVisible)
                        if committing && mode == .changes { commitBar }
                    }
                    HStack(spacing: 0) {
                        if navigatorVisible {
                            VStack(spacing: 0) {
                                if isWorkspace { workspaceBand }
                                workspaceNavigator
                            }.frame(width: width).clipped()
                            Rectangle().fill(Theme.hairline).frame(width: ExplorerSplitLayout.dividerWidth)
                        }
                        VStack(spacing: 0) {
                            if isWorkspace {
                                header(compact: headerWidth < 600, namesProject: false)
                                if committing && mode == .changes { commitBar }
                            }
                            content(narrowHistory: narrowHistory)
                        }.frame(maxWidth: .infinity).clipped()
                    }
                    .overlay(alignment: .leading) {
                        if navigatorVisible && isWorkspace {
                            WorkspaceSplitHandle(width: Binding(get: { treeWidth }, set: { treeWidth = $0 }), displayedWidth: width,
                                                 availableWidth: geometry.size.width)
                                .offset(x: width + (ExplorerSplitLayout.dividerWidth - ExplorerSplitLayout.handleWidth) / 2)
                        }
                    }
                }
            }
            if let review, mode == .changes,
               !files.isEmpty || !review.reviews.comments(review.sessionID).isEmpty
                || !review.reviews.rounds(review.sessionID).isEmpty {
                // The toast sits in a ZStack that is always there. When an overlay's
                // content is a bare `if`, SwiftUI drops the overlay's alignment and the
                // alignment guide, and the toast hangs down from the bar, off the screen.
                reviewStrip(review)
                    .overlay(alignment: .top) {
                        ZStack {
                            if let toast {
                                ReviewToastView(toast: toast) { self.toast = nil }
                                    .transition(.opacity)
                                    .id(toast.id)
                            }
                        }
                        .alignmentGuide(.top) { $0[.bottom] + 10 }
                    }
                    .zIndex(1)
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
        .background(WindowKeyAnchor(handler: reviewKeys))
        .motion(Motion.reveal, value: toast?.id)
        .task(id: toast?.id) {
            guard let toast else { return }
            try? await Task.sleep(for: .seconds(toast.action == nil ? 3.2 : 6))
            if self.toast?.id == toast.id { self.toast = nil }
        }
        .onAppear { reviewKeys.start { handleReviewKey($0) } }
        .onDisappear { reviewKeys.stop() }
        .onChange(of: review.map { $0.reviews.runs($0.sessionID) } ?? []) { old, new in
            reportFinishedRuns(old: old, new: new)
        }
        // The screen opens on the last snapshot taken of this tree while a fresh one
        // is fetched, so the file list is there at first glance instead of after git.
        .task(id: root) {
            if snapshot == nil { model.snapshot = gitStats.snapshot(at: root) }
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
        // The text keeps an empty row under each line a thread hangs from, so a thread
        // that comes or goes is only seen once the text is built again. The reader stays
        // where they were.
        .onChange(of: threadLineIDs) { _, _ in
            diffScroll = .hold
            Task { await renderDiff() }
        }
        .onChange(of: fileSelection.activeID) { _, path in
            if commentDraft?.path != path { commentDraft = nil }
        }
        .onChange(of: diff) { _, _ in followDraft() }
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
        isWorkspace || mode == .history || width >= 650 || committing
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
            if mode == .changes, let review {
                let open = review.reviews.threads(review.sessionID).count { !$0.round.resolved.contains($0.comment.id) }
                let count = review.reviews.kept(review.sessionID).count + open
                let unread = review.reviews.unreadCount(review.sessionID) > 0
                let asked = review.reviews.questions(review.sessionID)
                let answering = asked.contains { $0.status == .answering }
                HStack(spacing: 4) {
                    ChoicePill(title: "Files \(navigatorFileCount)", selected: navigation.list == .files) {
                        navigation.list = .files
                    }
                    ChoicePill(title: count > 0 ? "Review \(count)" : "Review", selected: showingReview,
                               dot: unread ? Theme.plan : nil) { showingReview = true }
                    ChoicePill(title: asked.isEmpty ? "Questions" : "Questions \(asked.count)", selected: showingQuestions,
                               dot: answering ? Theme.plan : nil) { showingQuestions = true }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.top, 12)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Show")
            }
            if mode == .changes, showingReview, let review {
                ChangesReviewNavigator(review: review, orderedComments: orderedComments,
                                       navigation: navigation, fileLabel: fileLabel, focus: focus)
            } else if mode == .changes, showingQuestions, let review {
                questionsNavigator(review)
            } else {
                filesNavigator
            }
        }
        .background(Theme.card)
    }

    private var navigatorFileCount: Int {
        repositories.reduce(0) { total, repository in
            total + ((repository.root == root ? snapshot : gitStats.snapshot(at: repository.root))?.files.count ?? 0)
        }
    }

    private var filesNavigator: some View {
        VStack(spacing: 0) {
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
            // Same spacing as the selected project's rows, so picking another project
            // does not shift the list.
            HStack(spacing: 10) {
                StatusChip(kind: file.kind)
                fileName(file)
                counts(file)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(showsCursor(item) ? Theme.accent : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 8)
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
        repositoryRoot == root ? commits : navigation.commits[repositoryRoot]
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
            let selection = navigation.history(for: repositoryRoot)
            selection.select(commit)
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

                if let review {
                    let comments = review.reviews.comments(review.sessionID, root: repoRoot, path: file.path)
                        + review.reviews.threads(review.sessionID, root: repoRoot, path: file.path)
                            .filter { !$0.round.resolved.contains($0.comment.id) }.map(\.comment)
                    if !comments.isEmpty {
                        let pending = comments.contains(where: \.isPending)
                        HStack(spacing: 3) {
                            Label("\(comments.count)", systemImage: "text.bubble")
                            if pending { Circle().fill(Theme.attention).frame(width: 5, height: 5) }
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(pending ? Theme.attentionText : Theme.accent)
                        .appTooltip(counted(comments.count, "review comment") + (pending ? ", some still to look at" : ""))
                    }
                    let asked = review.reviews.questions(review.sessionID, root: repoRoot, path: file.path).count { !$0.resolved }
                    if asked > 0 {
                        Label("\(asked)", systemImage: "questionmark.bubble")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.plan)
                            .appTooltip(counted(asked, "question") + ", answered here")
                    }
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
                if mode == .changes, review != nil, !orderedComments.isEmpty { commentNavigation }
                if mode == .changes, let file = selected {
                    Image(systemName: "ellipsis").padding(8).contentShape(Rectangle())
                        .appMenu {
                            var entries: [MenuEntry] = []
                            if !file.isBinary && diff?.images == nil {
                                entries = DiffLayout.allCases.map { layout in
                                    .item(layout.title, checked: appSettings.changesDiffLayout == layout) {
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
                if appSettings.changesDiffLayout == .sideBySide {
                    HStack {
                        versionHeader("Last commit", version: .before, file: file)
                        versionHeader("Working tree", version: .after, file: file)
                    }.padding(.horizontal, 20).padding(.vertical, 8)
                }
            }
            if mode == .changes, let review {
                let placement = placement
                if !placement.unplaced.isEmpty { unplacedComments(placement.unplaced, review: review) }
                if !placement.onFile.isEmpty { fileComments(placement.onFile, review: review) }
            }
            diffBody(truncationHint: truncationHint)
                .overlay(alignment: .topLeading) {
                    if mode == .changes, review != nil, !coachSeen, diff?.lines.isEmpty == false,
                       orderedComments.isEmpty, commentDraft == nil {
                        coachMark.padding(.leading, 70).padding(.top, 40)
                    }
                }
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
        } else if mode == .changes, appSettings.changesDiffLayout == .sideBySide, let diff {
            if let review {
                SideBySideDiff(lines: diff.lines, expand: expand, threads: threadViews(review), picked: pickedKeys,
                               onLine: { pickLine($0, extending: $1) }, onRange: { pickRange($0) },
                               reveal: revealedLine)
            } else {
                SideBySideDiff(lines: diff.lines, expand: expand)
            }
        } else if let diffText {
            if mode == .changes, let review {
                DiffTextView(text: diffText, scroll: diffScroll,
                             onExpand: { expand($0, $1) },
                             onLine: { key, extending in
                                 if let anchor = DiffComments.anchor(key) { pickLine(anchor, extending: extending) }
                             },
                             onRange: { start, end in
                                 if let first = DiffComments.anchor(start), let last = DiffComments.anchor(end) {
                                     pickRange(first.extended(to: last))
                                 }
                             },
                             picked: pickedKeys,
                             threads: threadViews(review),
                             reveal: revealedLine)
            } else {
                DiffTextView(text: diffText, scroll: diffScroll) { gap, direction in
                    expand(gap, direction)
                }
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
            content: AnyView(RemoteCommitList(commits: commits,
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
            content: AnyView(RemoteCommitList(commits:
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
            content: AnyView(RemoteCommitList(commits:
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

    // Every git action ends in a reload, success or not: a failed pull can still have
    // moved the tree, and the header has to show whatever is true now.
    private func perform(_ progress: String, failure: String,
                         _ action: @escaping () async -> String?) {
        guard !busy else { return }
        Task {
            let error = await model.perform(progress, action)
            if let error { dialogs.show(.notice(failure, message: error)) }
            await reload()
        }
    }

    private func reload(fetchOrigin: Bool = false) async {
        guard await model.reload(root: root, fetchOrigin: fetchOrigin, gitStats: gitStats,
                                 onError: { error in
            dialogs.show(.notice("Could not refresh origin", message: error))
        }), let fresh = snapshot else { return }
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
            await loadDiff(file, root: fresh.root, recheckList: false)
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
                navigation.commits[repository.root] = history.commits
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
        guard await model.loadHistory(at: repoRoot), let commits else { return }
        navigation.commits[root] = commits

        if let current = historySelection.commit,
           commits.contains(where: { $0.id == current.id }) { return }
        if let first = commits.first { historySelection.select(first) }
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
        await model.renderDiff(
            language: (mode == .changes ? selected : nil).flatMap {
                CodeLanguage(fileExtension: ($0.path as NSString).pathExtension)
            },
            scale: appSettings.textSize.scale, numbered: mode == .changes,
            comments: mode == .changes ? diffComments(for: selected, lines: diff.lines) : nil)

    }

    // A grey gap row stands for the unchanged lines the diff skipped. Pressing one of its
    // controls reads that end of the gap back and drops the lines in beside the row, so a
    // change can be read with the code around it without leaving the pane.
    private func expand(_ key: String, _ direction: DiffExpandDirection) {
        Task {
            guard await model.expand(key, direction, at: repoRoot) else { return }
            diffScroll = direction == .down ? .follow : .hold
            await renderDiff()
        }
    }

    private func closeDiff() {
        if mode == .changes { fileSelection.clear() }
        clearDiffContent()
    }

    private func clearDiffContent() {
        model.clearDiff()
        diffScroll = .top
    }

    private func loadDiff(_ file: GitChange, root: String, recheckList: Bool = true) async {
        guard let loaded = await model.loadDiff(file, at: root, isCurrent: {
            mode == .changes && fileSelection.activeID == file.id
        }) else { return }
        // The list can be older than the tree, for example when a session commits just
        // as a file is opened. An empty diff for a row that counts changed lines means
        // the list is out of date, so read it again rather than show an empty file.
        // The reload opens the diff without this check, so it cannot loop.
        let countedLines = (file.added ?? 0) + (file.removed ?? 0) > 0
        if recheckList, countedLines, loaded.lines.isEmpty, loaded.note == nil, loaded.images == nil {
            await reload()
            return
        }
        diffScroll = .top
        diff = loaded
        diffText = nil
        // Publish the file before building its text, so comments arriving during the
        // build are rendered against these lines too.
        await renderDiff()
    }

    // MARK: - Review

    private var openFileComments: [ReviewComment] {
        guard let review, let file = selected else { return [] }
        return inlineComments(review, path: file.path)
    }

    // A change made from a question's answer is drawn inside the question's thread, so it
    // is left out of the cards while the question is still there.
    private func inlineComments(_ review: ReviewTarget, path: String) -> [ReviewComment] {
        let asked = Set(review.reviews.questions(review.sessionID).map(\.id))
        return review.reviews.comments(review.sessionID, root: repoRoot, path: path)
            .filter { $0.questionID.map { !asked.contains($0) } ?? true }
    }

    private var openFileQuestions: [ReviewQuestion] {
        guard let review, let file = selected else { return [] }
        return review.reviews.questions(review.sessionID, root: repoRoot, path: file.path)
    }

    private var questionPlacement: [Int: [ReviewQuestion]] {
        guard let diff else { return [:] }
        return Self.placeQuestions(openFileQuestions, in: diff.lines)
    }

    // Questions hang under their lines the way comments do. One whose code has left the
    // diff is still in the Questions list.
    static func placeQuestions(_ questions: [ReviewQuestion], in lines: [DiffLine]) -> [Int: [ReviewQuestion]] {
        guard !questions.isEmpty else { return [:] }
        let numbered = NumberedDiffLine.lines(lines)
        var below: [Int: [ReviewQuestion]] = [:]
        for question in questions.sorted(by: { $0.created < $1.created }) where !question.isWhole {
            if let found = ReviewPlacement.locate(question.anchor, excerpt: question.excerpt,
                                                  excerptOffsets: question.excerptOffsets, in: numbered) {
                below[found.lastID, default: []].append(question)
            }
        }
        return below
    }

    private var placement: ReviewPlacement {
        guard let diff else { return ReviewPlacement() }
        return ReviewPlacement.place(openFileComments, in: diff.lines)
    }

    // Sent comments stay under their lines as threads. One whose code has left the diff
    // is still in the review list, so it is not listed again above the diff.
    private var openFileThreads: [(round: ReviewRound, comment: ReviewComment)] {
        guard let review, let file = selected else { return [] }
        return review.reviews.threads(review.sessionID, root: repoRoot, path: file.path)
    }

    private var sentPlacement: ReviewPlacement {
        guard let diff else { return ReviewPlacement() }
        return ReviewPlacement.place(openFileThreads.map(\.comment), in: diff.lines)
    }

    private var pickedKeys: Set<String> {
        commentDraft.map { DiffComments.keys($0.anchor) } ?? []
    }

    // Every comment in the review, in the order they are read and stepped through.
    private var orderedComments: [ReviewComment] {
        guard let review else { return [] }
        return ReviewOrder.sorted(review.reviews.comments(review.sessionID), roots: repositories.map(\.root))
    }

    // The id of the diff line a new comment's composer opens under: the last of its lines.
    private func lineID(for anchor: DiffAnchor, in lines: [DiffLine]) -> Int? {
        let last = anchor.lastLine ?? anchor.line
        return NumberedDiffLine.lines(lines).first { $0.side == anchor.side && $0.number == last }?.id
    }

    // The lines a thread hangs from: those with comments placed under them, and the one a
    // comment is being written about.
    private func threadLines(placement: ReviewPlacement, sent: ReviewPlacement, asked: [Int: [ReviewQuestion]],
                             lines: [DiffLine]) -> Set<Int> {
        var ids = Set(placement.below.keys).union(sent.below.keys).union(asked.keys)
        if let draft = commentDraft, draft.path == selected?.path, draft.editing == nil,
           let id = lineID(for: draft.anchor, in: lines) {
            ids.insert(id)
        }
        return ids
    }

    private var threadLineIDs: Set<Int> {
        guard review != nil, mode == .changes, let diff else { return [] }
        return threadLines(placement: placement, sent: sentPlacement, asked: questionPlacement, lines: diff.lines)
    }

    private func diffComments(for file: GitChange?, lines: [DiffLine]) -> DiffComments? {
        guard let review else { return nil }
        let comments = file.map { inlineComments(review, path: $0.path) } ?? []
        let sent = file.map { review.reviews.threads(review.sessionID, root: repoRoot, path: $0.path).map(\.comment) } ?? []
        let asked = file.map { review.reviews.questions(review.sessionID, root: repoRoot, path: $0.path) } ?? []
        return DiffComments(threads: threadLines(placement: ReviewPlacement.place(comments, in: lines),
                                                 sent: ReviewPlacement.place(sent, in: lines),
                                                 asked: Self.placeQuestions(asked, in: lines), lines: lines))
    }

    // What hangs under each line: its cards, and the composer where one is being written.
    // An existing comment opened to edit turns into the composer in its own place.
    private func threadViews(_ review: ReviewTarget) -> [Int: AnyView] {
        guard let diff else { return [:] }
        let placement = placement
        let sent = sentPlacement
        let asked = questionPlacement
        let rounds = Dictionary(openFileThreads.map { ($0.comment.id, $0.round) }, uniquingKeysWith: { first, _ in first })
        var views: [Int: AnyView] = [:]
        let draftLine: Int? = {
            guard let draft = commentDraft, draft.path == selected?.path else { return nil }
            if let editing = draft.editing {
                return placement.below.first { $0.value.contains { $0.id == editing } }?.key
            }
            return lineID(for: draft.anchor, in: diff.lines)
        }()
        for id in threadLines(placement: placement, sent: sent, asked: asked, lines: diff.lines) {
            let comments = placement.below[id] ?? []
            let threads = (sent.below[id] ?? []).compactMap { comment in rounds[comment.id].map { ($0, comment) } }
            views[id] = AnyView(VStack(alignment: .leading, spacing: 8) {
                ForEach(asked[id] ?? []) { question in
                    questionThread(question, review: review)
                }
                ForEach(threads, id: \.1.id) { round, comment in
                    thread(comment, round: round, review: review)
                }
                ForEach(comments) { comment in
                    if commentDraft?.editing == comment.id {
                        composer(review)
                    } else {
                        card(comment, review: review)
                    }
                }
                if draftLine == id, commentDraft?.editing == nil { composer(review) }
            })
        }
        return views
    }

    private var revealedLine: DiffReveal? {
        guard let focusedComment,
              let line = placement.below.first(where: { $0.value.contains { $0.id == focusedComment } })?.key
                ?? sentPlacement.below.first(where: { $0.value.contains { $0.id == focusedComment } })?.key
                ?? questionPlacement.first(where: { $0.value.contains { $0.id == focusedComment } })?.key
        else { return nil }
        return DiffReveal(line: line, serial: revealSerial)
    }

    private func thread(_ comment: ReviewComment, round: ReviewRound, review: ReviewTarget) -> some View {
        let focused = focusedComment == comment.id
        return ReviewThreadView(
            round: round, comment: comment, agent: review.agent, fileName: fileLabel(comment),
            working: review.isBusy(), showsQuote: false, focused: focused,
            projectPath: repoRoot, textScale: appSettings.textSize.scale,
            reply: { replyInThread($0, to: comment, round: round, review: review) },
            resolve: {
                review.reviews.resolve(comment.id, round: round.id, in: review.sessionID)
                announce("Resolved")
            },
            reopen: { review.reviews.reopen(comment.id, round: round.id, in: review.sessionID) })
            .padding(.bottom, 2)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Theme.accent : Theme.border, lineWidth: focused ? 2 : 1))
            .onTapGesture {
                focusedComment = comment.id
                review.reviews.markRead(comment.id, in: review.sessionID)
            }
    }

    // A reply goes to the agent at once, as a turn of its own about those lines.
    private func replyInThread(_ text: String, to comment: ReviewComment, round: ReviewRound, review: ReviewTarget) {
        let names = projectNames
        Task {
            guard let prompt = await review.reviews.reply(text, to: comment.id, round: round.id, in: review.sessionID,
                                                          projectNames: names) else { return }
            let busy = review.isBusy()
            review.send(prompt)
            announce(busy ? "Reply queued for \(review.agent.title)" : "Reply sent to \(review.agent.title)")
        }
    }

    private func card(_ comment: ReviewComment, review: ReviewTarget, showsLines: Bool = true) -> some View {
        ReviewCommentCard(comment: comment, focused: focusedComment == comment.id, showsLines: showsLines,
                          onEdit: { openComment(comment) },
                          onDelete: { deleteComment(comment) },
                          onKeep: { keep(comment) },
                          onDismiss: { dismiss(comment) })
            .onTapGesture { focusedComment = comment.id }
    }

    @ViewBuilder private func composer(_ review: ReviewTarget) -> some View {
        if let draft = commentDraft {
            let editing = draft.editing.flatMap { review.reviews.comment($0, in: review.sessionID) }
            let finding = editing?.isPending == true ? editing : nil
            ReviewComposer(
                text: Binding(get: { commentDraft?.text ?? "" }, set: { commentDraft?.text = $0 }),
                kind: Binding(get: { commentDraft?.kind ?? .change }, set: { commentDraft?.kind = $0 }),
                title: finding.map { "Edit \($0.authorName)'s finding" } ?? (editing == nil ? "New comment" : "Edit comment"),
                linesLabel: draft.anchor.label,
                agentTitle: review.agent.title,
                action: finding != nil ? "Keep with my edits" : editing == nil ? "Add comment" : "Save",
                stretches: editing == nil,
                place: place(root: repoRoot, path: draft.path, anchor: draft.anchor),
                forksConversation: review.agent == .claudeCode,
                onDelete: editing != nil && finding == nil ? { if let editing { deleteComment(editing) } } : nil,
                onSave: saveComment,
                onCancel: { commentDraft = nil })
        }
    }

    private func pickLine(_ anchor: DiffAnchor, extending: Bool) {
        guard let file = selected else { return }
        if let id = reattaching {
            moveUnplaced(id, to: anchor)
            return
        }
        coachSeen = true
        focusedComment = nil
        // A saved comment keeps the lines it was left on, so only a new one stretches.
        if extending, let draft = commentDraft, draft.path == file.path, draft.editing == nil {
            let stretched = draft.anchor.extended(to: anchor)
            let quote = excerpt(stretched)
            commentDraft?.anchor = stretched
            commentDraft?.excerpt = quote.text
            commentDraft?.excerptOffsets = quote.offsets
        } else {
            openDraft(at: anchor, in: file)
        }
    }

    // A drag down the numbers picks the whole run at once.
    private func pickRange(_ anchor: DiffAnchor) {
        guard let file = selected else { return }
        if let id = reattaching {
            moveUnplaced(id, to: anchor)
            return
        }
        coachSeen = true
        focusedComment = nil
        openDraft(at: anchor, in: file)
    }

    // A note part way written moves to the new lines rather than being dropped.
    private func openDraft(at anchor: DiffAnchor, in file: GitChange) {
        let quote = excerpt(anchor)
        if let draft = commentDraft, draft.path == file.path, draft.editing == nil, !draft.text.isBlank {
            commentDraft?.anchor = anchor
            commentDraft?.excerpt = quote.text
            commentDraft?.excerptOffsets = quote.offsets
        } else {
            commentDraft = CommentDraft(anchor: anchor, path: file.path, excerpt: quote.text,
                                        excerptOffsets: quote.offsets)
        }
    }

    // A diff read again under a note being written can have moved its lines. The note
    // follows its code there, so it is still saved against the lines it was written for.
    private func followDraft() {
        guard let draft = commentDraft, draft.editing == nil, draft.path == selected?.path,
              let lines = diff?.lines,
              let found = ReviewPlacement.locate(draft.anchor, excerpt: draft.excerpt,
                                                 excerptOffsets: draft.excerptOffsets,
                                                 in: NumberedDiffLine.lines(lines)),
              found.anchor != draft.anchor else { return }
        commentDraft?.anchor = found.anchor
    }

    private func openComment(_ comment: ReviewComment) {
        guard comment.root == repoRoot else {
            focus(comment)
            return
        }
        if selected?.path != comment.path, let file = files.first(where: { $0.path == comment.path }) {
            mode = .changes
            select(file)
        }
        focusedComment = nil
        commentDraft = CommentDraft(anchor: comment.anchor, path: comment.path,
                                    excerpt: comment.excerpt, excerptOffsets: comment.excerptOffsets,
                                    text: comment.body, kind: comment.kind, editing: comment.id)
    }

    // The code a comment is about, quoted with it so the agent sees what was meant even
    // if the lines have moved by the time it reads them.
    private func excerpt(_ anchor: DiffAnchor) -> (text: String, offsets: [Int]) {
        NumberedDiffLine.excerpt(anchor, in: diff?.lines ?? [])
    }

    private func saveComment() {
        guard let review, let draft = commentDraft, !draft.text.isBlank else { return }
        if let id = draft.editing {
            let wasPending = review.reviews.comment(id, in: review.sessionID)?.isPending == true
            review.reviews.update(id, body: draft.text.trimmed, kind: draft.kind, in: review.sessionID)
            commentDraft = nil
            if wasPending {
                announce("Kept with your edits")
                afterTriage(from: id)
                return
            }
            announce("Comment saved")
        } else if draft.kind == .question {
            let question = ReviewQuestion(root: repoRoot, path: draft.path, anchor: draft.anchor, excerpt: draft.excerpt,
                                          excerptOffsets: draft.excerptOffsets, agent: review.agent,
                                          question: draft.text.trimmed)
            review.reviews.ask(question, context: questionContext(review), in: review.sessionID)
            commentDraft = nil
            focusedComment = question.id
            announce("Asked. The answer appears under the lines and stays here.")
        } else {
            commentDraft = nil
            sendChange(ReviewComment(root: repoRoot, path: draft.path, anchor: draft.anchor,
                                     excerpt: draft.excerpt, body: draft.text.trimmed,
                                     excerptOffsets: draft.excerptOffsets, kind: draft.kind),
                       review: review)
        }
    }

    private func deleteComment(_ comment: ReviewComment) {
        guard let review else { return }
        review.reviews.remove(comment.id, from: review.sessionID)
        if commentDraft?.editing == comment.id { commentDraft = nil }
        if focusedComment == comment.id { focusedComment = nil }
        announce("Comment deleted")
    }

    // MARK: Moving through the review

    // Puts a comment in focus and brings it on screen, opening its file, or its project,
    // first if it is elsewhere.
    private func focus(_ comment: ReviewComment) {
        focusedComment = comment.id
        revealSerial += 1
        review?.reviews.markRead(comment.id, in: review?.sessionID ?? UUID())
        if commentDraft?.editing != nil || commentDraft?.text.isBlank != false { commentDraft = nil }
        guard comment.root == repoRoot else {
            selectRepository(comment.root, comment.path)
            return
        }
        if selected?.path != comment.path, let file = files.first(where: { $0.path == comment.path }) {
            mode = .changes
            select(file)
        }
        announce(comment.spokenName)
    }

    private func step(_ by: Int) {
        let list = orderedComments
        guard let next = ReviewOrder.step(from: list.contains { $0.id == focusedComment } ? focusedComment : nil,
                                          by: by, in: list) else { return }
        focus(next)
    }

    // After a finding is sorted, focus moves on to the next one still waiting, so a whole
    // set can be sorted from the keyboard without looking for the next.
    private func afterTriage(from id: UUID) {
        guard let review else { return }
        let ordered = orderedComments
        let pending = ordered.filter(\.isPending)
        guard !pending.isEmpty else {
            focusedComment = nil
            showToast("All findings sorted. \(counted(review.reviews.kept(review.sessionID).count, "comment")) ready to send.")
            return
        }
        // The next waiting one after where this one stood, going round to the first.
        let after = ordered.firstIndex { $0.id == id }.map { index in
            ordered[(index + 1)...].first(where: \.isPending)
        } ?? nil
        focus(after ?? pending[0])
    }

    private func keep(_ comment: ReviewComment) {
        guard let review else { return }
        review.reviews.keep(comment.id, in: review.sessionID)
        announce("Kept \(comment.authorName)'s finding")
        afterTriage(from: comment.id)
    }

    private func dismiss(_ comment: ReviewComment) {
        guard let review, let gone = review.reviews.dismiss(comment.id, from: review.sessionID) else { return }
        let sessionID = review.sessionID
        let reviews = review.reviews
        afterTriage(from: comment.id)
        showToast("Dismissed \(comment.authorName)'s finding", action: "Undo") {
            reviews.restore(gone.comment, at: gone.index, to: sessionID)
            focus(gone.comment)
        }
    }

    // The keys that move through a review and sort what is in it. Single letters only
    // count while a finding is in focus and nothing is being typed.
    private func handleReviewKey(_ event: NSEvent) -> Bool {
        guard let review, mode == .changes, dialogs.current == nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .option, event.keyCode == 125 || event.keyCode == 126 {
            step(event.keyCode == 125 ? 1 : -1)
            return true
        }
        guard flags.isEmpty, let id = focusedComment,
              let comment = review.reviews.comment(id, in: review.sessionID) else { return false }
        if event.keyCode == 53 {
            focusedComment = nil
            return true
        }
        guard comment.isPending else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "k": keep(comment)
        case "e": openComment(comment)
        case "d": dismiss(comment)
        default: return false
        }
        return true
    }

    private func showToast(_ text: String, action title: String? = nil, perform: (() -> Void)? = nil) {
        toast = ReviewToast(text: text, actionTitle: title, action: perform)
        announce(text)
    }

    // MARK: Comments that lost their lines

    private func moveUnplaced(_ id: UUID, to anchor: DiffAnchor) {
        guard let review else { return }
        let quote = excerpt(anchor)
        review.reviews.move(id, to: anchor, excerpt: quote.text, offsets: quote.offsets, in: review.sessionID)
        reattaching = nil
        focusedComment = id
        revealSerial += 1
        showToast("Moved to \(anchor.label.lowercased())")
    }

    private func unplacedComments(_ comments: [ReviewComment], review: ReviewTarget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(comments) { comment in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.attentionText)
                    VStack(alignment: .leading, spacing: 8) {
                        (Text("This comment's code is no longer in the diff.").fontWeight(.semibold)
                         + Text(" It was on \(comment.anchor.label.lowercased()). It still goes with your review."))
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        card(comment, review: review)
                        if !comment.excerpt.isBlank {
                            Text(comment.excerpt).font(.mono(11)).foregroundStyle(.secondary).lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Theme.sunken))
                        }
                        HStack(spacing: 12) {
                            if reattaching == comment.id {
                                Text("Click a line number to move the comment there.")
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                                InlineLink(title: "Cancel", tint: Color.secondary) { reattaching = nil }
                            } else {
                                ActionButton(title: "Move to a line", tone: .outlined, height: 26, size: 11.5,
                                             icon: "scope") {
                                    reattaching = comment.id
                                    announce("Click a line number to move the comment there")
                                }
                                InlineLink(title: "Leave it as a file comment", tint: Color.secondary) {
                                    review.reviews.keepOnFile(comment.id, in: review.sessionID)
                                    showToast("It stays in the review as a comment on the whole file")
                                }
                                InlineLink(title: "Delete", tint: Theme.deletion) { deleteComment(comment) }
                            }
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.attention.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.attention.opacity(0.3)))
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
    }

    private func fileComments(_ comments: [ReviewComment], review: ReviewTarget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(comments) { comment in
                if commentDraft?.editing == comment.id {
                    composer(review)
                } else {
                    card(comment, review: review)
                }
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
    }

    // The first time the diff takes comments, a note says how.
    private var coachMark: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask or comment on any line").font(.system(size: 12.5, weight: .semibold))
            Text("Click a line number to ask a question or request a change. Drag down the numbers to cover several lines. Questions are answered here; changes wait until you send them to \(review?.agent.title ?? "the agent").")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                InlineLink(title: "Got it") { coachSeen = true }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 300)
        .floatingCard(cornerRadius: 10)
        .accessibilityElement(children: .contain)
    }

    // MARK: Review bar

    // One line that says what you will send. Everything a second opinion is doing lives
    // behind its one control, and the finer details are in the title's tooltip.
    @ViewBuilder private func reviewStrip(_ review: ReviewTarget) -> some View {
        let all = review.reviews.comments(review.sessionID)
        let kept = all.filter { !$0.isPending }
        let pending = all.count - kept.count
        let fileCount = Set(kept.map { $0.root + "/" + $0.path }).count
        let settled = settledComments(all)
        let unplaced = placement.unplaced.count
        let sent = review.reviews.threads(review.sessionID).count
        let unread = review.reviews.unreadCount(review.sessionID)
        let asked = review.reviews.questions(review.sessionID).count
        let details = [
            !kept.isEmpty ? "On \(counted(fileCount, "file")). Changes wait here until you send them"
                : all.isEmpty ? "Click a line number to ask or comment" : "Nothing kept yet",
            sent > 0 ? "\(sent) sent" : nil,
            unplaced > 0 ? "\(unplaced) not on a line, because its code moved or was removed" : nil,
            settled > 0 ? "\(settled) on files with no changes left. They are still in the review, and the send dialog lists them" : nil
        ].compactMap { $0 }
        HStack(spacing: 10) {
            Label("Your review", systemImage: "text.bubble.fill")
                .font(.system(size: 12, weight: .semibold))
                .labelStyle(ReviewBarLabelStyle())
                .lineLimit(1)
                .fixedSize()
                .appTooltip(details.joined(separator: ". ") + ".")
                .accessibilityHint(details.joined(separator: ". "))
            reviewCount(count: kept.count, text: "to send",
                        icon: "pencil", tint: Theme.accent, help: "Goes to \(review.agent.title) when you send") {
                showingReview = true
            }
            reviewCount(count: asked, text: asked == 1 ? "question stays here" : "questions stay here",
                        icon: "eye.slash", tint: Theme.plan, help: "Answered here. Never sent to \(review.agent.title)") {
                showingQuestions = true
            }
            if unread > 0 {
                Button(action: nextUnread) {
                    Text(unread == 1 ? "1 reply to read" : "\(unread) replies to read")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.plan)
                        .lineLimit(1).fixedSize()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .appTooltip("Open the next reply")
            }
            Spacer(minLength: 8)
            SecondOpinionChip(status: secondOpinionStatus(review),
                              open: { openSecondOpinion(review) },
                              askAgain: { openAsk(review) })
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 20)
            if !all.isEmpty {
                InlineLink(title: "Clear", tint: Color.secondary) { confirmClear(review, kept: kept.count, pending: pending) }
            }
            InlineLink(title: "Preview message", tint: Color.secondary) { previewSend(review, startsOnMessage: true) }
                .disabled(kept.isEmpty)
                .opacity(kept.isEmpty ? 0.5 : 1)
                .appTooltip("The exact message \(review.agent.title) gets")
            ActionButton(title: kept.isEmpty ? "Send to \(review.agent.title)"
                         : "Send \(kept.count) to \(review.agent.title)",
                         tone: .green, height: 28, size: 12, icon: "paperplane.fill") { previewSend(review) }
                .disabled(kept.isEmpty)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Theme.card)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    // A count in the review bar that says where things go, in words as well as colour.
    private func reviewCount(count: Int, text: String, icon: String, tint: Color, help: String,
                             open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text("\(count)").fontWeight(.bold)
                Text(text)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(count > 0 ? tint : Color.secondary)
            .padding(.horizontal, 9).frame(height: 24)
            .background(Capsule().fill((count > 0 ? tint : Color.secondary).opacity(0.1)))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .appTooltip(help)
        .accessibilityLabel("\(count) \(text)")
    }

    // The first thread with an answer not yet read, in the order the review list shows.
    private func nextUnread() {
        guard let review,
              let next = review.reviews.threads(review.sessionID).first(where: { $0.round.unread.contains($0.comment.id) })
        else { return }
        showingReview = true
        focus(next.comment)
    }

    // A file that has been committed or reverted leaves the list, and its comments with
    // it. They still go with the review, so the strip says how many are out of sight.
    private func settledComments(_ comments: [ReviewComment]) -> Int {
        let changed = Set(repositories.flatMap { repository -> [String] in
            let snapshot = repository.root == root ? snapshot : gitStats.snapshot(at: repository.root)
            guard let snapshot else { return [] }
            return snapshot.files.map { snapshot.root + "/" + $0.path }
        })
        guard !changed.isEmpty || snapshot != nil else { return 0 }
        return comments.count { !changed.contains($0.root + "/" + $0.path) }
    }

    // Says once when each reviewer is done, with the way to its findings. The progress and
    // findings dialogs already show it happen, so nothing is said while one is open.
    private func reportFinishedRuns(old: [SecondOpinionRun], new: [SecondOpinionRun]) {
        guard let review else { return }
        for run in new where !run.isRunning {
            guard old.first(where: { $0.reviewer == run.reviewer })?.isRunning == true else { continue }
            if secondOpinionDialog != nil, dialogs.current?.id == secondOpinionDialog {
                announce("\(run.reviewer.label()) finished its review")
                continue
            }
            switch run.state {
            case .finished(let found) where found > 0:
                showToast("\(run.reviewer.label()) found \(counted(found, "thing")) to look at", action: "Look at them") {
                    openFindings(review, from: run.reviewer)
                }
            case .finished:
                showToast("\(run.reviewer.label()) found nothing worth raising")
            case .failed:
                showToast("\(run.reviewer.label()) could not finish the review", action: "Try again") {
                    review.reviews.retrySecondOpinion(review.sessionID, reviewer: run.reviewer)
                }
            case .running:
                break
            }
        }
    }

    // MARK: Second opinion

    private func secondOpinionStatus(_ review: ReviewTarget) -> SecondOpinionStatus {
        SecondOpinionStatus(runs: review.reviews.runs(review.sessionID),
                            findings: review.reviews.comments(review.sessionID).filter { $0.reviewer != nil },
                            dismissed: review.reviews.dismissedFindings(review.sessionID).count)
    }

    // The bar's control opens whichever dialog its state is about.
    private func openSecondOpinion(_ review: ReviewTarget) {
        switch secondOpinionStatus(review) {
        case .ask: openAsk(review)
        case .reviewing, .failed: openProgress(review)
        case .ready: openFindings(review)
        case .settled(let kept, let dismissed):
            if kept + dismissed > 0 { openFindings(review) } else { openProgress(review) }
        }
    }

    private func openAsk(_ review: ReviewTarget) {
        let installed = AgentKind.allCases.filter { review.executable($0) != nil }
        let running = Set(review.reviews.runs(review.sessionID).filter(\.isRunning).map(\.reviewer))
        if pickerLineup.isEmpty {
            // With no saved lineup the dialog seats a first reviewer itself.
            pickerLineup = Preferences.secondOpinionLineup().filter { installed.contains($0.agent) }
        }
        let canReadSince = review.reviews.latestTrees(review.sessionID) != nil
        if pickerScope == .sinceReview, !canReadSince { pickerScope = .all }
        if pickerScope == .file, selected == nil { pickerScope = .all }
        let changed = repositories.reduce(0) { total, repository in
            total + ((repository.root == root ? snapshot : gitStats.snapshot(at: repository.root))?.files.count ?? 0)
        }
        secondOpinionDialog = nil
        dialogs.show(Dialog(
            title: "Ask for a second opinion",
            content: AnyView(ChangesOpinionAsk(
                author: review.author, installed: installed, running: running,
                lineup: pickerLineup, focus: navigation.secondOpinionFocus, scope: pickerScope,
                fileCount: changed, fileName: selected?.fileName, canReadSince: canReadSince,
                ask: { lineup, focus, scope in
                    pickerLineup = lineup
                    navigation.secondOpinionFocus = focus
                    pickerScope = scope
                    askForSecondOpinion(review, lineup: lineup)
                })),
            actions: [], width: 620, framesItself: true))
    }

    private func openProgress(_ review: ReviewTarget) {
        let reviews = review.reviews
        let sessionID = review.sessionID
        let dialog = Dialog(
            title: "Second opinion",
            content: AnyView(SecondOpinionProgressView(
                review: review,
                stop: { reviewer in
                    reviews.stopSecondOpinion(sessionID, reviewer: reviewer)
                    announce("Stopped \(reviewer.label())'s review")
                },
                stopAll: {
                    reviews.stopSecondOpinion(sessionID)
                    announce("Stopped every review")
                },
                lookAt: { reviewer in openFindings(review, from: reviewer) })),
            actions: [], width: 580, framesItself: true)
        secondOpinionDialog = dialog.id
        dialogs.show(dialog)
    }

    // Opens on the first finding still to look at, from one reviewer when asked.
    private func openFindings(_ review: ReviewTarget, from reviewer: SecondOpinion.Reviewer? = nil) {
        let list = SecondOpinionFindings.ordered(review.reviews.findings(review.sessionID))
        let first = list.first { $0.isPending && (reviewer == nil || $0.raised(by: reviewer!)) }
            ?? list.first { reviewer == nil || $0.raised(by: reviewer!) }
        let dialog = Dialog(
            title: "Findings",
            content: AnyView(SecondOpinionFindingsView(review: review, selected: first?.id)),
            actions: [], width: 900, framesItself: true)
        secondOpinionDialog = dialog.id
        dialogs.show(dialog)
    }

    private func askForSecondOpinion(_ review: ReviewTarget, lineup: [SecondOpinion.Reviewer]) {
        let scope: SecondOpinionRequest.Scope
        switch pickerScope {
        case .all: scope = .all
        case .file: scope = selected.map { .file(root: repoRoot, path: $0.path) } ?? .all
        case .sinceReview: scope = review.reviews.latestTrees(review.sessionID).map { .sinceReview(trees: $0) } ?? .all
        }
        let running = Set(review.reviews.runs(review.sessionID).filter(\.isRunning).map(\.reviewer))
        var seen = Set<SecondOpinion.Reviewer>()
        let chosen = lineup.filter { !running.contains($0) && seen.insert($0).inserted }
        review.reviews.beginSecondOpinion(review.sessionID)
        startSecondOpinion(review, reviewers: chosen, scope: scope)
        openProgress(review)
    }

    private func startSecondOpinion(_ review: ReviewTarget, reviewers: [SecondOpinion.Reviewer],
                                    scope: SecondOpinionRequest.Scope) {
        var asked: [String] = []
        for reviewer in reviewers {
            guard let executable = review.executable(reviewer.agent) else { continue }
            review.reviews.startSecondOpinion(review.sessionID, reviewer: reviewer, request: SecondOpinionRequest(
                focus: SecondOpinion.Focus.allCases.filter(navigation.secondOpinionFocus.contains),
                scope: scope, repositories: reviewRepositories, executable: executable))
            asked.append(reviewer.label())
        }
        guard !asked.isEmpty else { return }
        announce("Asked \(asked.joined(separator: " and ")) for a second opinion")
    }

    // The open project leads, so the reviewer starts in the folder the session works in.
    private var reviewRepositories: [ReviewRepository] {
        let open = repositories.filter { $0.root == root } + repositories.filter { $0.root != root }
        return open.map { ReviewRepository(root: $0.root, name: $0.name) }
    }

    // MARK: Clearing and sending

    private func confirmClear(_ review: ReviewTarget, kept: Int, pending: Int) {
        let what = counted(kept, "comment") + (pending > 0 ? " and \(counted(pending, "finding"))" : "")
        dialogs.show(.impact(
            "Clear the review?",
            rows: [
                .init(title: what, detail: "Everything not yet sent"),
                .init(title: "The changes themselves", detail: "Nothing in the files is touched", kept: true)
            ],
            warning: "Comments that have not been sent cannot be brought back.",
            compact: true,
            action: "Clear review") {
                review.reviews.clear(review.sessionID)
                commentDraft = nil
                focusedComment = nil
                showToast("Review cleared")
            })
    }

    private var projectNames: [String: String] {
        Dictionary(repositories.map { ($0.root, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private func fileLabel(_ comment: ReviewComment) -> String {
        fileLabel(root: comment.root, path: comment.path)
    }

    private func fileLabel(root: String, path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard repositories.count > 1 else { return name }
        return (projectNames[root] ?? (root as NSString).lastPathComponent) + " · " + name
    }

    // The project, file and lines a question or a new note is about, as its band names them.
    private func place(root: String, path: String, anchor: DiffAnchor?) -> String {
        let project = projectNames[root] ?? (root as NSString).lastPathComponent
        guard let anchor, !path.isEmpty else { return project + " · whole change" }
        let lines = anchor.lastLine.map { "\(anchor.line)–\($0)" } ?? "\(anchor.line)"
        return project + " · " + (path as NSString).lastPathComponent + " " + lines + (anchor.side == .old ? " (removed)" : "")
    }

    private func previewSend(_ review: ReviewTarget, startsOnMessage: Bool = false) {
        let kept = ReviewOrder.sorted(review.reviews.kept(review.sessionID), roots: repositories.map(\.root))
        guard !kept.isEmpty else { return }
        let carried = Set(kept.filter { $0.why != nil }.compactMap(\.questionID))
        let leftOut = review.reviews.questions(review.sessionID).count { !carried.contains($0.id) }
        let names = projectNames
        let busy = review.isBusy()
        dialogs.show(Dialog(
            title: "Send your review to \(review.agent.title)",
            message: "It goes to the session as one message. Anything you untick stays in the review for later.",
            content: AnyView(SendReviewSheet(
                agentTitle: review.agent.title, comments: kept,
                pendingCount: review.reviews.pending(review.sessionID).count, busy: busy,
                questionsLeftOut: leftOut, startsOnMessage: startsOnMessage,
                fileName: fileLabel,
                prompt: { ReviewPrompt.feedback($0, projectNames: names, note: $1) },
                lookFirst: { openFindings(review) },
                send: { sendReview(review, comments: $0, note: $1) })),
            actions: [],
            width: 620))
    }

    // Each review goes as a round of its own, so Chat can show it as one card and say
    // afterwards what came of each comment. Comments left unticked stay for the next.
    private func sendReview(_ review: ReviewTarget, comments: [ReviewComment], note: String) {
        guard !comments.isEmpty else { return }
        let prompt = ReviewPrompt.feedback(comments, projectNames: projectNames, note: note)
        let busy = review.isBusy()
        review.reviews.recordRound(comments, prompt: prompt, note: note,
                                   roots: repositories.map(\.root), in: review.sessionID)
        review.send(prompt)
        if let editing = commentDraft?.editing, comments.contains(where: { $0.id == editing }) { commentDraft = nil }
        focusedComment = nil
        let asked = review.reviews.questions(review.sessionID).count
        let stayed = asked == 0 ? "" : asked == 1 ? ". 1 question stayed here" : ". \(asked) questions stayed here"
        showToast((busy ? "\(counted(comments.count, "comment")) queued for \(review.agent.title)"
                        : "Sent \(counted(comments.count, "comment")) to \(review.agent.title)") + stayed,
                  action: "Open Chat", perform: review.openChat)
    }

    // A new change goes on its own, at once, as a round of its own. The rest of the
    // review stays where it is.
    private func sendChange(_ change: ReviewComment, review: ReviewTarget) {
        let prompt = ReviewPrompt.feedback([change], projectNames: projectNames, note: "")
        let busy = review.isBusy()
        review.reviews.recordRound([change], prompt: prompt, note: "",
                                   roots: repositories.map(\.root), in: review.sessionID)
        review.send(prompt)
        showToast(busy ? "Change queued for \(review.agent.title)" : "Sent the change to \(review.agent.title)",
                  action: "Open Chat", perform: review.openChat)
    }

    // MARK: Questions

    private func questionContext(_ review: ReviewTarget) -> QuestionContext {
        let conversation = review.conversation()
        return QuestionContext(agent: review.agent, executable: review.executable(review.agent),
                               directory: conversation?.directory ?? repoRoot,
                               repositories: reviewRepositories,
                               conversationID: conversation?.claudeSessionID,
                               recentChat: conversation?.recentChat ?? "")
    }

    private func questionThread(_ question: ReviewQuestion, review: ReviewTarget, showsBand: Bool = true) -> some View {
        let focused = focusedComment == question.id
        let reviews = review.reviews
        let sessionID = review.sessionID
        let waiting = question.changeID.flatMap { reviews.comment($0, in: sessionID) }
        let round = waiting == nil ? question.changeID.flatMap { reviews.round(sending: $0, in: sessionID) } : nil
        let sent = round?.comments.first { $0.id == question.changeID }
        return QuestionThreadView(
            question: question,
            place: place(root: question.root, path: question.path, anchor: question.isWhole ? nil : question.anchor),
            steps: reviews.questionSteps[question.id] ?? [],
            showsBand: showsBand, focused: focused,
            projectPath: repoRoot, textScale: appSettings.textSize.scale,
            change: waiting ?? sent, changeSent: sent == nil ? nil : round?.sent,
            followUp: {
                reviews.followUp($0, to: question.id, context: questionContext(review), in: sessionID)
                announce("Asked a follow-up")
            },
            resolve: {
                reviews.setResolved(question.id, true, in: sessionID)
                announce("Resolved")
            },
            reopen: { reviews.setResolved(question.id, false, in: sessionID) },
            retry: { reviews.retryQuestion(question.id, context: questionContext(review), in: sessionID) },
            delete: {
                reviews.deleteQuestion(question.id, in: sessionID)
                if focusedComment == question.id { focusedComment = nil }
                announce("Question deleted")
            },
            makeChange: question.isWhole ? nil : {
                guard let change = reviews.makeChange(from: question.id, in: sessionID) else { return }
                sendChange(change, review: review)
            },
            takeOut: {
                reviews.takeOutOfReview(question.id, in: sessionID)
                announce("Taken out of the review")
            },
            editChange: { text in
                if let id = question.changeID { reviews.update(id, body: text, in: sessionID) }
            },
            sendsQuestion: { on in
                if let id = question.changeID { reviews.setSendsQuestion(on, change: id, in: sessionID) }
            })
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Theme.plan : Theme.border, lineWidth: focused ? 2 : 1))
            .onTapGesture { focusedComment = question.id }
    }

    // Puts a question in focus and brings it on screen. One about the whole change has no
    // lines, so it opens in the list instead.
    private func focus(_ question: ReviewQuestion) {
        focusedComment = question.id
        revealSerial += 1
        guard !question.isWhole else { return }
        guard question.root == repoRoot else {
            selectRepository(question.root, question.path)
            return
        }
        if selected?.path != question.path, let file = files.first(where: { $0.path == question.path }) {
            mode = .changes
            select(file)
        }
        announce(question.spokenName)
    }

    private func askAboutWholeChange(_ review: ReviewTarget) {
        guard !wholeQuestion.isBlank else { return }
        let question = ReviewQuestion.whole(root: repoRoot, agent: review.agent, question: wholeQuestion.trimmed)
        review.reviews.ask(question, context: questionContext(review), in: review.sessionID)
        wholeQuestion = ""
        focusedComment = question.id
        announce("Asked. The answer appears in this list and stays here.")
    }

    @ViewBuilder private func questionsNavigator(_ review: ReviewTarget) -> some View {
        let asked = review.reviews.questions(review.sessionID).sorted { $0.created > $1.created }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    wholeChangeBox(review)
                    ReviewGroupHeader(title: "Asked in this review", count: asked.count)
                    if asked.isEmpty {
                        VStack(spacing: 6) {
                            Text("No questions yet").font(.system(size: 12.5, weight: .semibold))
                            Text("Click a line number and choose Ask a question. The answer comes here, never in the chat.")
                        }
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding(.vertical, 24).padding(.horizontal, 12)
                    }
                    ForEach(asked) { question in
                        Group {
                            if question.isWhole && focusedComment == question.id {
                                questionThread(question, review: review, showsBand: false)
                            } else {
                                questionItem(question, review: review)
                            }
                        }
                        .id(question.id)
                    }
                }
                .padding(10)
            }
            .onChange(of: focusedComment) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func wholeChangeBox(_ review: ReviewTarget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about the whole change").font(.system(size: 12.5, weight: .semibold))
            TextField("For example: why does each plugin get its own folder?", text: $wholeQuestion, axis: .vertical)
                .lineLimit(1...4)
                .appTextField()
                .onSubmit { askAboutWholeChange(review) }
                .accessibilityLabel("Question about the whole change")
            HStack(spacing: 8) {
                Label("Answered here, never in the chat", systemImage: "eye.slash")
                    .font(.system(size: 11)).foregroundStyle(Theme.plan)
                    .lineLimit(1)
                Spacer(minLength: 0)
                ActionButton(title: "Ask", tone: .plan, height: 26, size: 11.5, icon: "questionmark") {
                    askAboutWholeChange(review)
                }
                .disabled(wholeQuestion.isBlank)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.plan.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.plan.opacity(0.25)))
    }

    // A question in the list: where it is, where it stands, and the start of its answer.
    private func questionItem(_ question: ReviewQuestion, review: ReviewTarget) -> some View {
        let isFocused = focusedComment == question.id
        let lines = question.lastLine.map { "\(question.line)–\($0)" } ?? "\(question.line)"
        return VStack(alignment: .leading, spacing: 6) {
            Button { focus(question) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(question.isWhole ? "Whole change" : fileLabel(root: question.root, path: question.path) + " " + lines)
                            .font(.mono(10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        questionBadge(question, review: review)
                    }
                    Text(question.text).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    switch question.status {
                    case .answering:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(review.reviews.questionSteps[question.id]?.last ?? "Starting").lineLimit(1)
                        }
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    case .failed:
                        Text(question.failure ?? "").font(.system(size: 11.5)).foregroundStyle(Theme.warningText).lineLimit(2)
                    case .answered:
                        ReviewText(text: question.exchanges.last?.answer ?? "", size: 11.5, lineLimit: 3)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(question.spokenName)
            .accessibilityAddTraits(isFocused ? .isSelected : [])
            if question.status == .failed {
                HStack(spacing: 12) {
                    InlineLink(title: "Try again", size: 11.5) {
                        review.reviews.retryQuestion(question.id, context: questionContext(review), in: review.sessionID)
                    }
                    InlineLink(title: "Delete", size: 11.5, tint: Theme.deletion) {
                        review.reviews.deleteQuestion(question.id, in: review.sessionID)
                        announce("Question deleted")
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isFocused ? Theme.plan.opacity(0.08) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isFocused ? Theme.plan.opacity(0.3) : .clear))
        .hoverFill(cornerRadius: 8)
        .opacity(question.resolved ? 0.7 : 1)
    }

    private func questionBadge(_ question: ReviewQuestion, review: ReviewTarget) -> some View {
        let sent = question.changeID.map { review.reviews.round(sending: $0, in: review.sessionID) != nil } ?? false
        let waiting = question.changeID.map { review.reviews.comment($0, in: review.sessionID) != nil } ?? false
        let (text, ink): (String, Color) = switch question.status {
        case .answering: ("Answering…", Color.secondary)
        case .failed: ("Couldn't answer", Theme.warningText)
        case .answered:
            sent ? ("Became a change", Theme.accent)
                : waiting ? ("Change in review", Theme.accent)
                : question.resolved ? ("Resolved", Color.secondary) : ("Answered", Theme.plan)
        }
        return Text(text)
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(ink)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(ink.opacity(0.12)))
            .lineLimit(1).fixedSize()
    }

    // MARK: Review list

    // Where the focused comment stands in the whole review, with the way to the next.
    private var commentNavigation: some View {
        let list = orderedComments
        let index = list.firstIndex { $0.id == focusedComment }
        let here = openFileComments.count
        return HStack(spacing: 4) {
            Text(index.map { "Comment \($0 + 1) of \(list.count)" }
                 ?? counted(list.count, "comment") + (here > 0 ? ", \(here) here" : ""))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            GlyphButton(icon: "chevron.up", side: 24) { step(-1) }
                .appTooltip("Previous comment  ⌥↑")
                .accessibilityLabel("Previous comment")
            GlyphButton(icon: "chevron.down", side: 24) { step(1) }
                .appTooltip("Next comment  ⌥↓")
                .accessibilityLabel("Next comment")
        }
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

// The review bar's title: its icon in the accent, its words in the ink.
