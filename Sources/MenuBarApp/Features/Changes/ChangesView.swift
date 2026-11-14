import AppKit
import SwiftUI

// The uncommitted changes in a session's folder: the project directory itself, or the
// session's worktree. Sessions edit the real files there, so this screen is how you
// see what the agent did before you keep it. The diffs themselves never touch the tree;
// the header carries the little git a review ends in: switch branch, commit, pull, push.
struct ChangesView: View {
    let root: String
    let initiallySelectedPath: String?
    let repositories: [ChangesRepository]
    let requestedPath: String?
    // One screen serves every project in the workspace, so the navigator keeps its place
    // when another project is picked. Each project still gets a model of its own: git work
    // started for one project can only ever land in that project's model.
    @State private var models = ChangesModels()
    private var model: ChangesModel { models.model(for: root) }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var commentDraft: CommentDraft?
    @State private var toast: ReviewToast?
    // The second opinion dialog showing progress or findings, so a reviewer finishing
    // while it is open does not also raise a toast behind it.
    @State private var secondOpinionDialog: UUID?
    // An unplaced comment waiting for a line number to be clicked to move onto.
    @State private var reattaching: UUID?
    // Bumped to scroll the diff to the focused comment again, even when it has not moved.
    @State private var revealSerial = 0
    @State private var reviewKeys = WindowKeyHandler(handlesTyping: true)
    @AppStorage("changes.reviewCoachSeen") private var coachSeen = false
    private var focusedComment: UUID? {
        get { navigation.focusedComment }
        nonmutating set { navigation.focusedComment = newValue }
    }

    @State private var copied: GitInspector.CopyVersion?
    @State private var copiedPath: String?
    private var refreshFailed: Bool { model.refreshFailed }
    private var latestCommit: GitCommitSummary? { model.latestCommit }
    @State private var openLatestCommit = false
    @State private var fetches = 0
    // Until the project is read, it shows the last snapshot taken of its tree, so its
    // files are listed at once instead of after git.
    private var snapshot: GitSnapshot? { model.snapshot ?? gitStats.snapshot(at: root) }
    private var loading: Bool { model.loading }
    private var working: String? {
        get { model.working }
        nonmutating set { model.working = newValue }
    }
    private var mode: Mode {
        get { navigation.showingHistory ? .history : .changes }
        nonmutating set { navigation.showingHistory = newValue == .history }
    }
    private var commitDraft: ChangesCommitDraft { navigation.commitDraft(for: root) }
    @FocusState private var commitFocused: Bool
    @State private var commitSucceeded = false
    @FocusState private var pushFocused: Bool
    // Files the next commit leaves out. Tracking the exclusions rather than the picks
    // means a file that appears between refreshes starts selected, like everything else.
    private var excluded: Set<GitChange.ID> {
        get { commitDraft.excluded }
        nonmutating set { commitDraft.excluded = newValue }
    }
    private var amend: Bool {
        get { commitDraft.amend }
        nonmutating set { commitDraft.setAmend(newValue, lastMessage: snapshot?.lastCommitSubject) }
    }
    private var fileSelection: ChangeFileSelection {
        get { navigation.selections[root] ?? ChangeFileSelection() }
        nonmutating set { navigation.selections[root] = newValue }
    }
    private var commits: [GitCommitSummary]? { model.commits }
    private var historyNote: String? { model.historyNote }
    private var loadingHistory: Bool { model.loadingHistory }
    private var historySelection: CommitHistorySelection { navigation.history(for: root) }
    private var diff: FileDiff? { model.diff }
    private var diffText: NSAttributedString? { model.diffText }
    private var loadingDiff: Bool { model.loadingDiff }
    @State private var diffScroll = DiffTextView.Scroll.top
    // Gap rows git is reading the hidden lines for right now.
    private var expanding: Set<String> { model.expanding }
    // Projects whose first file has been picked, or that kept the one picked before.
    @State private var appliedInitialSelection: Set<String>

