import SwiftUI

// The two strips above the sidebar's buttons both say the same kind of thing: what has
// piled up, what clearing it would cost, and how long is left before the app clears it
// itself. Drawing them through one view is what keeps them reading as one row that
// changed its mind rather than two rows that happen to sit together.
struct CleanupStrip: View {
    let title: String
    let detail: String
    // An urgent strip is one holding something a person would miss. A calm strip is only
    // an offer, so it sits on the plain field colour and says nothing in its border.
    let isUrgent: Bool
    let countdownAt: Date?
    let countdownLabel: String
    let hoverTitle: String
    let label: String
    // A strip doing the work it offered cannot be asked again until it is done.
    var isWorking = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isUrgent ? Theme.attentionText : Color.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Text(detail)
                            .font(.mono(10))
                            .foregroundStyle(isUrgent ? Theme.attentionText : Color.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let countdownAt { countdown(until: countdownAt) }
                }
                .opacity(hovering ? 0 : 1)

                Text(hoverTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isUrgent ? Theme.attentionText : Color.primary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .surface(isUrgent ? Theme.attention.opacity(0.10) : Theme.field, cornerRadius: 9,
                     border: isUrgent ? Theme.attention.opacity(0.45) : .clear)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .opacity(isWorking ? 0.55 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }

    // Counted down on the second, since the number is a promise about when the app will
    // act on its own and a stale one would be a promise it is already breaking.
    private func countdown(until deadline: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let text = CleanupCountdown.text(until: deadline, now: context.date)
            HStack(spacing: 4) {
                Image(systemName: "timer")
                    .font(.system(size: 9, weight: .semibold))
                Text(text)
                    .font(.mono(10, .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(CleanupCountdown.isUrgent(until: deadline, now: context.date)
                ? Theme.deletion
                : isUrgent ? Theme.attentionText : Theme.accent)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(countdownLabel)
            .accessibilityValue(text)
        }
    }
}

// MARK: - Old sessions

// Sessions pile up quietly, and the worktrees behind them take real disk. The strip says
// how much has gone stale and hands it to a screen that explains what clearing each one
// would cost. Once the sweep has a cohort waiting, the strip switches to that cohort: the
// count beside the countdown is what the sweep will take, so the number a person reads
// before walking away is the number that goes.
struct OldSessionsStrip: View {
    let summary: OldSessionsWatch.Summary
    let deletion: OldSessionSweep.Deletion?
    let days: Int
    let onReview: () -> Void

    var body: some View {
        CleanupStrip(
            title: Self.title(summary, deleting: deletion?.sessions, days: days),
            detail: Self.detail(summary, deleting: deletion?.sessions, days: days),
            isUrgent: summary.losesWork > 0,
            countdownAt: deletion?.at,
            countdownLabel: "Automatic deletion countdown",
            hoverTitle: "Click to review",
            label: "Review old sessions",
            action: onReview)
    }

    // The strip makes one statement at a time. Once a cohort is waiting the top line is a
    // promise about that cohort and nothing else, so it counts the sessions the sweep has
    // already settled on rather than everything that has gone quiet.
    static func title(_ summary: OldSessionsWatch.Summary, deleting: Int?, days: Int) -> String {
        guard let deleting else {
            return "\(counted(summary.sessions, "session")) older than \(counted(days, "day"))"
        }
        return "\(counted(deleting, "session")) will be deleted"
    }

    // Under a promise the detail carries the threshold the top line gave up naming and
    // says what the cohort is leaving behind. With no cohort waiting the strip is only an
    // offer to review, so the detail counts what accepting it would cost.
    static func detail(_ summary: OldSessionsWatch.Summary, deleting: Int?, days: Int) -> String {
        guard let deleting else { return reviewDetail(summary) }
        var parts = ["Older than \(counted(days, "day"))"]
        // The summary is refreshed on its own slower clock, so it can lag a cohort that
        // has just lost a member and count fewer sessions than the cohort takes. There is
        // nothing left for review when it does.
        let kept = summary.sessions - deleting
        if kept > 0 { parts.append("\(kept) kept for review") }
        if summary.snoozedProjects > 0 {
            parts.append("\(counted(summary.snoozedProjects, "project")) snoozed")
        }
        return parts.joined(separator: " · ")
    }

    // "1 project snoozed · 1 would lose work", so a quiet strip is never a mystery.
    // With nothing snoozed the line says only what it has always said.
    private static func reviewDetail(_ summary: OldSessionsWatch.Summary) -> String {
        let work = summary.losesWork == 1
            ? "1 session would lose work"
            : "\(summary.losesWork) sessions would lose work"
        guard summary.snoozedProjects > 0 else { return work }
        let snoozed = "\(counted(summary.snoozedProjects, "project")) snoozed"
        guard summary.losesWork > 0 else { return snoozed }
        return "\(snoozed) · \(summary.losesWork) would lose work"
    }
}

// What the old sessions strip knows, kept apart from the sidebar that shows it because
// measuring it reads every session's worktrees off disk. That is far too slow to do while
// the sidebar draws, so it runs on its own clock and the strip reads whatever the last
// pass settled on.
@MainActor
@Observable
final class OldSessionsWatch {
    struct Summary: Equatable {
        var sessions = 0
        var losesWork = 0
        // Projects whose snooze is holding old sessions back. A snooze over a project
        // with nothing old to hide is not worth a line in the strip.
        var snoozedProjects = 0
    }

    // What the strip is standing on. A pass is worth running again only when one of these
    // has moved, which is what keeps the disk reads off every redraw.
    struct RefreshRule: Equatable {
        struct Session: Equatable {
            let id: UUID
            let isBusy: Bool
            let isPinned: Bool
        }

        let days: Int
        let oldSessions: [Session]
        let nextOldAt: Date?
    }

    private static let refreshInterval: TimeInterval = 3_600

    private(set) var summary = Summary()

    func rule(store: ProjectStore, runner: SessionRunner, days: Int) -> RefreshRule {
        let sessions = store.sidebarSessions
        return RefreshRule(
            days: days,
            oldSessions: OldSessions.olderThan(days, in: sessions,
                                               snoozedUntil: { store.snoozeDeadline(for: $0) })
                .map {
                    RefreshRule.Session(id: $0.id,
                                        isBusy: runner.isBusy($0.id, store: store),
                                        isPinned: $0.isPinned)
                },
            nextOldAt: OldSessions.nextOldAt(days, in: sessions,
                                             snoozedUntil: { store.snoozeDeadline(for: $0) }))
    }

    func watch(store: ProjectStore, runner: SessionRunner, days: Int) async {
        while !Task.isCancelled {
            await refresh(store: store, runner: runner, days: days)
            let now = Date()
            let hourly = now.addingTimeInterval(Self.refreshInterval)
            // The earliest snooze deadline counts as well, so the strip wakes up on the
            // minute a project comes back rather than at the next hourly pass.
            let nextOld = OldSessions.nextOldAt(
                days, in: store.sidebarSessions, now: now,
                snoozedUntil: { store.snoozeDeadline(for: $0) })
            let next = min(hourly, nextOld ?? .distantFuture)
            do {
                try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            } catch {
                return
            }
        }
    }

    private func refresh(store: ProjectStore, runner: SessionRunner, days: Int) async {
        let old = OldSessions.olderThan(days, in: store.sidebarSessions)
            .filter { !runner.isBusy($0.id, store: store) }
        let heldBack = old.filter { ProjectSnooze.isActive(store.snoozeDeadline(for: $0)) }
        let sessions = old.filter { !ProjectSnooze.isActive(store.snoozeDeadline(for: $0)) }
        var losesWork = 0
        for session in sessions {
            guard !Task.isCancelled else { return }
            let cost = await SessionCost.settledCost(
                worktrees: store.checkoutProjects(for: session).compactMap(\.worktreePath),
                design: store.designCost(for: session))
            if cost.losesWork { losesWork += 1 }
        }
        guard !Task.isCancelled else { return }
        summary = Summary(sessions: sessions.count,
                          losesWork: losesWork,
                          snoozedProjects: Set(heldBack.map(\.projectID)).count)
    }
}

// MARK: - Orphaned worktrees

// A worktree whose session is gone keeps its whole checkout on disk, and nothing else in
// the app mentions it. This is the only place it is ever named.
struct OrphanedWorktreesStrip: View {
    @Environment(ProjectStore.self) private var store
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(AppSettings.self) private var appSettings
    @Environment(OrphanedWorktreeMonitor.self) private var monitor

    var body: some View {
        let worktrees = monitor.worktrees
        let bytes = worktrees.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        let size = bytes > 0 ? bytes.formatted(.byteCount(style: .file)) : "No disk usage"

        return CleanupStrip(
            title: counted(worktrees.count, "orphaned worktree"),
            detail: "No session · \(size)",
            isUrgent: true,
            countdownAt: appSettings.autoPruneOrphanedWorktrees
                ? monitor.automaticDeletionAt
                : nil,
            countdownLabel: "Automatic pruning countdown",
            hoverTitle: "Click to prune",
            label: "Prune orphaned worktrees",
            isWorking: monitor.isPruning,
            action: { confirmPrune(worktrees) })
    }

    private func confirmPrune(_ worktrees: [OrphanedWorktree]) {
        guard !worktrees.isEmpty else { return }
        dialogs.show(OrphanedWorktreePruning.confirmation(for: worktrees) {
            Task { await prune(worktrees) }
        })
    }

    private func prune(_ worktrees: [OrphanedWorktree]) async {
        let result = await monitor.prune(worktrees, in: store)
        guard !result.failures.isEmpty else { return }
        dialogs.show(.notice("Could not prune some worktrees",
                             message: result.failures.map(\.message).joined(separator: "\n")))
    }
}
