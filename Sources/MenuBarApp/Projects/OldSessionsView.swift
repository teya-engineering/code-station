import SwiftUI

// The offer to clear out sessions that have gone quiet. Everything here is a choice: the
// sheet arrives with the harmless rows ticked and says, next to each one, exactly what
// deleting it costs. Nothing is ever cleared without this screen being read.
struct OldSessionsView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [Row] = []
    @State private var ticked: Set<UUID> = []

    private var days: Int { appSettings.oldSessionDays }

    private struct Row: Identifiable {
        let session: ChatSession
        let projectName: String
        var outcome: SessionOutcome

        var id: UUID { session.id }
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
                                         toggle: { toggle(row) })
                    }
                    if losable > 0 { warning }
                }
                .padding(20)
            }
            .frame(maxHeight: 420)
            footer
        }
        .frame(width: 620)
        .background(Theme.background)
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
                Text("Folders on disk are untouched.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button { dismiss() } label: {
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
                .disabled(ticked.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.card)
        }
    }

    private var deleteLabel: String {
        ticked.isEmpty ? "Delete" : "Delete \(ticked.count) session\(ticked.count == 1 ? "" : "s")"
    }

    private var losable: Int {
        rows.filter { $0.outcome.losesWork }.count
    }

    // "last turn 9 days ago · 4 turns · ⑂ conductor/pty-test · clean"
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
        rows = OldSessions.olderThan(days, in: store.sessions)
            .filter { !runner.state($0.id).isBusy }
            .map { session in
                Row(session: session,
                    projectName: session.workspaceID.flatMap(store.workspace)?.name
                        ?? store.project(session.projectID)?.name ?? "",
                    outcome: startingOutcome(session))
            }
        ticked = Set(rows.filter { $0.outcome.isSafeToPreselect }.map(\.id))

        for row in rows where row.outcome == .checking {
            var added = 0
            var removed = 0
            for path in worktreePaths(row.session) {
                let snapshot = await GitInspector.snapshot(at: path)
                guard snapshot.state == .ready else { continue }
                added += snapshot.totalAdded
                removed += snapshot.totalRemoved
            }
            settle(row.id, on: added == 0 && removed == 0
                   ? .worktreeRemoved
                   : .wouldLoseWork(added: added, removed: removed))
        }
    }

    private func startingOutcome(_ session: ChatSession) -> SessionOutcome {
        worktreePaths(session).contains { FileManager.default.fileExists(atPath: $0) }
            ? .checking : .historyOnly
    }

    private func worktreePaths(_ session: ChatSession) -> [String] {
        store.checkoutProjects(for: session).compactMap(\.worktreePath)
    }

    private func settle(_ id: UUID, on outcome: SessionOutcome) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].outcome = outcome
        // Ticking happens here rather than up front, so a box is only ever ticked for the
        // user once git has said the worktree holds nothing.
        if outcome.isSafeToPreselect { ticked.insert(id) }
    }

    // MARK: - Acting

    private func toggle(_ row: Row) {
        if ticked.contains(row.id) {
            ticked.remove(row.id)
        } else {
            ticked.insert(row.id)
        }
    }

    // The sheet is the question for everything that costs nothing but history. Ticking a
    // row that holds uncommitted work is the one choice worth asking about twice.
    private func confirmDelete() {
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
        for row in chosen {
            SessionRemoval.remove(row.session, from: store)
        }
        dismiss()
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
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(ticked ? Theme.accent : Theme.card)
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
                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Theme.monogram(for: projectName))
                            .frame(width: 6, height: 6)
                        Text(projectName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if hasWorktree {
                        StatusPill(text: "WT", running: false)
                    }
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
    }

    // The cost of the row, said in colour as well as in words: nothing to lose reads as
    // grey, a worktree going as amber, work going as red.
    private var tint: Color {
        switch outcome {
        case .historyOnly, .checking: Color.secondary
        case .worktreeRemoved: Theme.secret
        case .wouldLoseWork: Theme.deletion
        }
    }

    private var border: Color {
        switch outcome {
        case .historyOnly, .checking: Theme.border
        case .worktreeRemoved: Theme.secret.opacity(0.35)
        case .wouldLoseWork: Theme.deletion.opacity(0.45)
        }
    }
}
