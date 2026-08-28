import SwiftUI

// The offer to clear out sessions that have gone quiet. Everything here is a choice: the
// sheet arrives with the harmless rows ticked and says, next to each one, exactly what
// deleting it costs. Anything that would lose work can only be cleared from here.
struct OldSessionsView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [Row] = []
    @State private var ticked: Set<UUID> = []
    // Counted apart from `ticked`, so unticking a row the app chose never buys room for
    // another one to be chosen in its place.
    @State private var autoTicked = 0
    @State private var deletionProgress: DeletionProgress?

    // A tick is a promise the user has read the row. Past a certain length nobody reads the
    // whole list, so the ticking stops and anything beyond it has to be asked for by hand.
    private static let preselectLimit = 50

    private var days: Int { appSettings.oldSessionDays }

    private struct Row: Identifiable {
        let session: ChatSession
        let projectName: String
        var cost: SessionRemovalCost

        var id: UUID { session.id }
    }

    private struct DeletionProgress {
        let total: Int
        var completed = 0
        // The session being worked on rather than the one about to be. A checkout can take
        // a while to clear, and a counter alone leaves that time looking like nothing is
        // happening.
        var current = ""
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(rows) { row in
                        SessionChoiceRow(title: row.session.title,
                                         projectName: row.projectName,
                                         detail: detail(row),
                                         cost: row.cost,
                                         hasWorktree: !worktreePaths(row.session).isEmpty,
                                         ticked: ticked.contains(row.id),
                                         canToggle: row.cost.canSelect && !isDeleting,
                                         toggle: { toggle(row) })
                    }
                    // Said out loud, so a half-ticked list reads as a decision rather than
                    // a glitch.
                    if preselectCapped {
                        notice(icon: "checklist",
                               "Only the first \(Self.preselectLimit) sessions are ticked for you. Tick the rest by hand if you want those gone as well.")
                    }
                    // What this screen can do that cannot be undone, said before the button
                    // is reached rather than in a dialog after it.
                    if designArtifactsAtRisk > 0 {
                        notice(icon: "paintbrush.pointed", tint: Theme.deletion,
                               Self.designArtifactsCost(designArtifactsAtRisk, unticked: true))
                    }
                    if dirtyWorktrees > 0 {
                        notice(icon: "exclamationmark.triangle", tint: Theme.deletion,
                               Self.dirtyWorktreeCost(dirtyWorktrees, unticked: true))
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 420)

            SheetFooter(title: footerNote,
                        primary: SheetAction(title: deleteLabel,
                                             enabled: !ticked.isEmpty && !isDeleting,
                                             tone: .danger, action: confirmDelete),
                        dismiss: { if !isDeleting { dismiss() } })
                .disabled(isDeleting)
        }
        .frame(width: 620)
        .background(Theme.background)
        .interactiveDismissDisabled(isDeleting)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Sessions older than \(counted(days, "day"))")
                .font(.serif(16))
            Text("Ticked sessions are removed from the app. Change the \(counted(days, "day")) in Settings.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    // A card under the list saying something about the list as a whole. Tinted when it
    // warns, plain when it only explains.
    private func notice(icon: String, tint: Color? = nil, _ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint ?? Color.secondary)
            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .surface(tint?.opacity(0.07) ?? Theme.card, cornerRadius: 10,
                 border: tint?.opacity(0.25) ?? Theme.border)
    }

    // What deleting would cost, worded for one session or for several. The card that
    // flags the rows adds that they were left unticked; the dialog that asks again
    // leaves that out, since by then the user has ticked them.
    private static func designArtifactsCost(_ count: Int, unticked: Bool) -> String {
        if count == 1 {
            return "One Design session contains generated files\(unticked ? ", so it is left unticked" : ""). "
                + "Deleting it permanently removes its HTML and local assets."
        }
        return "\(count) Design sessions contain generated files\(unticked ? ", so they are left unticked" : ""). "
            + "Deleting them permanently removes their HTML and local assets."
    }

    private static func dirtyWorktreeCost(_ count: Int, unticked: Bool) -> String {
        if count == 1 {
            return "One session has uncommitted changes in its worktree\(unticked ? ", so it is left unticked" : ""). "
                + "Deleting it loses those changes; its branch survives if git considers that safe."
        }
        return "\(count) sessions have uncommitted changes in their worktrees\(unticked ? ", so they are left unticked" : ""). "
            + "Deleting them loses those changes; their branches survive if git considers that safe."
    }

    // Which one of them is being worked on, not how many are behind: a count that reads 0
    // for as long as the first session takes says nothing about whether it is moving.
    private var deleteLabel: String {
        if let progress = deletionProgress {
            return "Deleting \(min(progress.completed + 1, progress.total)) of \(progress.total)…"
        }
        return ticked.isEmpty ? "Delete" : "Delete \(counted(ticked.count, "session"))"
    }

    // The line that explains the button while there is nothing to explain, and names what
    // is being cleared once there is.
    private var footerNote: String {
        guard let current = deletionProgress?.current, !current.isEmpty else {
            return "Project folders stay on disk. Ticked Design files and session worktrees are removed."
        }
        return "Clearing \(current)…"
    }

    private var isDeleting: Bool {
        deletionProgress != nil
    }

    private var designArtifactsAtRisk: Int {
        rows.count { $0.cost.deletesDesignArtifacts }
    }

    private var dirtyWorktrees: Int {
        rows.count { $0.cost.worktree.losesWork }
    }

    private var preselectCapped: Bool {
        rows.count { $0.cost.losesNothing } > Self.preselectLimit
    }

    // "last turn 9 days ago · 4 turns · ⑂ code-station/pty-test · clean"
    private func detail(_ row: Row) -> String {
        var parts = ["last turn " + SessionAge.phrase(since: row.session.lastActivity)]
        if let turns = row.session.usage?.turns, turns > 0 {
            parts.append(counted(turns, "turn"))
        }
        let worktrees = worktreePaths(row.session)
        if let path = worktrees.first {
            let label = worktrees.count == 1
                ? (row.session.worktreeBranch ?? (path as NSString).lastPathComponent)
                : "\(worktrees.count) worktrees"
            parts.append("⑂ " + label)
            switch row.cost.worktree {
            case .checking: parts.append("checking…")
            case .checkFailed: parts.append("check failed")
            case .wouldLoseWork(let added, let removed):
                parts.append("+\(added) -\(removed) uncommitted")
            default: parts.append("clean")
            }
        } else {
            parts.append("no worktree")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Loading

    // A session that is running is never old, however long ago its last turn was: it is
    // busy right now, which is the opposite of what this screen is for.
    private func load() async {
        rows = OldSessions.olderThan(days, in: store.userSessions)
            .filter { !runner.state($0.id).isBusy }
            .map { session in
                Row(session: session,
                    projectName: session.workspaceID.flatMap(store.workspace)?.name
                        ?? store.project(session.projectID)?.name ?? "",
                    cost: startingCost(session))
            }
        ticked = Set(rows.filter { $0.cost.losesNothing }
            .prefix(Self.preselectLimit)
            .map(\.id))
        autoTicked = ticked.count

        for row in rows where row.cost.worktree == .checking {
            guard !isDeleting else { return }
            let cost = await SessionCost.settledCost(
                worktrees: worktreePaths(row.session),
                deletesDesignArtifacts: store.hasDesignArtifacts(for: row.session))
            guard !isDeleting else { return }
            settle(row.id, on: cost)
        }
    }

    private func startingCost(_ session: ChatSession) -> SessionRemovalCost {
        SessionCost.startingCost(
            worktrees: worktreePaths(session),
            deletesDesignArtifacts: store.hasDesignArtifacts(for: session))
    }

    private func worktreePaths(_ session: ChatSession) -> [String] {
        store.checkoutProjects(for: session).compactMap(\.worktreePath)
    }

    private func settle(_ id: UUID, on cost: SessionRemovalCost) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].cost = cost
        // Ticking happens here rather than up front, so a box is only ever ticked for the
        // user once git has said the worktree holds nothing.
        if cost.losesNothing, autoTicked < Self.preselectLimit {
            ticked.insert(id)
            autoTicked += 1
        }
    }

    // MARK: - Acting

    private func toggle(_ row: Row) {
        guard row.cost.canSelect, !isDeleting else { return }
        if ticked.contains(row.id) {
            ticked.remove(row.id)
        } else {
            ticked.insert(row.id)
        }
    }

    // The sheet is the question for everything that costs nothing but history. Ticking a
    // row that holds generated files or uncommitted work is worth asking about twice.
    private func confirmDelete() {
        guard !isDeleting else { return }
        let chosen = rows.filter { ticked.contains($0.id) }
        let designArtifacts = chosen.count { $0.cost.deletesDesignArtifacts }
        let dirtyWorktrees = chosen.count { $0.cost.worktree.losesWork }
        guard designArtifacts > 0 || dirtyWorktrees > 0 else {
            delete(chosen)
            return
        }
        var consequences: [String] = []
        if designArtifacts > 0 {
            consequences.append(Self.designArtifactsCost(designArtifacts, unticked: false))
        }
        if dirtyWorktrees > 0 {
            consequences.append(Self.dirtyWorktreeCost(dirtyWorktrees, unticked: false))
        }
        dialogs.show(.confirm(chosen.count == 1
                                  ? "Delete a session with saved work?"
                                  : "Delete sessions with saved work?",
                              message: consequences.joined(separator: "\n\n"),
                              action: deleteLabel) {
            delete(chosen)
        })
    }

    private func delete(_ chosen: [Row]) {
        guard deletionProgress == nil, !chosen.isEmpty else { return }
        deletionProgress = DeletionProgress(total: chosen.count)
        let batchStartedAt = Date()
        SessionLog.note("old session deletion started count=\(chosen.count)")
        Task {
            var failures: [SessionLifecycle.Failure] = []
            for row in chosen {
                let startedAt = Date()
                deletionProgress?.current = row.session.title
                SessionLog.note("deletion started", session: row.id)
                let result = await SessionLifecycle.remove(
                    row.session, from: store, runner: runner)
                let elapsed = Int(max(0, Date().timeIntervalSince(startedAt)) * 1_000)
                if case .failure(let failure) = result {
                    failures.append(failure)
                    SessionLog.note(
                        "deletion failed durationMs=\(elapsed) reason=\(failure.title)",
                        session: row.id)
                } else {
                    SessionLog.note("deletion finished durationMs=\(elapsed)", session: row.id)
                }
                deletionProgress?.completed += 1
            }
            let elapsed = Int(max(0, Date().timeIntervalSince(batchStartedAt)) * 1_000)
            SessionLog.note(
                "old session deletion finished count=\(chosen.count) failures=\(failures.count) durationMs=\(elapsed)")
            rows.removeAll { store.session($0.id) == nil }
            ticked = ticked.intersection(rows.map(\.id))
            guard failures.isEmpty else {
                deletionProgress = nil
                dialogs.show(.notice(failures.count == 1
                                         ? failures[0].title
                                         : "Could not delete some sessions",
                                     message: failures.map(\.message).joined(separator: "\n")))
                return
            }
            dismiss()
        }
    }
}

