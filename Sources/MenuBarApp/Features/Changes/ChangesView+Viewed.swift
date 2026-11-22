import AppKit
import SwiftUI

extension ChangesView {
    func repositorySnapshot(_ repositoryRoot: String) -> GitSnapshot? {
        if repositoryRoot == root { return snapshot }
        return review == nil ? gitStats.snapshot(at: repositoryRoot) : navigation.snapshots[repositoryRoot]
    }

    // MARK: - Viewed files

    // The comparison read during the last refresh.
    func version(_ file: GitChange, in repositoryRoot: String) -> ViewedChange? {
        repositorySnapshot(repositoryRoot)?.reviewChanges[file.path]
    }

    // Files are ticked off only in a session, whose review keeps the ticks. Nil outside
    // one, and until the file's content has been read.
    func viewedState(_ file: GitChange, in repositoryRoot: String) -> ViewedState? {
        guard let review, let version = version(file, in: repositoryRoot) else { return nil }
        return review.reviews.viewed.state(notesKey(repositoryRoot, file.path), change: version,
                                           in: review.sessionID)
    }

    var hidesViewed: Bool { review != nil && navigation.hideViewed }

    var hasViewedMarks: Bool { review.map { $0.reviews.viewed.hasMarks($0.sessionID) } ?? false }

    var viewedTally: ViewedTally? {
        guard review != nil, repositories.allSatisfy({ navigation.snapshots[$0.root]?.state == .ready }) else { return nil }
        var viewed = 0
        var total = 0
        for repository in repositories {
            for file in changes(in: repository.root) {
                total += 1
                if viewedState(file, in: repository.root) == .viewed { viewed += 1 }
            }
        }
        return total == 0 ? nil : ViewedTally(viewed: viewed, total: total)
    }

    // What the turn's footer counts: the changed files, or the open commit's in History.
    var footerTally: ViewedTally? { mode == .changes ? viewedTally : historyTally }

    func toggleViewed(_ file: GitChange, in repositoryRoot: String, advance: Bool = false) {
        guard let review,
              let version = advance ? model.diff?.reviewChange : version(file, in: repositoryRoot) else { return }
        advanceTask?.cancel()
        let store = review.reviews.viewed
        let key = notesKey(repositoryRoot, file.path)
        if store.state(key, change: version, in: review.sessionID) == .viewed {
            store.unmark(key, change: version, in: review.sessionID)
            announce("\(file.fileName) marked not viewed")
            return
        }
        store.mark(key, change: version, in: review.sessionID)
        announce("\(file.fileName) marked viewed")
        keepViewedText(file, change: version, in: repositoryRoot, store: store)
        guard advance, repositoryRoot == root, file.id == model.fileSelection.activeID else { return }
        advanceTask?.cancel()
        advanceTask = Task {
            // The tick lands first, so moving on reads as the result of it.
            try? await Task.sleep(for: .seconds(Motion.controlDuration))
            guard !Task.isCancelled, model.fileSelection.activeID == file.id else { return }
            openNextNotViewed(after: file)
        }
    }

    // The text read is kept beside the tick, so the lines the agent adds later can be
    // picked out.
    func keepViewedText(_ file: GitChange, change: ViewedChange, in repositoryRoot: String,
                        store: ViewedFileStore) {
        guard !file.isBinary, file.kind != .deleted else { return }
        let gitRoot = gitRoot(repositoryRoot)
        Task {
            guard let read = await FileVersion.text(at: file.path, root: gitRoot),
                  read.version == change.after.blob else { return }
            store.keep(read.text, for: change.after.blob)
        }
    }

    func setViewed(_ targets: [GitChange], _ viewed: Bool, in repositoryRoot: String) {
        guard let review else { return }
        let store = review.reviews.viewed
        for file in targets {
            guard let version = version(file, in: repositoryRoot) else { continue }
            let key = notesKey(repositoryRoot, file.path)
            if viewed {
                store.mark(key, change: version, in: review.sessionID)
                keepViewedText(file, change: version, in: repositoryRoot, store: store)
            } else {
                store.unmark(key, change: version, in: review.sessionID)
            }
        }
        let what = targets.count == 1 ? targets[0].fileName : counted(targets.count, "file")
        announce("\(what) marked \(viewed ? "viewed" : "not viewed")")
    }

