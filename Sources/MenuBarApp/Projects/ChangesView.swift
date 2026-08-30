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
}

// The uncommitted changes in a session's folder: the project directory itself, or the
// session's worktree. Sessions edit the real files there, so this screen is how you
// see what the agent did before you keep it. The diffs themselves never touch the tree;
// the header carries the little git a review ends in: switch branch, commit, pull, push.
struct ChangesView: View {
    let root: String
    let initiallySelectedPath: String?

    private enum Mode: Hashable { case changes, history }

    @Environment(DialogPresenter.self) private var dialogs
    @Environment(GitStatsCache.self) private var gitStats
    @Environment(AppSettings.self) private var appSettings

    @State private var snapshot: GitSnapshot?
    @State private var loading = false
    @State private var working: String?
    @State private var mode: Mode = .changes
    @State private var committing = false
    @State private var commitMessage = ""
    @FocusState private var commitFocused: Bool
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
    @State private var appliedInitialSelection = false

    private var files: [GitChange] { snapshot?.files ?? [] }
    private var selected: GitChange? { files.first { $0.id == fileSelection.activeID } }
    private var selectedFiles: [GitChange] { files.filter { !excluded.contains($0.id) } }
    private var repoRoot: String { snapshot?.root ?? root }
    private var busy: Bool { loading || working != nil }

    // Amending rewrites the last commit, which is only safe while nothing else has it:
    // an unpublished branch, or one that is ahead of its upstream.
    private var canAmend: Bool {
        guard let snapshot, snapshot.hasCommits else { return false }
        return snapshot.upstream == nil || snapshot.ahead > 0
    }

