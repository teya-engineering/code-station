import Foundation

enum SessionState: Equatable {
    case idle
    case starting
    case streaming
    // Codex reported a transport interruption but its process is still trying to finish
    // the turn. The message is kept visible until progress resumes or the turn ends.
    case reconnecting(String)
    // Codex has produced no output for long enough to be considered unresponsive, with
    // no command, question, or background task that would make silence expected.
    case stalled
    // Stop has been requested, but the process still owns its working directory until
    // termination is confirmed.
    case stopping
    // The turn has answered, but a background task it started is still running. The
    // process is held open so the task's completion can wake the agent again.
    case waiting
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .starting, .streaming, .reconnecting, .stalled, .stopping, .waiting: true
        case .idle, .failed: false
        }
    }
}

// Why a session belongs in the activity menu. A question outranks a run because it tells
// the user there is something to do, and a live run outranks an older unseen completion.
enum SessionNotice: Int, Equatable {
    case needsInput
    case running
    case finished

    init?(isBusy: Bool, needsInput: Bool, finishedUnseen: Bool) {
        if needsInput {
            self = .needsInput
        } else if isBusy {
            self = .running
        } else if finishedUnseen {
            self = .finished
        } else {
            return nil
        }
    }
}

// What the left sidebar can have selected.
enum SidebarSelection: Hashable {
    case home
    case session(UUID)
    case workspace(UUID)
}