    private var files: [GitChange] { snapshot?.files ?? [] }
    private var selected: GitChange? { files.first { $0.id == fileSelection.activeID } }
    // The file the diff pane is drawing. While a newly selected file is being read this is
    // still the one before it, so the header, the cards and a press on a line all agree
    // with the code on screen.
    private var shownFile: GitChange? {
        guard diff != nil, let id = model.diffFileID else { return selected }
        return files.first { $0.id == id } ?? selected
    }
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
        _ = memory.commitDraft(for: root)
        isWorkspace = navigation != nil
        _appliedInitialSelection = State(initialValue: navigation?.selections[root] != nil
            && initiallySelectedPath == nil && requestedPath == nil ? [root] : [])
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
                            }
                            if !navigatorVisible { modeChoices }
                            content(narrowHistory: narrowHistory)
                            if !navigatorVisible && mode == .changes && !files.isEmpty { commitBar }
                        }.frame(maxWidth: .infinity).clipped()
                    }
                    .overlay {
                        ZStack(alignment: .leading) {
                            if navigatorVisible && isWorkspace {
                                WorkspaceSplitHandle(width: Binding(get: { treeWidth }, set: { treeWidth = $0 }), displayedWidth: width,
                                                     availableWidth: geometry.size.width)
                                    .offset(x: width + (ExplorerSplitLayout.dividerWidth - ExplorerSplitLayout.handleWidth) / 2)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .background(Theme.background)
        // The toast sits in a ZStack that is always there. When an overlay's content is a
        // bare `if`, SwiftUI drops the overlay's alignment.
        .overlay(alignment: .bottom) {
            ZStack {
                if let toast {
                    ReviewToastView(toast: toast) { self.toast = nil }
                        .transition(.opacity)
                        .id(toast.id)
                }
            }
            .padding(.bottom, Space.xl)
        }
        .overlay { wholeChangeCard }
        .motion(Motion.reveal, value: navigation.askingWholeChange)
        .overlay(alignment: .top) {
            if loading && snapshot != nil {
                Breathing { Rectangle().fill(Theme.accent) }
                    .frame(height: 2).allowsHitTesting(false)
                    .accessibilityLabel("Refreshing Git status")
            }
        }
        .background(WindowKeyAnchor(handler: reviewKeys))
        .motion(Motion.reveal, value: toast?.id)
        .task(id: toast?.id) {
            guard let toast else { return }
            try? await Task.sleep(for: .seconds(toast.action == nil ? 3.2 : 6))
            if self.toast?.id == toast.id { self.toast = nil }
        }
        .onAppear {
            reviewKeys.start { handleReviewKey($0) }
            takeSecondOpinionRequest()
        }
        .onDisappear { reviewKeys.stop() }
        .onChange(of: review.map { $0.reviews.runs($0.sessionID) } ?? []) { old, new in
            reportFinishedRuns(old: old, new: new)
        }
        .onChange(of: navigation.secondOpinionRequest) { _, _ in takeSecondOpinionRequest() }
        .task(id: root) {
            if model.snapshot == nil { model.snapshot = gitStats.snapshot(at: root) }
            await reload()
            await refreshOtherProjects()
        }
        .onChange(of: root) { _, root in switchedProject(root) }
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
        .onChange(of: threadLineIDs) { _, ids in
            guard ids != model.renderedThreads else { return }
            diffScroll = .hold
            Task { await renderDiff() }
        }
        .onChange(of: fileSelection.activeID) { _, path in
            if commentDraft?.path != path { commentDraft = nil }
        }
        .onChange(of: diff) { _, _ in followDraft() }
    }

    private var syncStatus: String {
        snapshot?.syncDescription(remoteUnavailable: refreshFailed) ?? "Checking branch status"
    }

    private var cleanContent: some View {
        VStack(spacing: Space.xl) {
            PaneMessage(icon: "checkmark.seal", title: "No uncommitted changes",
                        detail: "\(repositoryName) has no pending changes.\n" + syncStatus) {
                ActionButton(title: "View commit history") { mode = .history }
            }
            .frame(maxHeight: 260)
            if let subject = snapshot?.lastCommitSubject {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text("Latest commit").font(Typography.label)
                    Button { openLatestCommit = true; mode = .history } label: {
                        HStack {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            Text(subject).font(Typography.body.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .hoverFill()
                    if let latestCommit {
                        Text("\(latestCommit.shortHash) · \(latestCommit.author) · \(latestCommit.relativeDate)")
                            .font(Typography.caption).foregroundStyle(.secondary)
                    } else if let date = snapshot?.lastCommitDate {
                        Text(date, style: .relative).font(Typography.caption).foregroundStyle(.secondary)
                    }
                    Text(snapshot?.upstream.map { "Tracking " + $0 } ?? "No upstream branch")
                        .font(Typography.data).foregroundStyle(.secondary)
                }
                .padding(Space.xxl).background(Theme.card, in: RoundedRectangle(cornerRadius: Radius.floating))
                .overlay(RoundedRectangle(cornerRadius: Radius.floating).stroke(Theme.border))
                .frame(maxWidth: 660)
            }
            Spacer()
        }.padding(Space.xxxl).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func versionHeader(_ title: String, version: GitInspector.CopyVersion, file: GitChange) -> some View {
        HStack {
            Text(title).font(Typography.detail)
            Spacer()
            copyButton(version, file: file, label: "Copy")
        }.frame(maxWidth: .infinity)
    }

    private func copyButton(_ version: GitInspector.CopyVersion, file: GitChange, label: String) -> some View {
        let isCopied = copied == version && copiedPath == file.id
        return Button {
            copy(version, file: file)
        } label: {
            Label {
                Text(isCopied ? "Copied" : label)
            } icon: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
            .font(Typography.detail).padding(Space.md)
            .foregroundStyle(isCopied ? Theme.addition : Color.primary)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.control)).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .hoverLift()
        .motion(Motion.pop, value: isCopied)
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
        isWorkspace || mode == .history || width >= 650 || !files.isEmpty
    }

    private var workspaceBand: some View {
        HStack {
            Text("Workspace").font(Typography.body.weight(.semibold))
            Spacer()
            Text(counted(repositories.count, "project"))
                .font(Typography.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.xxl)
        .headerBand()
    }

    // The header names the project only while the navigator is hidden, so the name is
    // never shown twice.
    private func header(compact: Bool, namesProject: Bool) -> some View {
        VStack(spacing: Space.sm) {
            if let snapshot, snapshot.state == .ready {
                HStack(spacing: Space.md) {
                    if namesProject && !compact { projectLabel }
                    branchControl(snapshot)
                    if !compact {
                        Spacer(minLength: 0)
                        ViewThatFits(in: .horizontal) {
                            Text(syncStatus).font(Typography.caption).foregroundStyle(.secondary).fixedSize()
                            Color.clear.frame(width: 0, height: 0)
                        }.layoutPriority(-1)
                        remoteControls(snapshot, compact: false)
                    }
                }
                if compact {
                    HStack(spacing: Space.md) {
                        if namesProject { projectLabel }
                        Spacer(minLength: 0)
                        remoteControls(snapshot, compact: true)
                    }
                }
            }
        }
        .padding(.horizontal, compact ? 12 : 20)
        .headerBand(height: compact ? 82 : Theme.headerHeight)
    }

    private func branchControl(_ snapshot: GitSnapshot) -> some View {
        Button { showBranches() } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                Text(snapshot.branch).font(Typography.code.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .padding(Space.md).background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.control))
            .contentShape(Rectangle())
            .hoverLift()
        }.buttonStyle(.plain)
            .appTooltip("Branches and actions: " + snapshot.branch + " (⌘B)")
            .accessibilityLabel("Branches and actions, current branch " + snapshot.branch)
            .disabled(busy)
    }

    private func remoteControls(_ snapshot: GitSnapshot, compact: Bool) -> some View {
        HStack(spacing: Space.sm) {
            if commitSucceeded {
                HStack(spacing: Space.xs) {
                    ChangesSuccessMark()
                    if !compact { Text("Committed locally").font(Typography.caption) }
                }
                .foregroundStyle(Theme.accent)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Committed locally. Ready to push.")
                .transition(.opacity)
            }
            pushButton(snapshot, compact: compact)
            Button {
                fetches += 1
                Task {
                    await reload(fetchOrigin: true)
                    announce(self.snapshot?.state != .ready ? "Could not read Git status. Try again."
                        : refreshFailed ? "Fetch from origin failed. Try again." : "Git status refreshed.")
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .actOut("arrow.clockwise", trigger: fetches)
                    .padding(Space.md).contentShape(Rectangle())
                    .hoverLift(amount: Motion.smallLift)
            }.buttonStyle(.plain).disabled(busy)
                .appTooltip("Fetch from origin").accessibilityLabel("Fetch from origin")
            Image(systemName: "ellipsis").padding(Space.md).contentShape(Rectangle())
                .hoverLift(amount: Motion.smallLift)
                .appMenu { repositoryMenu(snapshot) }
                .accessibilityLabel("Repository actions for " + repositoryName).disabled(busy)
        }
    }

    // A menu when there is a choice to make, a plain name when there is not.
    @ViewBuilder private var projectLabel: some View {
        let label = HStack(spacing: Space.sm) {
            ProjectDot(tint: Theme.projectTint(for: repositoryName), size: 8)
            Text(repositoryName).font(Typography.body.weight(.semibold)).lineLimit(1)
            if repositories.count > 1 { Image(systemName: "chevron.down").font(Font.system(size: Typography.Size.micro)) }
        }
        if repositories.count > 1 {
            label.padding(Space.sm).surface(Theme.field, cornerRadius: Radius.control).contentShape(Rectangle())
                .hoverLift()
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
        case .publish: title = compact ? "Publish" : "Publish branch"
        default:
            if !snapshot.hasCommits { title = "No commits" }
            else if snapshot.upstream != nil && !snapshot.trackingKnown { title = "Status unknown" }
            else { title = "Up to date" }
        }
        return ActionButton(title: title, tone: .outlined,
                            height: ControlHeight.md, size: Typography.Size.detail, icon: action == nil ? "checkmark" : "arrow.up") {
            pushFocused = true
            confirmPush(snapshot)
        }
        .focused($pushFocused)
        .overlay(RoundedRectangle(cornerRadius: Radius.control)
            .stroke(pushFocused ? Theme.accent : .clear, lineWidth: 2))
        .accessibilityLabel(title)
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
        entries.append(.item("Branches and actions", icon: "point.topleft.down.to.point.bottomright.curvepath") { showBranches() })
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
            [ChangesNavigatorItem(root: repository.root, path: nil)]
                + (collapsedRepositories.contains(repository.root) ? [] : shownChanges(repository.root).flatMap { file in
                    [ChangesNavigatorItem(root: repository.root, path: file.id)]
                        + listedNotes(file, in: repository.root).map {
                            ChangesNavigatorItem(root: repository.root, path: file.id, note: $0.id)
                        }
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
        if mode == .changes, let item = navigatorCursor, let path = item.path, item.note == nil,
           direction == .left || direction == .right {
            let key = notesKey(item.root, path)
            if direction == .left { navigation.foldedNotes.insert(key) } else { navigation.foldedNotes.remove(key) }
            return
        }
        guard direction == .up || direction == .down,
              let next = ChangesNavigatorItem.next(after: navigatorCursor,
                  step: direction == .up ? -1 : 1, in: navigatorItems) else { return }
        navigatorCursor = next
        if let id = next.note {
            if let note = note(id, at: next) { openNote(note) }
        } else if mode == .history {
            if next.root == root, let commit = commits?.first(where: { $0.hash == next.path }) {
                historySelection.select(commit)
                announce(commit.subject)
            }
        } else if next.root == root, let file = files.first(where: { $0.id == next.path }) {
            mode = .changes
            select(file)
        }
    }

    private var modeChoices: some View {
        HStack(spacing: Space.xs) {
            ChoicePill(title: "Changes \(navigatorFileCount)", selected: mode == .changes) { mode = .changes }
            ChoicePill(title: "History", selected: mode == .history) { mode = .history }
            Spacer(minLength: 0)
        }.padding(Space.lg)
    }

    private var workspaceNavigator: some View {
        VStack(spacing: 0) {
            modeChoices
            if mode == .history { historyFilterField }
            if mode == .changes && navigatorFileCount > 0 { changesFilterRow }
            filesNavigator
            if mode == .changes, let review { unsentStrip(review) }
            if mode == .changes && !files.isEmpty { commitBar }
        }
        .motion(Motion.reveal, value: unsentCount)
        .background(Theme.card)
    }

    private var navigatorFileCount: Int {
        repositories.reduce(0) { total, repository in total + changes(in: repository.root).count }
    }

    // MARK: - Comments under their files

    // The repository a project's comments are stored against, which is git's own root.
    private func gitRoot(_ repositoryRoot: String) -> String {
        repositoryRoot == root ? repoRoot : gitStats.snapshot(at: repositoryRoot)?.root ?? repositoryRoot
    }

    private func changes(in repositoryRoot: String) -> [GitChange] {
        repositoryRoot == root ? files : gitStats.snapshot(at: repositoryRoot)?.files ?? []
    }

    private func notesKey(_ repositoryRoot: String, _ path: String) -> String {
        gitRoot(repositoryRoot) + "/" + path
    }

    private func notes(_ file: GitChange, in repositoryRoot: String) -> FileNotes {
        guard let review else { return FileNotes(unsent: [], sent: [], questions: []) }
        return FileNotes.on(root: gitRoot(repositoryRoot), path: file.path, in: review.reviews, session: review.sessionID)
    }

    // The comments listed under a file right now: none while folded away.
    private func listedNotes(_ file: GitChange, in repositoryRoot: String) -> [FileNote] {
        let key = notesKey(repositoryRoot, file.path)
        guard review != nil, !navigation.foldedNotes.contains(key) else { return [] }
        return notes(file, in: repositoryRoot).shown(includingResolved: navigation.resolvedShown.contains(key))
    }

    private func note(_ id: UUID, at item: ChangesNavigatorItem) -> FileNote? {
        guard let file = changes(in: item.root).first(where: { $0.id == item.path }) else { return nil }
        return notes(file, in: item.root).notes.first { $0.id == id }
    }

    private func openNote(_ note: FileNote) {
        switch note.source {
        case .unsent(let comment), .sent(let comment, _): focus(comment)
        case .question(let question): focus(question)
        }
    }

    private func shownChanges(_ repositoryRoot: String) -> [GitChange] {
        let query = navigation.fileFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return changes(in: repositoryRoot) }
        return changes(in: repositoryRoot).filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    private var isFilteringFiles: Bool {
        !navigation.fileFilter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var changesFilterRow: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(Typography.label)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter files", text: Binding(get: { navigation.fileFilter }, set: { navigation.fileFilter = $0 }))
                .textFieldStyle(.plain)
                .font(Typography.body)
                .accessibilityLabel("Filter changed files by name")
                .onMoveCommand { direction in
                    if direction == .up || direction == .down { moveNavigator(direction) }
                }
        }
        .padding(.horizontal, Space.md)
        .frame(height: ControlHeight.md)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.border))
        .padding(.horizontal, Space.lg).padding(.bottom, Space.xxs)
    }

    @ViewBuilder private func fileNotes(_ file: GitChange, in repositoryRoot: String) -> some View {
        let key = notesKey(repositoryRoot, file.path)
        let all = notes(file, in: repositoryRoot)
        if review != nil, !all.isEmpty, !navigation.foldedNotes.contains(key) {
            let showingResolved = navigation.resolvedShown.contains(key)
            VStack(alignment: .leading, spacing: Space.xxs) {
                ForEach(all.shown(includingResolved: showingResolved)) { note in
                    noteRow(note, file: file, in: repositoryRoot)
                }
                if all.resolvedCount > 0 {
                    InlineLink(title: showingResolved ? "Hide resolved" : "\(all.resolvedCount) resolved",
                               size: Typography.Size.detail, tint: Color.secondary) {
                        if !navigation.resolvedShown.insert(key).inserted { navigation.resolvedShown.remove(key) }
                    }
                    .padding(.horizontal, Space.md).padding(.vertical, Space.xxs)
                }
            }
            .padding(.leading, Space.md)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.hairline).frame(width: 1.5)
            }
            .padding(.leading, 30).padding(.top, 1).padding(.bottom, Space.xs)
            .transition(.fold)
        }
    }

    private func noteRow(_ note: FileNote, file: GitChange, in repositoryRoot: String,
                         fileLabel: String? = nil) -> some View {
        let item = ChangesNavigatorItem(root: repositoryRoot, path: file.id, note: note.id)
        var stop: (() -> Void)?
        if case .question(let question) = note.source, question.status == .answering, let review {
            stop = { stopAnswering(question, review: review) }
        }
        return FileNoteRow(note: note, agentTitle: review?.agent.title ?? "Agent", fileLabel: fileLabel,
                           focused: focusedComment == note.id, showsCursor: showsCursor(item),
                           open: {
                               navigatorCursor = item
                               navigatorCursorVisible = false
                               navigatorFocused = true
                               openNote(note)
                           }, stop: stop)
            .id(item)
    }

    private func notesBadge(_ file: GitChange, in repositoryRoot: String) -> some View {
        let key = notesKey(repositoryRoot, file.path)
        let all = notes(file, in: repositoryRoot)
        return Group {
            if review != nil, !all.isEmpty {
                FileNotesBadge(notes: all, expanded: !navigation.foldedNotes.contains(key)) {
                    if !navigation.foldedNotes.insert(key).inserted { navigation.foldedNotes.remove(key) }
                }
                .transition(.fadeIn)
            }
        }
    }

    // Files that have since been committed or reverted but still have comments open on
    // them. The comments still go with the review, so they stay reachable below the list.
    private func settledFiles(_ review: ReviewTarget) -> [SettledFile] {
        let changed = Set(repositories.flatMap { repository in
            changes(in: repository.root).map { notesKey(repository.root, $0.path) }
        })
        let unsent: [SettledFile] = review.reviews.comments(review.sessionID).map { SettledFile(root: $0.root, path: $0.path) }
        let sent: [SettledFile] = review.reviews.threads(review.sessionID)
            .filter { !$0.round.resolved.contains($0.comment.id) }
            .map { SettledFile(root: $0.comment.root, path: $0.comment.path) }
        let asked: [SettledFile] = review.reviews.questions(review.sessionID)
            .filter { !$0.isWhole && !$0.resolved }
            .map { SettledFile(root: $0.root, path: $0.path) }
        var seen = Set<String>()
        return (unsent + sent + asked)
            .filter { !changed.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { $0.id < $1.id }
    }

    @ViewBuilder private var settledNotes: some View {
        if let review {
            let settled = settledFiles(review)
            if !settled.isEmpty {
                sectionHeader("No changes left")
                ForEach(settled) { settled in
                    let file = GitChange(path: settled.path, kind: .modified, isStaged: false, isUnstaged: false, isBinary: false)
                    let all = FileNotes.on(root: settled.root, path: settled.path, in: review.reviews, session: review.sessionID)
                    ForEach(all.open) { note in
                        noteRow(note, file: file, in: settled.root, fileLabel: fileLabel(root: settled.root, path: settled.path))
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Typography.label).foregroundStyle(.secondary)
            .padding(.horizontal, Space.sm).padding(.top, Space.lg).padding(.bottom, Space.xxs)
            .accessibilityAddTraits(.isHeader)
    }

    // Comments not sent yet wait just above Commit, so they are not forgotten before the
    // work is kept. Replies not yet read are pointed at from here too. Findings alone do not
    // show the strip, since the second opinion lineup already points at them.
    @ViewBuilder private func unsentStrip(_ review: ReviewTarget) -> some View {
        let all = review.reviews.comments(review.sessionID)
        let kept = all.filter { !$0.isPending }
        let pending = all.count - kept.count
        let unread = review.reviews.unreadCount(review.sessionID)
        if !kept.isEmpty || unread > 0 {
            HStack(spacing: Space.md) {
                if !kept.isEmpty {
                    Image(systemName: "text.bubble").font(Typography.detail).foregroundStyle(Theme.plan)
                        .accessibilityHidden(true)
                    Text("\(counted(kept.count, "comment")) not sent yet")
                        .font(Typography.detail.weight(.medium)).foregroundStyle(Theme.plan)
                        .lineLimit(1).truncationMode(.tail)
                        .contentTransition(.numericText())
                    Image(systemName: "ellipsis").font(Typography.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, Space.xs).frame(height: 22).contentShape(Rectangle())
                        .hoverLift(amount: Motion.smallLift)
                        .appMenu {
                            var entries: [MenuEntry] = [
                                .item("Preview message") { previewSend(review, startsOnMessage: true) },
                            ]
                            if pending > 0 {
                                entries.append(.item("Look at findings") { openFindings(review) })
                            }
                            entries.append(.item("Clear review", kind: .destructive) {
                                confirmClear(review, kept: kept.count, pending: pending)
                            })
                            return entries
                        }
                        .accessibilityLabel("Review actions")
                }
                if unread > 0 {
                    Button(action: nextUnread) {
                        Text(unread == 1 ? "1 reply" : "\(unread) replies")
                            .font(Typography.label).foregroundStyle(Theme.plan)
                            .lineLimit(1).fixedSize()
                            .contentTransition(.numericText())
                            .contentShape(Rectangle())
                            .hoverLift()
                    }
                    .buttonStyle(.plain)
                    .appTooltip("Open the next reply")
                    .accessibilityLabel(unread == 1 ? "1 reply to read" : "\(unread) replies to read")
                }
                Spacer(minLength: 4)
                if !kept.isEmpty {
                    ActionButton(title: "Send to \(review.agent.title)", tone: .green, height: ControlHeight.md, size: Typography.Size.detail,
                                 icon: "paperplane.fill") { previewSend(review) }
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
            .background(Theme.card)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            .transition(.fadeIn)
        }
    }

    // Only the user's own comments move the strip. Replies arrive from the agent, so the
    // strip shows them without motion.
    private var unsentCount: Int {
        guard let review else { return 0 }
        return review.reviews.comments(review.sessionID).filter { !$0.isPending }.count
    }

    private var filesNavigator: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.xxs) {
                        ForEach(repositories) { repository in
                            if mode == .history { historyProject(repository) } else { changesProject(repository) }
                        }
                        if mode == .changes {
                            if isFilteringFiles && repositories.allSatisfy({ shownChanges($0.root).isEmpty }) {
                                Text("No matching files")
                                    .font(Typography.detail).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity).padding(.vertical, Space.xl)
                            }
                            settledNotes
                        }
                    }.padding(Space.md)
                    .smoothlyResizes(when: mode == .history ? collapsedHistories : collapsedRepositories)
                    .smoothlyResizes(when: navigation.foldedNotes)
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
                    if let item = navigatorCursor, let id = item.note {
                        if let note = note(id, at: item) { openNote(note) }
                        return .handled
                    }
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
                // A comment put in focus from the diff, the chat or the keyboard is brought
                // into view under its file, opening the file's comments if they were folded.
                .onChange(of: focusedComment) { _, id in
                    guard let id, mode == .changes else { return }
                    if let item = navigatorItems.first(where: { $0.note == id }) {
                        proxy.scrollTo(item)
                    } else if let review, let comment = review.reviews.comment(id, in: review.sessionID)
                                ?? review.reviews.threads(review.sessionID).first(where: { $0.comment.id == id })?.comment {
                        navigation.foldedNotes.remove(comment.root + "/" + comment.path)
                    } else if let review, let question = review.reviews.question(id, in: review.sessionID) {
                        if question.isWhole { openWholeChangeThread(question.id) }
                        else { navigation.foldedNotes.remove(question.root + "/" + question.path) }
                    }
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
        let changes = shownChanges(repository.root)
        let item = ChangesNavigatorItem(root: repository.root, path: nil)
        if !isFilteringFiles || !changes.isEmpty {
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
        }
        // Each file is a row of the lazy stack itself, not part of one block per project,
        // so only the rows on screen are built. Its comments follow as a row of their own.
        if !collapsedRepositories.contains(repository.root) {
            ForEach(changes) { file in
                Group {
                    if repository.root == root {
                        row(file)
                    } else {
                        otherProjectRow(file, in: repository.root)
                    }
                }
                .overlay {
                    // Lit while a reference to this file in an answer is under the pointer.
                    let cited = navigation.citeHover?.sameFile(root: repository.root, path: file.path) == true
                    RoundedRectangle(cornerRadius: Radius.control)
                        .fill(Theme.plan.opacity(cited ? 0.08 : 0))
                        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.plan.opacity(cited ? 0.45 : 0)))
                        .motion(Motion.hover, value: cited)
                        .allowsHitTesting(false)
                }
                .modifier(ProjectRule())
                .id(ChangesNavigatorItem(root: repository.root, path: file.id))
                .transition(.fold)
                fileNotes(file, in: repository.root)
                    .modifier(ProjectRule())
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
            HStack(spacing: Space.md) {
                StatusChip(kind: file.kind)
                fileName(file)
                notesBadge(file, in: repositoryRoot)
                counts(file)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control)
                    .stroke(showsCursor(item) ? Theme.accent : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.control)
    }

    // MARK: - History navigator

    private var historyFilterField: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "magnifyingglass")
                .font(Typography.label)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter commits by title or hash",
                      text: Binding(get: { historyFilter }, set: { historyFilter = $0 }))
                .textFieldStyle(.plain)
                .font(Typography.body)
                .accessibilityLabel("Filter commits by title or hash")
                .onMoveCommand { direction in
                    if direction == .up || direction == .down { moveNavigator(direction) }
                }
        }
        .padding(.horizontal, Space.md)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.border))
        .padding(.horizontal, Space.lg).padding(.top, Space.lg).padding(.bottom, Space.xxs)
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
                        .font(Typography.caption).foregroundStyle(.secondary)
                        .padding(.leading, 36).padding(.vertical, Space.sm)
                }
                ForEach(CommitDay.groups(shown)) { group in
                    Text(group.title)
                        .font(Font.system(size: Typography.Size.micro)).foregroundStyle(.tertiary)
                        .padding(.leading, 36).padding(.top, Space.md).padding(.bottom, Space.xxs)
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
            HStack(spacing: Space.md) {
                Circle()
                    .fill(isSelected ? Theme.accent : Color.secondary.opacity(0.45))
                    .frame(width: 6, height: 6)
                Text(commit.subject)
                    .font(Typography.detail)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(commit.date.map(RelativeTime.short) ?? commit.relativeDate)
                    .font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.leading, Space.xxl).padding(.trailing, Space.md)
            .frame(height: 28)
            .background(isSelected ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: Radius.inset))
            .overlay(RoundedRectangle(cornerRadius: Radius.inset).stroke(isSelected ? Theme.accent.opacity(0.3) : .clear))
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3).padding(.vertical, Space.sm)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.inset).stroke(showsCursor(item) ? Theme.accent : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.inset)
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
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(file.fileName).font(Typography.detail.weight(.medium)).lineLimit(1)
            Text((file.path as NSString).deletingLastPathComponent)
                .font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary).lineLimit(1)
            if let original = file.originalPath {
                Text("was \(original)").font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .appTooltip(file.path)
    }

    private func showBranches() {
        guard !busy else { return }
        let operationRoot = repoRoot
        dialogs.show(Dialog(title: "Branches", content: AnyView(
            BranchBrowserView(root: operationRoot, repository: repositoryName, mergeInitially: false) {
                await reload()
            }), actions: [], width: 780, isModal: true, framesItself: true, fitsWindow: true))
    }

    // MARK: - Commit

    private var commitBlocker: String? {
        if files.contains(where: { $0.kind == .conflicted }) { return "Resolve conflicts to commit" }
        return selectedFiles.isEmpty ? "Pick at least one file" : nil
    }

    private var commitBar: some View {
        HStack(spacing: Space.md) {
            Toggle(isOn: Binding(
                get: { selectedFiles.count == files.count },
                set: { on in excluded = on ? [] : Set(files.map(\.id)) }
            )) {
                Text(selectedFiles.count == files.count
                     ? "All \(counted(files.count, "file"))"
                     : "\(selectedFiles.count) of \(files.count) files")
                    .font(Typography.detail.weight(.medium))
            }.toggleStyle(.appCheckbox)
            Spacer(minLength: 0)
            let conflicted = files.contains { $0.kind == .conflicted }
            ActionButton(title: conflicted ? "Resolve conflicts to commit"
                            : selectedFiles.isEmpty ? "Commit…" : "Commit \(counted(selectedFiles.count, "file"))…",
                         tone: .green, height: ControlHeight.lg) { openCommitDialog() }
                .disabled(busy || commitBlocker != nil)
                .focused($commitFocused)
                .overlay(RoundedRectangle(cornerRadius: Radius.control)
                    .stroke(commitFocused ? Theme.accent : .clear, lineWidth: 2))
                .appTooltip(commitBlocker ?? "Commit (⌘↵)")
                .layoutPriority(1)
        }
        .padding(Space.lg).background(Theme.card).disabled(busy)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func openCommitDialog() {
        let chosen = selectedFiles
        guard !busy, commitBlocker == nil, let snapshot else { return }
        mode = .changes
        let operationRoot = repoRoot
        let dialog = CommitDialogModel(draft: commitDraft, files: chosen, canAmend: canAmend,
                                       lastSubject: snapshot.lastCommitSubject) { message, files, amend in
            working = amend ? "Amending…" : "Committing…"
            announce(working ?? "Committing…")
            let error = await GitActions.commitSelected(message: message, files: files,
                                                        amend: amend, at: operationRoot)
            await reload()
            working = nil
            if error != nil { announce("Could not create the commit. Your message has been kept.") }
            return error
        }
        dialogs.show(Dialog(title: dialog.title, content: AnyView(
            CommitDialogView(model: dialog, repository: repositoryName, branch: snapshot.branch) { amended in
                didCommit(amended: amended)
            }), actions: [], onCancel: { commitFocused = true },
            width: 520, isModal: true, framesItself: true, fitsWindow: true, hugsContent: true,
            canDismiss: { !dialog.isCommitting }))
    }

    private func didCommit(amended: Bool) {
        commitSucceeded = true
        let done = amended ? "Commit amended locally" : "Committed locally"
        let push = snapshot?.remoteActions.first {
            switch $0 {
            case .push, .publish: true
            case .pull: false
            }
        }
        switch push {
        case .push(let count):
            showToast(done, action: "Push \(counted(count, "commit"))") { if let snapshot { confirmPush(snapshot) } }
        case .publish:
            showToast(done, action: "Publish branch") { if let snapshot { confirmPush(snapshot) } }
        default:
            showToast(done)
        }
    }

    // MARK: - Content

    @ViewBuilder private func content(narrowHistory: Bool) -> some View {
        switch snapshot?.state {
        case .ready:
            Group {
                if mode == .history {
                    historyContent(narrow: narrowHistory)
                } else if files.isEmpty {
                    cleanContent
                } else {
                    HStack(spacing: 0) {
                        if let file = shownFile {
                            diffPane(truncationHint: "Open the file to see the rest.",
                                     reveal: { reveal(file) }) {
                                fileName(file)
                                counts(file)
                                if fileSelection.ids.count > 1 {
                                    Text("\(fileSelection.ids.count) files selected")
                                        .font(Typography.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .transition(.fadeIn)
                        } else {
                            PaneMessage(icon: "doc.text", title: "Select a file",
                                        detail: "Choose a changed file in the workspace navigator.")
                                .transition(.fadeIn)
                        }
                    }
                    .motion(Motion.reveal, value: shownFile == nil)
                }
            }
            .id(mode)
            .transition(.headerPage(reduceMotion: reduceMotion))
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
            HStack(spacing: Space.md) {
                if mode == .changes {
                    Toggle(isOn: Binding(
                        get: { !excluded.contains(file.id) },
                        set: { on in
                            if on { excluded.remove(file.id) } else { excluded.insert(file.id) }
                        }
                    )) { EmptyView() }
                    .toggleStyle(.appCheckbox)
                    .appTooltip("Include in the commit")
                    .accessibilityLabel("Include " + file.path + " in commit")
                    .disabled(busy)
                }

                StatusChip(kind: file.kind)

                fileName(file)

                if file.isStaged && file.isUnstaged {
                    Text("partly staged").font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary)
                }

                notesBadge(file, in: root)

                counts(file)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .surface(isSelected ? Theme.accent.opacity(0.06) : .clear, cornerRadius: Radius.control,
                     border: isSelected ? Theme.accent.opacity(0.25) : .clear)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control)
                    .stroke(showsCursor(ChangesNavigatorItem(root: root, path: file.id)) ? Theme.accent : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: Radius.control)
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

    private func beginCommit(with chosen: [GitChange]) {
        excluded = Set(files.map(\.id)).subtracting(chosen.map(\.id))
        openCommitDialog()
    }

    @ViewBuilder private func counts(_ file: GitChange) -> some View {
        if file.isBinary {
            Text("binary").font(Typography.caption).foregroundStyle(.secondary)
        } else {
            HStack(spacing: Space.sm) {
                Text(file.added.map { "+\($0)" } ?? "")
                    .foregroundStyle(Theme.addition)
                Text(file.removed.map { "-\($0)" } ?? "")
                    .foregroundStyle(Theme.deletion)
            }
            .font(Typography.data.weight(.medium))
        }
    }

    // MARK: - Diff

    // History and file reviews share the same diff surface.
    private func diffPane<Title: View>(truncationHint: String, reveal: (() -> Void)? = nil,
                                       @ViewBuilder title: () -> Title) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.md) {
                title()
                // Beside the title rather than among the controls, so the buttons do not
                // shift under the pointer while comments are stepped through.
                if loadingDiff { ChangesProgressLabel(title: "Reading diff…", compact: true) }
                Spacer()
                if mode == .changes, review != nil, !orderedComments.isEmpty { commentNavigation }
                if mode == .changes, let file = shownFile {
                    Image(systemName: "ellipsis").padding(Space.md).contentShape(Rectangle())
                        .hoverLift(amount: Motion.smallLift)
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
                    Image(systemName: "xmark").font(Typography.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .hoverLift(amount: Motion.smallLift)
                .accessibilityLabel("Close diff")
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.xxl)
            .padding(.vertical, Space.md)

            if mode == .changes, let file = shownFile, !file.isBinary, diff?.images == nil {
                if appSettings.changesDiffLayout == .sideBySide {
                    HStack {
                        versionHeader("Last commit", version: .before, file: file)
                        versionHeader("Working tree", version: .after, file: file)
                    }.padding(.horizontal, Space.xxl).padding(.vertical, Space.md)
                }
            }
            if mode == .changes, let review {
                let placement = placement
                if !placement.unplaced.isEmpty { unplacedComments(placement.unplaced, review: review) }
                if !placement.onFile.isEmpty { fileComments(placement.onFile, review: review) }
            }
            // A new file's diff fades in once it has been read. The one before goes at once,
            // so two diffs are never drawn over each other.
            diffBody(truncationHint: truncationHint)
                .id(mode == .changes ? shownFile?.id : nil)
                .transition(.fadeIn)
                .motion(Motion.reveal, value: mode == .changes ? shownFile?.id : nil)
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        if mode == .changes, review != nil, !coachSeen, diff?.lines.isEmpty == false,
                           orderedComments.isEmpty, commentDraft == nil {
                            coachMark.padding(.leading, 70).padding(.top, 40)
                                .transition(.asymmetric(insertion: .opacity.animation(Motion.reveal),
                                                        removal: .opacity.animation(Motion.leave)))
                        }
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
                .font(Typography.body)
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
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.xxl)
                .padding(.vertical, Space.md)
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
            ChangesLoadingPlaceholder(title: "Loading history…").padding(Space.xxxl).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        let allUntracked = files.allSatisfy(\.isUntracked)
        var rows = files.map { file in
            Dialog.Impact.Row(title: file.path, detail: file.isUntracked
                ? "This untracked file will be moved to the Trash."
                : "Uncommitted changes will be removed. The file returns to its last committed state.")
        }
        rows.append(.init(title: "Your commits and other changed files",
                          detail: "Your saved history and changes in other files stay.", kept: true))
        if !allUntracked {
            rows.append(.init(title: "The last committed versions",
                              detail: "Tracked files are restored from the last commit.", kept: true))
        }
        dialogs.show(.impact(files.count > 1 ? "Discard changes in \(files.count) files?"
                : (file.isUntracked ? "Move this file to the Trash?" : "Discard changes?"),
            subject: .init(name: repositoryName), rows: rows,
            warning: allUntracked ? "Git has no copy of these files. They can be restored from the Trash until it is emptied."
                : "Discarded uncommitted changes in tracked files cannot be restored from Git.",
            action: allUntracked ? "Move to Trash" : "Discard changes") {
                perform("Discarding…", failure: "Could not discard changes") {
                    await GitActions.discard(files, at: root)
                }
            })
    }

    private func confirmPush(_ snapshot: GitSnapshot) {
        guard !busy else { return }
        let review = PushReviewModel(root: snapshot.root, hasUpstream: snapshot.upstream != nil)
        dialogs.show(Dialog(title: "Review your push", content: AnyView(
            PushReviewView(model: review, repository: repositoryName, branch: snapshot.branch,
                           upstream: snapshot.upstream) {
                if review.phase == .complete { commitSucceeded = false }
                await reload()
            }), actions: [], onCancel: { review.invalidate(); pushFocused = true },
            width: 560, isModal: true, framesItself: true, fitsWindow: true, hugsContent: true,
            maximumHeight: 480, canDismiss: { !review.isWorking }))
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
        if !appliedInitialSelection.contains(root) {
            appliedInitialSelection.insert(root)
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

    // What was half done in the project before belongs to its files, so it goes.
    private func switchedProject(_ root: String) {
        if navigation.selections[root] != nil && requestedPath == nil {
            appliedInitialSelection.insert(root)
        } else {
            appliedInitialSelection.remove(root)
        }
        commentDraft = nil
        reattaching = nil
        copied = nil
        copiedPath = nil
        commitSucceeded = false
        openLatestCommit = false
        diffScroll = .top
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
        guard let selectedID = fileSelection.activeID,
              let selected = files.first(where: { $0.id == selectedID }) else {
            clearDiffContent()
            return
        }
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
            language: (mode == .changes ? shownFile : nil).flatMap(language),
            scale: appSettings.textSize.scale, numbered: mode == .changes,
            comments: mode == .changes ? diffComments(for: shownFile, lines: diff.lines) : nil)
    }

    private func language(_ file: GitChange) -> CodeLanguage? {
        CodeLanguage(path: file.path)
    }

    // A grey gap row stands for the unchanged lines the diff skipped. Pressing one of its
    // controls reads that end of the gap back and drops the lines in beside the row, so a
    // change can be read with the code around it without leaving the pane.
    private func expand(_ key: String, _ direction: DiffExpandDirection) {
        // The lines on screen belong to the file before; the one selected is on its way.
        guard mode != .changes || shownFile?.id == selected?.id else { return }
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
        diffScroll = !recheckList && model.diffFileID == file.id ? .hold : .top
        await model.showDiff(loaded, of: file.id, language: language(file), scale: appSettings.textSize.scale,
                             comments: diffComments(for: file, lines: loaded.lines))
    }

    // MARK: - Review

    private var openFileComments: [ReviewComment] {
        guard let review, let file = shownFile else { return [] }
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
        guard let review, let file = shownFile else { return [] }
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
        guard let review, let file = shownFile else { return [] }
        return review.reviews.threads(review.sessionID, root: repoRoot, path: file.path)
    }

    private var sentPlacement: ReviewPlacement {
        guard let diff else { return ReviewPlacement() }
        return ReviewPlacement.place(openFileThreads.map(\.comment), in: diff.lines)
    }

    private var pickedKeys: Set<String> {
        commentDraft.map { DiffComments.keys($0.anchor) } ?? citedAnchor.map(DiffComments.keys) ?? []
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
                             lines: [DiffLine], path: String?) -> Set<Int> {
        var ids = Set(placement.below.keys).union(sent.below.keys).union(asked.keys)
        if let draft = commentDraft, draft.path == path, draft.editing == nil,
           let id = lineID(for: draft.anchor, in: lines) {
            ids.insert(id)
        }
        return ids
    }

    private var threadLineIDs: Set<Int> {
        guard review != nil, mode == .changes, let diff else { return [] }
        return threadLines(placement: placement, sent: sentPlacement, asked: questionPlacement, lines: diff.lines,
                           path: shownFile?.path)
    }

    private func diffComments(for file: GitChange?, lines: [DiffLine]) -> DiffComments? {
        guard let review else { return nil }
        let comments = file.map { inlineComments(review, path: $0.path) } ?? []
        let sent = file.map { review.reviews.threads(review.sessionID, root: repoRoot, path: $0.path).map(\.comment) } ?? []
        let asked = file.map { review.reviews.questions(review.sessionID, root: repoRoot, path: $0.path) } ?? []
        return DiffComments(threads: threadLines(placement: ReviewPlacement.place(comments, in: lines),
                                                 sent: ReviewPlacement.place(sent, in: lines),
                                                 asked: Self.placeQuestions(asked, in: lines), lines: lines,
                                                 path: file?.path))
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
            guard let draft = commentDraft, draft.path == shownFile?.path else { return nil }
            if let editing = draft.editing {
                return placement.below.first { $0.value.contains { $0.id == editing } }?.key
            }
            return lineID(for: draft.anchor, in: diff.lines)
        }()
        for id in threadLines(placement: placement, sent: sent, asked: asked, lines: diff.lines,
                              path: shownFile?.path) {
            let comments = placement.below[id] ?? []
            let threads = (sent.below[id] ?? []).compactMap { comment in rounds[comment.id].map { ($0, comment) } }
            views[id] = AnyView(VStack(alignment: .leading, spacing: Space.md) {
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
        if commentDraft == nil, let anchor = citedAnchor, let citation = navigation.citation, let diff,
           let id = lineID(for: DiffAnchor(side: anchor.side, line: anchor.line), in: diff.lines) {
            return DiffReveal(line: id, serial: citation.serial, key: DiffComments.key(DiffAnchor(side: anchor.side, line: anchor.line)))
        }
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
            .padding(.bottom, Space.xxs)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.card))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(focused ? Theme.accent : Theme.border, lineWidth: focused ? 2 : 1))
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
        guard let file = shownFile else { return }
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
        guard let file = shownFile else { return }
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
        guard let draft = commentDraft, draft.editing == nil, draft.path == shownFile?.path,
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
        guard dialogs.current == nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "b" {
            showBranches()
            return true
        }
        if flags == .command, event.keyCode == 36, mode == .changes {
            openCommitDialog()
            return true
        }
        let typing = WindowKeyHandler.isTyping(event.window?.firstResponder)
        if review != nil, !typing, flags == .shift, event.charactersIgnoringModifiers == "?" {
            if navigation.askingWholeChange { closeWholeChangeCard() } else { navigation.setAskingWholeChange(true) }
            return true
        }
        // The card has the first claim on Escape over the review behind it.
        if navigation.askingWholeChange, !typing, flags.isEmpty, event.keyCode == 53 {
            escapeWholeChangeCard()
            return true
        }
        guard !WindowKeyHandler.isTyping(event.window?.firstResponder), let review, mode == .changes else { return false }
        if flags == .option, event.keyCode == 125 || event.keyCode == 126 {
            step(event.keyCode == 125 ? 1 : -1)
            return true
        }
        if flags.isEmpty, event.keyCode == 53, let id = focusedComment,
           let question = review.reviews.question(id, in: review.sessionID), question.status == .answering {
            stopAnswering(question, review: review)
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
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(comments) { comment in
                HStack(alignment: .top, spacing: Space.md) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.attentionText)
                    VStack(alignment: .leading, spacing: Space.md) {
                        (Text("This comment's code is no longer in the diff.").fontWeight(.semibold)
                         + Text(" It was on \(comment.anchor.label.lowercased()). It still goes with your review."))
                            .font(Typography.detail)
                            .fixedSize(horizontal: false, vertical: true)
                        card(comment, review: review)
                        if !comment.excerpt.isBlank {
                            Text(comment.excerpt).font(Typography.data).foregroundStyle(.secondary).lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Space.md).background(RoundedRectangle(cornerRadius: Radius.inset).fill(Theme.sunken))
                        }
                        HStack(spacing: Space.lg) {
                            if reattaching == comment.id {
                                Text("Click a line number to move the comment there.")
                                    .font(Typography.label).foregroundStyle(Theme.accent)
                                InlineLink(title: "Cancel", tint: Color.secondary) { reattaching = nil }
                            } else {
                                ActionButton(title: "Move to a line", tone: .outlined, height: ControlHeight.sm, size: Typography.Size.detail,
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
                .padding(Space.lg)
                .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.attention.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(Theme.attention.opacity(0.3)))
            }
        }
        .padding(.horizontal, Space.xxl).padding(.bottom, Space.md)
    }

    private func fileComments(_ comments: [ReviewComment], review: ReviewTarget) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(comments) { comment in
                if commentDraft?.editing == comment.id {
                    composer(review)
                } else {
                    card(comment, review: review)
                }
            }
        }
        .padding(.horizontal, Space.xxl).padding(.bottom, Space.md)
    }

    // The first time the diff takes comments, a note says how.
    private var coachMark: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Ask or comment on any line").font(Typography.body.weight(.semibold))
            Text("Click a line number to ask a question or request a change. Drag down the numbers to cover several lines. Questions are answered here; changes wait until you send them to \(review?.agent.title ?? "the agent").")
                .font(Typography.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                InlineLink(title: "Got it") { coachSeen = true }
            }
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.lg)
        .frame(width: 300)
        .floatingCard(cornerRadius: Radius.card)
        .accessibilityElement(children: .contain)
    }

    // MARK: Replies

    // The first thread with an answer not yet read.
    private func nextUnread() {
        guard let review,
              let next = review.reviews.threads(review.sessionID).first(where: { $0.round.unread.contains($0.comment.id) })
        else { return }
        focus(next.comment)
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

    // The header's control opens whichever dialog its state is about.
    private func openSecondOpinion(_ review: ReviewTarget) {
        switch SecondOpinionStatus(reviews: review.reviews, sessionID: review.sessionID) {
        case .ask, .reviewing, .failed: openProgress(review)
        case .ready: openFindings(review)
        case .settled(let kept, let dismissed):
            if kept + dismissed > 0 { openFindings(review) } else { openProgress(review) }
        }
    }

    private func takeSecondOpinionRequest() {
        guard let request = navigation.secondOpinionRequest else { return }
        navigation.secondOpinionRequest = nil
        guard let review else { return }
        mode = .changes
        switch request {
        case .ask(let lineup): askForSecondOpinion(review, lineup: lineup)
        case .open: openSecondOpinion(review)
        }
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
            actions: [], width: 560, framesItself: true)
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
        switch navigation.secondOpinionScope {
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

    private func questionThread(_ question: ReviewQuestion, review: ReviewTarget, showsBand: Bool = true,
                                inCard: Bool = false, startFollowUp: (() -> Void)? = nil) -> some View {
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
            delete: { removeQuestion(question, review: review) },
            stop: { stopAnswering(question, review: review) },
            askAgain: { askAgain(question, review: review) },
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
            },
            startFollowUp: startFollowUp,
            editQuestion: inCard ? { editWholeChangeQuestion(question, review: review) } : nil,
            references: inCard ? { answerReferences($0) } : { _ in [] },
            showReference: { showCitation($0) },
            hoverReference: { navigation.citeHover = $0 })
            // In the card a thread sits flat on it, since a card inside a card is only
            // another edge to read past.
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(inCard ? .clear : Theme.card))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card)
                .stroke(inCard ? .clear : focused ? Theme.plan : Theme.border, lineWidth: focused && !inCard ? 2 : 1))
            .onTapGesture { focusedComment = question.id }
    }

    // Stopping is cheap and asking again undoes it, so it needs no confirming.
    private func stopAnswering(_ question: ReviewQuestion, review: ReviewTarget) {
        review.reviews.stopAnswering(question.id, in: review.sessionID)
        showToast("Stopped answering \u{201C}\(question.text.trimmed)\u{201D}", action: "Ask again") {
            focusedComment = question.id
            askAgain(question, review: review)
        }
    }

    private func askAgain(_ question: ReviewQuestion, review: ReviewTarget) {
        review.reviews.askAgain(question.id, context: questionContext(review), in: review.sessionID)
        if toast?.actionTitle == "Ask again" { toast = nil }
        announce("Asked again")
    }

    // Puts a question in focus and brings it on screen. One about the whole change has no
    // lines, so it opens in the card instead.
    private func focus(_ question: ReviewQuestion) {
        focusedComment = question.id
        revealSerial += 1
        guard !question.isWhole else {
            openWholeChangeThread(question.id)
            return
        }
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

    // MARK: Whole change

    private func openWholeChangeThread(_ id: UUID) {
        navigation.askExpanded = id
        navigation.setAskingWholeChange(true)
    }

    private func closeWholeChangeCard() {
        navigation.citation = nil
        navigation.setAskingWholeChange(false)
    }

    // A follow-up goes into the thread it was started from; anything else starts a thread.
    private func askAboutWholeChange(_ text: String, review: ReviewTarget) {
        let context = questionContext(review)
        if let id = navigation.askFollowing, review.reviews.question(id, in: review.sessionID) != nil {
            review.reviews.followUp(text, to: id, context: context, in: review.sessionID)
            navigation.askExpanded = id
            announce("Asked a follow-up. The answer appears in this card.")
        } else {
            let question = ReviewQuestion.whole(root: repoRoot, agent: review.agent, question: text)
            review.reviews.ask(question, context: context, in: review.sessionID)
            navigation.askExpanded = question.id
            announce("Asked. The answer appears in this card.")
        }
        navigation.askDraft = ""
        navigation.askFollowing = nil
    }

    // The card hangs off the top of the screen, just under the header button that opens
    // it.
    private var wholeChangeCard: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                if navigation.askingWholeChange, let review {
                    let threads = WholeChangeThreads.split(review.reviews.questions(review.sessionID))
                    WholeChangeAskCard(
                        navigation: navigation, open: threads.open, resolved: threads.resolved,
                        scope: changeScope,
                        agentTitle: review.agent.title,
                        forksConversation: review.agent == .claudeCode,
                        maxHeight: max(proxy.size.height - 27, 200),
                        ask: { askAboutWholeChange($0, review: review) },
                        escape: escapeWholeChangeCard,
                        close: closeWholeChangeCard) { question, expanded in
                            wholeChangeThread(question, expanded: expanded, review: review)
                        }
                        .environment(\.openURL, OpenURLAction { citeFile($0) })
                        .environment(\.linkHovered, LinkHoverAction { url in
                            navigation.citeHover = url.flatMap(resolveCitation)
                        })
                        .padding(.trailing, Space.xxl).padding(.top, Space.sm)
                        .transition(.popover(reduceMotion: reduceMotion))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private var changeScope: [WholeChangeAskScope] {
        repositories.compactMap { repository in
            let files = changes(in: repository.root)
            guard !files.isEmpty else { return nil }
            return WholeChangeAskScope(name: repository.name, files: files.count,
                                       added: files.reduce(0) { $0 + ($1.added ?? 0) },
                                       removed: files.reduce(0) { $0 + ($1.removed ?? 0) })
        }
    }

    // Esc stops an answer under way first, so the card does not vanish with it running.
    private func escapeWholeChangeCard() {
        if let review, let running = WholeChangeThreads.split(review.reviews.questions(review.sessionID)).open
            .last(where: { $0.status == .answering }) {
            stopAnswering(running, review: review)
            return
        }
        closeWholeChangeCard()
    }

    // Removing takes effect at once and an undo puts the question back where it was.
    private func removeQuestion(_ question: ReviewQuestion, review: ReviewTarget) {
        let reviews = review.reviews
        let sessionID = review.sessionID
        let index = reviews.questions(sessionID).firstIndex { $0.id == question.id } ?? 0
        if navigation.askFollowing == question.id { navigation.askFollowing = nil }
        reviews.deleteQuestion(question.id, in: sessionID)
        if focusedComment == question.id { focusedComment = nil }
        showToast("Removed \u{201C}\(question.text.trimmed)\u{201D}", action: "Undo") {
            reviews.restoreQuestion(question, at: index, in: sessionID)
            navigation.askExpanded = question.id
        }
    }

    // A stopped question goes back to the field to be asked in other words. A follow-up
    // is taken back from its thread; a first question takes its thread with it.
    private func editWholeChangeQuestion(_ question: ReviewQuestion, review: ReviewTarget) {
        if let text = review.reviews.withdrawFollowUp(question.id, in: review.sessionID) {
            navigation.askDraft = text
            navigation.askFollowing = question.id
        } else {
            navigation.askDraft = question.exchanges.last?.question ?? question.text
            navigation.askFollowing = nil
            review.reviews.deleteQuestion(question.id, in: review.sessionID)
        }
        announce("The question is back in the field")
    }

    private func resolveCitation(_ url: URL) -> ChangeCitation? {
        ChangeCitation.resolve(url, roots: repositories.map(\.root)) { root, path in
            changes(in: root).contains { $0.path == path }
        }
    }

    private func answerReferences(_ answer: String) -> [AnswerReference] {
        let names = Dictionary(repositories.map { ($0.root, $0.name) }, uniquingKeysWith: { first, _ in first })
        return ChangeCitation.references(in: answer, roots: repositories.map(\.root)) { root, path in
            changes(in: root).contains { $0.path == path }
        }
        .map { AnswerReference(citation: $0, tint: Theme.projectTint(for: names[$0.root] ?? "")) }
    }

    @ViewBuilder
    private func wholeChangeThread(_ question: ReviewQuestion, expanded: Bool, review: ReviewTarget) -> some View {
        if expanded || question.resolved {
            questionThread(question, review: review, showsBand: false, inCard: true, startFollowUp: {
                navigation.askFollowing = question.id
            })
        } else {
            WholeChangeFoldedThread(question: question, open: { navigation.askExpanded = question.id }) {
                questionBadge(question, review: review)
            }
        }
    }

    // A file named in an answer opens in the diff under the card, with the lines it names
    // lit, so the answer and the code can be read side by side. A file outside the change
    // opens the usual way.
    private func citeFile(_ url: URL) -> OpenURLAction.Result {
        guard let citation = resolveCitation(url) else { return .systemAction }
        showCitation(citation)
        return .handled
    }

    private func showCitation(_ found: ChangeCitation) {
        var citation = found
        citation.serial = (navigation.citation?.serial ?? 0) + 1
        navigation.citation = citation
        if commentDraft?.text.isBlank != false { commentDraft = nil }
        guard citation.root == root else {
            selectRepository(citation.root, citation.path)
            return
        }
        if selected?.path != citation.path, let file = files.first(where: { $0.path == citation.path }) {
            mode = .changes
            select(file)
        }
        announce("Showing \(citation.fileName)" + (citation.anchor.map { ", \($0.label.lowercased())" } ?? ""))
    }

    // The lines the cited reference names, while its file is the one on screen.
    private var citedAnchor: DiffAnchor? {
        guard let citation = navigation.citation, citation.root == root,
              citation.path == shownFile?.path else { return nil }
        return citation.anchor
    }

    private func questionBadge(_ question: ReviewQuestion, review: ReviewTarget) -> some View {
        let sent = question.changeID.map { review.reviews.round(sending: $0, in: review.sessionID) != nil } ?? false
        let waiting = question.changeID.map { review.reviews.comment($0, in: review.sessionID) != nil } ?? false
        let (text, ink): (String, Color) = switch question.status {
        case .answering: ("Answering…", Color.secondary)
        case .failed: ("Couldn't answer", Theme.warningText)
        case .stopped: ("Stopped", Color.secondary)
        case .answered:
            sent ? ("Became a change", Theme.accent)
                : waiting ? ("Change in review", Theme.accent)
                : question.resolved ? ("Resolved", Color.secondary) : ("Answered", Theme.plan)
        }
        return Text(text)
            .font(Typography.caption.weight(.semibold)).foregroundStyle(ink)
            .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs)
            .background(Capsule().fill(ink.opacity(0.12)))
            .lineLimit(1).fixedSize()
    }

    // MARK: Review list

    // Where the focused comment stands in the whole review, with the way to the next.
    private var commentNavigation: some View {
        let list = orderedComments
        let index = list.firstIndex { $0.id == focusedComment }
        let here = openFileComments.count
        return HStack(spacing: Space.xs) {
            Text(index.map { "Comment \($0 + 1) of \(list.count)" }
                 ?? counted(list.count, "comment") + (here > 0 ? ", \(here) here" : ""))
                .font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
            GlyphButton(icon: "chevron.up", side: ControlHeight.sm) { step(-1) }
                .appTooltip("Previous comment  ⌥↑")
                .accessibilityLabel("Previous comment")
            GlyphButton(icon: "chevron.down", side: ControlHeight.sm) { step(1) }
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
        // Finder opens outside the window, so the toast is what shows the click landed.
        showToast("Shown in Finder")
    }
}


// The rule down the side of a project's rows. It runs into the gaps between rows so the
// line is unbroken.
private struct ProjectRule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.leading, Space.md)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.border).frame(width: 1).padding(.vertical, -1.5)
            }
            .padding(.leading, Space.xxl)
    }
}

private struct SettledFile: Identifiable {
    let root: String
    let path: String
    var id: String { root + "/" + path }
}