    init(root: String, initiallySelectedPath: String? = nil) {
        self.root = root
        self.initiallySelectedPath = initiallySelectedPath
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if committing && mode == .changes { commitBar }
            content
        }
        .background(Theme.background)
        // The screen opens on the last snapshot taken of this tree while a fresh one
        // is fetched, so the file list is there at first glance instead of after git.
        .task(id: root) {
            if snapshot == nil { snapshot = gitStats.snapshot(at: root) }
            await reload()
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            if let snapshot, snapshot.state == .ready {
                branchControl(snapshot)

                HeaderTabToggle(selection: $mode,
                                options: [("Changes", .changes), ("History", .history)])

                if !snapshot.hasCommits {
                    Text("no commits yet").font(.system(size: 12)).foregroundStyle(.secondary)
                }

                if mode == .changes {
                    Text(files.isEmpty ? "no changes" : counted(files.count, "file"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    if !files.isEmpty {
                        DiffPair(added: snapshot.totalAdded, removed: snapshot.totalRemoved,
                                 size: 13, spacing: 8, weight: .medium)
                    }
                }

                Spacer()

                if let working {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(working).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else if loading || loadingHistory {
                    ProgressView().controlSize(.small)
                }

                if !files.isEmpty && mode == .changes {
                    headerAction("Commit", icon: "checkmark.circle") {
                        if committing {
                            committing = false
                        } else {
                            beginCommit()
                        }
                    }
                }
                if snapshot.upstream != nil {
                    headerAction("Pull", icon: "arrow.down", count: snapshot.behind) { pull() }
                }
                if snapshot.hasCommits {
                    headerAction("Push", icon: "arrow.up", count: snapshot.ahead) {
                        confirmPush(snapshot)
                    }
                }
            } else {
                Text((root as NSString).lastPathComponent).font(.system(size: 13, weight: .medium))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }

            Button {
                Task { await reload(fetchOrigin: true) }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .disabled(busy)
            .appTooltip("Refresh")
        }
        .padding(.horizontal, 20)
        .headerBand(height: Theme.subHeaderHeight)
    }

    private func branchControl(_ snapshot: GitSnapshot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 12))
            Text(snapshot.branch).font(.mono(13, .medium)).lineLimit(1)
            if !snapshot.branches.isEmpty {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .appMenu { branchMenu(snapshot) }
        .appTooltip("Switch branch")
    }

    private func branchMenu(_ snapshot: GitSnapshot) -> [MenuEntry] {
        guard !busy else { return [] }
        return snapshot.branches.map { branch in
            let current = snapshot.onBranch && branch == snapshot.branch
            return .item(branch, checked: current) {
                guard !current else { return }
                perform("Switching to \(branch)…", failure: "Could not switch branch") {
                    await GitActions.switchBranch(branch, at: repoRoot)
                }
            }
        }
    }

    private func headerAction(_ label: String, icon: String, count: Int = 0,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .semibold))
                if count > 0 {
                    Text("\(count)")
                        .font(.mono(10, .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.field))
                        .overlay(Capsule().stroke(Theme.border))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .disabled(busy)
        .opacity(busy ? 0.4 : 1)
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
                PaneMessage(icon: "checkmark.seal", title: "No uncommitted changes",
                            detail: "The working tree matches the last commit.")
            } else {
                list(files, isOpen: selected != nil, row: row)
                if let file = selected {
                    Divider().overlay(Theme.hairline)
                    diffPane(truncationHint: "Open the file to see the rest.",
                             reveal: { reveal(file) }) {
                        Text(file.fileName).font(.serif(15, .semibold)).lineLimit(1)
                        Text(file.kind.label).font(.system(size: 11)).foregroundStyle(.secondary)
                        if fileSelection.ids.count > 1 {
                            Text("\(fileSelection.ids.count) files selected")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
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

    // The rows above a diff, for files and for commits alike. The list fills the pane
    // until something is open, then gives the diff the room.
    private func list<Item: Identifiable, Row: View>(
        _ items: [Item], isOpen: Bool, @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(items) { item in
                    row(item)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: isOpen ? 260 : .infinity)
    }

    private func row(_ file: GitChange) -> some View {
        let isSelected = fileSelection.ids.contains(file.id)
        return Button {
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

                VStack(alignment: .leading, spacing: 1) {
                    Text(file.path)
                        .font(.mono(12))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let original = file.originalPath {
                        Text("was \(original)")
                            .font(.mono(10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if file.isStaged && file.isUnstaged {
                    Text("partly staged").font(.system(size: 10)).foregroundStyle(.secondary)
                }

                counts(file)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .surface(isSelected ? Theme.card : .clear, cornerRadius: 8,
                     border: isSelected ? Theme.border : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .appContextMenu {
            [.item("Commit This File…") { beginCommit(with: file) },
             .separator,
             .item("Reveal in Finder") { reveal(file) },
             .item("Copy Path") { Pasteboard.copy(fileURL(file).path) },
             .separator,
             .item("Discard Changes", kind: .destructive) { confirmDiscard(file) }]
        }
    }

    private func beginCommit(with file: GitChange? = nil) {
        if let file {
            excluded = Set(files.lazy.map(\.id))
            excluded.remove(file.id)
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

    // The open diff under its title row. A file and a commit differ only in what the row
    // says, whether Finder can show the thing, and where the rest of a cut-short diff can
    // be read.
    private func diffPane<Title: View>(truncationHint: String, reveal: (() -> Void)? = nil,
                                       @ViewBuilder title: () -> Title) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                title()
                Spacer()
                if loadingDiff { ProgressView().controlSize(.small) }
                if let reveal {
                    InlineLink(title: "Reveal in Finder", action: reveal)
                }
                Button {
                    closeDiff()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            diffBody(truncationHint: truncationHint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card)
    }

    // The rendered diff below a pane header, so a file and a commit truncate and report
    // notes the same way.
    @ViewBuilder private func diffBody(truncationHint: String) -> some View {
        if let note = diff?.note {
            Text(note)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diffText {
            DiffTextView(text: diffText)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        if let diff, diff.truncated {
            Text("Showing the first \(diff.lines.count) lines of \(diff.totalLines). \(truncationHint)")
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
                list(commits, isOpen: selectedCommit != nil, row: commitRow)
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
    // words what the file will be left as.
    private func confirmDiscard(_ file: GitChange) {
        let root = repoRoot
        let untracked = file.isUntracked
        dialogs.show(Dialog(
            title: untracked ? "Delete this file?" : "Discard changes?",
            message: untracked
                ? "\(file.path) is not in git yet, so there is no committed version to go back "
                    + "to. It will be moved to the Trash."
                : "\(file.path) goes back to the way the last commit has it. The changes in it "
                    + "are lost.",
            actions: [
                .init(label: untracked ? "Move to Trash" : "Discard", kind: .destructive) {
                    perform("Discarding…", failure: "Could not discard changes") {
                        await GitActions.discard(file, at: root)
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
        if fetchOrigin, snapshot?.state == .ready,
           let error = await GitActions.fetchOrigin(at: repoRoot) {
            guard !Task.isCancelled else { return }
            dialogs.show(.notice("Could not refresh origin", message: error))
        }
        let fresh = await GitInspector.snapshot(at: root, lane: .interactive)
        guard !Task.isCancelled else { return }
        snapshot = fresh
        // The session header shows the same tree, so a commit or pull made here
        // updates its numbers too rather than waiting for the next run to end.
        gitStats.store(fresh, at: root)
        loading = false
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
            if let initiallySelectedPath,
               fresh.files.contains(where: { $0.id == initiallySelectedPath }) {
                fileSelection.select(initiallySelectedPath, in: orderedIDs,
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
        closeDiff()
        if mode == .history {
            Task { await loadHistory() }
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
        guard !Task.isCancelled, selectedCommit?.id == commit.id else { return }
        diff = loaded
        diffText = loaded.lines.isEmpty
            ? nil
            : DiffText.attributed(loaded.lines, scale: appSettings.textSize.scale)
        loadingDiff = false
    }

    // Built again from the lines already in hand rather than by asking git a second time:
    // nothing about the change has moved, only the size it is drawn at. A commit diff
    // spans many files and takes its languages from its own section headings, so only a
    // single file's diff has a language to name here.
    private func reopenDiff() {
        guard let diff, !diff.lines.isEmpty else { return }
        diffText = DiffText.attributed(
            diff.lines,
            language: selected.flatMap {
                CodeLanguage(fileExtension: ($0.path as NSString).pathExtension)
            },
            scale: appSettings.textSize.scale)
    }

    private func closeDiff() {
        fileSelection.clear()
        selectedCommit = nil
        clearDiffContent()
    }

    private func clearDiffContent() {
        diff = nil
        diffText = nil
        loadingDiff = false
    }

    private func loadDiff(_ file: GitChange, root: String) async {
        loadingDiff = true
        let loaded = await GitInspector.diff(for: file, root: root)
        guard !Task.isCancelled, fileSelection.activeID == file.id else { return }
        diff = loaded
        diffText = loaded.lines.isEmpty ? nil : DiffText.attributed(
            loaded.lines,
            language: CodeLanguage(fileExtension: (file.path as NSString).pathExtension),
            scale: appSettings.textSize.scale)
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
