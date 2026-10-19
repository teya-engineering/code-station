import Foundation

// How the last turn ended. Kept by the runner, since a turn's start is not written down
// anywhere else.
public struct TurnEnding: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case finished
        // The user asked it to stop.
        case stopped
        case failed
    }

    public let started: Date
    public let ended: Date
    public let outcome: Outcome
    // The commit each working directory had checked out when the turn began, so the
    // turn's own commits can be told apart from the ones before it.
    public var startHeads: [String: String] = [:]

    public var duration: TimeInterval { max(0, ended.timeIntervalSince(started)) }

    // A seal meeting an ending this recent is seeing it happen, so it stamps itself in.
    // Anything older is being read back and is simply there.
    public func isFresh(now: Date = Date()) -> Bool {
        (0..<2).contains(now.timeIntervalSince(ended))
    }

    public init(started: Date, ended: Date, outcome: Outcome, startHeads: [String: String] = [:]) {
        self.started = started
        self.ended = ended
        self.outcome = outcome
        self.startHeads = startHeads
    }
}
