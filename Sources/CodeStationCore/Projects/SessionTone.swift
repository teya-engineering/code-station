import Foundation

// What a session is doing, as the one word the whole app agrees on. Waiting is its own
// state rather than a kind of running: the turn is alive and will pick itself up, but
// nothing is being worked on, and a row that says RUNNING for an hour of that is the row
// that sends someone looking for a hang.
//
// A wait only reads as live while it can still end by itself. Once it has gone stale the
// task holding the turn open is never going to report, so the row joins the ones asking
// for someone rather than sitting on a green light for the rest of the day.
//
// The colours each front end draws a tone in belong to that front end.
public enum SessionTone: Sendable {
    case running, waiting, needsYou, idle

    public init(busy: Bool, needsInput: Bool = false, finished: Bool = false,
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

    // Every screen reads the tone from the same two places, so the lookup lives here
    // instead of being written out again on each one.
    @MainActor
    public init(_ sessionID: UUID, store: ProjectStore, runner: SessionRunner) {
        let live = LiveConversation.id(of: sessionID, store: store, runner: runner)
        self.init(busy: runner.state(live).isBusy || runner.isAskingSecondOpinion(sessionID),
                  needsInput: runner.question(live) != nil,
                  finished: store.isUnread(sessionID),
                  waiting: runner.state(live) == .waiting,
                  waitIsStale: runner.waitIsStale(live))
    }

    public var word: String {
        switch self {
        case .running: "RUNNING"
        case .waiting: "WAITING"
        case .needsYou: "NEEDS YOU"
        case .idle: "IDLE"
        }
    }
}

// The one-line count of what a set of sessions is doing:
// "2 RUNNING · 1 WAITING · 1 NEEDS YOU · 3 IDLE".
extension Sequence where Element == SessionTone {
    public var tally: String {
        var running = 0, waiting = 0, needsYou = 0, idle = 0
        for tone in self {
            switch tone {
            case .running: running += 1
            case .waiting: waiting += 1
            case .needsYou: needsYou += 1
            case .idle: idle += 1
            }
        }
        var parts: [String] = []
        if running > 0 { parts.append("\(running) RUNNING") }
        if waiting > 0 { parts.append("\(waiting) WAITING") }
        if needsYou > 0 { parts.append("\(needsYou) NEEDS YOU") }
        if idle > 0 { parts.append("\(idle) IDLE") }
        return parts.joined(separator: " · ")
    }
}