// One session up for deletion: the tick, who it is, and what removing it would cost. The
// cost is the point of the row, so it sits at the end where the eye stops.
private struct SessionChoiceRow: View {
    let title: String
    let projectName: String
    let detail: String
    let cost: SessionRemovalCost
    let hasWorktree: Bool
    let ticked: Bool
    let canToggle: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(isOn: Binding(get: { ticked }, set: { _ in toggle() })) {
                EmptyView()
            }
            .toggleStyle(.appCheckbox)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    // A column of its own, so the project reads down the list instead of
                    // landing wherever the title before it happened to end.
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Theme.monogram(for: projectName))
                            .frame(width: 6, height: 6)
                        Text(projectName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: 110, alignment: .leading)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if hasWorktree {
                        MonoChip(text: "WT")
                    }
                    Spacer(minLength: 0)
                }
                Text(detail)
                    .font(.mono(11))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(cost.label)
                .font(.mono(11))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .surface(Theme.card, cornerRadius: 10, border: border)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .allowsHitTesting(canToggle)
    }

    // The cost of the row, said in colour as well as in words: nothing to lose reads as
    // grey, a worktree going as amber, work going as red.
    private var tint: Color {
        if cost.deletesDesignArtifacts { return Theme.deletion }
        return switch cost.worktree {
        case .historyOnly, .checking: Color.secondary
        case .checkFailed: Theme.deletion
        case .worktreeRemoved: Theme.secret
        case .wouldLoseWork: Theme.deletion
        }
    }

    private var border: Color {
        if cost.deletesDesignArtifacts { return Theme.deletion.opacity(0.45) }
        return switch cost.worktree {
        case .historyOnly, .checking: Theme.border
        case .checkFailed: Theme.deletion.opacity(0.45)
        case .worktreeRemoved: Theme.secret.opacity(0.35)
        case .wouldLoseWork: Theme.deletion.opacity(0.45)
        }
    }
}
