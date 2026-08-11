import AppKit
import SwiftUI

// The uncommitted changes in a session's folder: the project directory itself, or the
// session's worktree. Sessions edit the real files there, so this screen is how you
// see what the agent did before you keep it. The diffs themselves never touch the tree;
// the header carries the little git a review ends in: switch branch, commit, pull, push.
struct ChangesView: View {
    let root: String
    // Set when the screen was opened by something that already knows a commit is the next
    // step, so the message field is waiting rather than a click away.
    var startCommitting = false

    @Environment(DialogPresenter.self) private var dialogs

    @State private var snapshot: GitSnapshot?
    @State private var loading = false
    @State private var working: String?
    @State private var committing = false
    @State private var commitMessage = ""
    @FocusState private var commitFocused: Bool
    @State private var selectedID: GitChange.ID?
    @State private var diff: FileDiff?
    @State private var diffText: NSAttributedString?
    @State private var loadingDiff = false

    private var files: [GitChange] { snapshot?.files ?? [] }
    private var selected: GitChange? { files.first { $0.id == selectedID } }
    private var repoRoot: String { snapshot?.root ?? root }
    private var busy: Bool { loading || working != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            if committing { commitBar }
            content
        }
        .background(Theme.background)
        .task(id: root) { await reload() }
        .onAppear {
            guard startCommitting else { return }
            committing = true
            commitFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            if let snapshot, snapshot.state == .ready {
                branchControl(snapshot)

                if !snapshot.hasCommits {
                    Text("no commits yet").font(.system(size: 12)).foregroundStyle(.secondary)
                }

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

                Spacer()

                if let working {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(working).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else if loading {
                    ProgressView().controlSize(.small)
                }

                if !files.isEmpty {
                    headerAction("Commit", icon: "checkmark.circle") {
                        committing.toggle()
                    }
                }
                if snapshot.upstream != nil {
                    headerAction("Pull", icon: "arrow.down", count: snapshot.behind) {
                        perform("Pulling…", failure: "Could not pull") {
                            await GitActions.pull(at: repoRoot)
                        }
                    }
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
            .help("Refresh")
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
        .help("Switch branch")
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
                Text("Commit")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.88)))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(busy || commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(busy || commitMessage.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)

            Button("Cancel") { committing = false }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .onAppear { commitFocused = true }
    }

    private func commit() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !busy else { return }
        Task {
            working = "Committing…"
            let error = await GitActions.commitAll(message: message, at: repoRoot)
            working = nil
            if let error {
                fail("Could not commit", error)
            } else {
                // The message only clears once it is safely in a commit, so a failed
                // attempt can be fixed and retried without retyping it.
                commitMessage = ""
                committing = false
            }
            await reload()
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch snapshot?.state {
        case .ready:
            if files.isEmpty {
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
             }]
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
                Text("Showing the first \(diff.lines.count) lines of \(diff.totalLines). Open the file to see the rest.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.field)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card)
    }

    // MARK: - Shared pieces

    private func message(icon: String, title: String, detail: String, mono: Bool = false) -> some View {
        PaneMessage(icon: icon, title: title, detail: detail, mono: mono)
    }

    // MARK: - Actions

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
        let fresh = await GitInspector.snapshot(at: root)
        guard !Task.isCancelled else { return }
        snapshot = fresh
        loading = false

        // Keep the open file open across a refresh, but only if it still has changes.
        if let selectedID, let file = fresh.files.first(where: { $0.id == selectedID }) {
            await loadDiff(file, root: fresh.root)
        } else {
            closeDiff()
        }
    }

    private func select(_ file: GitChange) {
        guard selectedID != file.id else {
            closeDiff()
            return
        }
        selectedID = file.id
        diff = nil
        diffText = nil
        let root = snapshot?.root ?? root
        Task { await loadDiff(file, root: root) }
    }

    private func closeDiff() {
        selectedID = nil
        diff = nil
        diffText = nil
    }

    private func loadDiff(_ file: GitChange, root: String) async {
        loadingDiff = true
        let loaded = await GitInspector.diff(for: file, root: root)
        guard !Task.isCancelled, selectedID == file.id else { return }
        diff = loaded
        diffText = loaded.lines.isEmpty ? nil : DiffText.attributed(loaded.lines)
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
            .help(kind.label)
    }
}
