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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    @State private var filter: Filter = .all
    @State private var picked: Set<OldSessionSweep.Parked.Item> = []
    // Rows answered in this sheet. They fold out at once rather than waiting for the
    // sweep's next pass to drop them from its list.
    @State private var answered: Set<OldSessionSweep.Parked.Item> = []
    // Fresh reads of each worktree, since the sweep's last answer can be an hour old. A
    // row with no answer yet is still being checked and cannot be deleted.
    @State private var costs: [UUID: SessionRemovalCost] = [:]
    @State private var orphanOutcomes: [String: SessionOutcome] = [:]
    @State private var isDeleting = false
    @State private var note: String?
    @State private var notes = 0

    enum Filter: Hashable {
        case all
        case family(CleanupReason.Family)
    }

    // A row in the waiting list: the sweep's reasons, and the session or worktree they
    // belong to.
    struct Item: Identifiable {
        let parked: OldSessionSweep.Parked
        let session: ChatSession?
        let orphan: OrphanedWorktree?

        var id: OldSessionSweep.Parked.Item { parked.item }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if items.isEmpty {
                        emptyState
                    } else {
                        pills
                        family(.losesWork, title: "Would lose work",
                               detail: "Deleting throws away something that exists nowhere else.")
                        family(.notLookedAt, title: "Not looked at yet",
                               detail: "Nothing on disk is lost, but you have not been back to these.")
                    }
                    if let deletion = status.deletion {
                        CleanupCrossLink(icon: "timer",
                                         tint: Theme.accent,
                                         text: Self.countdownLink(deletion.total),
                                         action: "See which",
                                         go: showCountdown)
                    }
                }
                .padding(Space.xxl)
                .motion(Motion.leave, value: answered)
                .motion(Motion.control, value: filter)
            }
            .frame(minHeight: 220, maxHeight: 480)

            SheetFooter(title: footerNote,
                        primary: SheetAction(title: deleteLabel,
                                             enabled: canDeletePicked,
                                             tone: .danger,
                                             action: { confirmDelete(pickedItems) }),
                        dismissTitle: "Cancel",
                        dismiss: { if !isDeleting { dismiss() } })
        }
        .frame(width: 660)
        .background(Theme.background)
        .interactiveDismissDisabled(isDeleting)
        .overlay(alignment: .top) {
            ZStack {
                if let note {
                    HeaderNote(icon: "checkmark", text: note)
                        .padding(.top, Space.md)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
                }
            }
            .motion(Motion.reveal, value: note)
        }
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(items.isEmpty ? "Waiting for your OK" : "\(items.count) waiting for your OK")
                .font(Typography.title)
                .contentTransition(.numericText(value: Double(items.count)))
                .motion(Motion.pop, value: items.count)
            Text("These are older than \(counted(appSettings.oldSessionDays, "day")), but deleting them would cost you something. They stay until you decide, however old they get.")
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .headerBand()
    }

    // "5 other sessions will be deleted when the countdown ends, without asking."
    nonisolated static func countdownLink(_ count: Int) -> String {
        "\(counted(count, "other session")) will be deleted when the countdown ends, without asking."
    }

    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 20))
                .foregroundStyle(Theme.dotOnText)
            Text("Nothing is waiting for you")
                .font(Typography.body.weight(.semibold))
            Text("Sessions older than \(counted(appSettings.oldSessionDays, "day")) that hold work or that you have not looked at will show up here. Read sessions with nothing to lose are cleared after a one-hour warning.")
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xxxl)
        .transition(.fadeIn)
    }

    private var pills: some View {
        let work = items.count { $0.parked.family == .losesWork }
        let unseen = items.count - work
        return HStack(spacing: Space.sm) {
            ChoicePill(title: "All \(items.count)", selected: filter == .all) {
                filter = .all
            }
            ChoicePill(title: "Would lose work \(work)",
                       selected: filter == .family(.losesWork), enabled: work > 0) {
                filter = .family(.losesWork)
            }
            ChoicePill(title: "Not looked at \(unseen)",
                       selected: filter == .family(.notLookedAt), enabled: unseen > 0) {
                filter = .family(.notLookedAt)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter")
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

    @ViewBuilder
    private func family(_ family: CleanupReason.Family, title: String,
                        detail: String) -> some View {
        let rows = items.filter { $0.parked.family == family }
        if !rows.isEmpty, filter == .all || filter == .family(family) {
            VStack(alignment: .leading, spacing: Space.md) {
                familyHeader(title: title, detail: detail)
                ForEach(rows) { item in
                    WaitingRow(item: item,
                               detail: meta(item),
                               cost: costLine(item),
                               lossTint: family == .losesWork,
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
            .transition(.fadeIn)
        }
    }

    private func familyHeader(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Typography.body.weight(.semibold))
            Text(detail)
                .font(Typography.detail)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.xxs)
    }

    // "code-station · Last turn 9 days ago"
    private func meta(_ item: Item) -> String {
        if let orphan = item.orphan {
            return "\(orphan.projectName) · No session owns it"
        }
        guard let session = item.session else { return "" }
        let project = store.project(session.projectID)?.name ?? "Unknown project"
        return "\(project) · Last turn \(SessionAge.phrase(since: session.lastActivity))"
    }

    // What deleting would cost, in the row's own words.
    private func costLine(_ item: Item) -> String? {
        if let orphan = item.orphan {
            guard let outcome = orphanOutcomes[orphan.id] else { return nil }
            let size = orphan.allocatedBytes > 0
                ? " · \(orphan.allocatedBytes.formatted(.byteCount(style: .file))) on disk" : ""
            if case .wouldLoseWork(let added, let removed) = outcome {
                return "+\(added) −\(removed) not committed\(size)"
            }
            return "No changes\(size)"
        }
        guard let session = item.session, let cost = costs[session.id] else { return nil }
        var parts: [String] = []
        if case .wouldLoseWork(let added, let removed) = cost.worktree {
            parts.append("+\(added) −\(removed) not committed")
        }
        if cost.unpushedCommits > 0 {
            parts.append("\(counted(cost.unpushedCommits, "commit")) on no remote")
        }
        if cost.design == .unimplemented { parts.append("Design never handed over") }
        if parts.isEmpty {
            if let snooze = session.snooze, snooze.isActive() {
                parts.append("History only · snoozed \(snooze.phrase())")
            } else if cost.worktree == .worktreeRemoved {
                parts.append("Conversation and a clean worktree")
            } else {
                parts.append("Conversation only")
            }
        }
        return parts.joined(separator: " · ")
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

    private var footerNote: String {
        let chosen = pickedItems
        guard !chosen.isEmpty else { return "Nothing here is deleted until you choose it." }
        let work = chosen.count { $0.parked.family == .losesWork }
        return work > 0 ? "\(chosen.count) selected · \(work) would lose work"
            : "\(chosen.count) selected"
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

    // A second note keeps the line up rather than letting the first one's timer take it
    // down early.
    private func show(_ text: String) {
        notes += 1
        let shown = notes
        note = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notes == shown { note = nil }
        }
    }
}

// One row of the waiting list: the tick, who it is and why it waits, what deleting costs,
// and the three answers. The reasons are chips in the colour of their family, so a scan
// down the list reads the colours before the words.
private struct WaitingRow: View {
    let item: CleanupReviewView.Item
    let detail: String
    let cost: String?
    let lossTint: Bool
    let isChecking: Bool
    let picked: Bool
    let isDeleting: Bool
    let togglePick: () -> Void
    let open: () -> Void
    let keepMenu: () -> [MenuEntry]
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Toggle(isOn: Binding(get: { picked }, set: { _ in togglePick() })) { EmptyView() }
                .toggleStyle(.appCheckbox)
                .disabled(isChecking || isDeleting)
                .opacity(isChecking ? 0.4 : 1)
                .accessibilityLabel("Select \(title)")

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title)
                    .font(Typography.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(Typography.data)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: Space.xs) {
                    ForEach(item.parked.reasons, id: \.self) { reason in
                        CleanupReasonChip(text: chipText(reason), reason: reason)
                    }
                }
                Text(isChecking ? "Checking the worktree…" : (cost ?? ""))
                    .font(Typography.data)
                    .foregroundStyle(isChecking || !lossTint ? Color.secondary : Theme.deletion)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Space.xs) {
                RowAction(title: item.session == nil ? "Show in Finder" : "Open", action: open)
                RowAction(title: "Keep", disclosure: true)
                    .appMenu(keepMenu)
                    .accessibilityLabel("Keep \(title)")
                RowAction(title: "Delete", tint: Theme.deletion, action: delete)
                    .disabled(isChecking || isDeleting)
                    .accessibilityLabel("Delete \(title)")
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.lg)
        .surface(Theme.card, cornerRadius: Radius.card,
                 border: picked ? Theme.deletion.opacity(0.45) : Theme.border)
        .hoverFill(cornerRadius: Radius.card)
        .motion(Motion.control, value: picked)
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        if let orphan = item.orphan {
            return "Orphaned worktree \(orphan.branch ?? (orphan.path as NSString).lastPathComponent)"
        }
        return item.session?.title ?? ""
    }

    // "Snoozed until 15 Nov" when the snooze has an end.
    private func chipText(_ reason: CleanupReason) -> String {
        guard reason == .snoozed, let deadline = item.session?.snooze?.deadline else {
            return reason.title
        }
        return "Snoozed until \(ProjectSnooze.wakeDay(deadline))"
    }
}

// A small inline action at the end of a row: accent text, or red for the one that
// deletes.
private struct RowAction: View {
    let title: String
    var tint: Color = Theme.accent
    var disclosure = false
    var action: (() -> Void)? = nil

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
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
        .frame(height: 24)
        .background(tint.opacity(hovering && isEnabled ? 0.1 : 0), in: RoundedRectangle(cornerRadius: Radius.inset))
        .motion(Motion.hover, value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: Radius.inset))
    }
}
