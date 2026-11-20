import Foundation
import Observation

struct DesignImplementationSettings: Equatable {
    var agent: AgentKind
    var settings: SessionSettings

    func applying(to original: SessionSettings?) -> SessionSettings {
        var result = original ?? SessionSettings()
        result.model = settings.model
        result.effort = settings.effort
        result.permissionMode = agent == .claudeCode ? settings.permissionMode : nil
        result.codexSandboxMode = agent == .codex ? settings.codexSandboxMode : nil
        result.copilotAccessMode = agent == .copilot ? settings.copilotAccessMode : nil
        return result
    }
}

@MainActor
@Observable
final class DesignImplementationDraft {
    let catalog: AgentCatalog
    let inherited: DesignImplementationSettings
    private(set) var agent: AgentKind
    private var drafts: [AgentKind: SessionSettings]
    private var followsDefaultModel: Set<AgentKind> = []
    var text = ""
    var isExpanded = false
    private(set) var isStarting = false
    private(set) var failure: DesignHandoffLifecycle.Failure?
    private(set) var effortAdjustment: String?

    init(session: ChatSession, catalog: AgentCatalog) {
        self.catalog = catalog
        agent = session.agent
        let settings = session.settings ?? SessionSettings()
        inherited = DesignImplementationSettings(agent: session.agent, settings: settings)
        drafts = [session.agent: settings]
    }

    var settings: SessionSettings { drafts[agent] ?? SessionSettings() }
    var isInherited: Bool {
        agent == inherited.agent && !followsDefaultModel.contains(agent)
            && DesignImplementationSettings(agent: agent, settings: settings).applying(to: nil)
                == inherited.applying(to: nil)
    }
    var hasAgents: Bool { !catalog.availableAgents.isEmpty }
    var canStart: Bool { !isStarting && catalog.isAvailable(agent) }
    var usesDefaultModel: Bool { followsDefaultModel.contains(agent) }
    var model: String? {
        catalog.validModel(usesDefaultModel ? catalog.defaults(for: agent).model : settings.model, for: agent)
    }
    var effort: String? {
        catalog.validEffort(settings.effort, for: agent, model: model) ?? defaultEffort
    }
    var defaultEffort: String? {
        catalog.validEffort(catalog.defaults(for: agent).effort, for: agent, model: model)
    }
    var effortLevels: [String] { catalog.effortOptions(for: agent, model: model).compactMap(\.id) }
    var effortTitle: String {
        effort.map { catalog.effortTitle($0, for: agent, model: model) } ?? "Default"
    }
    var modelTitle: String { catalog.modelTitle(model) }
    var permission: PermissionMode { settings.permissionMode ?? catalog.defaults(for: agent).permissionMode ?? .fallback }
    var codexAccess: CodexSandboxMode { settings.codexSandboxMode ?? catalog.defaults(for: agent).codexSandboxMode ?? .workspaceWrite }
    var copilotAccess: CopilotAccessMode { settings.copilotAccessMode ?? catalog.defaults(for: agent).copilotAccessMode ?? .workspace }
    var permissionTitle: String {
        switch agent {
        case .claudeCode, .kiro: permission.shortTitle
        case .codex: codexAccess.summary
        case .copilot: copilotAccess.summary
        }
    }
    var permissionDetail: String {
        switch agent {
        case .claudeCode, .kiro: permission.detail(for: agent)
        case .codex: codexAccess.detail
        case .copilot: copilotAccess.detail
        }
    }
    var summaryTitle: String {
        if !hasAgents { return "No agents available" }
        if !catalog.isAvailable(agent) { return "\(agent.title) is unavailable" }
        if isInherited { return "Same agent as the design session" }
        return agent == inherited.agent ? "\(agent.title) with custom settings" : "Implement with \(agent.title)"
    }
    var summaryDetail: String {
        if !hasAgents { return "Install an agent in Settings to implement." }
        if !catalog.isAvailable(agent) { return "Choose another agent or install \(agent.title) in Settings." }
        if isInherited { return "\(agent.title), with the same model, effort and permissions." }
        return "\(modelTitle), \(effortTitle.lowercased()) effort, \(permissionTitle)."
    }

    func reopen() {
        guard !isStarting else { return }
        isExpanded = false
        failure = nil
        catalog.refreshAvailableAgents()
    }

    func chooseAgent(_ agent: AgentKind) {
        guard !isStarting, catalog.isAvailable(agent) else { return }
        if drafts[agent] == nil {
            drafts[agent] = SessionSettings()
            followsDefaultModel.insert(agent)
        }
        self.agent = agent
        effortAdjustment = nil
        validateEffort()
    }

    func chooseModel(_ model: String?, useDefault: Bool = false) {
        guard !isStarting else { return }
        if useDefault { followsDefaultModel.insert(agent) }
        else { followsDefaultModel.remove(agent) }
        edit { $0.model = model }
        validateEffort()
    }

    func edit(_ change: (inout SessionSettings) -> Void) {
        guard !isStarting else { return }
        var updated = settings
        change(&updated)
        drafts[agent] = updated
        effortAdjustment = nil
    }

    func validateEffort() {
        guard !isStarting, let explicit = settings.effort,
              catalog.validEffort(explicit, for: agent, model: model) == nil else { return }
        edit { $0.effort = nil }
        effortAdjustment = "Effort reset to Default. \(modelTitle) does not support \(EffortChoice.summary(of: explicit, agent: agent).lowercased()) effort."
    }

    func reset() {
        guard !isStarting else { return }
        agent = inherited.agent
        drafts[agent] = inherited.settings
        followsDefaultModel.remove(agent)
        effortAdjustment = nil
        isExpanded = false
    }

    func start() -> DesignImplementationSettings? {
        guard canStart else { return nil }
        validateEffort()
        var resolved = settings
        resolved.model = model
        resolved.effort = effort
        resolved.permissionMode = agent == .claudeCode ? permission : nil
        resolved.codexSandboxMode = agent == .codex ? codexAccess : nil
        resolved.copilotAccessMode = agent == .copilot ? copilotAccess : nil
        isStarting = true
        failure = nil
        return DesignImplementationSettings(agent: agent, settings: resolved)
    }

    func finish(_ failure: DesignHandoffLifecycle.Failure? = nil) {
        isStarting = false
        self.failure = failure
    }
}
