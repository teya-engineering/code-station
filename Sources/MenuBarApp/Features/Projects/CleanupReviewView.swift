import AppKit
import SwiftUI

// The one place where everything cleanup holds for a yes is answered. The waiting list
// is the sweep's own, so its length is the number on the sidebar card. Each row says why
// it waits and what deleting it would cost, and offers three answers: open it, keep it
// (for a week, for good, or by reading it), or delete it after a dialog that names what
// goes. What the countdown will take lives in its own sheet, one link away.
struct CleanupReviewView: View {
    let status: OldSessionSweep.Status
    // Swaps this sheet for the list of what the countdown will take.
    let showCountdown: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(AppSettings.self) private var appSettings
    @Environment(OrphanedWorktreeMonitor.self) private var orphans
    @Environment(\.dismiss) private var dismiss

    @State private var picked: Set<OldSessionSweep.Parked.Item> = []
    // Rows answered in this sheet. They fold out at once rather than waiting for the
    // sweep's next pass to drop them from its list.
    @State private var answered: Set<OldSessionSweep.Parked.Item> = []
    // Fresh reads of each worktree, since the sweep's last answer can be an hour old. A
    // row with no answer yet is still being checked and cannot be deleted.
    @State private var costs: [UUID: SessionRemovalCost] = [:]
    @State private var orphanOutcomes: [String: SessionOutcome] = [:]
    @State private var isDeleting = false
    @State private var showsWhy = false
    @State private var note = TransientNote(duration: .seconds(3))

    // A row in the waiting list: the sweep's reasons, and the session or worktree they
    // belong to.
    struct Item: Identifiable {
        let parked: OldSessionSweep.Parked
        let session: ChatSession?
        let orphan: OrphanedWorktree?

        var id: OldSessionSweep.Parked.Item { parked.item }
    }

    // What deleting everything still on the list would throw away, added up from the
    // rows that have been checked.
    struct Stake: Equatable {
        var added = 0
        var removed = 0
        var commits = 0
        var designs = 0

        var isEmpty: Bool { added == 0 && removed == 0 && commits == 0 && designs == 0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .zIndex(1)
            readings
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if items.isEmpty {
                        emptyState
                    } else {
                        family(.losesWork, title: "Would lose work", dot: Theme.deletion,
                               detail: "Deleting throws away something that exists nowhere else.")
                        family(.notLookedAt, title: "Review first", dot: Theme.attention,
                               detail: "Your rules keep these until you decide.")
                    }
                }
                .padding(Space.pane)
                .motion(Motion.leave, value: answered)
            }
            .frame(minHeight: 220, maxHeight: 480)

