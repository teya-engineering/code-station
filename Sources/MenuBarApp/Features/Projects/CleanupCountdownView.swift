import AppKit
import SwiftUI

// What the countdown on the sidebar card will take when it ends. Everything here is old,
// read, and loses nothing on disk, so the sweep needs no yes. The only real answer is to
// keep something out of it. Deleting now is offered, but quietly, since waiting does the
// same thing.
struct CleanupCountdownView: View {
    let status: OldSessionSweep.Status
    // Swaps this sheet for the waiting list.
    let showWaiting: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(AppSettings.self) private var appSettings
    @Environment(OrphanedWorktreeMonitor.self) private var orphans
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    // Rows kept or deleted here. They fold out at once rather than waiting for the
    // sweep's next pass to drop them from its list.
    @State private var answered: Set<OldSessionSweep.Parked.Item> = []
    @State private var kept = 0
    @State private var isDeleting = false
    @State private var note: String?
    @State private var notes = 0

    struct Item: Identifiable {
        let id: OldSessionSweep.Parked.Item
        let session: ChatSession?
        let orphan: OrphanedWorktree?
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if items.isEmpty {
                        emptyState
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(items) { item in
                                GoingRow(title: title(item),
                                         detail: detail(item),
                                         openTitle: item.session == nil ? "Show in Finder" : "Open",
                                         open: { open(item) },
                                         keep: { keep(item) })
                                    .disabled(isDeleting)
                                    .transition(.fold)
                            }
                        }
                    }
                    if !status.parked.isEmpty {
                        CleanupCrossLink(icon: "exclamationmark.circle",
                                         tint: Theme.attentionText,
                                         text: Self.waitingLink(status.parked.count),
                                         action: "Review",
                                         go: showWaiting)
                    }
                }
                .padding(20)
                .motion(Motion.leave, value: answered)
            }
            .frame(minHeight: 220, maxHeight: 480)

            SheetFooter(title: "Kept sessions are asked about again in a week.",
                        secondary: SheetAction(title: deleteLabel,
                                               enabled: !items.isEmpty && !isDeleting,
                                               tone: .dangerOutlined,
                                               action: confirmDelete),
                        dismissTitle: "Done",
                        dismiss: { if !isDeleting { dismiss() } })
        }
        .frame(width: 660)
        .background(Theme.background)
        .interactiveDismissDisabled(isDeleting)
        .overlay(alignment: .top) {
            ZStack {
                if let note {
                    HeaderNote(icon: "checkmark", text: note)
                        .padding(.top, 10)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
                }
            }
            .motion(Motion.reveal, value: note)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(items.isEmpty ? "Nothing will be deleted" : "\(items.count) will be deleted")
                    .font(.serif(16))
                    .contentTransition(.numericText(value: Double(items.count)))
                    .motion(Motion.pop, value: items.count)
                Text("These are older than \(counted(appSettings.oldSessionDays, "day")), you have read them, and nothing on disk would be lost. Keep any you still want and it is left out of this sweep.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let deadline = status.deletion?.at {
                VStack(alignment: .trailing, spacing: 2) {
                    CleanupCountdownLabel(deadline: deadline, size: 15)
                    Text("left before they go")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .opacity(items.isEmpty ? 0 : 1)
                .motion(Motion.leave, value: items.isEmpty)
                .accessibilityHidden(items.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .headerBand()
    }

    private var emptyState: some View {
        let day = ProjectSnooze.wakeDay(Date().addingTimeInterval(OldSessions.deferral))
        return VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 20))
                .foregroundStyle(Theme.dotOnText)
            Text(kept > 0 && kept == answered.count ? "You kept them all" : "Nothing left in this countdown")
                .font(.system(size: 13, weight: .semibold))
            Text(kept > 0
                 ? "Nothing goes at the end of this countdown. Kept sessions come back on \(day) if they are still old by then."
                 : "Read sessions older than \(counted(appSettings.oldSessionDays, "day")) with nothing to lose show up here an hour before they go.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .transition(.fadeIn)
    }

    // "1 other session is old too, but it is not in this sweep. It waits for your OK."
    nonisolated static func waitingLink(_ count: Int) -> String {
        let one = count == 1
        return "\(counted(count, "other session")) \(one ? "is" : "are") old too, but \(one ? "it is" : "they are") not in this sweep. \(one ? "It waits" : "They wait") for your OK."
    }

    // MARK: - Rows

    private var items: [Item] {
        let sessions = status.cohort
            .filter { !answered.contains(.session($0)) }
            .compactMap(store.session)
            .map { Item(id: .session($0.id), session: $0, orphan: nil) }
        let worktrees = status.worktreeCohort
            .filter { !answered.contains(.worktree($0)) }
            .compactMap { id in orphans.worktrees.first { $0.id == id } }
            .map { Item(id: .worktree($0.id), session: nil, orphan: $0) }
        return sessions + worktrees
    }

    private func title(_ item: Item) -> String {
        if let orphan = item.orphan {
            return "Orphaned worktree \(orphan.branch ?? (orphan.path as NSString).lastPathComponent)"
        }
        return item.session?.title ?? ""
    }

    // "code-station · Conversation and a clean worktree · Last turn 7 days ago"
    private func detail(_ item: Item) -> String {
        if let orphan = item.orphan { return "\(orphan.projectName) · No changes" }
        guard let session = item.session else { return "" }
        let project = store.project(session.projectID)?.name ?? "Unknown project"
        return "\(project) · \(goes(session)) · Last turn \(SessionAge.phrase(since: session.lastActivity))"
    }

    private func goes(_ session: ChatSession) -> String {
        let hasWorktree = worktreePaths(session).contains { FileManager.default.fileExists(atPath: $0) }
        var what = hasWorktree ? "Conversation and a clean worktree" : "Conversation only"
        if store.designCost(for: session) == .implemented { what += ", built design files" }
        return what
    }

    private func worktreePaths(_ session: ChatSession) -> [String] {
        store.checkoutProjects(for: session).compactMap(\.worktreePath)
    }

    private var deleteLabel: String {
        items.isEmpty ? "Delete now" : "Delete \(items.count) now"
    }

    // MARK: - Acting

    private func open(_ item: Item) {
        if let session = item.session {
            store.selectSession(session.id)
            dismiss()
        } else if let orphan = item.orphan {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: orphan.path)])
            show("Shown in Finder")
        }
    }

    private func keep(_ item: Item) {
        let until = Date().addingTimeInterval(OldSessions.deferral)
        switch item.id {
        case .session(let id): store.deferCleanup(of: id, until: until)
        case .worktree(let path): orphans.deferCleanup(of: path, until: until)
        }
        answered.insert(item.id)
        kept += 1
        show("Kept “\(title(item))”. Asked again on \(ProjectSnooze.wakeDay(until)).")
    }

    private func confirmDelete() {
        let chosen = items
        guard !chosen.isEmpty, !isDeleting else { return }
        var rows = chosen.map { item in
            Dialog.Impact.Row(title: title(item),
                              detail: item.session.map(goes) ?? "The checkout, with no changes")
        }
        if chosen.contains(where: { item in
            item.orphan != nil || item.session.map { !worktreePaths($0).isEmpty } == true
        }) {
            rows.append(.init(title: "Branches with commits",
                              detail: "Only the clean worktrees go. Branches stay in each repository.",
                              kept: true))
        }
        let action = "Delete \(counted(chosen.count, "item"))"
        dialogs.show(.impact("\(action) now?",
                             message: "These go at the end of the countdown anyway. Only history goes. Nothing on disk is lost.",
                             rows: rows, action: action) {
            delete(chosen)
        })
    }

    private func delete(_ chosen: [Item]) {
        guard !isDeleting else { return }
        isDeleting = true
        SessionLog.note("cleanup countdown deletion started count=\(chosen.count)")
        Task {
            var failures: [String] = []
            var deleted = 0
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
                deleted += 1
                answered.insert(item.id)
            }
            isDeleting = false
            SessionLog.note("cleanup countdown deletion finished count=\(deleted) failures=\(failures.count)")
            if !failures.isEmpty {
                dialogs.show(.notice(failures.count == 1 ? "Could not delete an item"
                                         : "Could not delete some items",
                                     message: failures.joined(separator: "\n")))
            }
            if deleted > 0 { show("Deleted \(counted(deleted, "item"))") }
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

// A session or worktree the countdown will take. Open it, or keep it out of the sweep.
private struct GoingRow: View {
    let title: String
    let detail: String
    let openTitle: String
    let open: () -> Void
    let keep: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.mono(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            InlineLink(title: openTitle, size: 11.5, action: open)
                .accessibilityLabel("\(openTitle) \(title)")
            ActionButton(title: "Keep", tone: .outlined, height: 24, size: 11.5, action: keep)
                .accessibilityLabel("Keep \(title) out of this sweep")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .surface(Theme.sunken, cornerRadius: 10, border: Theme.settingsBorder)
        .accessibilityElement(children: .contain)
    }
}

// The line at the foot of each cleanup list that names the other list and swaps to it,
// so the two stay one click apart.
struct CleanupCrossLink: View {
    let icon: String
    let tint: Color
    let text: String
    let action: String
    let go: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity, alignment: .leading)
            InlineLink(title: action, size: 12, action: go)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .surface(Theme.field, cornerRadius: 10)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .transition(.fadeIn)
    }
}
