import SwiftUI
import CodeStationCore

// That the turn is still alive, and how long since it last said anything. A working turn
// reports something every few seconds, so the silence is the number worth watching: it is
// the only thing that separates a long build from a turn that will never come back. The
// call in flight is named in the block above, so the row does not repeat it.
struct WorkingRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppSettings.self) private var appSettings

    let since: Date
    let sessionID: UUID
    let avatarName: String?
    let agentTitle: String
    // The tasks holding the turn open, if that is why it is still here. Naming one is the
    // whole point of the row in that state: silence is expected, and what decides whether
    // it will ever end is what is running, not how long it has been quiet.
    var tasks: [AgentBackgroundTask] = []
    // When the wait began, which is what the row counts while it is waiting.
    var waitingSince: Date?

    private var waiting: Bool { waitingSince != nil }

    // Below this a gap is just the model thinking, and a clock ticking on every turn would
    // be noise. Past the second one it is long enough to be worth doubting.
    private static let showQuietAfter: TimeInterval = 20
    private static let concerningAfter: TimeInterval = 120

    // Held as state, not rebuilt with the view: the order is shuffled once, and a fresh
    // shuffle on every redraw would change the word mid-breath.
    @State private var words = WorkingWords()
    // When the row appeared, which is what the words are paced against. `since` moves
    // every time the agent says anything, and pacing off that would restart the cycle on
    // each event and leave the same word up all turn.
    @State private var started = Date()

    var body: some View {
        // The row has to keep counting when nothing arrives to redraw it, which is exactly
        // the case it exists for.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let quiet = context.date.timeIntervalSince(since)
            let avatar = currentAvatar
            let personality = avatar.personality
            let word = waiting ? "Waiting" : words.word(after: context.date.timeIntervalSince(started))
            HStack(spacing: 8) {
                AgentAvatarView(image: avatar.displayImage(for: sessionID), size: 20)
                    .id(avatar.id)
                    .transition(.fadeIn)
                Text("\(word)…")
                    .font(.mono(12, .medium))
                    .foregroundStyle(.primary)
                    // Each word is a replacement: the old one leaves before the new one
                    // fades in, so it cannot linger as the row moves down the transcript.
                    .id(word)
                    .transition(.fadeIn)
                if let waitingSince {
                    Text("for \(BackgroundTaskPhrase.of(tasks))")
                        .font(.mono(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // The same clock the strip runs, so the row and the header agree on
                    // how long this has been going on.
                    Text(RelativeTime.duration(since: waitingSince))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if quiet >= Self.showQuietAfter, !waiting {
                    Text("silent for \(elapsed(quiet))")
                        .font(.system(size: 11))
                        .foregroundStyle(quiet >= Self.concerningAfter
                                         ? Theme.warningText : .secondary)
                }
                Spacer(minLength: 0)
            }
            // The row keeps sliding down as the turn writes more above it. Without this the
            // avatar fading in on a new turn animates against the transcript rather than
            // against the row, and lands somewhere the row no longer is.
            .geometryGroup()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: word)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: avatar.id)
            // Only worth a hint once the silence is long enough to worry about; the
            // empty one shows nothing.
            .appTooltip {
                if waiting {
                    guard !tasks.isEmpty else { return Tooltip(title: "") }
                    return Tooltip(title: "\(agentTitle) has answered and is holding the turn open.",
                                   note: tasks.map(\.label).joined(separator: "\n"))
                }
                guard quiet >= Self.concerningAfter else { return Tooltip(title: "") }
                return Tooltip(title: "\(agentTitle) has sent nothing for a while.",
                               note: "The log in Settings says what it last did.")
            }
            .onAppear { words = WorkingWords(personality: personality) }
            .onChange(of: personality) { _, personality in
                words = WorkingWords(personality: personality)
                started = .now
            }
        }
    }

    private var currentAvatar: AgentAvatar {
        AgentAvatarSelection.avatar(named: avatarName, from: appSettings.agentAvatars)
    }

    private func elapsed(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        guard whole >= 60 else { return "\(whole)s" }
        return "\(whole / 60)m \(whole % 60)s"
    }
}
