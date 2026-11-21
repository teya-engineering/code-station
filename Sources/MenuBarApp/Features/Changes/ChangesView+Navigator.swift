import AppKit
import SwiftUI

extension ChangesView {
    // MARK: - Navigator

    private var navigatorItems: [ChangesNavigatorItem] {
        if mode == .history {
            return repositories.flatMap { repository in
                [ChangesNavigatorItem(root: repository.root, path: nil)]
                    + (navigation.collapsedHistories.contains(repository.root) ? [] : shownCommits(repository.root).map {
                        ChangesNavigatorItem(root: repository.root, path: $0.hash)
                    })
            }
        }
        return repositories.flatMap { repository in
            [ChangesNavigatorItem(root: repository.root, path: nil)]
                + (navigation.collapsed.contains(repository.root) ? [] : shownChanges(repository.root).flatMap { file in
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
                if direction == .left { navigation.collapsedHistories.insert(item.root) } else { navigation.collapsedHistories.remove(item.root) }
            } else {
                if direction == .left { navigation.collapsed.insert(item.root) } else { navigation.collapsed.remove(item.root) }
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
            if next.root == root, let commit = model.commits?.first(where: { $0.hash == next.path }) {
                model.historySelection.select(commit)
                announce(commit.subject)
            }
        } else if next.root == root, let file = files.first(where: { $0.id == next.path }) {
            mode = .changes
            select(file)
        }
    }

    var modeChoices: some View {
        HStack(spacing: Space.xs) {
            ChoicePill(title: "Changes \(navigatorFileCount)", selected: mode == .changes) { mode = .changes }
            ChoicePill(title: "History", selected: mode == .history) { mode = .history }
            Spacer(minLength: 0)
            if mode == .changes, let tally = viewedTally { viewedProgress(tally).transition(.fadeIn) }
        }.padding(Space.lg)
    }

    var workspaceNavigator: some View {
        VStack(spacing: 0) {
            modeChoices
            if mode == .history { historyFilterField }
            if mode == .changes && navigatorFileCount > 0 { changesFilterRow }
            filesNavigator
            if mode == .changes, let review { unsentStrip(review) }
            if mode == .changes && !localFiles.isEmpty { commitBar }
        }
        .motion(Motion.reveal, value: unsentCount)
        .background(Theme.card)
    }

    private var navigatorFileCount: Int {
        repositories.reduce(0) { total, repository in total + changes(in: repository.root).count }
    }

    private func repositoryStatus(_ repository: ChangesRepository) -> String {
        if repository.root == root, model.loading { return "Checking" }
        let status = repositorySnapshot(repository.root)
        return ChangesRepository.statusLabel(for: status)
    }

    // MARK: - Comments under their files

    // The repository a project's comments are stored against, which is git's own root.
    func gitRoot(_ repositoryRoot: String) -> String {
        repositorySnapshot(repositoryRoot)?.root ?? repositoryRoot
    }

    func changes(in repositoryRoot: String) -> [GitChange] {
        repositorySnapshot(repositoryRoot)?.files ?? []
    }

    func notesKey(_ repositoryRoot: String, _ path: String) -> String {
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
        var shown = changes(in: repositoryRoot)
        if hidesViewed { shown = shown.filter { viewedState($0, in: repositoryRoot) != .viewed } }
        let query = navigation.fileFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return shown }
        return shown.filter { $0.path.localizedCaseInsensitiveContains(query) }
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
                           focused: navigation.focusedComment == note.id, showsCursor: showsCursor(item),
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
                            if hidesViewed, let tally = viewedTally, tally.isDone {
                                allViewedMessage(tally)
                            } else if isFilteringFiles && repositories.allSatisfy({ shownChanges($0.root).isEmpty }) {
                                Text("No matching files")
                                    .font(Typography.detail).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity).padding(.vertical, Space.xl)
                            }
                            settledNotes
                        }
                    }.padding(Space.md)
                    .smoothlyResizes(when: mode == .history ? navigation.collapsedHistories : navigation.collapsed)
                    .smoothlyResizes(when: navigation.foldedNotes)
                    .smoothlyResizes(when: navigation.hideViewed)
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
                .onChange(of: model.fileSelection.activeID) { _, path in
                    guard let path else { return }
                    let item = ChangesNavigatorItem(root: root, path: path)
                    navigatorCursor = item
                    proxy.scrollTo(item)
                }
                // A comment put in focus from the diff, the chat or the keyboard is brought
                // into view under its file, opening the file's comments if they were folded.
                .onChange(of: navigation.focusedComment) { _, id in
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
                .onChange(of: model.historySelection.commit?.id) { _, hash in
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
                                collapsed: navigation.collapsed.contains(repository.root)) {
                if !navigation.collapsed.insert(repository.root).inserted {
                    navigation.collapsed.remove(repository.root)
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
        if !navigation.collapsed.contains(repository.root) {
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
            hiddenViewedNote(repository.root)
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
            let viewed = viewedState(file, in: repositoryRoot)
            HStack(spacing: Space.md) {
                StatusChip(kind: file.kind).opacity(viewed == .viewed ? 0.5 : 1)
                fileName(file, edited: viewed?.isEdited == true).opacity(viewed == .viewed ? 0.5 : 1)
                notesBadge(file, in: repositoryRoot)
                viewedMark(viewed)
                counts(file).opacity(viewed == .viewed ? 0.5 : 1)
            }
            .motion(Motion.control, value: viewed)
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
        .accessibilityValue(viewedState(file, in: repositoryRoot)?.spoken ?? "")
        .appContextMenu {
            viewedMenuEntries([file], in: repositoryRoot)
        }
    }

    // MARK: - File rows

    private func row(_ file: GitChange) -> some View {
        let isSelected = model.fileSelection.ids.contains(file.id)
        return Button {
            navigatorCursor = ChangesNavigatorItem(root: root, path: file.id)
            navigatorCursorVisible = false
            navigatorFocused = true
            mode = .changes
            select(file)
        } label: {
            HStack(spacing: Space.md) {
                if mode == .changes {
                    if file.hasLocalChanges {
                        commitCheckbox(file)
                    } else {
                        // Holds the checkbox's place so the file names stay in one column.
                        commitCheckbox(file).hidden()
                    }
                }

                let viewed = viewedState(file, in: root)
                StatusChip(kind: file.kind).opacity(viewed == .viewed ? 0.5 : 1)

                fileName(file, edited: viewed?.isEdited == true).opacity(viewed == .viewed ? 0.5 : 1)

                if file.isStaged && file.isUnstaged {
                    Text("partly staged").font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary)
                } else if !file.hasLocalChanges {
                    Text("committed").font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary)
                }

                notesBadge(file, in: root)

                viewedMark(viewed)

                counts(file).opacity(viewed == .viewed ? 0.5 : 1)
            }
            .motion(Motion.control, value: viewedState(file, in: root))
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
        .accessibilityValue(viewedState(file, in: root)?.spoken ?? "")
        .appContextMenu {
            let chosen = model.fileSelection.contextMenuFiles(for: file, in: files)
            // A row with only committed work has nothing to commit or discard, and acting
            // on the rest of the selection from it would not touch the row under the pointer.
            let ids = file.hasLocalChanges ? Set(chosen.map(\.id)) : []
            let targets = localFiles.filter { ids.contains($0.id) }
            let multiple = targets.count > 1
            // A file only the branch's commits changed can still be ticked off as read.
            let viewed = viewedMenuEntries(chosen, in: root)
            let viewedGroup: [MenuEntry] = viewed.isEmpty ? [] : viewed + [.separator]
            let finder: [MenuEntry] = [.item("Reveal in Finder") { reveal(file) },
                                       .item("Copy Path") { Pasteboard.copy(fileURL(file).path) }]
            guard !targets.isEmpty else { return viewedGroup + finder }
            return [.item(multiple ? "Commit \(targets.count) Files…" : "Commit This File…") {
                beginCommit(with: targets)
             },
             .separator]
             + viewedGroup
             + finder
             + [.separator,
                .item(multiple ? "Discard Changes in \(targets.count) Files…" : "Discard Changes",
                      kind: .destructive) { confirmDiscard(targets) }]
        }
    }

    private func commitCheckbox(_ file: GitChange) -> some View {
        Toggle(isOn: Binding(
            get: { !model.commitDraft.excluded.contains(file.id) },
            set: { on in
                if on { model.commitDraft.excluded.remove(file.id) } else { model.commitDraft.excluded.insert(file.id) }
            }
        )) { EmptyView() }
        .toggleStyle(.appCheckbox)
        .appTooltip("Include in the commit")
        .accessibilityLabel("Include " + file.path + " in commit")
        .disabled(model.busy)
    }

    private func beginCommit(with chosen: [GitChange]) {
        model.commitDraft.excluded = Set(localFiles.map(\.id)).subtracting(chosen.map(\.id))
        openCommitDialog()
    }

    // MARK: - History navigator

    private var historyFilterField: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "magnifyingglass")
                .font(Typography.label)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter commits by title or hash",
                      text: Binding(get: { navigation.historyFilter }, set: { navigation.historyFilter = $0 }))
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
        repositoryRoot == root ? model.commits : navigation.commits[repositoryRoot]
    }

    private func shownCommits(_ repositoryRoot: String) -> [GitCommitSummary] {
        (projectCommits(repositoryRoot) ?? []).filter { $0.matches(navigation.historyFilter) }
    }

    private func historyDetail(_ repositoryRoot: String) -> String {
        if repositoryRoot == root, model.historyNote != nil { return "Unavailable" }
        guard let all = projectCommits(repositoryRoot) else { return "Loading" }
        if navigation.historyFilter.trimmingCharacters(in: .whitespaces).isEmpty { return counted(all.count, "commit") }
        return "\(shownCommits(repositoryRoot).count) of \(all.count)"
    }

    // Commits sit under their project the way files sit under it in the Explorer, so the
    // navigator is the one place that names the project and the one control that picks it.
    @ViewBuilder private func historyProject(_ repository: ChangesRepository) -> some View {
        let all = projectCommits(repository.root) ?? []
        let shown = shownCommits(repository.root)
        let item = ChangesNavigatorItem(root: repository.root, path: nil)
        let isCollapsed = navigation.collapsedHistories.contains(repository.root)
        WorkspaceProjectRow(name: repository.name,
                            detail: historyDetail(repository.root),
                            selected: repository.root == root,
                            showsCursor: showsCursor(item),
                            hasChildren: !all.isEmpty,
                            collapsed: isCollapsed) {
            if !navigation.collapsedHistories.insert(repository.root).inserted {
                navigation.collapsedHistories.remove(repository.root)
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
        let isSelected = repositoryRoot == root && model.historySelection.commit?.id == commit.id
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
            model.historySelection.select(commit)
        } else {
            let selection = navigation.history(for: repositoryRoot)
            selection.select(commit)
            selectRepository(repositoryRoot, nil)
        }
        announce(commit.subject)
    }

    // Picking a project opens it on its newest commit, so the page is never left empty.
    private func openProjectHistory(_ repositoryRoot: String) {
        navigation.collapsedHistories.remove(repositoryRoot)
        if let newest = projectCommits(repositoryRoot)?.first {
            openCommit(newest, in: repositoryRoot)
        } else if repositoryRoot != root {
            selectRepository(repositoryRoot, nil)
        }
    }

    private func showsCursor(_ item: ChangesNavigatorItem) -> Bool {
        navigatorFocused && navigatorCursorVisible && navigatorCursor == item
    }

    func fileName(_ file: GitChange, edited: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(file.fileName).font(Typography.detail.weight(.medium)).lineLimit(1)
            Text((file.path as NSString).deletingLastPathComponent)
                .font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary).lineLimit(1)
            if let original = file.originalPath {
                Text("was \(original)").font(Font.system(size: Typography.Size.micro)).foregroundStyle(.secondary).lineLimit(1)
            }
            if edited {
                Text("Edited since you viewed it")
                    .font(Font.system(size: Typography.Size.micro, weight: .medium))
                    .foregroundStyle(Theme.attentionText).lineLimit(1)
                    .transition(.fold)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .appTooltip(file.path)
    }
}

// The rule down the side of a project's rows. It runs into the gaps between rows so the
// line is unbroken.
struct ProjectRule: ViewModifier {
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
