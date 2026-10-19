import Foundation

// Which of a session's two conversations a screen is talking about. A Design companion
// lives behind the tab of the session that opened it and has no row anywhere, so that
// session's row is the only place its work can show.
public enum LiveConversation {
    // The companion, when it is the side to describe, and nil when the session speaks for
    // itself. Callers that only need an id use `id(of:store:runner:)`.
    @MainActor
    public static func of(_ sessionID: UUID, store: ProjectStore,
                   runner: SessionRunner) -> ChatSession? {
        guard let companion = store.designCompanions[sessionID] else { return nil }
        // A turn in the visible conversation is the one being read, so it keeps the row
        // even if the companion is running too.
        if runner.state(sessionID).isBusy || runner.question(sessionID) != nil { return nil }
        if runner.state(companion.id).isBusy || runner.question(companion.id) != nil {
            return companion
        }
        // Neither is running, so the row belongs to whichever spoke last. The card already
        // carries the newer of the two times, which is what makes this a comparison rather
        // than another lookup.
        guard let card = store.sidebarSession(sessionID) else { return companion }
        return companion.lastActivity >= card.lastActivity ? companion : nil
    }

    @MainActor
    public static func id(of sessionID: UUID, store: ProjectStore, runner: SessionRunner) -> UUID {
        of(sessionID, store: store, runner: runner)?.id ?? sessionID
    }
}

extension SessionRunner {
    // Whether anything is running for a session, its own turn or the one its Design
    // companion is taking. Counts, sweeps and anything that treats a session as free to
    // clear away have to ask this rather than the session's own state.
    @MainActor
    public func isBusy(_ sessionID: UUID, store: ProjectStore) -> Bool {
        if state(sessionID).isBusy || isAskingSecondOpinion(sessionID) { return true }
        guard let companion = store.designCompanions[sessionID] else { return false }
        return state(companion.id).isBusy
    }

    // A second opinion runs beside the agent rather than as one of its turns, so the
    // session's own state stays idle while a reviewer works. Rows still have to show it
    // as running, or a review that takes minutes looks like nothing is happening.
    @MainActor
    public func isAskingSecondOpinion(_ sessionID: UUID) -> Bool {
        reviews.isReviewing(sessionID)
            || opinions.opinions(sessionID).contains(where: \.isRunning)
            || designOpinions.opinion(sessionID)?.isRunning == true
    }
}

// How a session reads on a screen. Home, a project and a workspace all describe the same
// session, so the state light and the line under the title are worked out here once rather
// than restated on each screen with slightly different wording.
public enum SessionActivity {
    // The state is passed in because screens that describe many sessions at once already
    // look it up for their own grouping, and the rail passes a tool it resolved its own way.
    public static func line(permission: PermissionRequest?, runningTool: ToolUse?,
                     root: String, lastTool: String?, finished: Bool,
                     backgroundTasks: [AgentBackgroundTask] = []) -> String {
        if let permission {
            return permission.isQuestion
                ? "waiting on an answer · \(permission.title)"
                : "waiting on \(permission.toolName) permission"
        }
        // Before the running tool: a held-open turn can still have the call that started
        // the task on the row, and the wait is the truer thing to say about it.
        if !backgroundTasks.isEmpty {
            return "waiting for \(BackgroundTaskPhrase.of(backgroundTasks))"
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
    public static func line(for session: ChatSession, store: ProjectStore,
                     runner: SessionRunner) -> String {
        let live = LiveConversation.of(session.id, store: store, runner: runner) ?? session
        let busy = runner.state(live.id).isBusy
        return line(permission: runner.question(live.id),
                    runningTool: busy ? runner.runningTool(live.id) : nil,
                    root: store.workingDirectory(for: session) ?? "",
                    lastTool: live.summary.lastTool,
                    finished: store.hasFinished(session.id),
                    backgroundTasks: runner.backgroundTasks(live.id))
    }
}

// How the tasks holding a turn open read on a row. One of them is named, because its own
// description is what says whether the wait has an end: a build finishes, a dev server
// does not. Past one, the count is all a single line can carry.
public enum BackgroundTaskPhrase {
    public static func of(_ tasks: [AgentBackgroundTask]) -> String {
        guard let first = tasks.first else { return "a background task" }
        guard tasks.count == 1 else { return "\(tasks.count) background tasks" }
        return first.label
    }
}
