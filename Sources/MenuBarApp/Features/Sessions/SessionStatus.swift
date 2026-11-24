import SwiftUI

// MARK: - State

// What a session is doing, as the one word and colour the whole app agrees on. Waiting is
// its own state rather than a kind of running: the turn is alive and will pick itself up,
// but nothing is being worked on, and a row that says RUNNING for an hour of that is the
// row that sends someone looking for a hang.
//
// A wait only reads as live while it can still end by itself. Once it has gone stale the
// task holding the turn open is never going to report, so the row joins the ones asking
// for someone rather than sitting on a green light for the rest of the day.
enum SessionTone {
    case running, waiting, needsYou, idle

    init(busy: Bool, needsInput: Bool = false, finished: Bool = false,
         waiting: Bool = false, waitIsStale: Bool = false) {
        if needsInput || finished || (waiting && waitIsStale) {
            self = .needsYou
        } else if waiting {
            self = .waiting
        } else if busy {
            self = .running
        } else {
            self = .idle
        }
    }

    var word: String {
        switch self {
        case .running: "RUNNING"
        case .waiting: "WAITING"
        case .needsYou: "NEEDS YOU"
        case .idle: "IDLE"
        }
    }

    // Waiting shares the live colour with running and is told apart by its light, which
    // does not breathe. Colour says the session is alive; the pulse says it is moving.
    var colour: Color {
        switch self {
        case .running, .waiting: Theme.dotOn
        case .needsYou: Theme.attention
        case .idle: Color.secondary
        }
    }

    // The same colour read as words, or as a thin mark that stands in for them. The light
    // colours sink into a pale card, so these are the ones measured as ink.
    var wordColour: Color {
        switch self {
        case .running, .waiting: Theme.dotOnText
        case .needsYou: Theme.attentionText
        // The system's secondary grey falls short of text contrast on the pale card at
        // the small sizes a state word is set in, so idle is a step darker.
        case .idle: Color(nsColor: .labelColor).opacity(0.72)
        }
    }

    // A card carries its state as a ring rather than a fill, so a column of them reads as
    // one column with a few live rows in it.
    var ring: Color {
        switch self {
        case .running: Theme.dotOn.opacity(0.45)
        case .waiting: Theme.dotOn.opacity(0.3)
        case .needsYou: Theme.attention.opacity(0.5)
        case .idle: Theme.border
        }
    }

    var ringWidth: CGFloat { self == .idle ? 1 : 1.3 }
}

// The state light beside the state word. The avatar already carries motion while a
// session runs, so this stays still and gives the renderer no second animation to drive.
struct StateLight: View {
    let tone: SessionTone
    var size: CGFloat = 6
    // A failed turn shares its tone with anything else that needs the user, and is told
    // apart by wearing the error colour instead.
    var colour: Color?

    var body: some View {
        Circle()
            .fill(colour ?? tone.colour)
            .frame(width: size, height: size)
    }
}

// The state line of a sidebar card, laid as a band across the top of the card so the
// state can be found down a long rail without reading the word. Needs you is striped and
// still, running is striped and drifts, waiting is a plain band. Idle has none, which is
// what makes the other three stand out. The light and the word stay on the band, so the
// state is never carried by colour or pattern alone.
struct StateBand: Equatable {
    let fill: Color
    let stripe: Color?
    let drifts: Bool
    let word: Color
}

extension SessionTone {
    var band: StateBand? {
        switch self {
        case .needsYou:
            StateBand(fill: Theme.attention.opacity(0.14), stripe: Theme.attention.opacity(0.3),
                      drifts: false, word: Theme.attentionText)
        case .running:
            StateBand(fill: Theme.dotOn.opacity(0.1), stripe: Theme.dotOn.opacity(0.16),
                      drifts: true, word: Theme.dotOnText)
        case .waiting:
            StateBand(fill: Theme.dotOn.opacity(0.09), stripe: nil, drifts: false,
                      word: Theme.dotOnText)
        case .idle:
            nil
        }
    }
}

// How many sessions under a folded row want the user. Once the row is open the cards say
// it themselves, so the row drops it.
struct NeedsYouChip: View {
    let count: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.inset)
        Text(verbatim: "\(count)")
            .font(Typography.caps)
            .foregroundStyle(Theme.attentionText)
            .padding(.horizontal, Space.xs)
            .frame(minWidth: 20, minHeight: 16)
            .background {
                ZStack {
                    shape.fill(Theme.attention.opacity(0.16))
                    StripeFill(colour: Theme.attention.opacity(0.34), period: 8)
                        .clipShape(shape)
                }
            }
            .overlay(shape.strokeBorder(Theme.attention.opacity(0.5), lineWidth: 1))
            .fixedSize()
            .appTooltip(Self.label(count))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.label(count))
    }

    static func label(_ count: Int) -> String { "\(count) waiting for you" }
}
