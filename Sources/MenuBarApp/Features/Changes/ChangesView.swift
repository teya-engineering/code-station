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
    @State private var models: ChangesModels
    var model: ChangesModel { models.model(for: root) }
    @State var navigation: ChangesNavigationMemory
    private let isWorkspace: Bool
    let selectRepository: (String, String?) -> Void
    let review: ReviewTarget?

    // The navigator keeps its own cursor instead of focusing each row, since a plain
    // button only takes keyboard focus when Full Keyboard Access is on.
    @State var navigatorCursor: ChangesNavigatorItem?
    @FocusState var navigatorFocused: Bool
    // A click already highlights the row it picks, so the cursor outline only shows
    // while the keyboard is driving the navigator.
    @State var navigatorCursorVisible = false

    enum Mode: Hashable { case changes, history }

    @Environment(DialogPresenter.self) var dialogs
    @Environment(GitStatsCache.self) var gitStats
    @Environment(AppSettings.self) var appSettings
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.askSecondOpinionOnFile) private var askSecondOpinionOnFile

    @State var commentDraft: CommentDraft?
    @State var toast: ReviewToast?
    // The second opinion dialog showing progress or findings, so a reviewer finishing
    // while it is open does not also raise a toast behind it.
    @State var secondOpinionDialog: UUID?
    // An unplaced comment waiting for a line number to be clicked to move onto.
    @State var reattaching: UUID?
    // Bumped to scroll the diff to the focused comment again, even when it has not moved.
    @State var revealSerial = 0
    @State var reviewKeys = WindowKeyHandler(handlesTyping: true)
    @Environment(\.keyBindings) private var keyBindings
    @AppStorage("changes.reviewCoachSeen") var coachSeen = false

    @State private var copied: GitInspector.CopyVersion?
    @State private var copiedPath: String?
    @State private var fetches = 0
    // Until the project is read, it shows the last snapshot taken of its tree, so its
    // files are listed at once instead of after git.
    var snapshot: GitSnapshot? { model.snapshot ?? gitStats.snapshot(at: root) }
    var mode: Mode {
        get { navigation.showingHistory ? .history : .changes }
        nonmutating set { navigation.showingHistory = newValue == .history }
    }
    @FocusState private var commitFocused: Bool
    @State private var commitSucceeded = false
    @FocusState private var pushFocused: Bool

    var files: [GitChange] { snapshot?.files ?? [] }
    var selected: GitChange? { files.first { $0.id == model.fileSelection.activeID } }
    // The file the diff pane is drawing. While a newly selected file is being read this is
    // still the one before it, so the header, the cards and a press on a line all agree
    // with the code on screen.
    var shownFile: GitChange? {
        guard model.diff != nil, let id = model.diffFileID else { return selected }
        return files.first { $0.id == id } ?? selected
    }
    var localFiles: [GitChange] { snapshot?.localFiles ?? [] }
    private var selectedFiles: [GitChange] { localFiles.filter { !model.commitDraft.excluded.contains($0.id) } }
    private var comparesToRemote: Bool { snapshot?.comparedToRemote == true }
    var repoRoot: String { snapshot?.root ?? root }
    private var repositoryName: String { repositories.first { $0.root == root }?.name ?? root }

    // What the model's loads take from this screen.
    private var screen: ChangesScreen {
        ChangesScreen(gitStats: gitStats,
                      otherRoots: repositories.map(\.root).filter { $0 != root },
                      firstPath: requestedPath ?? initiallySelectedPath,
                      textScale: { appSettings.textSize.scale },
                      comments: diffComments,
                      fetchFailed: { dialogs.show(.notice("Could not refresh origin", message: $0)) })
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
        let models = ChangesModels(navigation: memory)
        // A project that comes back with the file picked before keeps it, unless a file
        // was asked for.
        models.model(for: root).pickedInitialFile = navigation?.selections[root] != nil
            && initiallySelectedPath == nil && requestedPath == nil
        _models = State(initialValue: models)
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
    // header spans the whole pane.
    var body: some View {
        let placed = placements
        VStack(spacing: 0) {
            GeometryReader { geometry in
                // A narrow history has no room for two columns, so the navigator and the
                // commit page take turns.
                let narrowHistory = mode == .history && geometry.size.width < 850
                let navigatorVisible = showsNavigator(width: geometry.size.width) && !narrowHistory
                let width = !isWorkspace ? 280
                    : ExplorerSplitLayout.treeWidth(navigation.treeWidth, availableWidth: geometry.size.width)
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
                            content(narrowHistory: narrowHistory, placed: placed)
                            if !navigatorVisible && mode == .changes && !localFiles.isEmpty { commitBar }
                        }.frame(maxWidth: .infinity).clipped()
                    }
                    .overlay {
                        ZStack(alignment: .leading) {
                            if navigatorVisible && isWorkspace {
                                WorkspaceSplitHandle(width: Binding(get: { navigation.treeWidth }, set: { navigation.treeWidth = $0 }), displayedWidth: width,
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
            if model.loading && snapshot != nil {
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
            await model.refreshOthers(for: screen)
        }
        .onChange(of: root) { old, _ in switchedProject(from: old) }
        .onChange(of: requestedPath) { _, path in
            guard let file = files.first(where: { $0.id == path }) else { return }
            mode = .changes
            select(file)
        }
        .onChange(of: mode) { _, _ in model.switchedMode(reopening: selected, at: repoRoot, for: screen) }
        .onChange(of: syncStatus) { _, status in announce(status) }
        // The open diff is one attributed string built when the file was picked, so its
        // font is baked in and a new reading size only reaches it by building it again.
        .onChange(of: appSettings.textSize) { _, _ in reopenDiff() }
        // The text keeps an empty row under each line a thread hangs from, so a thread
        // that comes or goes is only seen once the text is built again. The reader stays
        // where they were.
        .onChange(of: threadLineIDs(placed)) { _, ids in
            guard ids != model.renderedThreads else { return }
            model.diffScroll = .hold
            renderDiff()
        }
        .onChange(of: model.fileSelection.activeID) { _, path in
            if commentDraft?.path != path { commentDraft = nil }
        }
        .onChange(of: model.diff) { _, _ in followDraft() }
    }

    private var syncStatus: String {
        snapshot?.syncDescription(remoteUnavailable: model.refreshFailed) ?? "Checking branch status"
    }

    private var cleanContent: some View {
        VStack(spacing: Space.xl) {
            PaneMessage(icon: "checkmark.seal",
                        title: comparesToRemote ? "No changes from \(snapshot?.remoteBase?.ref ?? "origin")" : "No uncommitted changes",
                        detail: "\(repositoryName) has no pending changes.\n" + syncStatus) {
                HStack(spacing: Space.md) {
                    ActionButton(title: "View commit history") { mode = .history }
                    if !comparesToRemote, let base = snapshot?.remoteBase {
                        ActionButton(title: "Compare to \(base.ref)", tone: .outlined) { compare(toRemote: true) }
                            .disabled(model.busy)
                    }
                }
            }
            .frame(maxHeight: 260)
            if let subject = snapshot?.lastCommitSubject {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text("Latest commit").font(Typography.label)
                    Button { model.openLatestCommit = true; mode = .history } label: {
                        HStack {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            Text(subject).font(Typography.body.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .hoverFill()
                    if let latestCommit = model.latestCommit {
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

    func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func baseTitle(for file: GitChange) -> String {
        guard snapshot?.diffBase(for: file) != nil, let base = snapshot?.remoteBase else { return "Last commit" }
        return base.ref + " @ " + String(base.commit.prefix(7))
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
        .accessibilityLabel(version == .patch ? "Copy unified diff"
            : version == .before ? "Copy \(baseTitle(for: file)) version" : "Copy working tree version")
    }

    private func copy(_ version: GitInspector.CopyVersion, file: GitChange) {
        Task {
            let result = await GitInspector.copyText(for: file, root: repoRoot, version: version,
                                                     base: snapshot?.diffBase(for: file))
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
                    compareChoices(snapshot, compact: compact)
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
            .appTooltip(keyBindings.tooltip("Branches and actions: " + snapshot.branch, for: .branches))
            .accessibilityLabel("Branches and actions, current branch " + snapshot.branch)
            .disabled(model.busy)
    }

    // Only offered when the remote's default branch is known. The base is where the
    // branch left it, which is what a pull request compares against.
    @ViewBuilder private func compareChoices(_ snapshot: GitSnapshot, compact: Bool) -> some View {
        if mode == .changes, let base = snapshot.remoteBase {
            HStack(spacing: Space.xs) {
                if !compact {
                    Text("Compare to").font(Typography.caption).foregroundStyle(.secondary).fixedSize()
                }
                ChoicePill(title: "HEAD", selected: !model.comparesToRemote, enabled: !model.busy) {
                    compare(toRemote: false)
                }
                .appTooltip("Uncommitted changes, compared to the last commit")
                ChoicePill(title: base.ref, selected: model.comparesToRemote, enabled: !model.busy) {
                    compare(toRemote: true)
                }
                .appTooltip("Everything this branch changes since it left \(base.ref), committed or not")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Compare to")
        }
    }

    private func compare(toRemote: Bool) {
        guard !model.busy, model.comparesToRemote != toRemote else { return }
        model.comparesToRemote = toRemote
        model.diffScroll = .top
        Task { await reload() }
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
                        : model.refreshFailed ? "Fetch from origin failed. Try again." : "Git status refreshed.")
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .actOut("arrow.clockwise", trigger: fetches)
                    .padding(Space.md).contentShape(Rectangle())
                    .hoverLift(amount: Motion.smallLift)
            }.buttonStyle(.plain).disabled(model.busy)
                .appTooltip("Fetch from origin").accessibilityLabel("Fetch from origin")
            Image(systemName: "ellipsis").padding(Space.md).contentShape(Rectangle())
                .hoverLift(amount: Motion.smallLift)
                .appMenu { repositoryMenu(snapshot) }
                .accessibilityLabel("Repository actions for " + repositoryName).disabled(model.busy)
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
        .disabled(model.busy || action == nil)
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

    func showBranches() {
        guard !model.busy else { return }
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

    var commitBar: some View {
        HStack(spacing: Space.md) {
            Toggle(isOn: Binding(
                get: { selectedFiles.count == localFiles.count },
                set: { on in model.commitDraft.excluded = on ? [] : Set(localFiles.map(\.id)) }
            )) {
                Text(selectedFiles.count == localFiles.count
                     ? "All \(counted(localFiles.count, "file"))"
                     : "\(selectedFiles.count) of \(localFiles.count) files")
                    .font(Typography.detail.weight(.medium))
            }.toggleStyle(.appCheckbox)
            Spacer(minLength: 0)
            let conflicted = files.contains { $0.kind == .conflicted }
            ActionButton(title: conflicted ? "Resolve conflicts to commit"
                            : selectedFiles.isEmpty ? "Commit…" : "Commit \(counted(selectedFiles.count, "file"))…",
                         tone: .green, height: ControlHeight.lg) { openCommitDialog() }
                .disabled(model.busy || commitBlocker != nil)
                .focused($commitFocused)
                .overlay(RoundedRectangle(cornerRadius: Radius.control)
                    .stroke(commitFocused ? Theme.accent : .clear, lineWidth: 2))
                .appTooltip(commitBlocker ?? keyBindings.tooltip("Commit", for: .commitSelected))
                .layoutPriority(1)
        }
        .padding(Space.lg).background(Theme.card).disabled(model.busy)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    func openCommitDialog() {
        let chosen = selectedFiles
        guard !model.busy, commitBlocker == nil, let snapshot else { return }
        mode = .changes
        let operationRoot = repoRoot
        let dialog = CommitDialogModel(draft: model.commitDraft, files: chosen, canAmend: snapshot.canAmend,
                                       lastSubject: snapshot.lastCommitSubject) { message, files, amend in
            model.working = amend ? "Amending…" : "Committing…"
            announce(model.working ?? "Committing…")
            let error = await GitActions.commitSelected(message: message, files: files,
                                                        amend: amend, at: operationRoot)
            await reload()
            model.working = nil
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

    @ViewBuilder private func content(narrowHistory: Bool, placed: DiffPlacements) -> some View {
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
                            diffPane(truncationHint: "Open the file to see the rest.", placed: placed,
                                     reveal: { reveal(file) }) {
                                fileName(file)
                                counts(file)
                                if model.fileSelection.ids.count > 1 {
                                    Text("\(model.fileSelection.ids.count) files selected")
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

    @ViewBuilder func counts(_ file: GitChange) -> some View {
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
    private func diffPane<Title: View>(truncationHint: String, placed: DiffPlacements,
                                       reveal: (() -> Void)? = nil,
                                       @ViewBuilder title: () -> Title) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.md) {
                title()
                // Beside the title rather than among the controls, so the buttons do not
                // shift under the pointer while comments are stepped through.
                if model.loadingDiff { ChangesProgressLabel(title: "Reading diff…", compact: true) }
                Spacer()
                if mode == .changes, review != nil, !orderedComments.isEmpty { commentNavigation }
                if mode == .changes, review != nil, let file = shownFile, let askOnFile = askSecondOpinionOnFile {
                    AnswerLineupButton(subject: "only " + file.fileName,
                                       accessibilityName: "Get a second opinion on " + file.fileName) {
                        askOnFile(repoRoot, file.path)
                    }
                }
                if mode == .changes, let file = shownFile {
                    Image(systemName: "ellipsis").padding(Space.md).contentShape(Rectangle())
                        .hoverLift(amount: Motion.smallLift)
                        .appMenu {
                            var entries: [MenuEntry] = []
                            if !file.isBinary && model.diff?.images == nil {
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
                    model.closeDiff()
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

            if mode == .changes, let file = shownFile, !file.isBinary, model.diff?.images == nil {
                if appSettings.changesDiffLayout == .sideBySide {
                    HStack {
                        versionHeader(baseTitle(for: file), version: .before, file: file)
                        versionHeader("Working tree", version: .after, file: file)
                    }.padding(.horizontal, Space.xxl).padding(.vertical, Space.md)
                }
            }
            if mode == .changes, let review {
                if !placed.comments.unplaced.isEmpty { unplacedComments(placed.comments.unplaced, review: review) }
                if !placed.comments.onFile.isEmpty { fileComments(placed.comments.onFile, review: review) }
            }
            // A new file's diff fades in once it has been read. The one before goes at once,
            // so two diffs are never drawn over each other.
            diffBody(truncationHint: truncationHint, placed: placed)
                .id(mode == .changes ? shownFile?.id : nil)
                .transition(.fadeIn)
                .motion(Motion.reveal, value: mode == .changes ? shownFile?.id : nil)
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        if mode == .changes, review != nil, !coachSeen, model.diff?.lines.isEmpty == false,
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
    @ViewBuilder private func diffBody(truncationHint: String, placed: DiffPlacements) -> some View {
        if let images = model.diff?.images {
            ImageDiffView(images: images)
        } else if let note = model.diff?.note {
            Text(note)
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if mode == .changes, model.diff?.lines.isEmpty == true, !model.loadingDiff {
            PaneMessage(icon: "doc", title: "No content changes",
                        detail: "This file may have metadata changes or changes confined to the index.")
        } else if mode == .changes, appSettings.changesDiffLayout == .sideBySide, let diff = model.diff {
            if let review {
                SideBySideDiff(lines: diff.lines, marks: model.diffMarks, expand: expand,
                               threads: threadViews(review, placed), picked: pickedKeys,
                               onLine: { pickLine($0, extending: $1) }, onRange: { pickRange($0) },
                               reveal: revealedLine(placed))
            } else {
                SideBySideDiff(lines: diff.lines, marks: model.diffMarks, expand: expand)
            }
        } else if let diffText = model.diffText {
            if mode == .changes, let review {
                DiffTextView(text: diffText, scroll: model.diffScroll,
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
                             threads: threadViews(review, placed),
                             reveal: revealedLine(placed))
            } else {
                DiffTextView(text: diffText, scroll: model.diffScroll) { gap, direction in
                    expand(gap, direction)
                }
            }
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        if let diff = model.diff, diff.truncated {
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
        if narrow && !model.historySelection.showingDetail {
            workspaceNavigator
        } else if let historyNote = model.historyNote {
            PaneMessage(icon: "exclamationmark.triangle", title: "Could not read the history",
                        detail: historyNote, mono: true)
        } else if let commits = model.commits {
            if commits.isEmpty {
                PaneMessage(icon: "clock", title: "No commits yet",
                            detail: "This branch has no history to show.")
            } else {
                CommitHistoryView(root: repoRoot, selection: model.historySelection,
                                  back: narrow ? { model.historySelection.showingDetail = false } : nil)
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
        guard !model.busy else { return }
        Task {
            model.working = "Pulling…"
            let outcome = await GitActions.pull(at: repoRoot)
            model.working = nil
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
    func confirmDiscard(_ files: [GitChange]) {
        guard !model.busy, let file = files.first else { return }
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
        guard !model.busy else { return }
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
        guard !model.busy else { return }
        Task {
            let error = await model.perform(progress, action)
            if let error { dialogs.show(.notice(failure, message: error)) }
            await reload()
        }
    }

    private func reload(fetchOrigin: Bool = false) async {
        await model.reload(fetchOrigin: fetchOrigin, for: screen)
    }

    // What was half done in the project before belongs to its files, so it goes.
    private func switchedProject(from old: String) {
        model.pickedInitialFile = navigation.selections[root] != nil && requestedPath == nil
        commentDraft = nil
        reattaching = nil
        copied = nil
        copiedPath = nil
        commitSucceeded = false
        models.model(for: old).openLatestCommit = false
        model.diffScroll = .top
    }

    func select(_ file: GitChange) {
        let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        let previousActiveID = model.fileSelection.activeID
        model.fileSelection.select(file.id,
                             in: files.map(\.id),
                             extendingRange: flags.contains(.shift),
                             toggling: flags.contains(.command))
        guard model.fileSelection.activeID != previousActiveID else { return }
        guard let selectedID = model.fileSelection.activeID,
              let selected = files.first(where: { $0.id == selectedID }) else {
            model.clearDiff()
            return
        }
        let root = repoRoot
        Task { await model.loadDiff(selected, at: root, for: screen) }
    }

    // Built again from the lines already in hand rather than by asking git a second time:
    // nothing about the change has moved, only the size it is drawn at.
    private func reopenDiff() {
        model.diffScroll = .top
        renderDiff()
    }

    // A commit diff spans many files and takes its languages from its own section
    // headings, so only a single file's diff has a language to name here.
    private func renderDiff() {
        guard let diff = model.diff, !diff.lines.isEmpty else { return }
        model.renderDiff(
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
            model.diffScroll = direction == .down ? .follow : .hold
            renderDiff()
        }
    }

    func fileURL(_ file: GitChange) -> URL {
        URL(fileURLWithPath: snapshot?.root ?? root).appendingPathComponent(file.path)
    }

    func reveal(_ file: GitChange) {
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
