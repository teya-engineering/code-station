import Foundation
import Synchronization

public final class StreamBatcher: Sendable {
    public struct Batch: Sendable {
        public var events: [StreamEvent] = []
        public var stderr = ""
        public var stdoutActivity = false
        public var stdoutClosed = false
        public var stderrClosed = false
    }

    private struct State: Sendable {
        public var pending = Batch()
        public var flushScheduled = false
    }
    private let state = Mutex(State())

    public func append(events: [StreamEvent] = [], stderr: String = "",
                stdoutActivity: Bool = false, stdoutClosed: Bool = false,
                stderrClosed: Bool = false) -> Bool {
        state.withLock { state in
            state.pending.events.append(contentsOf: events)
            state.pending.stderr += stderr
            state.pending.stdoutActivity = state.pending.stdoutActivity || stdoutActivity
            state.pending.stdoutClosed = state.pending.stdoutClosed || stdoutClosed
            state.pending.stderrClosed = state.pending.stderrClosed || stderrClosed
            guard !state.flushScheduled else { return false }
            state.flushScheduled = true
            return true
        }
    }

    public func drain() -> Batch {
        state.withLock { state in
            let batch = state.pending
            state = State()
            return batch
        }
    }
}
