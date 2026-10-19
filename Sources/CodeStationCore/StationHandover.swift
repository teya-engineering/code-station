import Foundation
import Observation

// Handing the station from one host to another (ADR-0003): a daemon to a GUI that has
// just opened, or a quitting GUI to a daemon, so terminals attached to it keep working.
//
// The host handing over tells its clients, refuses new turns and lists the turns still
// running. Only once none is left does it let go: it stops serving, saves, sweeps its
// processes and releases the station lock, and the next host claims it. A running turn
// never moves between processes; sessions resume on the next host as after a restart.

// Where a handover stands, as the host handing over sees it.
public struct StationHandoverStatus: Codable, Equatable, Sendable {
    // Turns still running on the host. It lets go once there are none.
    public let running: [RemoteRunningTurn]

    public init(running: [RemoteRunningTurn]) {
        self.running = running
    }
}

// One turn still running on a host that is handing over: the conversation it runs in (a
// session, or a session's Design conversation) and how to name it.
public struct RemoteRunningTurn: Codable, Equatable, Sendable, Identifiable {
    public let sessionID: String
    public let title: String
    public let project: String

    public var id: String { sessionID }

    public init(sessionID: String, title: String, project: String) {
        self.sessionID = sessionID
        self.title = title
        self.project = project
    }
}

extension StationRefusal {
    static func handingOver(to successor: String) -> StationRefusal {
        StationRefusal("The station is moving to \(successor). Try again in a moment.")
    }

    static let doesNotHandOver = StationRefusal(
        "This station host does not hand the station over. Quit it, then try again.")
}

// The side that takes the station, driving the host that hands it over: the GUI as it
// opens over a daemon, or the GUI handing its own station to a daemon as it quits.
//
// It asks the host to hand over and asks again until no turn is left running, then tells
// it to let go. Turns still running after a short wait are put to the person
// (`isAsking`): wait for them, or stop them. Nothing here claims the lock; whoever runs
// the handover claims it once the host has let go (`StationLock.claimOnceReleased`).
@MainActor
@Observable
public final class StationHandover {
    public enum Phase: Equatable, Sendable {
        // Asking the host, and waiting a moment for turns to end on their own.
        case waiting
        // Turns still run after the short wait: the person chooses to wait or stop them.
        case asking
        // The person chose to wait for them.
        case waitingForTurns
        // The person chose to stop them; waiting for them to go.
        case stopping
        // No turn is left; the host is letting go.
        case releasing
        case released
    }

    public let successor: String
    public private(set) var phase: Phase = .waiting
    // The turns still running on the host, as it last said.
    public private(set) var running: [RemoteRunningTurn] = []

    @ObservationIgnored private let station: any StationInterface
    @ObservationIgnored private let shortWait: Duration
    @ObservationIgnored private let pace: Duration
    // The turns the person chose to stop, and when, while stopping.
    @ObservationIgnored private var stopped: Set<String> = []
    @ObservationIgnored private var stoppingSince: ContinuousClock.Instant?

    // `station` is a client of the host handing over. `successor` names who takes the
    // station, in the words its clients are told.
    public init(station: any StationInterface, successor: String,
                shortWait: Duration = .seconds(3), pace: Duration = .milliseconds(200)) {
        self.station = station
        self.successor = successor
        self.shortWait = shortWait
        self.pace = pace
    }

    // Whether the person is being asked what to do about the turns still running.
    public var isAsking: Bool { phase == .asking }

    // Runs the handover until the host has let go. Throws when the host refuses to hand
    // over. A host that goes away once it is told to let go has done what was asked.
    public func run() async throws(StationRefusal) {
        let started = ContinuousClock.now
        while true {
            running = try await station.handOver(to: successor).running
            if running.isEmpty { break }
            if phase == .waiting, ContinuousClock.now - started >= shortWait {
                phase = .asking
            }
            // A turn that started after the stop (the GUI's own prompt as it quits), or
            // one that will not go, is put to the person again rather than left running
            // with nothing on screen.
            if phase == .stopping, running.contains(where: { !stopped.contains($0.sessionID) })
                || stoppingSince.map({ ContinuousClock.now - $0 >= shortWait }) == true {
                phase = .asking
                stoppingSince = nil
            }
            try? await Task.sleep(for: pace)
        }
        phase = .releasing
        do {
            try await station.releaseStation()
        } catch {
            // Gone before its answer arrived: it let go as told.
            guard error == .hostGone else { throw error }
        }
        phase = .released
    }

    // The person would rather the turns finished.
    public func keepWaiting() {
        guard phase == .asking else { return }
        phase = .waitingForTurns
    }

    // The person would rather not wait: every turn still running is stopped, keeping what
    // it has done so far, and the handover goes on once they have gone.
    public func stopTurns() {
        guard phase == .asking || phase == .waitingForTurns else { return }
        phase = .stopping
        let turns = running
        stopped = Set(turns.map(\.sessionID))
        stoppingSince = .now
        Task { [station] in
            for turn in turns { try? await station.stopTurn(turn.sessionID) }
        }
    }
}
