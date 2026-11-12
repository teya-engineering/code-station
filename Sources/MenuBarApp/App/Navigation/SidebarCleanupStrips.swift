import SwiftUI

// One line of a cleanup card: what is piled up, what it is, and either how long is left
// before the app acts on its own or a chevron that says the line opens the review. The
// whole line is the button, so the card reads as two answers to one question.
struct CleanupLine: View {
    enum Tone {
        case plain
        // Something here waits for a person, so the words wear the amber of attention.
        case attention
    }

    let title: String
    let detail: String
    var tone: Tone = .plain
    var countdownAt: Date? = nil
    let label: String
    var onHover: (Bool) -> Void = { _ in }
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tone == .attention ? Theme.attentionText : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .contentTransition(.numericText())
                    Text(detail)
                        .font(.mono(10))
                        .foregroundStyle(tone == .attention ? Theme.attentionText : Color.secondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                if let countdownAt {
                    CleanupCountdownLabel(deadline: countdownAt)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tone == .attention ? Theme.attentionText : Color.secondary)
                        .offset(x: hovering ? 2 : 0)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hovering ? 0.05 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .motion(Motion.hover, value: hovering)
        .onPointerHover {
            hovering = $0
            onHover($0)
        }
        .accessibilityLabel(label)
        .accessibilityValue("\(title), \(detail)")
    }
}

// Counted down on the second, since the number is a promise about when the app will
// act on its own and a stale one would be a promise it is already breaking.
private struct CleanupCountdownLabel: View {
    let deadline: Date

    var body: some View {
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
                ? Theme.deletion : Theme.accent)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Automatic deletion countdown")
            .accessibilityValue(text)
        }
    }
}

// The card the lines sit in. Amber when everything in it waits for a person, plain
// otherwise, so the colour of the card says whether the app will act on its own.
private struct CleanupCard<Content: View>: View {
    var isUrgent = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .surface(isUrgent ? Theme.attention.opacity(0.10) : Theme.field, cornerRadius: 9,
                     border: isUrgent ? Theme.attention.opacity(0.45) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Old sessions

// Everything cleanup has to say, in one card. The top line is the promise: what goes when
// the countdown ends. The bottom line is the standing question: what waits for a yes and
// why. Hovering a line lights up the sidebar rows it is talking about, so the numbers are
// never abstract.
struct CleanupStrip: View {
    let status: OldSessionSweep.Status
    let onReview: () -> Void
    // The rows a hovered line names, or nil once the pointer leaves.
    var onHighlight: (CleanupHighlight?) -> Void = { _ in }

    var body: some View {
        let deletion = status.deletion
        let parked = status.parked
        if deletion == nil && parked.isEmpty {
            if status.swept > 0 {
                Text("Nothing old is left. Sessions are checked again every hour.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .transition(.fadeIn)
            }
        } else {
            CleanupCard(isUrgent: deletion == nil) {
                if let deletion {
                    CleanupLine(title: Self.deletionTitle(deletion),
                                detail: Self.deletionDetail(deletion),
                                countdownAt: deletion.at,
                                label: "Review what the sweep will delete",
                                onHover: { onHighlight($0 ? .goes : nil) },
                                action: onReview)
                }
                if deletion != nil && !parked.isEmpty {
                    Rectangle()
                        .fill(Theme.attention.opacity(0.35))
                        .frame(height: 1)
                }
                if !parked.isEmpty {
                    CleanupLine(title: Self.waitingTitle(parked),
                                detail: Self.waitingDetail(parked),
                                tone: .attention,
                                label: "Review sessions waiting for your OK",
                                onHover: { onHighlight($0 ? .waits : nil) },
                                action: onReview)
                        .background(deletion == nil ? .clear : Theme.attention.opacity(0.10))
                }
            }
            .transition(.fold)
        }
    }

    // "7 will be deleted"
    nonisolated static func deletionTitle(_ deletion: OldSessionSweep.Deletion) -> String {
        "\(deletion.total) will be deleted"
    }

    // "6 sessions, 1 worktree"
    nonisolated static func deletionDetail(_ deletion: OldSessionSweep.Deletion) -> String {
        var parts: [String] = []
        if deletion.sessions > 0 { parts.append(counted(deletion.sessions, "session")) }
        if deletion.worktrees > 0 { parts.append(counted(deletion.worktrees, "worktree")) }
        return parts.joined(separator: ", ")
    }

    nonisolated static func waitingTitle(_ parked: [OldSessionSweep.Parked]) -> String {
        "\(parked.count) waiting for your OK"
    }

    // "5 hold work · 2 not seen yet"
    nonisolated static func waitingDetail(_ parked: [OldSessionSweep.Parked]) -> String {
        let work = parked.count { $0.family == .losesWork }
        let unseen = parked.count - work
        var parts: [String] = []
        if work > 0 { parts.append("\(work) \(work == 1 ? "holds" : "hold") work") }
        if unseen > 0 { parts.append("\(unseen) not seen yet") }
        return parts.joined(separator: " · ")
    }
}

// Which rows a hovered strip line is talking about.
enum CleanupHighlight: Equatable {
    case goes
    case waits
}

// With automatic cleanup off the app never deletes on its own, so the strip is only an
// offer to review what has gone quiet.
struct OldSessionsOfferStrip: View {
    let summary: OldSessionsWatch.Summary
    let days: Int
    let onReview: () -> Void

    var body: some View {
        CleanupCard {
            CleanupLine(title: Self.title(summary, days: days),
                        detail: Self.detail(summary),
                        label: "Review old sessions",
                        action: onReview)
        }
    }

    nonisolated static func title(_ summary: OldSessionsWatch.Summary, days: Int) -> String {
        "\(counted(summary.sessions, "session")) older than \(counted(days, "day"))"
    }

    // "Automatic cleanup is off · 1 would lose work", so a quiet strip is never a mystery.
    nonisolated static func detail(_ summary: OldSessionsWatch.Summary) -> String {
        var parts = ["Automatic cleanup is off"]
        if summary.losesWork > 0 { parts.append("\(summary.losesWork) would lose work") }
        if summary.snoozedProjects > 0 {
            parts.append("\(counted(summary.snoozedProjects, "project")) snoozed")
        }
        return parts.joined(separator: " · ")
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
                                        isBusy: runner.isBusy($0.id, store: store))
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
// the app mentions it. When cleanup does not look after orphans, this is the only place
// one is ever named, and pruning is always a click and a yes.
struct OrphanedWorktreesStrip: View {
    @Environment(ProjectStore.self) private var store
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(OrphanedWorktreeMonitor.self) private var monitor

    var body: some View {
        let worktrees = monitor.worktrees
        let bytes = worktrees.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        let size = bytes > 0 ? bytes.formatted(.byteCount(style: .file)) : "No disk usage"

        return CleanupCard(isUrgent: true) {
            CleanupLine(title: counted(worktrees.count, "orphaned worktree"),
                        detail: "No session · \(size)",
                        tone: .attention,
                        label: "Prune orphaned worktrees",
                        action: { confirmPrune(worktrees) })
                .disabled(monitor.isPruning)
                .opacity(monitor.isPruning ? 0.55 : 1)
        }
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
