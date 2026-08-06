import AppKit
import SwiftUI

// The uncommitted changes in a session's folder: the project directory itself, or the
// session's worktree. Sessions edit the real files there, so this screen is how you
// see what the agent did before you keep it. The diffs themselves never touch the tree;
// the header carries the little git a review ends in: switch branch, commit, pull, push.
struct ChangesView: View {
    let root: String

    @Environment(DialogPresenter.self) private var dialogs

    @State private var snapshot: GitSnapshot?
    @State private var loading = false
    @State private var working: String?
    @State private var committing = false
    @State private var commitMessage = ""
    @FocusState private var commitFocused: Bool
    @State private var selectedID: GitChange.ID?
    @State private var diff: FileDiff?
    @State private var blocks: [DiffBlock] = []
    @State private var diffWidth: CGFloat = 0
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
                        let hasUpstream = snapshot.upstream != nil
                        perform("Pushing…", failure: "Could not push") {
                            await GitActions.push(hasUpstream: hasUpstream, at: repoRoot)
                        }
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

            Button("Commit") { commit() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.88)))
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
            } else if !blocks.isEmpty {
                diffBody
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

    private var diffBody: some View {
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                // Runs of same kind lines are drawn as one Text so that a 2000 line diff
                // is a few dozen views instead of a few thousand.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(blocks) { block in
                        Text(block.text)
                            .font(.mono(11))
                            .foregroundStyle(color(block.kind))
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, block.kind == .section ? 4 : 0)
                            .frame(width: max(diffWidth, geometry.size.width), alignment: .leading)
                            .background(background(block.kind))
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: Theme.addition
        case .deletion: Theme.deletion
        case .hunk, .meta, .section: .secondary
        case .context: .primary
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: Theme.dotOn.opacity(0.14)
        case .deletion: Theme.deletion.opacity(0.10)
        case .hunk, .section: Theme.field
        case .meta, .context: .clear
        }
    }

    // MARK: - Shared pieces

    private func message(icon: String, title: String, detail: String, mono: Bool = false) -> some View {
        PaneMessage(icon: icon, title: title, detail: detail, mono: mono)
    }

    // MARK: - Actions

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
        blocks = []
        let root = snapshot?.root ?? root
        Task { await loadDiff(file, root: root) }
    }

    private func closeDiff() {
        selectedID = nil
        diff = nil
        blocks = []
    }

    private func loadDiff(_ file: GitChange, root: String) async {
        loadingDiff = true
        let loaded = await GitInspector.diff(for: file, root: root)
        guard !Task.isCancelled, selectedID == file.id else { return }
        diff = loaded
        blocks = DiffBlock.group(loaded.lines)
        diffWidth = DiffBlock.width(of: loaded.lines)
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

// One run of consecutive diff lines that share a kind.
struct DiffBlock: Identifiable {
    let id: Int
    let kind: DiffLine.Kind
    let text: String

    static func group(_ lines: [DiffLine]) -> [DiffBlock] {
        var blocks: [DiffBlock] = []
        var current: [String] = []
        var kind: DiffLine.Kind?

        for line in lines {
            if line.kind != kind, let open = kind {
                blocks.append(DiffBlock(id: blocks.count, kind: open, text: current.joined(separator: "\n")))
                current = []
            }
            kind = line.kind
            current.append(line.text)
        }
        if let kind, !current.isEmpty {
            blocks.append(DiffBlock(id: blocks.count, kind: kind, text: current.joined(separator: "\n")))
        }
        return blocks
    }

    // Monospaced text means the longest line is also the widest, so one measurement is
    // enough to size the scrollable area without laying out every line first.
    static func width(of lines: [DiffLine]) -> CGFloat {
        guard let longest = lines.max(by: { $0.text.count < $1.text.count })?.text else { return 0 }
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let measured = (longest as NSString).size(withAttributes: [.font: font]).width
        return ceil(measured) + 32
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