            SheetFooter(primary: SheetAction(title: deleteLabel,
                                             enabled: canDeletePicked,
                                             tone: .danger,
                                             action: { confirmDelete(pickedItems) }),
                        dismissTitle: "Cancel",
                        dismiss: closeOrDismiss) {
                countdownLink
            }
        }
        .frame(width: 660)
        .background(Theme.background)
        .interactiveDismissDisabled(isDeleting)
        .headerNote(note, alignment: .top, top: Space.md)
        .task { await load() }
    }

    // Escape puts the explanation away before it closes the sheet.
    private func closeOrDismiss() {
        if showsWhy {
            showsWhy = false
        } else if !isDeleting {
            dismiss()
        }
    }

    // MARK: - Header

    private var header: some View {
        SheetTitle(name: "Waiting for your OK", icon: "hourglass",
                   tint: Theme.attention, ink: Theme.attentionText, count: items.count) {
            WhyButton(label: "Why these wait", isOpen: $showsWhy) {
                Text("These have reached the age set by their matching rules, and at least one rule asks for review. They stay until you decide, however old they get.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Space.pane)
        .headerBand()
    }

    // The threshold, then what is at stake across the rows still on the list.
    private var readings: some View {
        let stake = stake
        return HStack(spacing: Space.md) {
            if items.isEmpty {
                StatusCaps(text: "NOTHING IS WAITING")
            } else {
                StatusCaps(text: "OLD UNDER YOUR RULES")
                StatusRule()
                if stake.isEmpty {
                    StatusCaps(text: "NOTHING AT STAKE")
                } else {
                    StatusCaps(text: "AT STAKE")
                    ForEach(Array(Self.stakeReadings(stake).enumerated()), id: \.element) { index, reading in
                        if index > 0 { StatusDot() }
                        switch reading {
                        case .diff(let added, let removed):
                            DiffPair(added: added, removed: removed)
                                .contentTransition(.numericText())
                        case .value(let text):
                            StatusValue(text: text)
                                .contentTransition(.numericText())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .motion(Motion.pop, value: stake)
        .accessibilityElement(children: .combine)
        .statusBand(padding: Space.pane)
    }

    enum StakeReading: Hashable {
        case diff(added: Int, removed: Int)
        case value(String)
    }

    // "+3000 −16 · 2 commits · 1 design", leaving out whatever is nothing.
    nonisolated static func stakeReadings(_ stake: Stake) -> [StakeReading] {
        var readings: [StakeReading] = []
        if stake.added > 0 || stake.removed > 0 {
            readings.append(.diff(added: stake.added, removed: stake.removed))
        }
        if stake.commits > 0 { readings.append(.value(counted(stake.commits, "commit"))) }
        if stake.designs > 0 { readings.append(.value(counted(stake.designs, "design"))) }
        return readings
    }

    // "1 other is deleted at the countdown"
    nonisolated static func countdownLink(_ count: Int) -> String {
        "\(counted(count, "other")) \(count == 1 ? "is" : "are") deleted at the countdown"
    }

    @ViewBuilder
    private var countdownLink: some View {
        if let deletion = status.deletion {
            HStack(spacing: Space.sm) {
                Image(systemName: "timer")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.accent)
                Text(Self.countdownLink(deletion.total))
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                InlineLink(title: "See which", action: showCountdown)
            }
            .accessibilityElement(children: .contain)
            .transition(.fadeIn)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 20))
                .foregroundStyle(Theme.dotOnText)
            Text("Nothing is waiting for you")
                .font(Typography.title)
            Text("Sessions whose matching rules ask for review wait here until you decide. Rules that allow auto-delete start a one-hour countdown instead.")
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xxxl)
        .transition(.fadeIn)
    }

    // MARK: - Waiting list

    private var items: [Item] {
        status.parked.compactMap { parked in
            guard !answered.contains(parked.item) else { return nil }
            switch parked.item {
            case .session(let id):
                guard let session = store.session(id) else { return nil }
                return Item(parked: parked, session: session, orphan: nil)
            case .worktree(let path):
                guard let orphan = orphans.worktrees.first(where: { $0.id == path }) else {
                    return nil
                }
                return Item(parked: parked, session: nil, orphan: orphan)
            }
        }
    }

    // One rule names the group and counts it. The sentence behind the name is a hover
    // away, since the name already says it.
    @ViewBuilder
    private func family(_ family: CleanupReason.Family, title: String, dot: Color,
                        detail: String) -> some View {
        let rows = items.filter { $0.parked.family == family }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Space.md) {
                SectionRule(title: title.uppercased(), dot: dot) {
                    Text(verbatim: "\(rows.count)")
                        .font(Typography.caps)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: Double(rows.count)))
                        .motion(Motion.pop, value: rows.count)
                }
                .appTooltip(detail)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        WaitingRow(item: item,
                                   project: projectName(item),
                                   age: age(item),
                                   diff: diff(item),
                                   commits: commits(item),
                                   divided: index > 0,
                                   isChecking: isChecking(item),
                                   picked: picked.contains(item.id),
                                   isDeleting: isDeleting,
                                   togglePick: { togglePick(item) },
                                   open: { open(item) },
                                   keepMenu: { keepMenu(item) },
                                   delete: { confirmDelete([item]) })
                            .transition(.fold)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                .cardSurface()
            }
            .transition(.fadeIn)
        }
    }

    private func projectName(_ item: Item) -> String {
        if let orphan = item.orphan { return orphan.projectName }
        guard let session = item.session else { return "" }
        return store.project(session.projectID)?.name ?? "Unknown project"
    }

    private func age(_ item: Item) -> String {
        if let orphan = item.orphan {
            guard orphan.allocatedBytes > 0 else { return "No session owns it" }
            return "No session · \(orphan.allocatedBytes.formatted(.byteCount(style: .file)))"
        }
        guard let session = item.session else { return "" }
        return SessionAge.phrase(since: session.cleanupActivity)
    }

    // The lines that are not committed, once the worktree has been read.
    private func diff(_ item: Item) -> (added: Int, removed: Int)? {
        let outcome = if let orphan = item.orphan {
            orphanOutcomes[orphan.id]
        } else {
            item.session.flatMap { costs[$0.id]?.worktree }
        }
        if case .wouldLoseWork(let added, let removed)? = outcome { return (added, removed) }
        return nil
    }

    private func commits(_ item: Item) -> Int {
        item.session.flatMap { costs[$0.id]?.unpushedCommits } ?? 0
    }

    private var stake: Stake {
        items.reduce(into: Stake()) { stake, item in
            if let diff = diff(item) {
                stake.added += diff.added
                stake.removed += diff.removed
            }
            stake.commits += commits(item)
            if let session = item.session, costs[session.id]?.design == .unimplemented {
                stake.designs += 1
            }
        }
    }

    private func isChecking(_ item: Item) -> Bool {
        if let orphan = item.orphan { return orphanOutcomes[orphan.id] == nil }
        guard let id = item.session?.id else { return false }
        return costs[id]?.canSelect != true
    }

    // MARK: - Footer

    private var pickedItems: [Item] {
        items.filter { picked.contains($0.id) }
    }

    private var canDeletePicked: Bool {
        !isDeleting && !pickedItems.isEmpty && !pickedItems.contains(where: isChecking)
    }

    private var deleteLabel: String {
        let count = pickedItems.count
        return count == 0 ? "Delete selected" : "Delete \(counted(count, "item"))"
    }

    // MARK: - Loading

    private func load() async {
        for item in items {
            guard let session = item.session else { continue }
            let starting = SessionCost.startingCost(worktrees: worktreePaths(session),
                                                    design: store.designCost(for: session))
            if starting.worktree != .checking { costs[session.id] = starting }
        }
        for item in items {
            guard !Task.isCancelled else { return }
            if let session = item.session, costs[session.id] == nil {
                costs[session.id] = await SessionCost.settledCost(
                    worktrees: worktreePaths(session),
                    design: store.designCost(for: session))
            } else if let orphan = item.orphan {
                orphanOutcomes[orphan.id] = await SessionCost.settledOutcome(
                    worktrees: [orphan.path])
            }
        }
    }

    private func worktreePaths(_ session: ChatSession) -> [String] {
        store.checkoutProjects(for: session).compactMap(\.worktreePath)
    }

    // MARK: - Acting

    private func togglePick(_ item: Item) {
        guard !isChecking(item), !isDeleting else { return }
        if picked.contains(item.id) { picked.remove(item.id) } else { picked.insert(item.id) }
    }

    private func open(_ item: Item) {
        if let session = item.session {
            store.selectSession(session.id)
            dismiss()
        } else if let orphan = item.orphan {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: orphan.path)])
            show("Shown in Finder")
        }
    }

    private func keepMenu(_ item: Item) -> [MenuEntry] {
        let until = Date().addingTimeInterval(OldSessions.deferral)
        let day = ProjectSnooze.wakeDay(until)
        var entries: [MenuEntry] = [
            .item("Ask again in a week", icon: "clock",
                  subtitle: "Hidden from this list until \(day)") {
                deferCleanup(item.id, until: until)
                answer(item.id)
                show("Hidden until \(day)")
            }
        ]
        guard let session = item.session else { return entries }
        entries.append(.item("Pin it", icon: "pin", subtitle: "Pinned sessions are never old") {
            store.setPinned(true, forSession: session.id)
            answer(item.id)
            show("Pinned “\(session.title)”")
        })
        if item.parked.reasons.contains(.unread) {
            entries.append(.item("Mark as read", icon: "envelope.open",
                                 subtitle: "It goes at the next sweep if nothing else holds it") {
                store.markRead(session.id)
                // Still held for something else, it stays, with that reason left.
                if item.parked.reasons.allSatisfy({ $0 == .unread }) { answer(item.id) }
                show("Marked as read")
            })
        }
        return entries
    }

    private func deferCleanup(_ id: OldSessionSweep.Parked.Item, until: Date) {
        switch id {
        case .session(let sessionID): store.deferCleanup(of: sessionID, until: until)
        case .worktree(let path): orphans.deferCleanup(of: path, until: until)
        }
    }

    private func answer(_ id: OldSessionSweep.Parked.Item) {
        answered.insert(id)
        picked.remove(id)
    }

    // Every deletion from here is confirmed, with one line for each thing that goes and
    // what it takes with it. The warning is there whenever any of it is work that exists
    // nowhere else.
    private func confirmDelete(_ chosen: [Item]) {
        guard !chosen.isEmpty, !isDeleting, !chosen.contains(where: isChecking) else { return }
        showsWhy = false
        var rows = chosen.map { item in
            Dialog.Impact.Row(title: title(item), detail: goes(item))
        }
        if chosen.contains(where: { item in
            item.orphan != nil || item.session.map { !worktreePaths($0).isEmpty } == true
        }) {
            rows.append(.init(title: "Branches with commits",
                              detail: "They stay in the repository.", kept: true))
        }
        let work = chosen.count { $0.parked.family == .losesWork }
        let warning: String? = switch work {
        case 0: nil
        case 1: "One of these holds work that exists nowhere else. It cannot be restored."
        default: "\(work) of these hold work that exists nowhere else. It cannot be restored."
        }
        let action = "Delete \(counted(chosen.count, "item"))"
        dialogs.show(.impact("\(action)?",
                             message: work > 0
                                 ? "Read the list: some of this is work, not just history."
                                 : "Only history goes. Nothing on disk is lost.",
                             rows: rows, warning: warning, action: action) {
            delete(chosen)
        })
    }

    private func title(_ item: Item) -> String {
        if let orphan = item.orphan { return orphanTitle(orphan) }
        return item.session?.title ?? ""
    }

    private func orphanTitle(_ orphan: OrphanedWorktree) -> String {
        "Orphaned worktree \(orphan.branch ?? (orphan.path as NSString).lastPathComponent)"
    }

    // What goes with one row: the changes, the commits, the design, or only the history.
    private func goes(_ item: Item) -> String {
        if let orphan = item.orphan {
            if case .wouldLoseWork(let added, let removed)? = orphanOutcomes[orphan.id] {
                return "The checkout, with +\(added) −\(removed) uncommitted"
            }
            return "The checkout"
        }
        guard let session = item.session, let cost = costs[session.id] else { return "The conversation" }
        var parts = ["The conversation"]
        if case .wouldLoseWork(let added, let removed) = cost.worktree {
            parts.append("+\(added) −\(removed) uncommitted")
        } else if cost.worktree == .worktreeRemoved {
            parts.append("a clean worktree")
        }
        if cost.unpushedCommits > 0 {
            parts.append("\(counted(cost.unpushedCommits, "unpushed commit")) in its worktree")
        }
        if cost.design == .unimplemented { parts.append("unbuilt design files") }
        return parts.joined(separator: ", ")
    }

    private func delete(_ chosen: [Item]) {
        guard !isDeleting else { return }
        isDeleting = true
        SessionLog.note("cleanup review deletion started count=\(chosen.count)")
        Task {
            var failures: [String] = []
            var deleted: [Item] = []
            for item in chosen {
                if let session = item.session {
                    let result = await SessionLifecycle.remove(session, from: store, runner: runner)
                    if case .failure(let failure) = result {
                        failures.append(failure.message)
                        continue
                    }
                } else if let orphan = item.orphan {
                    let result = await orphans.prune([orphan], in: store)
                    failures += result.failures.map(\.message)
                    guard !result.removed.isEmpty else { continue }
                }
                deleted.append(item)
                answer(item.id)
            }
            isDeleting = false
            SessionLog.note("cleanup review deletion finished count=\(deleted.count) failures=\(failures.count)")
            if !failures.isEmpty {
                dialogs.show(.notice(failures.count == 1 ? "Could not delete an item"
                                         : "Could not delete some items",
                                     message: failures.joined(separator: "\n")))
            }
            if deleted.count == 1 {
                show("Deleted “\(title(deleted[0]))”")
            } else if deleted.count > 1 {
                show("Deleted \(counted(deleted.count, "item"))")
            }
        }
    }

    private func show(_ text: String) {
        note.show(text, icon: "checkmark")
    }
}

