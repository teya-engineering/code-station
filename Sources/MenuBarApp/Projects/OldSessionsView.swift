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
        var outcome: SessionOutcome

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
                                         outcome: row.outcome,
                                         hasWorktree: !worktreePaths(row.session).isEmpty,
                                         ticked: ticked.contains(row.id),
                                         canToggle: row.outcome.canSelect && !isDeleting,
                                         toggle: { toggle(row) })
                    }
                    if preselectCapped { capNotice }
                    if losable > 0 { warning }
                }
                .padding(20)
            }
            .frame(maxHeight: 420)
            footer
        }
        .frame(width: 620)
        .background(Theme.background)
        .interactiveDismissDisabled(isDeleting)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Sessions older than \(days) day\(days == 1 ? "" : "s")")
                .font(.serif(16))
            Text("Ticked sessions are removed from the app. Change the \(days) day\(days == 1 ? "" : "s") in Settings.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    // Said out loud, so a half-ticked list reads as a decision rather than a glitch.
    private var capNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Only the first \(Self.preselectLimit) sessions are ticked for you. Tick the rest by hand if you want those gone as well.")
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }

    // The one thing this screen can do that cannot be undone, said before the button is
    // reached rather than in a dialog after it.
    private var warning: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.deletion)
            Text(losable == 1
                 ? "One session has uncommitted changes in its worktree, so it is left unticked. Deleting it loses those changes; its branch survives if git considers that safe."
                 : "\(losable) sessions have uncommitted changes in their worktrees, so they are left unticked. Deleting them loses those changes; their branches survive if git considers that safe.")
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.deletion.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.deletion.opacity(0.25)))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 10) {
                Text(footerNote)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                Button {
                    guard !isDeleting else { return }
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .disabled(isDeleting)
                Button { confirmDelete() } label: {
                    Text(deleteLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(ticked.isEmpty ? Theme.dotOff : Theme.deletion))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(ticked.isEmpty || isDeleting)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.card)
        }
    }

    // Which one of them is being worked on, not how many are behind: a count that reads 0
    // for as long as the first session takes says nothing about whether it is moving.
    private var deleteLabel: String {
        if let progress = deletionProgress {
            return "Deleting \(min(progress.completed + 1, progress.total)) of \(progress.total)…"
        }
        return ticked.isEmpty
            ? "Delete"
            : "Delete \(ticked.count) session\(ticked.count == 1 ? "" : "s")"
    }

    // The line that explains the button while there is nothing to explain, and names what
    // is being cleared once there is.
    private var footerNote: String {
        guard let current = deletionProgress?.current, !current.isEmpty else {
            return "Original project folders stay on disk. Session worktrees are removed."
        }
        return "Clearing \(current)…"
    }

    private var isDeleting: Bool {
        deletionProgress != nil
    }

    private var losable: Int {
        rows.count { $0.outcome.losesWork }
    }

    private var preselectCapped: Bool {
        rows.count { $0.outcome.losesNothing } > Self.preselectLimit
    }

    // "last turn 9 days ago · 4 turns · ⑂ code-station/pty-test · clean"
    private func detail(_ row: Row) -> String {
        var parts = ["last turn " + SessionAge.phrase(since: row.session.lastActivity)]
        if let turns = row.session.usage?.turns, turns > 0 {
            parts.append("\(turns) turn\(turns == 1 ? "" : "s")")
        }
        let worktrees = worktreePaths(row.session)
        if let path = worktrees.first {
            let label = worktrees.count == 1
                ? (row.session.worktreeBranch ?? (path as NSString).lastPathComponent)
                : "\(worktrees.count) worktrees"
            parts.append("⑂ " + label)
            switch row.outcome {
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
                    outcome: startingOutcome(session))
            }
        ticked = Set(rows.filter { $0.outcome.losesNothing }
            .prefix(Self.preselectLimit)
            .map(\.id))
        autoTicked = ticked.count

        for row in rows where row.outcome == .checking {
            guard !isDeleting else { return }
            let outcome = await SessionCost.settledOutcome(worktrees: worktreePaths(row.session))
            guard !isDeleting else { return }
            settle(row.id, on: outcome)
        }
    }

    private func startingOutcome(_ session: ChatSession) -> SessionOutcome {
        SessionCost.startingOutcome(worktrees: worktreePaths(session))
    }

    private func worktreePaths(_ session: ChatSession) -> [String] {
        store.checkoutProjects(for: session).compactMap(\.worktreePath)
    }

    private func settle(_ id: UUID, on outcome: SessionOutcome) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].outcome = outcome
        // Ticking happens here rather than up front, so a box is only ever ticked for the
        // user once git has said the worktree holds nothing.
        if outcome.losesNothing, autoTicked < Self.preselectLimit {
            ticked.insert(id)
            autoTicked += 1
        }
    }

    // MARK: - Acting

    private func toggle(_ row: Row) {
        guard row.outcome.canSelect, !isDeleting else { return }
        if ticked.contains(row.id) {
            ticked.remove(row.id)
        } else {
            ticked.insert(row.id)
        }
    }

    // The sheet is the question for everything that costs nothing but history. Ticking a
    // row that holds uncommitted work is the one choice worth asking about twice.
    private func confirmDelete() {
        guard !isDeleting else { return }
        let chosen = rows.filter { ticked.contains($0.id) }
        let losing = chosen.filter { $0.outcome.losesWork }
        guard !losing.isEmpty else {
            delete(chosen)
            return
        }
        dialogs.show(Dialog(
            title: losing.count == 1
                ? "Delete a session with uncommitted work?"
                : "Delete \(losing.count) sessions with uncommitted work?",
            message: "The changes in \(losing.count == 1 ? "its worktree are" : "their worktrees are") not committed anywhere, so deleting takes them with it.",
            actions: [
                .init(label: deleteLabel, kind: .destructive) { delete(chosen) },
                .init(label: "Cancel", kind: .cancel)
            ]))
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
                dialogs.show(Dialog(
                    title: failures.count == 1
                        ? failures[0].title
                        : "Could not delete some sessions",
                    message: failures.map(\.message).joined(separator: "\n"),
                    actions: [.init(label: "OK", kind: .cancel)]))
                return
            }
            dismiss()
        }
    }
}

// One session up for deletion: the tick, who it is, and what removing it would cost. The
// outcome is the point of the row, so it sits at the end where the eye stops.
private struct SessionChoiceRow: View {
    let title: String
    let projectName: String
    let detail: String
    let outcome: SessionOutcome
    let hasWorktree: Bool
    let ticked: Bool
    let canToggle: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(ticked ? Theme.accentFill : Theme.card)
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(ticked ? .clear : Theme.border, lineWidth: 1.5))
                    .overlay {
                        if ticked {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
            }
            .buttonStyle(.plain)

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
                        StatusPill(text: "WT", running: false)
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

            Text(outcome.label)
                .font(.mono(11))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(border))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .allowsHitTesting(canToggle)
    }

    // The cost of the row, said in colour as well as in words: nothing to lose reads as
    // grey, a worktree going as amber, work going as red.
    private var tint: Color {
        switch outcome {
        case .historyOnly, .checking: Color.secondary
        case .checkFailed: Theme.deletion
        case .worktreeRemoved: Theme.secret
        case .wouldLoseWork: Theme.deletion
        }
    }

    private var border: Color {
        switch outcome {
        case .historyOnly, .checking: Theme.border
        case .checkFailed: Theme.deletion.opacity(0.45)
        case .worktreeRemoved: Theme.secret.opacity(0.35)
        case .wouldLoseWork: Theme.deletion.opacity(0.45)
        }
    }
}