    func viewedMenuEntries(_ targets: [GitChange], in repositoryRoot: String) -> [MenuEntry] {
        let states = targets.compactMap { viewedState($0, in: repositoryRoot) }
        guard !states.isEmpty else { return [] }
        let allViewed = states.allSatisfy { $0 == .viewed }
        let multiple = targets.count > 1
        let title = allViewed
            ? (multiple ? "Mark \(targets.count) Files as Not Viewed" : "Mark as Not Viewed")
            : (multiple ? "Mark \(targets.count) Files as Viewed" : "Mark as Viewed")
        return [.item(title, detail: multiple ? nil : keyBindings.label(for: .toggleViewed)) {
            setViewed(targets, !allViewed, in: repositoryRoot)
        }]
    }

    // The next changed file not viewed yet: further down this project, then round from
    // its top, then in the projects after it.
    func openNextNotViewed(after current: GitChange?) {
        let here = changes(in: root)
        let start = current.flatMap { file in here.firstIndex { $0.id == file.id } } ?? -1
        let ordered = Array(here.suffix(from: min(here.count, start + 1))) + Array(here.prefix(max(0, start)))
        if let next = ordered.first(where: { viewedState($0, in: root) != .viewed }) {
            open(next)
            return
        }
        for repository in repositories where repository.root != root {
            if let next = changes(in: repository.root).first(where: { viewedState($0, in: repository.root) != .viewed }) {
                selectRepository(repository.root, next.id)
                return
            }
        }
        if let current, viewedState(current, in: root) != .viewed {
            announce("This is the last file not viewed yet")
        } else if repositories.contains(where: { repositorySnapshot($0.root) == nil }) {
            announce("Still reading the other projects")
        } else {
            announce("Every changed file is viewed")
        }
    }

    // Opens a file as a plain click would, whatever keys happen to be held.
    func open(_ file: GitChange) {
        mode = .changes
        navigatorCursor = ChangesNavigatorItem(root: root, path: file.id)
        model.fileSelection.select(file.id, in: files.map(\.id), extendingRange: false, toggling: false)
        let root = repoRoot
        Task { await model.loadDiff(file, at: root, for: screen) }
    }

    func clearViewed() {
        guard let review else { return }
        let store = review.reviews.viewed
        let session = review.sessionID
        let cleared = store.checkpoint(in: session)
        store.clear(session)
        showToast("Viewed marks cleared", action: "Undo") { store.restore(cleared, in: session) }
    }

    // Scrolls to the first of the new lines, and washes them all in amber once so the eye
    // lands on them.
    func goToNewLines() {
        guard let diff = model.diff, let first = NumberedDiffLine.lines(diff.lines)
            .first(where: { shownFreshKeys.contains(DiffComments.key($0.anchor)) }) else { return }
        freshRevealKey = DiffComments.key(first.anchor)
        freshRevealFlash = shownFreshKeys
        freshRevealSerial += 1
    }

    var freshRequest: FreshRequest? {
        guard mode == .changes, let review, let file = shownFile, let diff = model.diff, !diff.lines.isEmpty,
              let version = version(file, in: root), diff.reviewChange == version, !model.loadingDiff,
              viewedState(file, in: root)?.isEdited == true,
              let since = review.reviews.viewed.latest(notesKey(root, file.path), change: version, in: review.sessionID)?.version
        else { return nil }
        return FreshRequest(root: repoRoot, fileID: file.id, version: version, since: since, lines: diff.lines.count)
    }

    var shownFreshKeys: Set<String> {
        guard let freshLines, let request = freshRequest, freshLines.request == request else { return [] }
        return freshLines.keys
    }

    // Compares the text last viewed with the file now, to find the lines added since, and
    // with the version the diff compares with, to find the removed lines it still had.
    func findFreshLines() async {
        guard let request = freshRequest, let review else {
            freshLines = nil
            return
        }
        let current = request.version.after == .absent
            ? (version: FileVersion.deleted, text: "")
            : await FileVersion.text(at: request.fileID, root: repoRoot)
        guard let viewed = review.reviews.viewed.text(of: request.since), let current,
              current.version == request.version.after.blob else {
            freshLines = FreshLines(request: request, keys: [])
            return
        }
        let base = request.version.before == .absent ? nil
            : await GitInspector.blobText(request.version.before.blob, root: request.root)
        let (added, removed) = await Git.offMain(lane: .interactive) {
            (ViewedLines.added(since: viewed, in: current.text),
             base.map { ViewedLines.removed(since: viewed, in: current.text, base: $0) } ?? [])
        }
        guard !Task.isCancelled, freshRequest == request, let diff = model.diff else { return }
        freshLines = FreshLines(request: request,
                                keys: ViewedLines.freshKeys(added: added, removed: removed, in: diff.lines))
    }

