import Foundation

// Running a task is one gesture: a fresh session in the task's folder, with the saved
// prompt already sent. Every screen that offers a Run button goes through here, so a
// task run means the same thing wherever it starts.
@MainActor
enum TaskRun {
    // A repeatable task can always run again. A one-off keeps its button only until the
    // first run exists, so the sessions themselves are the record of it having run.
    nonisolated static func canRun(repeats: Bool, hasRun: Bool) -> Bool {
        repeats || !hasRun
    }

    static func canRun(_ task: Project, store: ProjectStore) -> Bool {
        task.kind == .adHoc && canRun(repeats: task.task?.repeats ?? false,
                                      hasRun: hasRun(task, store: store))
    }

    static func hasRun(_ task: Project, store: ProjectStore) -> Bool {
        store.sidebarSessions.contains { $0.projectID == task.id && $0.workspaceID == nil }
    }

    @discardableResult
    static func run(_ task: Project, store: ProjectStore, runner: SessionRunner,
                    agentAvatarName: String?) -> Result<ChatSession, PersistenceFailure> {
        let session = store.insertSession(in: task.id, agent: runner.agent,
                                          model: runner.defaults.model,
                                          agentAvatarName: agentAvatarName)
        if case .success(let created) = session {
            let prompt = task.task?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !prompt.isEmpty {
                runner.send(prompt, sessionID: created.id, store: store)
            }
        }
        return session
    }
}
