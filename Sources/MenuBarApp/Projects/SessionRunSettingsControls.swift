import SwiftUI

// The settings for the next turn are shared by Chat and Design. Both surfaces use this
// view so a choice has the same meaning and follows the same app default in either mode.
struct SessionRunSettingsControls: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs

    let sessionID: UUID

    var body: some View {
        if let session = store.session(sessionID) {
            let agent = session.agent
            HStack(spacing: 10) {
                modelControl(session, lastRan: session.usage?.model(for: agent))
                effortMenu(agent: agent)
                if agent == .claudeCode {
                    permissionsMenu(agent: agent)
                } else {
                    codexAccessMenu(agent: agent)
                }
            }
        }
    }

    private var sessionSettings: SessionSettings {
        store.session(sessionID)?.settings ?? SessionSettings()
    }

    private func changeSettings(_ edit: (inout SessionSettings) -> Void) {
        var updated = sessionSettings
        edit(&updated)
        store.setSettings(updated, for: sessionID)
    }

    @ViewBuilder private func modelControl(_ session: ChatSession, lastRan: String?) -> some View {
        let settings = sessionSettings
        let agent = session.agent
        let model = ModelChoice.valid(settings.model, for: agent)
        let label = model.map { ModelChoice.title(of: $0) }
            ?? lastRan.map { ModelChoice.shortName(of: $0) }
            ?? "Default model"
        settingMenu(label,
                    overridden: model != nil,
                    help: "The model this session will use for its next turn.",
                    defaultTitle: "Use \(agent.title) default",
                    options: ModelChoice.options(for: agent).compactMap { choice in
                        choice.id.map { (id: $0, title: choice.title) }
                    },
                    selection: Binding(get: { model },
                                       set: { id in chooseModel(id, for: session,
                                                                lastRan: lastRan) }))
    }

    private func chooseModel(_ model: String?, for session: ChatSession, lastRan: String?) {
        let current = ModelChoice.valid(sessionSettings.model, for: session.agent)
        guard model != current else { return }
        guard session.hasAgentConversation else {
            changeSettings { $0.model = model }
            return
        }

        let currentTitle = current.map { ModelChoice.title(of: $0) }
            ?? lastRan.map { ModelChoice.shortName(of: $0) }
            ?? "the \(session.agent.title) default"
        let nextTitle = model.map { ModelChoice.title(of: $0) }
            ?? "the \(session.agent.title) default"
        dialogs.show(.confirm(
            "Change from \(currentTitle) to \(nextTitle)?",
            message: "The next turn will resume this conversation using \(nextTitle). "
                + "The conversation and files stay in place. If this selects a different "
                + "model, cached context may not carry over, so processing the existing "
                + "context can use more input tokens.",
            action: "Change model", kind: .primary) {
                changeSettings { $0.model = model }
            })
    }

    private func effortMenu(agent: AgentKind) -> some View {
        let settings = sessionSettings
        let override = EffortChoice.valid(settings.effort, for: agent)
        let appDefault = EffortChoice.valid(runner.defaults(for: agent).effort, for: agent)
        let chosen = override ?? appDefault
        return settingMenu(
            chosen.map { "\(EffortChoice.summary(of: $0, agent: agent)) effort" }
                ?? "Default effort",
            overridden: override != nil,
            help: "How long the model thinks before it answers.",
            defaultTitle: defaultTitle(
                appDefault.map { EffortChoice.summary(of: $0, agent: agent) }),
            options: EffortChoice.all(for: agent).compactMap { choice in
                choice.id.map { (id: $0, title: choice.title) }
            },
            selection: Binding(get: { override },
                               set: { id in changeSettings { $0.effort = id } }))
    }

    private func permissionsMenu(agent: AgentKind) -> some View {
        let settings = sessionSettings
        let defaults = runner.defaults(for: agent)
        return settingMenu(
            PermissionMode(stored: settings.permissionMode ?? defaults.permissionMode).shortTitle,
            overridden: settings.permissionMode != nil,
            help: "How much the agent asks before it acts.",
            defaultTitle: defaultTitle(
                PermissionMode(stored: defaults.permissionMode).shortTitle),
            options: PermissionMode.allCases.map { (id: $0.rawValue, title: $0.title) },
            selection: Binding(get: { settings.permissionMode },
                               set: { mode in
                                   changeSettings { $0.permissionMode = mode }
                               }))
    }

    private func codexAccessMenu(agent: AgentKind) -> some View {
        let settings = sessionSettings
        let override = CodexSandboxMode.valid(settings.codexSandboxMode)
        let appDefault = CodexSandboxMode.resolved(runner.defaults(for: agent).codexSandboxMode)
        let selected = override ?? appDefault
        return settingMenu(
            selected.summary,
            overridden: override != nil,
            help: selected.detail,
            defaultTitle: defaultTitle(appDefault.title),
            options: CodexSandboxMode.allCases.map { (id: $0.rawValue, title: $0.title) },
            warning: selected == .fullAccess,
            warningOption: CodexSandboxMode.fullAccess.rawValue,
            selection: Binding(get: { override?.rawValue },
                               set: { value in
                                   changeSettings { $0.codexSandboxMode = value }
                               }))
    }

    private func defaultTitle(_ resolved: String?) -> String {
        resolved.map { "Use the default (\($0))" } ?? "Use the default"
    }

    private func settingMenu(_ label: String, overridden: Bool, help: String,
                             defaultTitle: String,
                             options: [(id: String, title: String)],
                             warning: Bool = false,
                             warningOption: String? = nil,
                             selection: Binding<String?>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: overridden ? .semibold : .regular))
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
        }
        .foregroundStyle(warning ? Theme.deletion
                                 : overridden ? Theme.accent : Color.secondary)
        .fixedSize()
        .appMenu {
            var entries: [MenuEntry] = [
                .item(defaultTitle, checked: selection.wrappedValue == nil) {
                    selection.wrappedValue = nil
                },
                .separator,
            ]
            entries += options.map { option in
                MenuEntry.item(option.title,
                               kind: option.id == warningOption ? .destructive : .plain,
                               checked: selection.wrappedValue == option.id,
                               subtitle: option.id == warningOption
                                   ? "No file, service, or network restrictions."
                                   : nil) {
                    selection.wrappedValue = option.id
                }
            }
            return entries
        }
        .appTooltip(overridden ? "\(help) Overridden for this session." : help)
    }
}