    // A tick for a file read, or an amber dot for one the agent has edited since.
    func viewedMark(_ state: ViewedState?) -> some View {
        ZStack {
            if state == .viewed {
                Image(systemName: "checkmark")
                    .font(.system(size: Typography.Size.micro, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: Space.xxs)))
            } else if state?.isEdited == true {
                Circle().fill(Theme.attention).frame(width: Space.sm, height: Space.sm)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: review == nil ? 0 : Space.lg)
        .accessibilityHidden(true)
    }

    func viewedProgress(_ tally: ViewedTally) -> some View {
        HStack(spacing: Space.sm) {
            ProgressRing(fraction: Double(tally.viewed) / Double(tally.total))
            ViewThatFits(in: .horizontal) {
                Text(tally.label)
                Text("\(tally.viewed)/\(tally.total)")
            }
            .font(Typography.caption.monospacedDigit())
            .lineLimit(1)
            .contentTransition(.numericText())
        }
        .foregroundStyle(tally.isDone ? Theme.accent : Color.secondary)
        .padding(.horizontal, Space.sm)
        .frame(height: ControlHeight.sm)
        .contentShape(Rectangle())
        .hoverLift(amount: Motion.smallLift)
        .motion(Motion.control, value: tally)
        .appMenu {
            [.item("Hide viewed files", checked: navigation.hideViewed) { navigation.hideViewed.toggle() },
             .item("Open the next file not viewed", detail: keyBindings.label(for: .nextNotViewed),
                   disabled: tally.isDone) { openNextNotViewed(after: shownFile) },
             .separator,
             .item("Clear viewed marks", disabled: !hasViewedMarks) { clearViewed() }]
        }
        .accessibilityLabel("\(tally.viewed) of \(tally.total) files viewed")
        .accessibilityHint("Hide viewed files, open the next one, or clear the marks")
    }

    func allViewedMessage(_ tally: ViewedTally) -> some View {
        VStack(spacing: Space.sm) {
            Text("All \(counted(tally.total, "file")) viewed").font(Typography.label)
            Text("Viewed files are hidden. A file comes back on its own if the agent edits it again.")
                .font(Typography.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            InlineLink(title: "Show viewed files", size: Typography.Size.caption) { navigation.hideViewed = false }
        }
        .frame(maxWidth: .infinity).padding(.vertical, Space.xl).padding(.horizontal, Space.md)
        .transition(.fadeIn)
    }

    @ViewBuilder func hiddenViewedNote(_ repositoryRoot: String) -> some View {
        if hidesViewed, !navigation.collapsed.contains(repositoryRoot), viewedTally?.isDone != true {
            let hidden = changes(in: repositoryRoot).filter { viewedState($0, in: repositoryRoot) == .viewed }.count
            if hidden > 0 {
                HStack(spacing: Space.sm) {
                    Text("\(counted(hidden, "viewed file")) hidden")
                        .font(Typography.caption).foregroundStyle(.secondary)
                    InlineLink(title: "Show", size: Typography.Size.caption) { navigation.hideViewed = false }
                }
                .padding(.leading, Space.xxxl + Space.md).padding(.vertical, Space.xs)
                .modifier(ProjectRule())
                .transition(.fold)
            }
        }
    }

    // Says a file the person ticked off has changed since, and how much of it is new.
    func editedBand(since: Date) -> some View {
        let count = shownFreshKeys.count
        let time = Calendar.current.isDateInToday(since)
            ? since.formatted(date: .omitted, time: .shortened)
            : since.formatted(date: .abbreviated, time: .shortened)
        let lines = count > 0 ? " \(counted(count, "new line")) \(count == 1 ? "carries" : "carry") an amber mark." : ""
        return HStack(spacing: Space.md) {
            Circle().fill(Theme.attention).frame(width: Space.sm, height: Space.sm).accessibilityHidden(true)
            Text("\(Text("Edited again since you viewed it at \(time).").fontWeight(.semibold))\(lines)")
                .font(Typography.detail)
                .foregroundStyle(Theme.attentionText)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: Space.md)
            if count > 0 {
                InlineLink(title: "Go to the new lines", tint: Theme.attentionText) { goToNewLines() }
            }
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.attention.opacity(0.12))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

}

struct FreshLines: Equatable {
    var request: FreshRequest
    var keys: Set<String>
}

struct FreshRequest: Equatable {
    var root: String
    var fileID: String
    var version: ViewedChange
    var since: String
    var lines: Int
}
