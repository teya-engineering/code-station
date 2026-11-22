import SwiftUI

// That the turn is still alive, and how long since it last said anything. A working turn
// reports something every few seconds, so the silence is the number worth watching: it is
// the only thing that separates a long build from a turn that will never come back. The
// call in flight is named in the block above, so the row does not repeat it.
struct WorkingRow: View {
    @Environment(AppSettings.self) private var appSettings

    let since: Date
    let sessionID: UUID
    let avatarName: String?
    let agentTitle: String
    // The words Claude's own spinner would show, for a Claude session that sets any.
    var spinnerVerbs: ClaudeSpinnerVerbs?
    var completionActivity: SessionCompletionActivity?
    // The tasks holding the turn open, if that is why it is still here. Naming one is the
    // whole point of the row in that state: silence is expected, and what decides whether
    // it will ever end is what is running, not how long it has been quiet.
    var tasks: [BackgroundTask] = []
    // When the wait began, which is what the row counts while it is waiting.
    var waitingSince: Date?

    private var waiting: Bool { waitingSince != nil }

    // Held as state, not rebuilt with the view: the order is shuffled once, and a fresh
    // shuffle on every redraw would change the word mid-breath.
    @State private var words = WorkingWords()
    // When the row appeared, which is what the words are paced against. `since` moves
    // every time the agent says anything, and pacing off that would restart the cycle on
    // each event and leave the same word up all turn.
    @State private var started = Date()

    // The last moment the row was drawn for. The clock below moves it only when the row
    // would read differently, so a second that changes nothing on screen costs nothing.
    @State private var now = Date()

    var body: some View {
        let reading = clock.reading(at: now)
        let avatar = currentAvatar
        let personality = avatar.personality
        let word = reading.word
        HStack(spacing: Space.md) {
            AgentAvatarView(image: avatar.displayImage(for: sessionID), size: 20)
                .id(avatar.id)
                .transition(.fadeIn)
            Text("\(word)…")
                .font(Typography.code.weight(.medium))
                .foregroundStyle(.primary)
                // Each word is a replacement: the old one leaves before the new one
                // fades in, so it cannot linger as the row moves down the transcript.
                .id(word)
                .transition(.fadeIn)
            if let waited = reading.waited {
                Text("for \(BackgroundTaskPhrase.of(tasks))")
                    .font(Typography.code)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The same clock the strip runs, so the row and the header agree on
                // how long this has been going on.
                Text(waited)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let silence = reading.silence {
                Text("silent for \(silence)")
                    .font(Typography.caption)
                    .foregroundStyle(reading.concerning ? Theme.warningText : .secondary)
            }
            Spacer(minLength: 0)
        }
        // The row keeps sliding down as the turn writes more above it. Without this the
        // avatar fading in on a new turn animates against the transcript rather than
        // against the row, and lands somewhere the row no longer is.
        .geometryGroup()
        .motion(Motion.reveal, value: word)
        .motion(Motion.reveal, value: avatar.id)
        // Only worth a hint once the silence is long enough to worry about; the
        // empty one shows nothing.
        .appTooltip {
            if let completionActivity {
                return Tooltip(title: completionActivity.label, note: completionActivity.detail)
            }
            if waiting {
                guard !tasks.isEmpty else { return Tooltip(title: "") }
                return Tooltip(title: "\(agentTitle) has answered and is holding the turn open.",
                               note: tasks.map(\.label).joined(separator: "\n"))
            }
            guard reading.concerning else { return Tooltip(title: "") }
            return Tooltip(title: "\(agentTitle) has sent nothing for a while.",
                           note: "The log in Settings says what it last did.")
        }
        .task(id: clock) {
            now = .now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let next = Date.now
                if clock.reading(at: next) != clock.reading(at: now) { now = next }
            }
        }
        .onAppear { words = WorkingWords(personality: personality, spinnerVerbs: spinnerVerbs) }
        .onChange(of: personality) { _, personality in
            words = WorkingWords(personality: personality, spinnerVerbs: spinnerVerbs)
            started = .now
        }
        .onChange(of: spinnerVerbs) { _, spinnerVerbs in
            words = WorkingWords(personality: personality, spinnerVerbs: spinnerVerbs)
        }
    }

    private var currentAvatar: AgentAvatar {
        AgentAvatarSelection.avatar(named: avatarName, from: appSettings.agentAvatars)
    }

    private var clock: WorkingRowClock {
        WorkingRowClock(since: since, started: started, words: words,
                        waitingSince: waitingSince, fixedWord: completionActivity?.label)
    }
}

// Everything the row shows that moves with time, worked out for one moment. The row
// redraws only when this changes. A clock that redrew every second would lay the whole
// window out again each time, even though most seconds change nothing a person can see.
struct WorkingRowClock: Equatable {
    // Below this a gap is just the model thinking, and a clock ticking on every turn would
    // be noise. Past the second one it is long enough to be worth doubting.
    static let showQuietAfter: TimeInterval = 20
    static let concerningAfter: TimeInterval = 120

    struct Reading: Equatable {
        var word: String
        var silence: String?
        var concerning: Bool
        var waited: String?
    }

    let since: Date
    let started: Date
    let words: WorkingWords
    let waitingSince: Date?
    var fixedWord: String?

    func reading(at now: Date) -> Reading {
        let quiet = now.timeIntervalSince(since)
        let waiting = waitingSince != nil
        return Reading(
            word: fixedWord ?? (waiting ? "Waiting" : words.word(after: now.timeIntervalSince(started))),
            silence: quiet >= Self.showQuietAfter && !waiting ? Self.elapsed(quiet) : nil,
            concerning: quiet >= Self.concerningAfter,
            waited: waitingSince.map { RelativeTime.duration(since: $0, now: now) })
    }

    private static func elapsed(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        guard whole >= 60 else { return "\(whole)s" }
        return "\(whole / 60)m \(whole % 60)s"
    }
}
