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

    init(personality: AgentPersonality) {
        self.init(order: personality.workingWords.shuffled())
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

// A quiet sign that a tool call is still alive. One letter dips out at a time, then the
// whole word rests before the next pass, so the status moves without competing with the
// command beside it.
struct RunningWord: View {
    private static let letters = Array("running")
    private static let frameRate: TimeInterval = 0.16
    private static let restingFrames = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                word(activeLetter: nil)
            } else {
                TimelineView(.periodic(from: .now, by: Self.frameRate)) { context in
                    word(activeLetter: Self.activeLetter(at: context.date))
                }
            }
        }
        .scaledMono(10.5)
        .foregroundStyle(.tertiary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("running")
    }

    private func word(activeLetter: Int?) -> some View {
        HStack(spacing: 0) {
            ForEach(Self.letters.indices, id: \.self) { index in
                Text(String(Self.letters[index]))
                    .opacity(index == activeLetter ? 0.2 : 1)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: activeLetter)
    }

    // An absolute clock lets redraws preserve the current pass instead of making the
    // first letter blink again whenever new output arrives.
    private static func activeLetter(at date: Date) -> Int? {
        let frame = Int(date.timeIntervalSinceReferenceDate / frameRate)
            % (letters.count + restingFrames)
        return frame < letters.count ? frame : nil
    }
}
