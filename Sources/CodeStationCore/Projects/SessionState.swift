import Foundation

public enum SessionState: Equatable {
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

    public var isBusy: Bool {
        switch self {
        case .starting, .streaming, .reconnecting, .stalled, .stopping, .waiting: true
        case .idle, .failed: false
        }
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// Why a session belongs in the activity menu. A question outranks a run because it tells
// the user there is something to do, and a live run outranks an older unseen completion.
public enum SessionNotice: Int, Equatable {
    case needsInput
    case running
    case finished

    public init?(isBusy: Bool, needsInput: Bool, finishedUnseen: Bool) {
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

extension SessionNotice {
    // Why this one is noticed, in the few words that fit under its title: the tool that
    // is asking, the question, or what the finished turn left behind.
    public func reason(question: PermissionRequest?) -> String {
        switch self {
        case .needsInput:
            guard let question else { return "waiting on an answer" }
            return question.isQuestion
                ? "question · \(question.title.lowercased())"
                : "permission · \(question.toolName.lowercased())"
        case .running:
            return "running"
        case .finished:
            return "finished while away"
        }
    }
}

// What the left sidebar can have selected.
public enum SidebarSelection: Hashable {
    case home
    case session(UUID)
    case workspace(UUID)
}
