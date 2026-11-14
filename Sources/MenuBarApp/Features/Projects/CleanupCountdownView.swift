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
    @State private var showsWhy = false
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
                .zIndex(1)
            readings
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if items.isEmpty {
                        emptyState
                    } else {
                        VStack(alignment: .leading, spacing: Space.md) {
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
                }
                .padding(Space.pane)
                .motion(Motion.leave, value: answered)
            }
            .frame(minHeight: 220, maxHeight: 480)

            SheetFooter(secondary: SheetAction(title: deleteLabel,
                                               enabled: !items.isEmpty && !isDeleting,
                                               tone: .dangerOutlined,
                                               action: confirmDelete),
                        dismissTitle: "Done",
                        dismiss: closeOrDismiss) {
                waitingLink
            }
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
        SheetTitle(name: "Deleted at the countdown", icon: "timer", count: items.count) {
            WhyButton(label: "Why these go", isOpen: $showsWhy) {
                Text("These are older than \(counted(appSettings.oldSessionDays, "day")), you have read them, and nothing on disk would be lost, so they go without asking. Keep any you still want and it is left out of this sweep. Kept sessions are asked about again in a week.")
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Space.pane)
        .headerBand()
    }

    // Why these qualify, then how long is left before they go.
    private var readings: some View {
        HStack(spacing: Space.md) {
            if items.isEmpty {
                StatusCaps(text: "NOTHING IN THIS COUNTDOWN")
            } else {
                StatusCaps(text: "OLDER THAN \(counted(appSettings.oldSessionDays, "day"))".uppercased())
                StatusRule()
                StatusCaps(text: "READ")
                StatusDot()
                StatusCaps(text: "NOTHING ON DISK LOST")
            }
            Spacer(minLength: Space.md)
            if let deadline = status.deletion?.at, !items.isEmpty {
                HStack(spacing: Space.sm) {
                    StatusCaps(text: "GOES IN")
                    CleanupCountdownLabel(deadline: deadline, size: Typography.Size.caption)
                }
                .transition(.fadeIn)
            }
        }
        .motion(Motion.leave, value: items.isEmpty)
        .accessibilityElement(children: .combine)
        .statusBand(padding: Space.pane)
    }

    // "1 other waits for your OK"
    nonisolated static func waitingLink(_ count: Int) -> String {
        "\(counted(count, "other")) \(count == 1 ? "waits" : "wait") for your OK"
    }

    @ViewBuilder
    private var waitingLink: some View {
        if !status.parked.isEmpty {
            HStack(spacing: Space.sm) {
                Image(systemName: "hourglass")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.attentionText)
                Text(Self.waitingLink(status.parked.count))
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                InlineLink(title: "Review", action: showWaiting)
            }
            .accessibilityElement(children: .contain)
            .transition(.fadeIn)
        }
    }

    private var emptyState: some View {
        let day = ProjectSnooze.wakeDay(Date().addingTimeInterval(OldSessions.deferral))
        return VStack(spacing: Space.sm) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 20))
                .foregroundStyle(Theme.dotOnText)
            Text(kept > 0 && kept == answered.count ? "You kept them all" : "Nothing left in this countdown")
                .font(Typography.title)
            Text(kept > 0
                 ? "Nothing goes at the end of this countdown. Kept sessions come back on \(day) if they are still old by then."
                 : "Read sessions older than \(counted(appSettings.oldSessionDays, "day")) with nothing to lose show up here an hour before they go.")
                .font(Typography.detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xxxl)
        .transition(.fadeIn)
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
        HStack(spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title)
                    .font(Typography.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(Typography.data)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            InlineLink(title: openTitle, size: Typography.Size.detail, action: open)
                .accessibilityLabel("\(openTitle) \(title)")
            ActionButton(title: "Keep", tone: .outlined, height: ControlHeight.sm, size: Typography.Size.detail, action: keep)
                .accessibilityLabel("Keep \(title) out of this sweep")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .surface(Theme.sunken, cornerRadius: Radius.card, border: Theme.settingsBorder)
        .accessibilityElement(children: .contain)
    }
}
