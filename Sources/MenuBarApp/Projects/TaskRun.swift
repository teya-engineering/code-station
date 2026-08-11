import Foundation

// Running a task is one gesture: a fresh session in the task's folder, with the saved
// prompt already sent. Every screen that offers a Run button goes through here, so a
// task run means the same thing wherever it starts.
@MainActor
enum TaskRun {
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
