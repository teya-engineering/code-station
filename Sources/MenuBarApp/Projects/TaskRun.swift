import Foundation

// Running a task is one gesture: a fresh session in the task's folder, with the saved
// prompt already sent. Every screen that offers a Run button goes through here, so a
// task run means the same thing wherever it starts. The task's own run choices win;
// anything it left unset follows the app defaults.
//
// A prompt with holes in it is filled in first - see TaskTemplate. The values come from
// the run sheet, and what they were is kept on both the task and the run: on the task so
// the next run starts from them, on the run so the list can say what it was about.
@MainActor
enum TaskRun {
    // Whether running has something to ask before it can start.
    static func needsInput(_ task: Project) -> Bool {
        guard let spec = task.task else { return false }
        return !TaskTemplate.inputs(in: spec).isEmpty
    }

    // A scheduled run cannot stop to show the input sheet. It reuses the last answer,
    // then the configured default, and waits if a required value still has no answer.
    static func automaticValues(for task: Project) -> [String: String]? {
        guard let spec = task.task else { return [:] }
        let inputs = TaskTemplate.inputs(in: spec)
        let values = Dictionary(uniqueKeysWithValues: inputs.map { input in
            let key = TaskTemplate.key(input.name)
            return (key, spec.lastValues[key] ?? input.startingValue)
        })
        guard inputs.allSatisfy({ input in
            !input.required || input.isAnswered(values[TaskTemplate.key(input.name)] ?? "")
        }) else { return nil }
        return values
    }

    @discardableResult
    static func run(_ task: Project, values: [String: String] = [:], note: String = "",
                    store: ProjectStore, runner: SessionRunner,
                    agentAvatarName: String?) -> Result<ChatSession, PersistenceFailure> {
        let spec = task.task
        let agent = spec?.agent ?? runner.agent
        let model = ModelChoice.valid(spec?.model, for: agent)
            ?? runner.defaults(for: agent).model
        if var spec, !values.isEmpty {
            spec.lastValues = values
            store.setTaskSpec(spec, for: task.id)
        }
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
            if !values.isEmpty { store.setTaskValues(values, for: created.id) }
            let prompt = prompt(for: spec, values: values, note: note)
            if !prompt.isEmpty {
                runner.send(prompt, sessionID: created.id, store: store)
            }
        }
        return session
    }

    // The note is whatever the run sheet was told on top of the template, so it comes
    // last, after everything the task always says.
    static func prompt(for spec: TaskSpec?, values: [String: String],
                       note: String) -> String {
        guard let spec else { return "" }
        let rendered = TaskTemplate.render(spec, values: values)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if extra.isEmpty { return rendered }
        return rendered.isEmpty ? extra : rendered + "\n\n" + extra
    }
}
