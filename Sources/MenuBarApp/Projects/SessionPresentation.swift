import Foundation

// How a session reads on a screen. Home, a project and a workspace all describe the same
// session, so the state light and the line under the title are worked out here once rather
// than restated on each screen with slightly different wording.
enum SessionActivity {
    // The state is passed in because screens that describe many sessions at once already
    // look it up for their own grouping, and the rail passes a tool it resolved its own way.
    static func line(permission: PermissionRequest?, runningTool: ToolUse?,
                     root: String, lastTool: String?, finished: Bool) -> String {
        if let permission {
            return permission.isQuestion
                ? "waiting on an answer · \(permission.title)"
                : "waiting on \(permission.toolName) permission"
        }
        if let runningTool {
            return ToolPresentationCache.presentation(for: runningTool, projectPath: root).label
        }
        guard let lastTool else { return finished ? "finished" : "not started" }
        return (finished ? "ended after " : "last: ") + lastTool
    }

    // The store owns where a session runs, so the root comes from it rather than from each
    // screen's own idea of the session's folder.
    @MainActor
    static func line(for session: ChatSession, store: ProjectStore,
                     runner: SessionRunner) -> String {
        let busy = runner.state(session.id).isBusy
        return line(permission: runner.question(session.id),
                    runningTool: busy ? runner.runningTool(session.id) : nil,
                    root: store.workingDirectory(for: session) ?? "",
                    lastTool: session.summary.lastTool,
                    finished: store.hasFinished(session.id))
    }
}

extension SessionTone {
    // Every screen reads the tone from the same two places, so the lookup lives here
    // instead of being written out again on each one.
    @MainActor
    init(_ sessionID: UUID, store: ProjectStore, runner: SessionRunner) {
        self.init(busy: runner.state(sessionID).isBusy,
                  needsInput: runner.question(sessionID) != nil,
                  finished: store.hasFinished(sessionID))
    }
}

// The one-line count of what a set of sessions is doing: "2 RUNNING · 1 NEEDS YOU · 3 IDLE".
extension Sequence where Element == SessionTone {
    var tally: String {
        var running = 0, waiting = 0, idle = 0
        for tone in self {
            switch tone {
            case .running: running += 1
            case .needsYou: waiting += 1
            case .idle: idle += 1
            }
        }
        var parts: [String] = []
        if running > 0 { parts.append("\(running) RUNNING") }
        if waiting > 0 { parts.append("\(waiting) NEEDS YOU") }
        if idle > 0 { parts.append("\(idle) IDLE") }
        return parts.joined(separator: " · ")
    }
}
