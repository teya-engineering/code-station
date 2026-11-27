import SwiftUI

// A session as a compact card. It carries the same state, title and activity the session
// shows on its project and on Home, so it reads the same wherever it is met.
struct SessionCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PullRequestReviewStore.self) private var pullRequestReviews
    let session: ChatSession
    let worktrees: WorktreeCoverage
    let selected: Bool
    let busy: Bool
    let failed: Bool
    let waiting: Bool
    let waitIsStale: Bool
    // When the turn stopped working, which is what a wait has to be counted from. The
    // session's own last activity is the start of the turn still holding it, so on a long
    // turn it reads as a far longer wait than the one actually being served.
    let waitingSince: Date?
    let needsInput: Bool
    let finished: Bool
    var completionActivity: SessionCompletionActivity?
    // Set while the session is put out of the way, so the card can say so.
    var snoozed: SessionSnooze? = nil
    // Worked out inside the card rather than handed in, because it reads the tool the
    // session is running. A tool starts and ends many times a turn, and only this card
    // has to be redrawn for it, not the whole rail.
    let activity: () -> String?
    let branch: String?
    let uncommitted: Bool
    let connected: Bool
    let isRenaming: Bool
    let checked: Bool?
    let onOpen: () -> Void
    let onWake: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    @Environment(AppSettings.self) private var appSettings

    @State private var hovering = false
    @FocusState private var cardFocused: Bool
    @FocusState private var deleteFocused: Bool
    @AccessibilityFocusState private var cardAccessibilityFocused: Bool

    private var tone: SessionTone {
        SessionTone(busy: busy, needsInput: needsInput, finished: finished,
                    waiting: waiting, waitIsStale: waitIsStale)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isRenaming {
                    cardContent
                        .frame(minHeight: snoozed == nil ? 0 : 74, alignment: .top)
                } else {
                    Button(action: onOpen) {
                        // The box floats over the card rather than standing beside it, so
                        // a state band still runs the full width of the card behind it.
                        cardContent
                            .overlay(alignment: .leading) {
                                if let checked {
                                    SidebarCheckbox(isOn: checked)
                                        .padding(.leading, Self.boxInset)
                                }
                            }
                            .frame(minHeight: snoozed == nil ? 0 : 74, alignment: .top)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .sidebarFocusRing($cardFocused)
                    .accessibilityFocused($cardAccessibilityFocused)
                    .accessibilityLabel(session.title)
                    .accessibilityValue(accessibilityStatus)
                    .accessibilityAddTraits(selected || checked == true ? [.isSelected] : [])
                }
            }
            .overlay(alignment: .topTrailing) {
                SessionSnoozeTag(snoozed: snoozed != nil)
                    .frame(width: 39, height: 66)
                    .padding(.leading, Space.md)
                    .padding(.trailing, Space.lg)
                    .padding(.top, Space.xs)
                    .clipped()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .trailing) {
                TrailingRowAction(
                    visible: checked == nil && !isRenaming && (hovering || cardFocused || deleteFocused),
                    icon: "trash", title: "Delete", tone: .delete,
                    width: TrailingRowAction.deleteWidth, base: cardFill, cornerRadius: Radius.control,
                    accessibilityLabel: "Delete session \(session.title)",
                    tooltip: "Delete session",
                    focus: $deleteFocused, action: onDelete)
                    .padding(1.4)
            }
            .appTooltip { tooltip }

            if let snoozed {
                SessionSnoozePocket(snooze: snoozed) {
                    cardFocused = true
                    cardAccessibilityFocused = true
                    onWake()
                }
                .disabled(checked != nil)
                .transition(reduceMotion ? .opacity.animation(Motion.reveal)
                    : .asymmetric(insertion: .fadeIn.animation(Motion.reveal),
                                  removal: .fold.animation(Motion.leave)))
            }
        }
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(cardFill))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card)
            .stroke(cardStroke, lineWidth: selected ? 1.4 : 1.2))
        .motion(Motion.control, value: [busy, finished, failed, selected])
        .motion(snoozed == nil ? Motion.leave : Motion.reveal, value: snoozed)
        .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        .onPointerHover { hovering = $0 }
    }

    // A failed turn needs the user like any other unread end, but says what happened
    // in its own word and colour, so the colour is never the only sign.
    private var word: String { failed ? "FAILED" : tone.word(completionActivity: completionActivity) }

    private var band: StateBand? {
        failed
            ? StateBand(fill: Theme.warningBackground, stripe: nil, drifts: false,
                        word: Theme.warningText)
            : tone.band
    }

    private var accessibilityStatus: String {
        var labels = [word.capitalized]
        if selected { labels.append("Currently viewing") }
        if session.isPinned { labels.append("Pinned") }
        if let snoozed { labels.append("Snoozed \(snoozed.phrase())") }
        if uncommitted { labels.append("Uncommitted changes") }
        if session.agentsUsed.count > 1 { labels.append("Now on \(session.agent.title)") }
        if connected { labels.append("Phone connected") }
        if worktrees.isComplete { labels.append("In a worktree") }
        if worktrees.isPartial { labels.append("Partly in a worktree") }
        return labels.joined(separator: ", ")
    }

    // A session that is doing something, or wants the user, wears its state line as a band
    // across the top of the card. The title below stays on the plain card, so it reads as
    // easily as an idle one.
    private static let boxInset: CGFloat = 10

    private var cardContent: some View {
        let band = band
        let edge: CGFloat = selected ? 9 : 8
        let leading: CGFloat = checked == nil ? 10 : Self.boxInset + 16 + 10
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                StateLight(tone: tone, colour: failed ? Theme.deletion : nil)
                Text(word)
                    .contentTransition(.opacity)
                    .motion(Motion.control, value: word)
                    .font(Typography.caps)
                    .kerning(0.9)
                    .foregroundStyle(band?.word ?? tone.colour)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                // WT means every checkout is a worktree. A session that is only partly
                // in worktrees still shares a folder, so it wears MIXED in the amber of
                // something that needs a look. The tooltip names which projects share.
                if worktrees.isComplete {
                    MonoChip(text: "WT", size: Typography.Size.micro)
                } else if worktrees.isPartial {
                    MonoChip(text: "MIXED", size: Typography.Size.micro, tint: Theme.attentionText)
                }
                if session.isTroubleshooting {
                    MonoChip(text: "TROUBLESHOOT", size: Typography.Size.micro, tint: Theme.secret)
                }
                if uncommitted { UncommittedMark() }
                if connected { MobileConnectionMark() }
                // Review threads on this session's pull request still waiting for an answer.
                if pullRequestReviews.waitingCount(session.id) > 0 {
                    MonoChip(text: "\(pullRequestReviews.waitingCount(session.id)) REVIEW", size: Typography.Size.micro, tint: Theme.attentionText)
                }
                // Only a session that has moved between agents names them here. One that
                // has kept to one agent has nothing to tell apart.
                let agents = session.agentsUsed
                if agents.count > 1 {
                    HStack(spacing: -Space.xs) {
                        ForEach(agents.filter { $0 != session.agent } + [session.agent]) { agent in
                            ReviewAvatar(agent: agent, size: Space.xl, muted: agent != session.agent)
                        }
                    }
                    .motion(Motion.control, value: session.agent)
                    .accessibilityHidden(true)
                }
                Spacer(minLength: 4)
                Text(RelativeTime.short(waiting ? waitingSince ?? session.lastActivity
                                                : session.lastActivity))
                    .font(Font.mono(Typography.Size.micro))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, leading)
            .padding(.trailing, Space.md)
            .padding(.top, band == nil ? edge : 6)
            .padding(.bottom, band == nil ? 0 : 5)
            .background {
                if let band {
                    ZStack {
                        band.fill
                        if let stripe = band.stripe {
                            StripeFill(colour: stripe, drifts: band.drifts)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: Space.xs) {
                if isRenaming {
                    SidebarRenameField(name: session.title, onCommit: onRename, onCancel: onCancelRename)
                } else {
                    Text(session.title)
                        .font(Typography.body.weight(.semibold))
                        .lineLimit(selected ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .truncationMode(.tail)
                        .changingName(session.title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ActivityLine(activity: activity())
            }
            .padding(.leading, leading)
            .padding(.trailing, snoozed == nil ? 10 : 60)
            .padding(.top, band == nil ? 5 : 7)
            .padding(.bottom, edge)
        }
    }

    // The hint carries the branch and full path because the compact card leaves both out.
    private var tooltip: Tooltip {
        var rows = [Tooltip.Row(label: "State", value: word.capitalized)]
        if let snoozed {
            rows.append(Tooltip.Row(label: "Snoozed", value: snoozed.phrase()))
        }
        if let branch {
            rows.append(Tooltip.Row(label: "Branch", value: branch))
        }
        if session.agentsUsed.count > 1 {
            rows.append(Tooltip.Row(label: "Agents", value: "\(session.agent.title), after \(session.agentsUsed.filter { $0 != session.agent }.map(\.title).formatted(.list(type: .and)))"))
        }
        if appSettings.showsCost(for: session.agent), let usage = session.usage, usage.turns > 0 {
            // Kiro counts in plan credits rather than dollars.
            if session.agent == .kiro {
                if let credits = usage.credits, credits > 0 {
                    rows.append(Tooltip.Row(label: "Spent", value: Money.credits(credits)))
                }
            } else {
                rows.append(Tooltip.Row(label: "Spent", value: Money.short(usage.costUSD)))
            }
        }
        if let context = session.usage?.contextFraction, context > 0 {
            rows.append(Tooltip.Row(label: "Context", value: "\(Int(context * 100))%"))
        }
        rows.append(Tooltip.Row(label: "Last active",
                                value: session.lastActivity.formatted(date: .abbreviated,
                                                                      time: .shortened)))
        return Tooltip(title: session.title,
                       subtitle: session.worktreePath?.abbreviatedPath,
                       note: note,
                       rows: rows)
    }

    // What is worth knowing before deleting this session outranks where it runs, and a
    // worktree session says both at once: the folder that would go is its own. A session
    // that is only partly in worktrees names the projects it still shares, since the
    // chip has no room for them.
    private var note: String? {
        if uncommitted {
            return session.worktreePath == nil
                ? "Uncommitted changes in the project folder."
                : "Uncommitted changes in this worktree. Deleting the session loses them."
        }
        if worktrees.isPartial {
            return "Runs in a worktree for \(worktrees.isolated.formatted(.list(type: .and))). Shares the project folder of \(worktrees.shared.formatted(.list(type: .and)))."
        }
        return worktrees.isComplete ? "Runs in its own git worktree." : nil
    }

    // Snoozed cards keep a solid surface behind their tag. Selection and run state
    // still have their own ring, band, light and word.
    private var cardFill: Color {
        if selected || snoozed != nil { return Theme.card }
        return hovering ? Theme.field : Theme.sunken
    }

    private var cardStroke: Color {
        if selected { return Theme.accent.opacity(0.64) }
        if checked == true { return Theme.accent.opacity(0.4) }
        if failed { return Theme.deletion.opacity(0.45) }
        if snoozed != nil { return Theme.snoozeEdge }
        return tone == .idle ? .clear : tone.ring
    }
}

// The card at the end of a capped session list. It wears the same shape as the cards
// above it so the column stays one column, but stays quieter than any of them: it is
// a control, not a session.
struct SeeMoreCard: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.label)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.sm)
                .background(RoundedRectangle(cornerRadius: Radius.card)
                    .fill(hovering ? Theme.field : Theme.sunken))
                .overlay(RoundedRectangle(cornerRadius: Radius.card)
                    .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onPointerHover { hovering = $0 }
    }
}

