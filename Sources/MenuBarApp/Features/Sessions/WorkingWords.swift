import SwiftUI

// The word shown while a turn is running. It changes every few seconds, which is the
// cheapest way of saying the app is still reading the process: a label that never moves
// looks the same whether the agent is working or has quietly died.
struct WorkingWords {
    // Present participles only. The row reads "<word>…", so every one of these has to
    // sound like something still going on.
    static let all = AgentPersonality.standard.workingWords

    // How long a word stays up: long enough to read, short enough that a row which has
    // stopped moving reads as stuck rather than slow.
    static let interval: TimeInterval = 3

    private let order: [String]

    // Shuffled per row, so two sessions running side by side do not chant in unison and
    // the same opening word is not seen at the top of every turn.
    init(order: [String] = all.shuffled()) {
        self.order = order.isEmpty ? ["Working"] : order
    }

    // The default bot in a Claude session says what Claude's own spinner would, so the
    // `spinnerVerbs` set for the CLI carry over. A bot with a personality keeps its own
    // lines, and the other agents have no such setting.
    init(personality: AgentPersonality, agent: AgentKind, lead: String?) {
        var words = personality.workingWords
        if personality == .standard, agent == .claudeCode {
            words = ClaudeSpinnerVerbs.applied(to: words, lead: lead)
        }
        self.init(order: words.shuffled())
    }

    // Walking a shuffled list rather than picking at random each time: random picks
    // repeat, and the same word twice in a row looks like the display has frozen.
    func word(after elapsed: TimeInterval) -> String {
        let step = Int(max(0, elapsed) / Self.interval)
        return order[step % order.count]
    }
}
