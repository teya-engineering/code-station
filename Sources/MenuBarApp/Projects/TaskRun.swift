import Foundation

// Running a task is one gesture: a fresh session in the task's folder, with the saved
// prompt already sent. Every screen that offers a Run button goes through here, so a
// task run means the same thing wherever it starts. The task's own run choices win;
// anything it left unset follows the app defaults.
@MainActor
enum TaskRun {
    @discardableResult
    static func run(_ task: Project, store: ProjectStore, runner: SessionRunner,
                    agentAvatarName: String?) -> Result<ChatSession, PersistenceFailure> {
        let agent = runner.agent
        let spec = task.task
        let model = ModelChoice.valid(spec?.model, for: agent)
            ?? runner.defaults(for: agent).model
        let session = store.insertSession(in: task.id, agent: agent,
                                          model: model,
                                          agentAvatarName: spec?.agentAvatarName
                                              ?? agentAvatarName)
        if case .success(let created) = session {
            var settings = created.settings ?? SessionSettings()
            settings.effort = EffortChoice.valid(spec?.effort, for: agent)
            settings.permissionMode = spec?.permissionMode
            settings.codexSandboxMode = spec?.codexSandboxMode
            store.setSettings(settings, for: created.id)
            let prompt = spec?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !prompt.isEmpty {
                runner.send(prompt, sessionID: created.id, store: store)
            }
        }
        return session
    }
}
