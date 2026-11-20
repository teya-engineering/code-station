import Foundation
import Observation

@MainActor
@Observable
final class AgentCatalog {
    var agent: AgentKind {
        didSet { Preferences.setAgent(agent, in: preferences) }
    }
    private var defaultsByAgent: [AgentKind: SessionSettings]
    private(set) var discoveredModels: [AgentKind: [ModelChoice.Option]]
    private var paths: [AgentKind: String]
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let discoversPaths: Bool
    @ObservationIgnored private var modelRefreshIDs: [AgentKind: UUID] = [:]
    @ObservationIgnored private var catalogsAsked: Set<AgentKind> = []

    init(paths: [AgentKind: String]? = nil,
         discoveredModels: [AgentKind: [ModelChoice.Option]] = [:],
         preferences: UserDefaults = .standard) {
        self.preferences = preferences
        agent = Preferences.agent(in: preferences)
        self.discoveredModels = discoveredModels
        defaultsByAgent = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map {
            ($0, Preferences.sessionDefaults(for: $0, in: preferences))
        })
        discoversPaths = paths == nil
        self.paths = paths ?? [:]
        refreshAvailableAgents()
    }

    var designAmbition: DesignAmbition { Preferences.designAmbition(in: preferences) }

    var defaults: SessionSettings {
        get { defaults(for: agent) }
        set { setDefaults(newValue, for: agent) }
    }

    func executable(for agent: AgentKind) -> String? { paths[agent] }

    func defaults(for agent: AgentKind) -> SessionSettings {
        defaultsByAgent[agent] ?? SessionSettings()
    }

    func setDefaults(_ defaults: SessionSettings, for agent: AgentKind) {
        defaultsByAgent[agent] = defaults
        Preferences.setSessionDefaults(defaults, for: agent, in: preferences)
    }

    func isAvailable(_ agent: AgentKind) -> Bool { paths[agent] != nil }

    func refreshAvailableAgents() {
        guard discoversPaths else { return }
        for kind in AgentKind.allCases {
            paths[kind] = ProcessManager.resolve(kind.command)
        }
    }

    // Reads the catalog the first time a picker for this agent is shown, and does nothing
    // on every later showing. Reading starts the agent's CLI, and that CLI may stop on a
    // system prompt for the sign-in it has stored, so the ask waits until a picker is on
    // screen and the person is already looking at that agent.
    func discoverModels(for agent: AgentKind) async {
        guard catalogsAsked.insert(agent).inserted else { return }
        await readModels(for: [agent])
    }

    // Asks every installed CLI that publishes a catalog for its models again, for the
    // refresh button on the Agents settings pane.
    func refreshDiscoveredModels() async {
        catalogsAsked.formUnion(AgentKind.allCases)
        await readModels(for: AgentKind.allCases)
    }

    // A read started while another is still asking wins: the older answer is dropped when
    // it arrives.
    private func readModels(for agents: [AgentKind]) async {
        await withTaskGroup(of: (AgentKind, [ModelChoice.Option]?, UUID).self) { group in
            for agent in agents {
                guard let path = paths[agent] else { continue }
                let id = UUID()
                modelRefreshIDs[agent] = id
                let searchPath = ProcessManager.searchPath
                group.addTask {
                    let models: [ModelChoice.Option]? = switch agent {
                    case .codex: await CodexModelReader.read(at: path, searchPath: searchPath)
                    case .copilot: await CopilotServer.models(at: path, searchPath: searchPath)
                    case .kiro: await KiroCLI.models(at: path, searchPath: searchPath)
                    case .claudeCode: nil
                    }
                    return (agent, models, id)
                }
            }
            for await (agent, models, id) in group {
                guard modelRefreshIDs[agent] == id, let models else { continue }
                discoveredModels[agent] = models
            }
        }
    }

    func modelOptions(for agent: AgentKind) -> [ModelChoice.Option] {
        ModelChoice.options(for: agent, discovered: discoveredModels[agent])
    }

    func validModel(_ id: String?, for agent: AgentKind) -> String? {
        ModelChoice.valid(id, for: agent, discovered: discoveredModels[agent])
    }

    func modelTitle(_ id: String?) -> String {
        ModelChoice.title(of: id, discovered: discoveredModels.values.flatMap { $0 })
    }

    func effortOptions(for agent: AgentKind, model: String?) -> [EffortChoice.Option] {
        EffortChoice.all(for: agent, model: model, discovered: discoveredModels[agent])
    }

    func validEffort(_ id: String?, for agent: AgentKind, model: String?) -> String? {
        EffortChoice.valid(id, for: agent, model: model, discovered: discoveredModels[agent])
    }

    func effortTitle(_ id: String?, for agent: AgentKind, model: String?) -> String {
        EffortChoice.summary(of: id, agent: agent, model: model,
                             discovered: discoveredModels[agent])
    }

    var availableAgents: [AgentKind] {
        AgentKind.allCases.filter(isAvailable)
    }

    func agentForNewSession(selected: AgentKind?) -> AgentKind? {
        if let selected, isAvailable(selected) { return selected }
        if isAvailable(agent) { return agent }
        return availableAgents.first
    }

    var available: Bool { isAvailable(agent) }

}
