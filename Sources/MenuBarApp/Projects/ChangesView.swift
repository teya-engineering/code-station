import AppKit
import SwiftUI

// The uncommitted changes in a session's folder: the project directory itself, or the
// session's worktree. Sessions edit the real files there, so this screen is how you
// see what the agent did before you keep it. The diffs themselves never touch the tree;
// the header carries the little git a review ends in: switch branch, commit, pull, push.
struct ChangesView: View {
    let root: String

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
    @State private var selectedID: GitChange.ID?
    @State private var commits: [GitCommitSummary]?
    @State private var historyNote: String?
    @State private var loadingHistory = false
    @State private var selectedCommit: GitCommitSummary?
    @State private var diff: FileDiff?
    @State private var diffText: NSAttributedString?
    @State private var loadingDiff = false

    private var files: [GitChange] { snapshot?.files ?? [] }
    private var selected: GitChange? { files.first { $0.id == selectedID } }
    private var selectedFiles: [GitChange] { files.filter { !excluded.contains($0.id) } }
    private var repoRoot: String { snapshot?.root ?? root }
    private var busy: Bool { loading || working != nil }

    // Amending rewrites the last commit, which is only safe while nothing else has it:
    // an unpublished branch, or one that is ahead of its upstream.
    private var canAmend: Bool {
        guard let snapshot, snapshot.hasCommits else { return false }
        return snapshot.upstream == nil || snapshot.ahead > 0
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
                    Text(files.isEmpty ? "no changes" : "\(files.count) file\(files.count == 1 ? "" : "s")")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    if !files.isEmpty {
                        HStack(spacing: 8) {
                            Text("+\(snapshot.totalAdded)").foregroundStyle(Theme.addition)
                            Text("-\(snapshot.totalRemoved)").foregroundStyle(Theme.deletion)
                        }
                        .font(.mono(13, .medium))
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
                        committing.toggle()
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
                Task { await reload() }
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
        let blocked = busy || commitMessage.trimmingCharacters(in: .whitespaces).isEmpty
            || selectedFiles.isEmpty
        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("Commit message", text: $commitMessage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    .focused($commitFocused)
                    .onSubmit { commit() }

                Button { commit() } label: {
                    Text(amend ? "Amend" : "Commit")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.88)))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(blocked)
                .opacity(blocked ? 0.4 : 1)

                Button("Cancel") {
                    committing = false
                    if amend { amend = false }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Toggle(isOn: Binding(
                    get: { excluded.isEmpty },
                    set: { on in excluded = on ? [] : Set(files.map(\.id)) }
                )) {
                    Text(excluded.isEmpty
                         ? "All \(files.count) file\(files.count == 1 ? "" : "s") selected"
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
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
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
                fail(fold ? "Could not amend" : "Could not commit", error)
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
                message(icon: "checkmark.seal", title: "No uncommitted changes",
                        detail: "The working tree matches the last commit.")
            } else {
                fileList
                if selectedID != nil {
                    Divider().overlay(Theme.hairline)
                    diffPane
                }
            }
        case .notARepo:
            message(icon: "folder", title: "Not a git repository",
                    detail: "This folder is not tracked by git, so there is nothing to compare against.")
        case .missingFolder:
            message(icon: "questionmark.folder", title: "Folder not found",
                    detail: root.abbreviatedPath)
        case .gitMissing:
            message(icon: "exclamationmark.triangle", title: "git not found",
                    detail: "Install the command line developer tools or add git to your PATH.")
        case .failed(let reason):
            message(icon: "exclamationmark.triangle", title: "Could not read this repository",
                    detail: reason, mono: true)
        case nil:
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(files) { file in
                    row(file)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        // Give the diff the room once a file is open, otherwise fill the pane.
        .frame(maxHeight: selectedID == nil ? .infinity : 260)
    }

    private func row(_ file: GitChange) -> some View {
        let isSelected = file.id == selectedID
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
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Theme.card : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Theme.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appContextMenu {
            [.item("Reveal in Finder") { reveal(file) },
             .item("Copy Path") {
                 NSPasteboard.general.clearContents()
                 NSPasteboard.general.setString(fileURL(file).path, forType: .string)
             },
             .separator,
             .item("Discard Changes", kind: .destructive) { confirmDiscard(file) }]
        }
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

    @ViewBuilder private var diffPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let file = selected {
                HStack(spacing: 10) {
                    Text(file.fileName).font(.serif(15, .semibold)).lineLimit(1)
                    Text(file.kind.label).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if loadingDiff { ProgressView().controlSize(.small) }
                    Button("Reveal in Finder") { reveal(file) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
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
            }

            diffBody(truncationHint: "Open the file to see the rest.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card)
    }

    // The rendered diff below a pane header, shared by the file pane and the commit
    // pane so both truncate and report notes the same way.
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
            message(icon: "exclamationmark.triangle", title: "Could not read the history",
                    detail: historyNote, mono: true)
        } else if let commits {
            if commits.isEmpty {
                message(icon: "clock", title: "No commits yet",
                        detail: "This branch has no history to show.")
            } else {
                historyList(commits)
                if selectedCommit != nil {
                    Divider().overlay(Theme.hairline)
                    commitDiffPane
                }
            }
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func historyList(_ commits: [GitCommitSummary]) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(commits) { commit in
                    commitRow(commit)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        // Give the diff the room once a commit is open, otherwise fill the pane.
        .frame(maxHeight: selectedCommit == nil ? .infinity : 260)
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
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Theme.card : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Theme.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appContextMenu {
            [.item("Copy Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.hash, forType: .string)
            }]
        }
    }

    @ViewBuilder private var commitDiffPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let commit = selectedCommit {
                HStack(spacing: 10) {
                    Text(commit.subject).font(.serif(15, .semibold)).lineLimit(1)
                    Text(commit.shortHash)
                        .font(.mono(11, .medium))
                        .foregroundStyle(.secondary)
                    Text("\(commit.author), \(commit.relativeDate)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if loadingDiff { ProgressView().controlSize(.small) }
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
            }

            diffBody(truncationHint: "Run git show in a terminal to see the rest.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card)
    }

    // MARK: - Shared pieces

    private func message(icon: String, title: String, detail: String, mono: Bool = false) -> some View {
        PaneMessage(icon: icon, title: title, detail: detail, mono: mono)
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

    // A pull that worked says nothing: the header numbers and the file list are the report.
    private func report(_ outcome: GitPullOutcome) {
        switch outcome {
        case .upToDate, .updated:
            break
        case .updatedWithStashConflict:
            fail("Pulled, with conflicts",
                 """
                 Origin's commits are in, but your uncommitted changes could not go back on \
                 top of them cleanly. The files hold both versions between conflict markers, \
                 and the originals are kept in a stash, which git stash list will show.
                 """)
        case .failed(let error):
            fail("Could not pull", error)
        }
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
                fail("Could not check commits to push", error)
            }
        }
    }

    private func pushDialog(commits: [GitPushCommit], upstream: String?,
                            hasUpstream: Bool, root: String) -> Dialog {
        let count = commits.count
        let title = count == 0
            ? (hasUpstream ? "Push branch?" : "Publish branch?")
            : "Push \(count) commit\(count == 1 ? "" : "s")?"
        let message = upstream.map {
            count == 0
                ? "No commits are ahead of \($0)."
                : "These commits will be pushed to \($0)."
        } ?? "This branch will be published to origin and start tracking it."
        return Dialog(
            title: title,
            message: message,
            content: AnyView(pushCommitList(commits)),
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
    private func behindDialog(behind: Int, commits: [GitPushCommit], upstream: String?,
                              hasUpstream: Bool, root: String) -> Dialog {
        let target = upstream ?? "origin"
        let mine = commits.count == 1 ? "your commit" : "your \(commits.count) commits"
        return Dialog(
            title: "Pull before pushing",
            message: "\(target) has \(behind) commit\(behind == 1 ? "" : "s") this branch does "
                + "not, so origin would refuse the push. Pulling first puts \(mine) on top.",
            content: AnyView(pushCommitList(commits)),
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
                fail("Could not pull", error)
                await reload()
                return
            }
            working = "Pushing…"
            let error = await GitActions.push(hasUpstream: hasUpstream, at: root)
            working = nil
            if let error {
                fail("Could not push", error)
            } else {
                report(outcome)
            }
            await reload()
        }
    }

    @ViewBuilder private func pushCommitList(_ commits: [GitPushCommit]) -> some View {
        if commits.isEmpty {
            Text("There are no new commits to send.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "COMMITS")
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
            if let error { fail(failure, error) }
            await reload()
        }
    }

    private func fail(_ title: String, _ message: String) {
        dialogs.show(Dialog(title: title, message: message,
                            actions: [.init(label: "OK", kind: .cancel)]))
    }

    private func reload() async {
        loading = true
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
        if let selectedID, let file = fresh.files.first(where: { $0.id == selectedID }) {
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
        guard selectedID != file.id else {
            closeDiff()
            return
        }
        closeDiff()
        selectedID = file.id
        let root = snapshot?.root ?? root
        Task { await loadDiff(file, root: root) }
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
        selectedID = nil
        selectedCommit = nil
        diff = nil
        diffText = nil
    }

    private func loadDiff(_ file: GitChange, root: String) async {
        loadingDiff = true
        let loaded = await GitInspector.diff(for: file, root: root)
        guard !Task.isCancelled, selectedID == file.id else { return }
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
