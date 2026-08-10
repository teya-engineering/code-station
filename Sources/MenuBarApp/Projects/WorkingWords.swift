import SwiftUI

// The word shown while a turn is running. It changes every few seconds, which is the
// cheapest way of saying the app is still reading the process: a label that never moves
// looks the same whether the agent is working or has quietly died.
struct WorkingWords {
    // Present participles only. The row reads "<word>…", so every one of these has to
    // sound like something still going on.
    static let all = [
        "Thinking", "Mulling", "Pondering", "Noodling", "Puzzling", "Ruminating",
        "Musing", "Percolating", "Simmering", "Brewing", "Churning", "Cogitating",
        "Deliberating", "Contemplating", "Untangling", "Distilling", "Marinating",
        "Concocting", "Tinkering", "Whirring", "Computing", "Synthesising",
        "Considering", "Reasoning", "Wrangling", "Spelunking", "Divining", "Sifting",
        "Weighing", "Scheming", "Drafting", "Reckoning", "Sussing", "Chewing",
        "Digging", "Hatching", "Gathering", "Threading", "Unpicking", "Rummaging"
    ]

    // How long a word stays up: long enough to read, short enough that a row which has
    // stopped moving reads as stuck rather than slow.
    static let interval: TimeInterval = 3

    private let order: [String]

    // Shuffled per row, so two sessions running side by side do not chant in unison and
    // the same opening word is not seen at the top of every turn.
    init(order: [String] = all.shuffled()) {
        self.order = order.isEmpty ? ["Working"] : order
    }

    // Walking a shuffled list rather than picking at random each time: random picks
    // repeat, and the same word twice in a row looks like the display has frozen.
    func word(after elapsed: TimeInterval) -> String {
        let step = Int(max(0, elapsed) / Self.interval)
        return order[step % order.count]
    }
}

// The mark beside the word. Cycling the shape of a star is quieter next to text than a
// spinning indicator, and like the word it keeps moving while the process is silent,
// which is exactly when the row is worth looking at.
struct WorkingGlyph: View {
    private static let frames = ["✳", "✻", "✽", "✻"]
    private static let frameRate: TimeInterval = 0.15

    var animated = true

    var body: some View {
        Group {
            if animated {
                TimelineView(.periodic(from: .now, by: Self.frameRate)) { context in
                    // The absolute clock keeps redraws from restarting the sequence.
                    let step = Int(context.date.timeIntervalSinceReferenceDate / Self.frameRate)
                    Text(Self.frames[abs(step) % Self.frames.count])
                }
            } else {
                Text(Self.frames[0])
            }
        }
        .font(.mono(12))
        .foregroundStyle(Theme.attention)
        // These glyphs are not all the same width, and the text beside them must not
        // shuffle sideways every frame.
        .frame(width: 13, alignment: .center)
    }
}
