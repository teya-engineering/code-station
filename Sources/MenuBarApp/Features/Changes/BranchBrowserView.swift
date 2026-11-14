import AppKit
import SwiftUI

struct BranchBrowserView: View {
    let root: String
    let repository: String
    let mergeInitially: Bool
    let changed: () async -> Void
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(MenuPresenter.self) private var menus
    @State private var catalog: GitBranchCatalog?
    @State private var query = ""
    @State private var selected: GitBranch?
    @State private var loadedPreview: GitBranchPreview?
    @State private var previewGeneration = 0
    @State private var previewRefresh = 0
    @State private var dialogID: UUID?
    @State private var page = Page.branches
    @State private var busy = false
    @State private var previewing = false
    @State private var loading = true
    @State private var message = ""
    @State private var failed = false
    @State private var consent = false
    @State private var method = GitBranchRecovery.Kind.merge
    @State private var branchName = ""
    @State private var worktreePath = ""
    @State private var conflictPaths: [String] = []
    @State private var conflictPath: String?
    @State private var conflictContents: GitConflictContents?
    @State private var resolution = ""
    @State private var confirmedRecovery = false
    @State private var confirmSkip = false
    @State private var keys = WindowKeyHandler(handlesTyping: true)
    @FocusState private var focus: String?

    private enum Page: Equatable { case branches, merge, mergeBack, compare, switchBranch, rebase, create, rename, worktree, stashes, recovery }
    private var visible: [GitBranch] {
        (catalog?.branches ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var preview: GitBranchPreview? {
        guard let loadedPreview, let selected else { return nil }
        if page == .mergeBack {
            return loadedPreview.source.ref == "refs/heads/" + current && loadedPreview.destination == selected.name ? loadedPreview : nil
        }
        return loadedPreview.source.id == selected.id ? loadedPreview : nil
    }
    private var current: String { catalog?.current ?? "" }
    private var isCurrent: Bool { selected?.ref == "refs/heads/" + current }
    // Git keeps a branch in one checkout at a time, so a branch open elsewhere,
    // such as main in the main checkout, can only take new work in that checkout.
    private var canMergeBack: Bool {
        guard let selected, !isCurrent, !current.isEmpty else { return false }
        return !selected.remote && !selected.worktree.isEmpty
    }
    private var renamable: Bool {
        guard let selected, let policy = catalog?.policy else { return false }
        return !selected.remote && (selected.worktree.isEmpty || isCurrent) && policy.allowsRewrite && !policy.protectedNames.contains(selected.name)
    }
    private var editable: Bool {
        guard let selected, let policy = catalog?.policy else { return false }
        return !selected.remote && selected.worktree.isEmpty && policy.allowsRewrite && !policy.protectedNames.contains(selected.name)
    }
    private var title: String {
        switch page {
        case .branches: "Branches"
        case .merge: "Merge branches"
        case .mergeBack: "Merge into " + (selected?.name ?? "branch")
        case .compare: "Compare branches"
        case .switchBranch: "Switch branch"
        case .rebase: "Rebase current branch"
        case .create: "New branch"
        case .rename: "Rename branch"
        case .worktree: "New worktree"
        case .stashes: "Stashes"
        case .recovery: "Recover Git operation"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.md) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .foregroundStyle(Theme.accent).padding(Space.md).background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.card))
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(title).font(Typography.display).accessibilityAddTraits(.isHeader)
                    Text(repository).font(Typography.detail).foregroundStyle(.secondary)
                }
                Spacer()
                if busy || previewing || loading { ChangesProgressLabel(title: busy ? "Working…" : "Reading repository…") }
                GlyphButton(icon: "xmark") { dialogs.dismiss() }
                    .disabled(busy).focused($focus, equals: "close")
                    .accessibilityLabel("Close branches").branchFocus(focus == "close")
            }.padding(Space.xxl)
            Divider()
            if !message.isEmpty {
                ScrollView {
                    HStack(alignment: .top, spacing: Space.md) {
                        Image(systemName: failed ? "exclamationmark.triangle" : "checkmark.circle")
                        Text(message).font(Typography.detail).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }.foregroundStyle(failed ? Theme.deletion : Theme.accent)
                        .padding(Space.lg).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                }.frame(maxHeight: 90).fixedSize(horizontal: false, vertical: true).background(Theme.field)
            }
            ZStack {
                if page == .branches { browser.transition(.fadeIn) }
                else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.xl) {
                            switch page {
                            case .merge, .mergeBack, .compare, .switchBranch, .rebase: previewContent
                            case .create, .rename, .worktree: nameForm
                            case .stashes: stashList
                            case .recovery: recoveryContent
                            case .branches: EmptyView()
                            }
                        }.padding(Space.xxl).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: .infinity)
                        .id(page).transition(.fadeIn)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .motion(Motion.reveal, value: page)
            Divider()
            footer.padding(Space.xl).background(Theme.field)
        }
        .background(Theme.card)
        .smoothlyResizes(when: message)
        .background(WindowKeyAnchor(handler: keys))
        .task {
            await reload()
            guard !Task.isCancelled else { return }
            loading = false
            if catalog?.recovery != nil { page = .recovery; await reloadConflicts() }
            else {
                if let branch = catalog?.branches.first(where: { $0.ref != "refs/heads/" + current && !$0.remote && catalog?.policy.protectedNames.contains($0.name) == true })
                    ?? catalog?.branches.first(where: { $0.ref != "refs/heads/" + current && !$0.remote })
                    ?? catalog?.branches.first(where: { $0.ref != "refs/heads/" + current }) {
                    selected = branch
                    if mergeInitially { page = .merge }
                } else { selected = catalog?.branches.first }
            }
            focus = page == .branches ? "search" : "back"
        }
        .task(id: "\(selected?.id ?? "")/\(page == .mergeBack)/\(previewRefresh)") { await loadPreview() }
        .onAppear {
            dialogID = dialogs.current?.id
            if let dialogID { dialogs.setDismissalGuard(for: dialogID) { !busy } }
            keys.start { handleKey($0) }
        }
        .onDisappear { previewGeneration += 1; keys.stop(); dialogs.restoreFocus() }
    }

    private var browser: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: Space.md) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Find a branch…", text: $query).textFieldStyle(.plain)
                            .focused($focus, equals: "search").accessibilityLabel("Find a branch")
                        Text("⌘ B").foregroundStyle(.secondary).font(Font.system(size: Typography.Size.micro))
                    }.font(Typography.detail).padding(Space.md)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.control))
                        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(focus == "search" ? Theme.accent : Theme.border, lineWidth: focus == "search" ? 2 : 1))
                        .padding(Space.lg)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Space.xs) {
                            if loading && catalog == nil {
                                ChangesLoadingPlaceholder(title: "Reading branches…").padding(Space.lg)
                            } else if visible.isEmpty {
                                Text("No branches match your search. Try another name or create a branch.")
                                    .font(Typography.detail).foregroundStyle(.secondary).padding(Space.lg)
                            }
                            ForEach([false, true], id: \.self) { remote in
                                let group = visible.filter { $0.remote == remote }
                                if !group.isEmpty {
                                    Text(remote ? "REMOTE" : "LOCAL").font(Typography.micro)
                                        .foregroundStyle(.secondary).padding(.top, Space.lg).padding(.horizontal, Space.md)
                                    ForEach(group) { branch in branchRow(branch) }
                                }
                            }
                        }.padding(.horizontal, Space.md).padding(.bottom, Space.lg)
                    }
                }.frame(width: geometry.size.width * 0.44)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        if let selected {
                            Text("SELECTED BRANCH").font(Typography.micro).foregroundStyle(.secondary)
                            Text(selected.name).font(Typography.display).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text(selected.remote ? "Remote-tracking branch" : selected.upstream.isEmpty ? "Local branch · No upstream" : "Tracks " + selected.upstream)
                                .font(Typography.detail).foregroundStyle(.secondary)
                            if !selected.worktree.isEmpty && !isCurrent {
                                Label("Open in " + selected.worktree, systemImage: "folder").font(Typography.caption).foregroundStyle(.secondary)
                            }
                            if catalog?.policy.protectedNames.contains(selected.name) == true {
                                Label("Protected or default branch", systemImage: "lock").font(Typography.caption)
                            }
                            Divider()
                            if isCurrent {
                                Text("You are working on this branch.").font(Typography.detail).foregroundStyle(.secondary)
                                actionRow("Stashes", detail: "Save or restore uncommitted work", icon: "archivebox", id: "stashes") { page = .stashes }
                                actionRow("New branch from here", detail: "Start from your current commit", icon: "plus", id: "create") { openName(.create) }
                            } else {
                                Text(preview.map { "\(counted($0.incoming.count, "incoming commit")) · \(counted($0.outgoing, "current-only commit"))" } ?? "Reading branch differences…")
                                    .font(Typography.detail).foregroundStyle(.secondary)
                                actionRow("Merge into " + current, detail: "Preview changes before merging", icon: "arrow.triangle.merge", id: "merge", emphasis: true) { open(.merge) }
                                if canMergeBack {
                                    actionRow("Merge \(current) into \(selected.name)", detail: "Runs in " + selected.worktree, icon: "arrow.triangle.merge", id: "mergeBack") { open(.mergeBack) }
                                }
                                actionRow("Compare with current branch", detail: "See commits and file differences", icon: "square.split.2x1", id: "compare") { open(.compare) }
                                actionRow("Switch to " + selected.name, detail: selected.worktree.isEmpty ? "Make this your working branch" : "Open in another worktree", icon: "arrow.left.arrow.right", id: "switch") { open(.switchBranch) }
                                    .disabled(!selected.worktree.isEmpty)
                                Divider()
                                actionRow("Rebase current branch onto this", detail: "Replay your commits on " + selected.name, icon: "arrow.triangle.branch", id: "rebase") { open(.rebase) }
                                    .disabled(catalog?.policy.allowsRewrite != true || catalog?.policy.protectedNames.contains(current) == true)
                            }
                            HStack {
                                Spacer()
                                ActionButton(title: "More actions", tone: .outlined, height: ControlHeight.md, icon: "ellipsis")
                                    .appMenu {
                                        var entries: [MenuEntry] = [.item("New worktree from here…", icon: "folder") { openName(.worktree) }]
                                        if renamable { entries.append(.item("Rename branch…") { openName(.rename) }) }
                                        if editable {
                                            entries.append(.item("Delete branch…", kind: .destructive) { confirmDelete() })
                                        }
                                        return entries
                                    }.accessibilityLabel("More actions for " + selected.name)
                                    .focused($focus, equals: "more").branchFocus(focus == "more")
                            }
                        } else if loading {
                            ChangesLoadingPlaceholder(title: "Reading branch details…")
                        } else {
                            Text("Select a branch to see its actions. Selection does not switch branches.")
                                .font(Typography.body).foregroundStyle(.secondary)
                        }
                        if let policy = catalog?.policy {
                            Text(policy.note).font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary)
                        }
                    }.padding(Space.xxl).frame(maxWidth: .infinity, alignment: .leading)
                        .id(selected?.id).transition(.fadeIn)
                        .motion(Motion.reveal, value: previewing)
                }.motion(Motion.reveal, value: selected?.id)
            }
        }.disabled(busy)
    }

    private func branchRow(_ branch: GitBranch) -> some View {
        Button { selected = branch } label: {
            HStack(spacing: Space.md) {
                Image(systemName: branch.remote ? "cloud" : "point.topleft.down.to.point.bottomright.curvepath")
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(branch.name).font(Typography.detail.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text(branch.ref == "refs/heads/" + current ? "Your current branch" : branch.remote ? "Remote-tracking branch" : branch.upstream.isEmpty ? "Local branch" : "Tracks " + branch.upstream)
                        .font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if branch.ref == "refs/heads/" + current { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }.padding(Space.md).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected?.id == branch.id ? Theme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).hoverFill().focused($focus, equals: branch.id).branchFocus(focus == branch.id)
            .appTooltip(branch.name).accessibilityLabel(branch.name + (branch.ref == "refs/heads/" + current ? ", current branch" : ""))
            .accessibilityAddTraits(selected?.id == branch.id ? .isSelected : [])
    }

    private func actionRow(_ title: String, detail: String, icon: String, id: String, emphasis: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: icon).frame(width: 20)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(title).font(Typography.label)
                    Text(detail).font(Typography.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(Space.md).frame(maxWidth: .infinity, alignment: .leading)
                .background(emphasis ? Theme.accent.opacity(0.10) : Theme.field, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).hoverFill().focused($focus, equals: id).branchFocus(focus == id)
    }

    private var previewContent: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: Space.xl) {
                previewBody
            }.id(preview != nil).transition(.fadeIn)
        }
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .motion(Motion.reveal, value: previewing)
    }

    @ViewBuilder private var previewBody: some View {
        if let preview {
            HStack(alignment: .top, spacing: Space.lg) {
                branchCard(page == .rebase || page == .switchBranch || page == .mergeBack ? "From current branch" : "From \(preview.source.remote ? "remote-tracking" : "local") branch",
                           page == .rebase || page == .switchBranch ? preview.destination : preview.source.name)
                Image(systemName: "arrow.right").foregroundStyle(Theme.accent).padding(.top, Space.xxxl)
                branchCard(page == .rebase ? "Replay onto" : page == .switchBranch ? "Switch to" : page == .mergeBack ? "Into its own checkout" : "Into your current branch",
                           page == .rebase || page == .switchBranch ? preview.source.name : preview.destination)
            }
            if page != .switchBranch {
                HStack {
                    Text(counted(preview.incoming.count, "incoming commit")).font(Typography.body.weight(.semibold))
                    Spacer()
                    Label(!preview.remoteVerified ? "Remote status unverified" : preview.conflictNote != nil ? "Conflict check unavailable" : preview.conflicts.isEmpty ? "No conflicts in checked refs" : "\(preview.conflicts.count) conflicts to resolve",
                          systemImage: !preview.remoteVerified || preview.conflictNote != nil || !preview.conflicts.isEmpty ? "exclamationmark.triangle" : "checkmark")
                        .font(Typography.caption).foregroundStyle(preview.remoteVerified && preview.conflicts.isEmpty && preview.conflictNote == nil ? Theme.accent : Theme.deletion)
                }
                if preview.incoming.isEmpty {
                    Text(page == .rebase ? "\(preview.destination) already has everything on \(preview.source.name), so there is nothing to replay."
                            + (canMergeBack ? " To put your work on \(preview.source.name), go back and choose Merge \(preview.destination) into \(preview.source.name)." : "")
                         : page == .mergeBack ? "\(preview.destination) already has everything on \(preview.source.name)."
                         : "Nothing to merge. Choose another branch to bring in new work.").font(Typography.body)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(preview.incoming) { commit in
                        HStack(spacing: Space.md) {
                            Image(systemName: "circle").font(.system(size: 7)).foregroundStyle(Theme.accent)
                            Text(commit.subject).font(Typography.detail)
                            Spacer()
                            Text(commit.shortID).font(Font.mono(Typography.Size.micro)).foregroundStyle(.secondary)
                        }.padding(Space.md)
                        Divider()
                    }
                }.overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.border))
                HStack {
                    Text("\(counted(preview.files.count, "file")) changed")
                    Text("+\(preview.files.compactMap(\.added).reduce(0, +))").foregroundStyle(Theme.addition)
                    Text("-\(preview.files.compactMap(\.removed).reduce(0, +))").foregroundStyle(Theme.deletion)
                }.font(Typography.caption)
                if page == .compare {
                    ForEach(preview.files) { file in
                        HStack {
                            Text(file.path).font(Typography.data).textSelection(.enabled)
                            Spacer()
                            Text(file.isBinary ? "binary" : "+\(file.added ?? 0) -\(file.removed ?? 0)").font(Typography.data)
                        }.padding(.vertical, Space.xs)
                    }
                }
                Text(preview.freshness).font(Typography.caption).foregroundStyle(.secondary)
                if let note = preview.conflictNote { Text(note).font(Typography.detail).foregroundStyle(Theme.deletion) }
                if !preview.conflicts.isEmpty {
                    Text("Resolve changes in:\n" + preview.conflicts.joined(separator: "\n"))
                        .font(Typography.detail).foregroundStyle(Theme.deletion).textSelection(.enabled)
                    if page == .mergeBack {
                        Text("Merge \(preview.destination) into \(preview.source.name) first and resolve the conflicts here.")
                            .font(Typography.detail).foregroundStyle(Theme.deletion)
                    }
                }
            }
            if (page == .merge || page == .mergeBack) && !preview.incoming.isEmpty {
                Text("How to merge").font(Typography.body.weight(.semibold))
                HStack(spacing: Space.md) {
                    if preview.outgoing == 0 {
                        ChoicePill(title: "Fast-forward", selected: method == .fastForward) { method = .fastForward }
                            .focused($focus, equals: "methodFastForward").branchFocus(focus == "methodFastForward")
                    }
                    ChoicePill(title: "Create a merge commit", selected: method == .merge) { method = .merge }
                        .disabled(!preview.policy.allowsMerge).focused($focus, equals: "methodMerge").branchFocus(focus == "methodMerge")
                    ChoicePill(title: "Squash into one commit", selected: method == .squash) { method = .squash }
                        .disabled(!preview.policy.allowsSquash).focused($focus, equals: "methodSquash").branchFocus(focus == "methodSquash")
                }
                Text(method == .fastForward ? "Move \(preview.destination) up to \(preview.source.name) without a new commit."
                     : method == .merge ? "Keep the full history of both branches." : "Combine the incoming changes into one local commit.")
                    .font(Typography.caption).foregroundStyle(.secondary)
            }
            if page == .rebase {
                Text("Rewrites \(preview.outgoing) commits on \(preview.destination). Published commits may require a force push. Conflicts pause the rebase for review.")
                    .font(Typography.detail).foregroundStyle(Theme.deletion)
            }
            if preview.dirtyCount > 0 && page == .mergeBack {
                Label("\(preview.destination) has uncommitted changes in \(selected?.worktree ?? ""). Commit or stash them there first.", systemImage: "archivebox")
                    .font(Typography.detail).foregroundStyle(Theme.deletion)
            } else if preview.dirtyCount > 0 && page != .compare {
                VStack(alignment: .leading, spacing: Space.md) {
                    Label("You have uncommitted changes", systemImage: "archivebox").font(Typography.label)
                    Toggle(isOn: $consent) {
                        Text(page == .switchBranch
                             ? "Stash my changes and leave them saved for \(preview.destination)"
                             : "Stash my changes, then restore them after \(page == .rebase ? "rebasing" : "merging")")
                            .font(Typography.detail)
                    }.toggleStyle(.appCheckbox).focused($focus, equals: "consent").branchFocus(focus == "consent")
                }.padding(Space.lg).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.card))
            }
        } else if previewing {
            ChangesLoadingPlaceholder(title: "Reading branch tips and checking for conflicts…")
                .transition(.opacity)
        } else {
            Text("Select a branch or refresh to try again.")
                .font(Typography.body).foregroundStyle(.secondary)
        }
    }

    private func branchCard(_ label: String, _ name: String) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(label).font(Typography.caption).foregroundStyle(.secondary)
            Text(name).font(Typography.body.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.padding(Space.xl).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(Theme.border))
    }

    private var nameForm: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(page == .create ? "Create a branch from \(current) and switch to it." : page == .rename ? "Rename the local branch \(selected?.name ?? ""). Its remote name stays unchanged." : "Create an isolated checkout from \(selected?.name ?? ""). The current checkout stays unchanged.")
                .font(Typography.body)
            TextField("New branch name", text: $branchName).appTextField().focused($focus, equals: "name")
                .accessibilityLabel("New branch name")
            if page == .worktree {
                TextField("New worktree folder", text: $worktreePath).appTextField().focused($focus, equals: "path")
                    .accessibilityLabel("New worktree folder")
                Text("Enter an absolute path to a folder that does not exist.").font(Typography.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var stashList: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            ActionButton(title: "Stash current changes", tone: .outlined, icon: "archivebox") {
                run { await GitBranches.stash(at: root) }
            }.disabled(busy).focused($focus, equals: "stash")
            if catalog?.stashes.isEmpty != false { Text("No saved stashes in this repository.").font(Typography.body).foregroundStyle(.secondary) }
            ForEach(catalog?.stashes ?? []) { stash in
                VStack(alignment: .leading, spacing: Space.md) {
                    Text(stash.message).font(Typography.detail).textSelection(.enabled)
                    HStack {
                        Text(stash.name + " · " + stash.id.prefix(8)).font(Font.mono(Typography.Size.micro)).foregroundStyle(.secondary)
                        Spacer()
                        ActionButton(title: "Restore on " + current, tone: .outlined, height: ControlHeight.md) {
                            run { await GitBranches.restore(stash, at: root) }
                        }.disabled(busy).focused($focus, equals: stash.id)
                    }
                }.padding(Space.lg).background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.control))
            }
        }
    }

    @ViewBuilder private var recoveryContent: some View {
        if let recovery = catalog?.recovery {
            Text(recovery.restoring ? "The branch operation has ended, but restoring local work needs attention." : "\(recovery.kind.rawValue.capitalized) from \(recovery.source) into \(recovery.branch) is paused.")
                .font(Typography.body.weight(.semibold))
            if let stash = recovery.stash {
                Text("Retained stash: " + stash).font(Typography.data).textSelection(.enabled)
            }
            if recovery.kind == .rebase && !recovery.restoring {
                ActionButton(title: "Skip this commit…", tone: .outlined) {
                    message = "Skipping drops the commit currently being replayed. Press Skip commit to confirm, or continue resolving it."
                    confirmSkip = true
                }.disabled(busy).focused($focus, equals: "skip")
                if confirmSkip {
                    ActionButton(title: "Skip commit", tone: .danger) {
                        confirmSkip = false
                        run { await GitBranches.skipRebaseCommit(at: root) }
                    }.disabled(busy).focused($focus, equals: "confirmSkip")
                }
                Text("During a rebase, Git's current side is the destination plus replayed commits; the incoming side is the commit being replayed.")
                    .font(Typography.caption).foregroundStyle(.secondary)
            }
            ForEach(conflictPaths, id: \.self) { path in
                actionRow(path, detail: "Review both versions or edit the result", icon: "exclamationmark.triangle", id: path) {
                    conflictPath = path
                    Task {
                        conflictContents = await GitBranches.contents(path: path, at: root)
                        resolution = conflictContents?.working ?? ""
                    }
                }
            }
            if let conflictPath, let contents = conflictContents {
                Text(conflictPath).font(Typography.code.weight(.semibold)).textSelection(.enabled)
                HStack(alignment: .top, spacing: Space.lg) {
                    conflictVersion("Current version", text: contents.current)
                    conflictVersion("Incoming version", text: contents.incoming)
                }
                HStack {
                    ActionButton(title: "Use current version", tone: .outlined) { resolve(side: "ours") }.focused($focus, equals: "ours")
                    ActionButton(title: "Use incoming version", tone: .outlined) { resolve(side: "theirs") }.focused($focus, equals: "theirs")
                }.disabled(busy)
                if contents.working != nil {
                    Text("Edit result").font(Typography.label)
                    TextEditor(text: $resolution).font(Typography.data).scrollContentBackground(.hidden)
                        .frame(height: 180).padding(Space.md).background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.control))
                        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.border))
                        .focused($focus, equals: "resolution").accessibilityLabel("Edit resolved file " + conflictPath)
                    ActionButton(title: "Save and mark resolved", tone: .outlined) { resolve(text: resolution) }.disabled(busy).focused($focus, equals: "saveResolution")
                }
                HStack {
                    ActionButton(title: "Reveal for external editing", tone: .outlined) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root).appendingPathComponent(conflictPath)])
                        // Finder opens outside the window, so the line above says the click landed.
                        failed = false
                        message = "Shown in Finder. Mark it resolved here once it is edited."
                    }.focused($focus, equals: "revealConflict")
                    ActionButton(title: "Mark edited file resolved", tone: .outlined) { resolve() }.disabled(busy).focused($focus, equals: "markResolved")
                }
            } else if conflictPaths.isEmpty {
                Text("No unresolved index conflicts. Check any error above before continuing.").font(Typography.detail).foregroundStyle(.secondary)
            }
            if recovery.restoring {
                Text("If restoration stopped before applying all files, recover them from the retained stash. Closing recovery keeps that stash. You can also retry restoration after saving or moving any current work.")
                    .font(Typography.detail).foregroundStyle(.secondary)
                ActionButton(title: "Retry stash restoration", tone: .outlined) {
                    run { await GitBranches.retryRestore(at: root) }
                }.disabled(busy).focused($focus, equals: "retryRestore")
                Toggle("I have checked all restored files", isOn: $confirmedRecovery).toggleStyle(.appCheckbox)
                    .focused($focus, equals: "confirmed")
            }
        } else {
            Text("No operation needs recovery.").font(Typography.body)
        }
    }

    private func conflictVersion(_ title: String, text: String?) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(title).font(Typography.label)
            ScrollView([.horizontal, .vertical]) {
                Text(text ?? "Deleted, binary or too large for an inline preview. Use a version or inspect it in an external editor.")
                    .font(Font.mono(Typography.Size.micro)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 120)
        }.padding(Space.md).frame(maxWidth: .infinity).background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.control))
    }

    private var footer: some View {
        HStack(spacing: Space.md) {
            if page == .branches {
                ActionButton(title: "New branch", tone: .outlined, icon: "plus") { openName(.create) }
                    .disabled(busy || catalog == nil).focused($focus, equals: "new")
                ActionButton(title: "Stashes", tone: .outlined, icon: "archivebox") { page = .stashes }
                    .disabled(busy).focused($focus, equals: "stashesFooter")
                if catalog?.recovery != nil {
                    ActionButton(title: "Resume operation", tone: .outlined) {
                        page = .recovery
                        Task { await reloadConflicts() }
                    }.disabled(busy).focused($focus, equals: "recover")
                }
                Spacer(minLength: 0)
                Text("Current: " + current).font(Typography.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                ActionButton(title: "Back", tone: .outlined) { page = .branches; message = "" }
                    .disabled(busy).focused($focus, equals: "back")
                if page == .merge || page == .mergeBack || page == .compare || page == .rebase || page == .switchBranch {
                    ActionButton(title: "Refresh", tone: .outlined) { previewRefresh += 1 }
                        .disabled(busy || previewing).focused($focus, equals: "refresh")
                }
                Spacer(minLength: 0)
                if page == .merge || page == .mergeBack || page == .rebase || page == .switchBranch {
                    Button { executePreview() } label: {
                        Text(busy ? "Working…" : primaryTitle).font(Typography.label)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true).padding(.horizontal, Space.lg).padding(.vertical, Space.md)
                            .frame(maxWidth: 340).foregroundStyle(Theme.onFill)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Radius.control)).contentShape(Rectangle())
                            .hoverLift()
                    }.buttonStyle(.plain).opacity(canExecute ? 1 : 0.4)
                        .disabled(!canExecute).focused($focus, equals: "primary").branchFocus(focus == "primary")
                } else if page == .compare {
                    ActionButton(title: "Review merge", tone: .green) { open(.merge) }.disabled(preview == nil).focused($focus, equals: "primary")
                } else if page == .create || page == .rename || page == .worktree {
                    ActionButton(title: page == .rename ? "Rename branch" : page == .worktree ? "Create worktree" : "Create branch", tone: .green) { submitName() }
                        .disabled(busy || branchName.isBlank || (page == .worktree && !worktreePath.hasPrefix("/")))
                        .focused($focus, equals: "primary")
                } else if page == .recovery, let recovery = catalog?.recovery {
                    if !recovery.restoring {
                        ActionButton(title: "Abort", tone: .outlined) { run { await GitBranches.abort(at: root) } }
                            .disabled(busy).focused($focus, equals: "abort")
                    }
                    ActionButton(title: recovery.restoring ? "Finish, keep stash" : "Continue " + recovery.kind.rawValue, tone: .green) {
                        run { await GitBranches.continueOperation(at: root) }
                    }.disabled(busy || !conflictPaths.isEmpty || (recovery.restoring && !confirmedRecovery)).focused($focus, equals: "primary")
                }
            }
        }
    }

    private var primaryTitle: String {
        if page == .switchBranch { return "Switch branch" }
        if page == .rebase { return "Rebase onto " + (selected?.name ?? "branch") }
        let name = selected?.name ?? "branch"
        if page == .mergeBack { return (method == .fastForward ? "Fast-forward " : method == .squash ? "Squash into " : "Merge into ") + name }
        return (method == .fastForward ? "Fast-forward to " : method == .squash ? "Squash " : "Merge ") + name
    }

    private var canExecute: Bool {
        guard let preview, !busy, !previewing else { return false }
        if page == .mergeBack {
            guard preview.dirtyCount == 0, preview.conflicts.isEmpty, preview.conflictNote == nil else { return false }
        } else if preview.dirtyCount > 0 && !consent { return false }
        if page == .switchBranch { return preview.source.worktree.isEmpty }
        guard preview.remoteVerified, !preview.incoming.isEmpty else { return false }
        if page == .rebase { return preview.policy.allowsRewrite && !preview.policy.protectedNames.contains(preview.destination) }
        return switch method {
        case .fastForward: preview.outgoing == 0
        case .merge: preview.policy.allowsMerge
        default: preview.policy.allowsSquash
        }
    }

    private func open(_ page: Page) {
        self.page = page
        consent = false
        message = ""
        focus = "back"
    }

    private func openName(_ page: Page) {
        self.page = page
        branchName = page == .rename ? selected?.name ?? "" : ""
        worktreePath = ""
        message = ""
        focus = "name"
    }

    private func reload() async {
        let result = await GitBranches.catalog(at: root)
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let value): catalog = value
        case .failure(let error): report(GitBranchResult(message: GitBranches.errorMessage(error), failed: true))
        }
    }

    private func loadPreview() async {
        previewGeneration += 1
        let generation = previewGeneration
        if preview == nil { loadedPreview = nil }
        consent = false
        let mergingBack = page == .mergeBack
        guard let selected, selected.ref != "refs/heads/" + current,
              let source = mergingBack ? catalog?.branches.first(where: { $0.ref == "refs/heads/" + current }) : selected else {
            previewing = false
            return
        }
        message = ""
        failed = false
        previewing = true
        let result = await GitBranches.preview(source, at: mergingBack ? selected.worktree : root)
        guard self.selected?.id == selected.id, mergingBack == (page == .mergeBack), generation == previewGeneration, !Task.isCancelled else { return }
        previewing = false
        switch result {
        case .success(let value):
            loadedPreview = value
            method = value.outgoing == 0 && !value.incoming.isEmpty ? .fastForward : value.policy.allowsMerge ? .merge : .squash
        case .failure(let error):
            loadedPreview = nil
            report(GitBranchResult(message: GitBranches.errorMessage(error), failed: true))
        }
    }

    private func executePreview() {
        guard canExecute, let preview else { return }
        let consent = consent
        let kind = page == .rebase ? GitBranchRecovery.Kind.rebase : method
        if page == .switchBranch { run { await GitBranches.switchBranch(preview, consent: consent, at: root) } }
        else if page == .mergeBack, let target = selected?.worktree {
            run { await GitBranches.integrateIntoOtherCheckout(preview, kind: kind, at: target) }
        }
        else { run { await GitBranches.integrate(preview, kind: kind, consent: consent, at: root) } }
    }

    private func submitName() {
        if page == .rename, let selected { run { await GitBranches.rename(selected, to: branchName, at: root) } }
        else {
            let source = page == .worktree ? selected : catalog?.branches.first { $0.ref == "refs/heads/" + current }
            let path = page == .worktree ? worktreePath : nil
            run { await GitBranches.create(name: branchName, from: source, worktree: path, at: root) }
        }
    }

    private func confirmDelete(force: Bool = false) {
        guard let selected, editable else { return }
        let unmerged = preview?.unmergedCount ?? 0
        dialogs.show(.impact(force ? "Force delete branch?" : "Delete branch?",
            subject: .init(name: repository), rows: [
                .init(title: selected.name, detail: "This local branch reference will be deleted."),
                .init(title: current, detail: "Your current branch stays.", kept: true),
                .init(title: "Working files and remote branches", detail: "Your work and remote references stay.", kept: true)
            ], warning: unmerged > 0 ? "\(unmerged) commits are not in the current branch. Force deletion can make them difficult to recover."
                : "Deleting a branch reference cannot be undone here.",
            action: unmerged > 0 && !force ? "Review force deletion…" : force ? "Force delete branch" : "Delete branch") {
                if unmerged > 0 && !force { confirmDelete(force: true) }
                else {
                    Task {
                        let result = await GitBranches.delete(selected, force: force, at: root)
                        await changed()
                        dialogs.show(.notice(result.failed ? "Could not delete branch" : "Branch deleted", message: result.message))
                    }
                }
            })
    }

    private func run(_ operation: @escaping () async -> GitBranchResult) {
        guard !busy else { return }
        busy = true
        Task {
            let result = await operation()
            report(result)
            await reload()
            await changed()
            busy = false
            conflictPath = nil
            conflictContents = nil
            confirmedRecovery = false
            if catalog?.recovery != nil { page = .recovery; await reloadConflicts() }
            else if !result.failed { page = .branches; selected = nil; loadedPreview = nil }
        }
    }

    private func report(_ result: GitBranchResult) {
        message = result.message
        failed = result.failed
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: result.message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func resolve(side: String? = nil, text: String? = nil) {
        guard let conflictPath else { return }
        run { await GitBranches.resolve(path: conflictPath, side: side, text: text, at: root) }
    }

    private func reloadConflicts() async { conflictPaths = await GitBranches.conflicts(at: root) }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard dialogs.current?.id == dialogID, !menus.isOpen else { return false }
        if event.keyCode == 53 { if !busy { dialogs.dismiss() }; return true }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "b" {
            if !busy { page = .branches; focus = "search" }
            return true
        }
        if page == .branches, !busy, modifiers.isEmpty, event.keyCode == 125 || event.keyCode == 126 {
            let index = visible.firstIndex { $0.id == selected?.id } ?? (event.keyCode == 125 ? -1 : visible.count)
            let next = index + (event.keyCode == 125 ? 1 : -1)
            if visible.indices.contains(next) { selected = visible[next] }
            return true
        }
        if event.keyCode == 48 {
            // Keep keyboard navigation within this custom modal, including plain buttons.
            if busy { return true }
            var order: [String] = []
            switch page {
            case .branches:
                order = ["search"] + visible.map(\.id)
                if selected != nil {
                    if isCurrent { order += ["stashes", "create"] }
                    else {
                        order.append("merge")
                        if canMergeBack { order.append("mergeBack") }
                        order.append("compare")
                        if selected?.worktree.isEmpty == true { order.append("switch") }
                        if catalog?.policy.allowsRewrite == true && catalog?.policy.protectedNames.contains(current) != true { order.append("rebase") }
                    }
                    order.append("more")
                }
                order += ["new", "stashesFooter"]
                if catalog?.recovery != nil { order.append("recover") }
            case .create, .rename, .worktree:
                order = ["name"]
                if page == .worktree { order.append("path") }
                order.append("back")
                if !branchName.isBlank && (page != .worktree || worktreePath.hasPrefix("/")) { order.append("primary") }
            case .stashes: order = ["stash"] + (catalog?.stashes.map(\.id) ?? []) + ["back"]
            case .recovery:
                order = []
                if catalog?.recovery?.kind == .rebase && catalog?.recovery?.restoring == false {
                    order.append("skip")
                    if confirmSkip { order.append("confirmSkip") }
                }
                order += conflictPaths
                if let contents = conflictContents {
                    order += ["ours", "theirs"]
                    if contents.working != nil { order += ["resolution", "saveResolution"] }
                    order += ["revealConflict", "markResolved"]
                }
                if catalog?.recovery?.restoring == true { order += ["retryRestore", "confirmed"] }
                order.append("back")
                if catalog?.recovery?.restoring == false { order.append("abort") }
                if conflictPaths.isEmpty && (catalog?.recovery?.restoring != true || confirmedRecovery) { order.append("primary") }
            default:
                if page == .merge || page == .mergeBack, let preview, !preview.incoming.isEmpty {
                    if preview.outgoing == 0 { order.append("methodFastForward") }
                    if preview.policy.allowsMerge { order.append("methodMerge") }
                    if preview.policy.allowsSquash { order.append("methodSquash") }
                }
                if page != .compare && page != .mergeBack && (preview?.dirtyCount ?? 0) > 0 { order.append("consent") }
                order.append("back")
                if !previewing { order.append("refresh") }
                if canExecute || page == .compare && preview != nil { order.append("primary") }
            }
            order.append("close")
            let index = order.firstIndex(of: focus ?? "") ?? 0
            let step = modifiers.contains(.shift) ? -1 : 1
            focus = order[(index + step + order.count) % order.count]
            return true
        }
        return false
    }
}

private extension View {
    func branchFocus(_ focused: Bool) -> some View {
        overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(focused ? Theme.accent : .clear, lineWidth: 2))
    }
}