// What the session is doing right now, under its title. Most tool calls finish in a
// few milliseconds, so the line holds for a moment before it gives way: long enough
// to read, and only ever replaced by the next call rather than by an empty gap. It is
// the agent that changes it, so the words are swapped where they stand: a fade on each
// one would keep the rail flickering while nobody is looking at it.
private struct ActivityLine: View {
    let activity: String?

    private static let minimumDwell: TimeInterval = 1

    @State private var shown: String?
    @State private var shownAt = Date.distantPast

    var body: some View {
        Group {
            if let shown {
                Text(shown)
                    .font(Font.mono(Typography.Size.micro))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // A newer value cancels the wait for the older one, which is what keeps the
        // hold from delaying anything the user would rather see.
        .task(id: activity) { await settle(on: activity) }
    }

    private func settle(on next: String?) async {
        let elapsed = Date().timeIntervalSince(shownAt)
        if shown != nil, elapsed < Self.minimumDwell {
            try? await Task.sleep(for: .seconds(Self.minimumDwell - elapsed))
            guard !Task.isCancelled else { return }
        }
        shown = next
        if next != nil { shownAt = Date() }
    }
}

// The session's folder holds work git does not have. It rides at the top of the card
// beside the state, because it is not what the session is doing: it is what deleting the
// session would cost.
private struct UncommittedMark: View {
    var body: some View {
        Image(systemName: "pencil.circle.fill")
            .font(Typography.caption)
            .foregroundStyle(Theme.attention)
    }
}

private struct MobileConnectionMark: View {
    var body: some View {
        Image(systemName: "iphone.radiowaves.left.and.right")
            .font(Typography.caption.weight(.semibold))
            .foregroundStyle(Theme.addition)
            .appTooltip("Phone connected")
            .accessibilityLabel("Phone connected")
    }
}

struct PinnedMark: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .appTooltip("Pinned")
            .accessibilityLabel("Pinned")
    }
}