// One row of the waiting list: the tick and the name, then why it waits, whose it is
// and how old, then the three answers. The reasons are chips in the colour of their
// family, so a scan down the list reads the colours before the words. Uncommitted work
// is shown as its diff, which is both the reason and the cost.
private struct WaitingRow: View {
    let item: CleanupReviewView.Item
    let project: String
    let age: String
    let diff: (added: Int, removed: Int)?
    let commits: Int
    // Every row but the first is split from the one above by a hairline. The line
    // belongs to the row, so it folds away with it.
    let divided: Bool
    let isChecking: Bool
    let picked: Bool
    let isDeleting: Bool
    let togglePick: () -> Void
    let open: () -> Void
    let keepMenu: () -> [MenuEntry]
    let delete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if divided {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            HStack(alignment: .top, spacing: Space.lg) {
                Toggle(isOn: Binding(get: { picked }, set: { _ in togglePick() })) { EmptyView() }
                    .toggleStyle(.appCheckbox)
                    .disabled(isChecking || isDeleting)
                    .opacity(isChecking ? 0.4 : 1)
                    .accessibilityLabel("Select \(title)")

                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(title)
                        .font(Typography.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    facts
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: Space.xs) {
                    GlyphButton(icon: item.session == nil ? "folder" : "arrow.up.right",
                                side: ControlHeight.sm, action: open)
                        .appTooltip(item.session == nil ? "Show in Finder" : "Open")
                        .accessibilityLabel(item.session == nil ? "Show \(title) in Finder" : "Open \(title)")
                    RowAction(title: "Keep", disclosure: true)
                        .appMenu(keepMenu)
                        .accessibilityLabel("Keep \(title)")
                    GlyphButton(icon: "trash", side: ControlHeight.sm, tint: Theme.deletion,
                                action: delete)
                        .disabled(isChecking || isDeleting)
                        .appTooltip("Delete")
                        .accessibilityLabel("Delete \(title)")
                }
            }
            .padding(Space.card)
            .background(picked ? Theme.accent.opacity(0.07) : .clear)
            .hoverFill(cornerRadius: 0)
        }
        .motion(Motion.control, value: picked)
        .accessibilityElement(children: .contain)
    }

    private var facts: some View {
        HStack(spacing: Space.sm) {
            ForEach(item.parked.reasons, id: \.self) { reason in
                CleanupReasonChip(text: chipText(reason), reason: reason,
                                  diff: isChecking ? nil : diff)
            }
            if isChecking {
                Text("Checking the worktree…")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .transition(.opacity)
            }
            HStack(spacing: Space.sm) {
                ProjectDot(tint: Theme.projectTint(for: project))
                Text(project)
                    .font(Typography.data)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(-1)
            Text(age)
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .motion(Motion.reveal, value: isChecking)
    }

    private var title: String {
        if let orphan = item.orphan {
            return "Orphaned worktree \(orphan.branch ?? (orphan.path as NSString).lastPathComponent)"
        }
        return item.session?.title ?? ""
    }

    // "Snoozed until 15 Nov" when the snooze has an end, and the count of commits once
    // the branch has been read.
    private func chipText(_ reason: CleanupReason) -> String {
        if reason == .unpushedCommits, commits > 0 {
            return "\(counted(commits, "commit")) not pushed"
        }
        guard reason == .snoozed, let deadline = item.session?.snooze?.deadline else {
            return reason.title
        }
        return "Snoozed until \(ProjectSnooze.wakeDay(deadline))"
    }
}

// The Keep answer at the end of a row: accent words with a chevron, opening its menu.
private struct RowAction: View {
    let title: String
    var tint: Color = Theme.accent
    var disclosure = false

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        label
            .opacity(isEnabled ? 1 : 0.4)
            .hoverLift(hovering && isEnabled)
            .onPointerHover { hovering = $0 }
    }

    private var label: some View {
        HStack(spacing: Space.xxs) {
            Text(title)
                .font(Typography.label)
            if disclosure {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Space.sm)
        .frame(height: ControlHeight.sm)
        .background(tint.opacity(hovering && isEnabled ? 0.1 : 0), in: RoundedRectangle(cornerRadius: Radius.inset))
        .motion(Motion.hover, value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: Radius.inset))
    }
}
