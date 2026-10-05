import SwiftUI

// The way out of a wait that has no end of its own. A held-open turn is correct behaviour
// and usually short, but nothing bounds it: a dev server or a watcher keeps the turn alive
// for as long as it runs, and from the outside that is indistinguishable from a hang. Past
// a few minutes the wait names itself and offers the only two answers there are.
struct WaitingNotice: View {
    @Environment(\.textScale) private var textScale

    let since: Date
    let tasks: [BackgroundTask]
    let agentTitle: String
    // Looked up rather than passed in already resolved: the answer costs a walk back
    // through the transcript, and the card is only on screen after minutes of waiting.
    let command: (BackgroundTask) -> String?
    let onKeepWaiting: () -> Void
    let onEnd: () -> Void

    // Short waits are ordinary - a build, a test run - and a card under every one of them
    // would be noise. This is about the ones that are not going to end on their own.
    private static let showAfter: TimeInterval = 3 * 60

    var body: some View {
        // Five seconds is fine for something that appears once after minutes, and it keeps
        // the transcript from redrawing every second for a card that is not counting.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if context.date.timeIntervalSince(since) >= Self.showAfter {
                card
            }
        }
    }

    private var title: String {
        tasks.count == 1 ? "Waiting on a background task" : "Waiting on \(tasks.count) background tasks"
    }

    private var consequence: String {
        tasks.count == 1 ? "Ending the turn also stops this task." : "Ending the turn also stops these tasks."
    }

    private var explainer: String {
        tasks.count == 1
            ? "\(agentTitle) has replied and will resume when this finishes. Ending the turn stops it. You can also send a message."
            : "\(agentTitle) has replied and will resume when these finish. Ending the turn stops them. You can also send a message."
    }

    // The icon column the task rows and the explainer line up under.
    private var indent: CGFloat { 24 * textScale }

    // Sized like a tool-call group rather than a dialog: the card sits in the transcript
    // for as long as the wait lasts, and anything louder pulls the eye off the reply above.
    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    heading
                    elapsed.fixedSize()
                    Spacer(minLength: 12)
                    actions
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        heading
                        elapsed.fixedSize()
                    }
                    actions.padding(.leading, indent)
                }
                VStack(alignment: .leading, spacing: 8) {
                    heading
                    elapsed.padding(.leading, indent)
                    actions.padding(.leading, indent)
                }
            }
            .frame(minHeight: 28 * textScale)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(tasks) { task in
                    WaitingTaskRow(task: task, command: command(task))
                }
            }
            .padding(.leading, indent)
            Text(explainer)
                .font(.system(size: 12 * textScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, indent)
        }
        .padding(.vertical, 10)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .onAppear { AccessibilityNotification.Announcement(title).post() }
    }

    private var heading: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 13 * textScale, weight: .medium))
                .foregroundStyle(Theme.attentionText)
                .frame(width: 14 * textScale)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13 * textScale, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var elapsed: some View {
        Text("Last reply \(RelativeTime.duration(since: since)) ago")
            .font(.system(size: 12 * textScale))
            .foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            ActionButton(title: "End turn", tone: .outlined,
                         height: 26 * textScale, size: 12 * textScale, action: onEnd)
                .help(consequence)
                .accessibilityHint(consequence)
            ActionButton(title: "Keep waiting", tone: .dark,
                         height: 26 * textScale, size: 12 * textScale, action: onKeepWaiting)
                .accessibilityHint("Dismiss this notice for the current wait.")
        }
        .fixedSize()
    }
}

private struct WaitingTaskRow: View {
    @Environment(\.textScale) private var textScale
    @State private var expanded = false
    @State private var hovering = false
    @FocusState private var focused: Bool
    let task: BackgroundTask
    let command: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if command != nil {
                Button { expanded.toggle() } label: { row }
                    .buttonStyle(.plain)
                    .focused($focused)
                    .onHover { hovering = $0 }
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(focused ? Theme.accent : .clear, lineWidth: 2))
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    .accessibilityHint("Shows the command for \(task.label)")
            } else {
                row.accessibilityElement(children: .combine)
            }
            if expanded, let command {
                (Text("$ ").foregroundStyle(Theme.terminalDim)
                    + Text(command).foregroundStyle(Theme.terminalText))
                    .font(.mono(11.5 * textScale))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.terminal, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.leading, 14 * textScale)
                    .padding(.bottom, 4)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8 * textScale, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 8 * textScale)
                .opacity(command == nil ? 0 : 1)
                .accessibilityHidden(true)
            Text(task.label)
                .font(.mono(12.5 * textScale))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                Circle().fill(Theme.attention).frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text("Pending")
            }
            .font(.system(size: 11 * textScale))
            .foregroundStyle(Theme.attentionText)
            .fixedSize()
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 26 * textScale)
        .background(hovering ? Theme.sunken : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .padding(.leading, -6)
    }
}
