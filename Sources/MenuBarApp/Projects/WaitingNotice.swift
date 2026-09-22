import SwiftUI

// The way out of a wait that has no end of its own. A held-open turn is correct behaviour
// and usually short, but nothing bounds it: a dev server or a watcher keeps the turn alive
// for as long as it runs, and from the outside that is indistinguishable from a hang. Past
// a few minutes the wait names itself and offers the only two answers there are.
struct WaitingNotice: View {
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

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "clock")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Still waiting for \(BackgroundTaskPhrase.of(tasks))")
                        .fontWeight(.semibold)
                    Text("\(agentTitle) answered \(RelativeTime.duration(since: since)) ago and the turn "
                        + "is being held open so the task can wake it again. Type to carry on in the same "
                        + "turn. Ending it stops the tasks it started.")
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(tasks) { task in
                        let command = command(task)
                        // A lone task with nothing known about it is already named in the
                        // line above, and an empty row would still take the stack's gap.
                        if tasks.count > 1 || command != nil {
                            VStack(alignment: .leading, spacing: 2) {
                                if tasks.count > 1 {
                                    Text("· \(task.label)")
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                // The description alone hides the difference between a
                                // wait that is working and one that can never finish. The
                                // command shows it: a loop over a file nothing writes any
                                // more gives itself away on sight, where its description
                                // never would.
                                if let command {
                                    Text(command)
                                        .font(.mono(11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ActionButton(title: "Keep waiting", tone: .outlined,
                             height: 28, size: 11.5, action: onKeepWaiting)
                ActionButton(title: "End turn", height: 28, size: 11.5, action: onEnd)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(12)
        .cardSurface(cornerRadius: 10)
    }
}
