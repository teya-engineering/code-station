import SwiftUI
import CodeStationCore

// One run of a task, as a line in its history. Every run shares the task's folder and
// a task rarely edits files, so the row leaves both out and says instead who started it,
// what it was given and how long it took. A live run shows what it is doing now, and a
// failed one says why it stopped.
struct TaskRunRow: View {
    let session: ChatSession
    let tone: SessionTone
    // Why the run stopped, when it ended in an error.
    let failure: String?
    // The live tool line, read only while the run works.
    let activity: String
    let given: String
    let onOpen: () -> Void
    let menu: () -> [MenuEntry]

    @State private var hovering = false

    private var isLive: Bool { tone == .running || tone == .waiting }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                light
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if session.isPinned { PinnedMark() }
                    }
                    meta
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(session.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.mono(11))
                        .foregroundStyle(.secondary)
                    took
                        .font(.mono(10.5))
                        .foregroundStyle(.tertiary)
                }
                .fixedSize()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Open run", onOpen)

            // Destructive actions live in the menu: a bare bin in a row is one mis-click
            // from losing a run.
            GlyphButton(icon: "ellipsis", side: 26)
                .appMenu(menu)
                .appTooltip("More run actions")
                .opacity(hovering ? 1 : 0)
                .accessibilityLabel("More for this run")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 11)
        .background(hovering ? Theme.field.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .appContextMenu(menu)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
    }

    @ViewBuilder private var light: some View {
        if failure != nil {
            Circle()
                .fill(Theme.deletion)
                .frame(width: 6, height: 6)
        } else {
            StateLight(tone: tone)
        }
    }

    // The colour of the light always comes with words: the live tool line, the reason a
    // run stopped, or the state's own name.
    @ViewBuilder private var meta: some View {
        HStack(spacing: 8) {
            if isLive {
                StatusCaps(text: tone.word, tint: tone.colour)
                Text(activity)
                    .font(.mono(11))
                    .foregroundStyle(Theme.dotOn)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                if tone == .needsYou {
                    StatusCaps(text: tone.word, tint: tone.colour)
                }
                trigger
                if let failure {
                    Text(failure)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.deletion)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .appTooltip(failure)
                } else if !given.isEmpty {
                    Text(given)
                        .font(.mono(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    @ViewBuilder private var trigger: some View {
        if session.isScheduledRun {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10, weight: .medium))
                    .accessibilityHidden(true)
                Text("Scheduled")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize()
        } else {
            Text("Run by you")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    // A live run counts up on its own clock; a finished one says how long it took, from
    // the moment it started to the last thing it said.
    @ViewBuilder private var took: some View {
        if isLive {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text("working \(RelativeTime.duration(since: session.createdAt))")
            }
        } else if session.lastActivity > session.createdAt {
            Text(TaskRunHistory.duration(session.lastActivity.timeIntervalSince(session.createdAt)))
        }
    }
}
